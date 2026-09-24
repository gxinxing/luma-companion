import SwiftUI
import LumaCore

/// 眼镜的感知入口与蜂群运行证据。页面只展示中台真实快照，不合成蜂的动作。
struct DeviceView: View {
    @EnvironmentObject private var link: GlassesLink
    @AppStorage("swarm.baseURL") private var swarmURL: String = SwarmLink.defaultBaseURL
    @State private var snapshot: SwarmLink.SwarmSnapshot?
    @State private var snapshotError: String?
    @State private var swarmStatus: String?
    @State private var uploading = false
    @State private var showSettings = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    journeyCard
                    runCard
                    evidenceGrid
                    perceptionCard
                    uploadCard
                    deviceCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 130)
            }
            .background(Color.lumaBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await refresh() }
        }
        .onAppear { startRefresh() }
        .onDisappear { refreshTask?.cancel(); refreshTask = nil }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("LUMA / SWARM")
                    .font(.caption2.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(.lumaAccent)
                Text("让感知进入蜂群")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                Text("从眼镜的一帧，到 Jev 的判断，再到音乐的变化。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 42, height: 42)
                    .background(Color.lumaSurface, in: Circle())
            }
            .accessibilityLabel("刷新蜂群状态")
        }
    }

    private var journeyCard: some View {
        HStack(spacing: 0) {
            journeyStep("眼镜", icon: "eyeglasses")
            journeyArrow
            journeyStep("感知", icon: "viewfinder")
            journeyArrow
            journeyStep("Jev", icon: "sparkle")
            journeyArrow
            journeyStep("音乐", icon: "music.note")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 10)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.lumaStroke, lineWidth: 1))
    }

    private func journeyStep(_ title: String, icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.lumaAccent)
                .frame(height: 24)
            Text(title).font(.caption2.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }

    private var journeyArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("当前演出").font(.headline)
                Spacer()
                Text(snapshot?.status == "running" ? "运行中" : "未确认")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot?.status == "running" ? .lumaAccent : .secondary)
            }
            if let snapshot {
                line("Jev 模型", snapshot.apiConfigured && snapshot.aiStatus == "ready" ? "已就绪" : "未就绪 / 未确认")
                line("设备输入", snapshot.deviceStatus == "not_connected" ? "尚未进入这场演出" : "已接入")
                if let stimulus = snapshot.lastStimulusId {
                    line("最近刺激", String(stimulus.prefix(12)) + "…")
                }
            } else {
                Text(snapshotError ?? "正在读取运行快照…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var evidenceGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本轮证据").font(.headline)
                Spacer()
                Text("来自中台账本")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                metric("Jev 调用", snapshot?.modelCalls)
                metric("蜂群判断", snapshot?.decisions)
            }
            HStack(spacing: 10) {
                metric("已应用蜂", snapshot?.appliedBees)
                metric("音乐痕迹", snapshot?.traceCount)
            }
            Text("未采集的指标显示 —；数字不代表艺术质量或自主进化已完成。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 29, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var perceptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("感知正在发生什么").font(.headline)
            line("眼镜", link.phase.isConnected ? "蓝牙已连接" : "等待连接")
            line("拍摄", link.lastCaptureAt.map { "最近 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚无照片")
            line("进化", snapshot?.generation.map { "乐句第 \($0) 代" } ?? "未采集")
            Text("目前拍照由人触发；持续自主采集与语音感知尚未接入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(20)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("把这一帧送入蜂群").font(.headline)
            Text("手机只发送照片特征。Jev 眼镜 Agent 会判断是否值得通知蜂群；原始照片保留在手机。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("中台地址", text: $swarmURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(13)
                .background(Color.lumaBackground, in: RoundedRectangle(cornerRadius: 12))
            Button { uploadLatestCapture() } label: {
                HStack {
                    if uploading { ProgressView().tint(.black) }
                    else { Image(systemName: "sparkles") }
                    Text(uploading ? "Jev 正在判断…" : "交给 Jev 判断")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.lumaAccent)
            .foregroundStyle(.black)
            .disabled(uploading || link.lastCapture == nil)
            if link.lastCapture == nil {
                Text("先在感知页获取一张照片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let swarmStatus {
                Text(swarmStatus)
                    .font(.caption)
                    .foregroundStyle(swarmStatus.hasPrefix("失败") ? .lumaRecording : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var deviceCard: some View {
        DisclosureGroup("设备详情", isExpanded: $showSettings) {
            VStack(spacing: 12) {
                line("连接", connectionText)
                line("电量", link.batteryPercent.map { "\($0)%" } ?? "—")
                line("固件", link.firmware ?? "—")
                line("项目 / 客户", link.project ?? "—")
                if let states = link.switchStates {
                    line("指示灯", Self.ledText(states.led))
                    line("佩戴检测", Self.onOff(states.wearDetection))
                    line("语音唤醒", Self.onOff(states.voiceCommand))
                    line("佩戴方向", Self.orientationText(states.orientation))
                }
                Button(link.phase.isConnected ? "断开眼镜" : "重新连接") {
                    if link.phase.isConnected { link.disconnect() }
                    else { link.start() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(link.phase.isConnected ? .lumaRecording : .lumaAccent)
            }
            .padding(.top, 16)
        }
        .font(.headline)
        .padding(20)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var connectionText: String {
        switch link.phase {
        case .connected: link.deviceName ?? "已连接"
        case .scanning: "正在寻找眼镜"
        case .connecting, .discovering: "正在连接"
        case .failed(let reason): reason
        case .bluetoothOff(let reason): "蓝牙不可用（\(reason)）"
        case .idle: "未连接"
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func refresh() async {
        do {
            let latest = try await SwarmLink.fetchSnapshot(baseURL: swarmURL)
            guard !Task.isCancelled else { return }
            snapshot = latest
            snapshotError = nil
        } catch {
            guard !Task.isCancelled else { return }
            snapshotError = "中台暂不可达：\(error.localizedDescription)"
        }
    }

    private func uploadLatestCapture() {
        guard !uploading, let data = link.lastCapture else { return }
        let capturedAt = link.lastCaptureAt ?? Date()
        let deviceName = link.deviceName ?? GlassesLink.fallbackDeviceName
        uploading = true
        swarmStatus = "正在确认演出并交给 Jev 眼镜 Agent…"
        Task {
            defer { uploading = false }
            do {
                let runId = try await SwarmLink.currentRunID(baseURL: swarmURL)
                let message = try await SwarmLink.sendCaptureToAgent(
                    data,
                    deviceName: deviceName,
                    baseURL: swarmURL,
                    runId: runId,
                    capturedAt: capturedAt
                )
                swarmStatus = message
                await refresh()
            } catch {
                swarmStatus = "失败：\(error.localizedDescription)"
            }
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
        case let .some(raw): "未知 (\(raw))"
        }
    }
}
