import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var link: GlassesLink
    @State private var recentCaptures: [URL] = []
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    connectionCard
                    previewCard
                    captureAction
                    if let failure = link.captureFailure {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.lumaRecording)
                    }

                    if let latest = recentCaptures.first {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("最近拍摄").font(.headline)
                                Spacer()
                                Text("右滑存相册 · 左滑删除")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            SwipeableCaptureCard(
                                captureURL: latest,
                                onDelete: { url in
                                    if CaptureStore.delete(url) {
                                        ImageDecodeCache.invalidate(url.path)
                                        showToast("已删除")
                                        refreshCaptures()
                                    } else {
                                        showToast("删除失败")
                                    }
                                },
                                onSave: { url in
                                    showToast("保存中…")
                                    Task {
                                        let saved = await CaptureStore.saveToPhotosFromDisk(url)
                                        showToast(saved ? "已保存到系统相册" : "保存失败，请检查相册权限")
                                    }
                                }
                            )
                            .id(latest)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 110)
            }
            .background(Color.lumaBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            .onAppear { refreshCaptures() }
            .onChange(of: link.lastCaptureAt) { refreshCaptures() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("LUMA / CAPTURE")
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.lumaAccent)
            Text("捕捉眼前")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("从眼镜取回这一刻，留下你看见的。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: link.phase.isConnected ? "checkmark" : "eyeglasses")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(link.phase.isConnected ? .black : .lumaAccent)
                .frame(width: 46, height: 46)
                .background(link.phase.isConnected ? Color.lumaAccent : Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(link.phase.isConnected ? "眼镜已连接" : "等待眼镜连接")
                    .font(.subheadline.weight(.semibold))
                Text(connectionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if let battery = link.batteryPercent, link.phase.isConnected {
                Text("\(battery)%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.lumaAccent)
            } else if !link.phase.isWorking && !link.phase.isConnected {
                Button("重试") { link.start() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.lumaAccent)
            }
        }
        .padding(16)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.lumaStroke, lineWidth: 1))
    }

    private var connectionDetail: String {
        switch link.phase {
        case .idle: "打开眼镜后轻点重试"
        case .bluetoothOff(let reason): reason == "unsupported" ? "模拟器不支持蓝牙；请在 iPhone 上使用" : "请打开 iPhone 蓝牙"
        case .scanning: "正在寻找附近的眼镜…"
        case .connecting: "正在建立蓝牙连接…"
        case .discovering: "正在读取设备能力…"
        case .connected: link.deviceName ?? "蓝牙连接正常"
        case .failed(let reason): reason
        }
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.lumaSurface)
            if let data = link.lastCapture {
                CachedImage(data: data, key: "lastCapture.\(link.lastCaptureAt?.timeIntervalSince1970 ?? 0)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 46, weight: .ultraLight))
                        .foregroundStyle(.lumaAccent)
                    Text("等待第一张照片")
                        .font(.subheadline.weight(.medium))
                    Text("按下快门后，眼镜会通过蓝牙回传预览")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 26)
            }
        }
        .frame(height: 285)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle().fill(.lumaAccent).frame(width: 6, height: 6)
                Text("最近一帧")
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
                if let at = link.lastCaptureAt {
                    Text("· \(at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.58), in: Capsule())
            .padding(14)
        }
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.lumaStroke, lineWidth: 1))
    }

    private var captureAction: some View {
        Button { link.takePhoto() } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.isTransferringCapture ? "正在接收照片" : "拍下一刻")
                        .font(.headline)
                    Text(link.isTransferringCapture ? "请稍候" : "蓝牙回传预览，无需热点")
                        .font(.caption)
                        .opacity(0.7)
                }
                Spacer()
                if link.isTransferringCapture { ProgressView().tint(.black) }
                else { Image(systemName: "arrow.up.right").font(.subheadline.weight(.bold)) }
            }
            .foregroundStyle(.black)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(link.phase.isConnected ? Color.lumaAccent : Color.lumaAccent.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
        }
        .disabled(!link.phase.isConnected || link.isTransferringCapture)
        .accessibilityLabel("拍摄")
    }

    private func refreshCaptures() { recentCaptures = CaptureStore.captures() }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == text { toast = nil }
        }
    }
}
