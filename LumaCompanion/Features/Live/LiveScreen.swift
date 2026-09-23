//
//  LiveScreen.swift
//  实时画面：眼镜摄像头，全屏取景器。
//
//  视图层刻意薄：`LiveStreamSession`（Services/，原样来自 LumaDemo）做整个 §12/§14
//  的拉起并发布解码好的 `CMSampleBuffer`；这里只把它们塞进
//  `AVSampleBufferDisplayLayer`（硬解）。没有任何协议字节到达此文件。
//
//  与 demo 版的差异：去掉步骤清单和统计列表，换成取景器 + 一行状态 + 停止键。
//  离开 tab（onDisappear）必须 stop() —— 否则眼镜停在热点模式、摄像头一直供电。
//

import AVFoundation
import Combine
import CoreMedia
import SwiftUI
import LumaCore

struct LiveScreen: View {
    @StateObject private var session: LiveStreamSession
    @EnvironmentObject private var link: GlassesLink
    /// 用户点过「停止」后，phase 抖动/重连触发的 `onChange` 不得把推流悄悄拉起来
    /// —— 重启的主动权只在用户手里（重进 tab 或点重试）。
    @State private var userStopped = false

    init(link: GlassesLink) {
        _session = StateObject(wrappedValue: LiveStreamSession(link: link))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 12) {
                    // ——— Viewfinder ———
                    ZStack {
                        Color.black
                        LiveVideoView(frames: session.frames)
                        if !session.isStreaming {
                            VStack(spacing: 8) {
                                if session.failure == nil && link.phase.isConnected {
                                    ProgressView().tint(.white).controlSize(.large)
                                }
                                Text(headline)
                                    .font(.callout)
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                        }
                        if let hint = session.joinHint {
                            Text(hint)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 10)
                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                                .padding(.top, 8)
                        }
                        if session.isStreaming {
                            VStack {
                                Spacer()
                                StatsOverlay(session: session)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)   // 1600 × 1200
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 16)

                    // ——— One line of state, not a lab panel ———
                    VStack(spacing: 6) {
                        if let failure = session.failure {
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.lumaRecording)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                            Button("重试") { session.start() }
                                .font(.subheadline)
                        } else {
                            Text(session.isStreaming ? "实时画面 · \(session.dimensions.map { "\($0.width)×\($0.height)" } ?? "")"
                                 : stepText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if session.isStreaming {
                            Button("停止") {
                                userStopped = true
                                session.stop()
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.lumaRecording)
                        } else if session.finished {
                            // 停止之后必须给一条明确的回头路。只看 step 的话这里会留一个
                            // 按不动的「取消」（stop() 被 finished 挡住，什么都不做），
                            // 用户除了重进 tab 无事可做。
                            Button("重新开始") {
                                userStopped = false
                                session.start()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!link.phase.isConnected)
                        } else if session.step != .openingWifi {
                            Button("取消") {
                                userStopped = true
                                session.stop()
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.secondary)
                        } else if !link.phase.isConnected {
                            StatusPill()
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("实时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onAppear {
            // 重进 tab 视为一次新的主动请求，恢复自动开播资格
            userStopped = false
            // 未连接时启动只会白等 15 秒然后报错——等连接建立后再自动开播
            if link.phase.isConnected { session.start() }
        }
        // iOS 17 起带单个参数的 onChange 已废弃，改两参形式（语义完全一致）。
        .onChange(of: link.phase) { _, phase in
            if phase.isConnected && !userStopped { session.start() }
        }
        // App 退到后台后 iPhone 会挂起 UDP 与 TCP，回来时链路已经是死的；而在这期间
        // 眼镜正开着热点、摄像头持续供电。退后台等同于离开 tab，走同一套收尾。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            userStopped = true
            session.stop()
        }
        // TEARDOWN + 0x44 + leave the network, whichever way the tab is left.
        .onDisappear { session.stop() }
    }

    private var headline: String {
        if !link.phase.isConnected {
            return "眼镜未连接 —— 先回「拍摄」页等它连上"
        }
        if let failure = session.failure { return failure }
        return stepText
    }

    private var stepText: String {
        switch session.step {
        case .openingWifi: "正在打开眼镜热点"
        case .awaitingSsid: "等待网络名称"
        case .joining: "正在加入网络"
        case .handshaking: "正在建立实时连接"
        case .streaming: "实时画面"
        }
    }
}

// MARK: - The display layer

/// A `UIViewRepresentable` around `AVSampleBufferDisplayLayer`.
///
/// The layer is the decoder: hand it sample buffers whose format description was built from
/// the stream's own SPS and PPS and it decodes in hardware. Everything upstream of here has
/// already been done by the crate and `VideoPipeline`.
struct LiveVideoView: UIViewRepresentable {
    let frames: PassthroughSubject<CMSampleBuffer, Never>

    func makeUIView(context: Context) -> SampleBufferView {
        let view = SampleBufferView()
        context.coordinator.attach(to: view, frames: frames)
        return view
    }

    func updateUIView(_ uiView: SampleBufferView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var cancellable: AnyCancellable?

        func attach(to view: SampleBufferView, frames: PassthroughSubject<CMSampleBuffer, Never>) {
            cancellable = frames.sink { [weak view] sample in
                view?.enqueue(sample)
            }
        }
    }

    /// A `UIView` whose backing layer IS the display layer, so there is no second layer to
    /// keep in sync with the view's bounds.
    final class SampleBufferView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

        private var displayLayer: AVSampleBufferDisplayLayer {
            layer as! AVSampleBufferDisplayLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            displayLayer.videoGravity = .resizeAspect
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func enqueue(_ sample: CMSampleBuffer) {
            let renderer = displayLayer.sampleBufferRenderer
            // A decode failure latches; flushing clears it so the next keyframe can start
            // the picture again rather than the view staying frozen for good.
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }
}

// MARK: - Readouts

private struct StatsOverlay: View {
    @ObservedObject var session: LiveStreamSession

    var body: some View {
        HStack(spacing: 12) {
            Label(String(format: "%.0f fps", session.stats.fps), systemImage: "speedometer")
            if let dimensions = session.dimensions {
                Text("\(dimensions.width)×\(dimensions.height)")
            }
            Spacer()
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(8)
    }
}
