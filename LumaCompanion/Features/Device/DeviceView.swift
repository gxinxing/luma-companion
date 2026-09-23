//
//  DeviceView.swift
//  设备页：电量、固件、身份、设置快照、断开。
//
//  只读：V1 不做设置写入（binding 也还没有 setter），把眼镜当前的十条设置原样展示。
//

import SwiftUI
// 设置快照里的枚举（`FfiGlassesOrientation`）要用中文在原页翻译出来，就得点名它的类型。
import LumaCore

struct DeviceView: View {
    @EnvironmentObject private var link: GlassesLink
    @AppStorage("swarm.baseURL") private var swarmURL: String = SwarmLink.defaultBaseURL
    @AppStorage("swarm.operatorToken") private var swarmToken: String = ""
    @State private var swarmStatus: String?
    /// 上传中防重入：连点会并发打多次 /api/stimuli。
    @State private var uploading = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                firmwareSection
                settingsSection
                swarmSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            row("状态") {
                switch link.phase {
                case .connected: Text("已连接").foregroundStyle(.green)
                case .scanning: Text("正在寻找眼镜…")
                case .connecting, .discovering: Text("正在连接…")
                case .idle: Text("未连接")
                case .bluetoothOff(let reason): Text("蓝牙不可用（\(reason)）")
                case .failed(let reason): Text("失败：\(reason)").foregroundStyle(.lumaRecording)
                }
            }
            if let name = link.deviceName { row("设备") { Text(name) } }
            row("眼镜电量") {
                if let battery = link.batteryPercent {
                    Text("\(battery)%\(link.charging ? " · 充电中" : "")")
                        .monospacedDigit()
                } else { Text("—") }
            }
            if link.phase.isConnected {
                Button("断开眼镜", role: .destructive) { link.disconnect() }
            } else {
                Button("重新连接") { link.start() }
            }
        } header: {
            Text("连接")
        }
    }

    private var firmwareSection: some View {
        Section {
            row("固件") { Text(link.firmware ?? "—") }
            row("项目 / 客户") { Text(link.project ?? "—") }
            row("设置快照") {
                Text(link.settingsComplete ? "已同步" : link.phase.isConnected ? "同步中…" : "—")
                    .foregroundStyle(link.settingsComplete ? .green : .secondary)
            }
        } header: {
            Text("眼镜信息")
        } footer: {
            Text("连接后自动读取；设置快照来自握手时的十帧设置广播。")
        }
    }

    private var swarmSection: some View {
        Section {
            TextField("中台地址", text: $swarmURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.callout)
            SecureField("操作员令牌（ARIA_OPERATOR_TOKEN）", text: $swarmToken)
                .font(.callout)
            Button {
                uploadLatestCapture()
            } label: {
                if uploading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("上传中…")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("上传最近一张到蜂群", systemImage: "arrow.up.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(uploading || !link.phase.isConnected || link.lastCapture == nil)
            if let swarmStatus {
                Text(swarmStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("蜂群中台")
        } footer: {
            Text("把眼镜拍到的画面作为 device 刺激送进演出（需要中台有运行中的场次和操作员令牌）。")
        }
    }

    private func uploadLatestCapture() {
        guard !uploading, let data = link.lastCapture else { return }
        uploading = true
        swarmStatus = "正在读取运行场次…"
        Task {
            defer { uploading = false }
            do {
                let runId = try await SwarmLink.currentRunID(baseURL: swarmURL)
                let message = try await SwarmLink.sendCapture(
                    data,
                    deviceName: link.deviceName ?? GlassesLink.fallbackDeviceName,
                    baseURL: swarmURL,
                    token: swarmToken,
                    runId: runId,
                    sequence: Int(Date().timeIntervalSince1970),
                    capturedAt: link.lastCaptureAt ?? Date()
                )
                swarmStatus = message
            } catch {
                swarmStatus = "失败：\(error.localizedDescription)"
            }
        }
    }

    private var settingsSection: some View {
        Section {
            if let states = link.switchStates {
                row("指示灯") { Text(Self.ledText(states.led)) }
                row("单段录制时长") {
                    Text(states.recordSeconds.map { "\($0) 秒" } ?? "…")
                }
                row("佩戴检测") { Text(Self.onOff(states.wearDetection)) }
                row("语音唤醒") { Text(Self.onOff(states.voiceCommand)) }
                // `"\($0)"` 在 LocalizedStringKey 里插的是调试描述，屏幕上显示的是
                // `portrait` / `landscape` 这种英文 case 名 —— 中文界面里这是错别字，
                // 编译器也就此给了废弃告警。
                row("佩戴方向") { Text(Self.orientationText(states.orientation)) }
                row("手势绑定") {
                    let bound = (states.gestures.compactMap { $0 }).count
                    Text("\(bound) / \(states.gestures.count) 个已绑定")
                }
            } else {
                Text("连接后显示设置快照")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("设置（只读）")
        }
    }

    private func row(
        _ label: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            value().font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private static func onOff(_ value: Bool?) -> String {
        switch value {
        case .some(true): "开启"
        case .some(false): "关闭"
        case .none: "…"
        }
    }
    private static func orientationText(_ value: FfiGlassesOrientation?) -> String {
        switch value {
        case .some(.portrait): "竖拍"
        case .some(.landscape): "横拍"
        case .none: "…"
        }
    }
    private static func ledText(_ value: UInt8?) -> String {
        switch value {
        case .some(0): "关闭"
        case .some(1): "低亮度"
        case .some(2): "高亮度"
        case .none: "…"
        // 这里不用 `value!`：现在的 case 排布保证了非空，但只要有人改动这条 switch，
        // 一个 `!` 就会把整个设备页变成崩溃。绑定一次，说人话一次。
        case let .some(raw): "未知 (\(raw))"
        }
    }
}
