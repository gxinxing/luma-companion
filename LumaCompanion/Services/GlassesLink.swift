//
//  GlassesLink.swift
//  The whole radio. Everything protocol-shaped comes from `LumaCore`.
//
//  Product edition of the LumaDemo link. Differences from the demo:
//
//    * Discovery by NAME FALLBACK as well as advertised service. This unit (E06-00F7)
//      does not list AA12 in its advertisement, so a service-filtered scan never sees it
//      (verified 2026-09-22 over the Python connector). We scan unfiltered, match on the
//      advertised service OR the remembered device name, and validate the GATT table after
//      connecting before declaring the glasses found.
//    * An explicit `Phase` state machine instead of a string, so the UI can render
//      "scanning / connecting / connected / failed" without stringly comparisons — and the
//      user always sees WHY nothing is happening.
//    * Auto-connect on launch and bounded auto-reconnect after an unexpected drop.
//      The stock app's silent-failure connect loop is the single biggest complaint in the
//      reverse-engineering notes (eyevue-audit/报告.md §5); this is the fix.
//    * AA15 is routed to a `GlassesFileReassembler`, so a photo taken with
//      `take_photo(ai)` arrives as bytes here and is published as `lastCapture`.
//
//  No UUID is typed here (`glassesGatt()` owns them), no frame is built here (the
//  `glasses*` builders do), no byte is interpreted here (`GlassesParser` does that).
//

import Combine
import CoreBluetooth
import Foundation
import LumaCore

@MainActor
final class GlassesLink: NSObject, ObservableObject {

    /// The one connection state the whole app renders from. Written on the main actor only.
    enum Phase: Equatable {
        case idle
        case bluetoothOff(String)
        case scanning
        case connecting
        case discovering
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
        var isWorking: Bool { self == .scanning || self == .connecting || self == .discovering }
    }

    // MARK: - State the UI renders

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var deviceName: String?
    @Published private(set) var batteryPercent: UInt8?
    @Published private(set) var charging = false
    @Published private(set) var firmware: String?
    @Published private(set) var project: String?
    @Published private(set) var settingsComplete = false
    /// The ten-frame settings burst, once it has arrived. Device page renders this.
    @Published private(set) var switchStates: FfiGlassesSwitchStates?

    /// The SSID from the most recent `.wifiCredentials` event. The Wi-Fi flows clear it
    /// before they write `0x39`/`0x67` so they never join yesterday's network.
    @Published private(set) var wifiSSID: String?

    /// The most recent photo that arrived over BLE (the small "AI" JPEG), and when it
    /// landed. Published as raw JPEG `Data` — the view turns it into an image.
    @Published private(set) var lastCapture: Data?
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var isTransferringCapture = false

    /// Every parsed control event, as it arrives. The Live and Memories flows subscribe
    /// rather than reach for a peripheral, which keeps this the single CoreBluetooth owner.
    let events = PassthroughSubject<FfiGlassesEvent, Never>()

    // MARK: - Radio + protocol

    private let gatt = glassesGatt()
    private lazy var serviceUUID = CBUUID(string: gatt.service)
    private lazy var writeUUID = CBUUID(string: gatt.write)
    private lazy var controlNotifyUUID = CBUUID(string: gatt.controlNotify)
    private lazy var fileNotifyUUID = CBUUID(string: gatt.fileNotify)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    /// One parser for the control stream (AA14). Voice, settings, battery — everything
    /// but file frames — flows through here.
    private var parser = GlassesParser()
    /// One reassembler for the file stream (AA15). A photo's bytes come off in fragments
    /// framed with 0x97/0x99; this turns them back into one `Data`.
    private var reassembler = GlassesFileReassembler()

    /// **One parser per characteristic** in the demo was about independence of the two
    /// streams; here the split is by role, and each object is reset per connection.
    private func resetProtocolState() {
        parser = GlassesParser()
        reassembler = GlassesFileReassembler()
    }

    // MARK: - Remembered device + auto-reconnect

    private static let rememberedIDDefaultsKey = "glasses.link.device.uuid"
    private static let rememberedNameDefaultsKey = "glasses.link.device.name"

    /// The advertised name to look for when nothing is remembered. E06-00F7 is the unit
    /// this project has verified against.
    static let fallbackDeviceName = "E06-00F7"

    private static func rememberedID() -> UUID? {
        UserDefaults.standard.string(forKey: rememberedIDDefaultsKey).flatMap(UUID.init(uuidString:))
    }
    private static func rememberedName() -> String {
        UserDefaults.standard.string(forKey: rememberedNameDefaultsKey) ?? fallbackDeviceName
    }
    private func remember(_ p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.rememberedIDDefaultsKey)
        if let name = p.name { UserDefaults.standard.set(name, forKey: Self.rememberedNameDefaultsKey) }
    }

    private var wantsConnection = false
    private var userDisconnected = false
    private var reconnectAttempts = 0
    /// 重连预算是「时间窗口」而非次数上限：这台眼镜的 BLE 广播是间歇性的（实测可能
    /// 1–2 分钟才广播一轮），现场观众还会反复开关机——旧的「5 次 × 2 秒」在眼镜下一次
    /// 广播到来之前就放弃了。改为约 5 分钟内持续但温和地找：`maxReconnectAttempts`
    /// 轮 × `reconnectInterval` 秒（30 × 10 s），每轮只发起一次扫描/直连，不空转也不
    /// 轰炸射频；窗口内 phase 保持可见，扫到/连上立即恢复（成功时 `reconnectAttempts`
    /// 清零），窗口用尽才报告一个可解释的失败。
    private static let maxReconnectAttempts = 30
    private static let reconnectInterval: TimeInterval = 10
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Writes (FIFO over ATT Write Requests)

    /// One slot per in-flight `.withResponse` write, in issue order — ATT acknowledges
    /// in FIFO, so ack #1 belongs to slot #1. Two kinds of writes share AA13: flow
    /// writes (`write()`, which await their own ack) and fire-and-forget `send()`s
    /// (interrogate / takePhoto / interruptVoice). An undiscriminated
    /// "resume the first waiter" lets a `send()`'s ack resume some flow's continuation
    /// early and corrupt handshake ordering — so every slot records whether its ack is
    /// owed to a waiter.
    private enum PendingWrite {
        case waiter(CheckedContinuation<Void, Never>)
        case untracked
    }
    private var pendingWrites: [PendingWrite] = []

    // MARK: - Init

    override init() {
        super.init()
        // "记忆"的第一层：重启后拍摄页仍有最近一张（连不上眼镜也能翻到）。
        if let saved = CaptureStore.latest() {
            lastCapture = saved.data
            lastCaptureAt = saved.at
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Called once at app launch. Connects as soon as Bluetooth is on; retries by itself
    /// after an unexpected drop, until `maxReconnectAttempts` gives up and reports a
    /// failure the user can see and retry.
    func start() {
        wantsConnection = true
        userDisconnected = false
        reconnectAttempts = 0
        // 取消可能还在飞的重连任务，避免旧任务与新 start 并发发起两次连接
        reconnectTask?.cancel()
        reconnectTask = nil
        // 已连接 / 正在连接握手时重复 start 是空操作（「重新连接」按钮可能被连点）
        guard phase != .connected, !phase.isWorking else { return }
        switch central.state {
        case .poweredOn:
            beginConnectAttempt()
        default:
            phase = .bluetoothOff(Self.label(central.state))
        }
    }

    // MARK: - Commands the UI can fire

    func startScan() {
        guard central.state == .poweredOn else {
            phase = .bluetoothOff(Self.label(central.state))
            return
        }
        wantsConnection = true
        userDisconnected = false
        reconnectAttempts = 0
        // 上一轮的重连任务若还在 10 秒计时中，到点会再发起一次 beginConnectAttempt，
        // 与这里的直接扫描撞车（双连接尝试）。
        reconnectTask?.cancel()
        reconnectTask = nil
        scan()
    }

    func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        phase = .connecting
        deviceName = p.name
        central.connect(p)
    }

    /// User-visible disconnect: no auto-reconnect afterwards. `0x56` is the only thing that
    /// closes the mic on this firmware — write it unconditionally on the way out.
    func disconnect() {
        wantsConnection = false
        userDisconnected = true
        reconnectTask?.cancel()
        send("interruptVoice", glassesInterruptVoice())
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetConnectionState()
        phase = .idle
    }

    /// Take a photo. `forAi: true` (the default) has the glasses push the small JPEG back
    /// over BLE — it lands in `lastCapture`. The full-resolution file goes to the on-glasses
    /// gallery and is downloadable from the Memories tab.
    func takePhoto(forAi: Bool = true) { send("takePhoto", glassesTakePhoto(forAi: forAi)) }
    func interruptVoice() { send("interruptVoice", glassesInterruptVoice()) }

    // MARK: - What the Wi-Fi flows need

    /// Forget the last announced SSID. Call immediately BEFORE writing `0x39`/`0x67`.
    func clearWifiSSID() { wifiSSID = nil }

    /// Write a frame and wait for the ATT write to be acknowledged. Never throws: the
    /// flows report "not connected" in their own status rather than unwinding.
    func write(_ name: String, _ frame: Data) async {
        guard let p = peripheral, let c = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = gatt.writeWithResponse ? .withResponse : .withoutResponse
        guard type == .withResponse else {
            p.writeValue(frame, for: c, type: type)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingWrites.append(.waiter(continuation))
            p.writeValue(frame, for: c, type: type)
            armAckWatchdog()
        }
        disarmAckWatchdogIfIdle()
    }

    // MARK: - Write watchdog

    /// AA13 的 ATT 确认有可能永远不来：射频丢包、眼镜在写的过程中重启、或它对某条
    /// 命令就是不回 ACK。这一侧的后果不是报错，而是 `withCheckedContinuation` 永久
    /// 挂起 —— 整个「开热点 → 等 SSID → 加入网络」流程停在第一步，屏幕永远显示
    /// 「正在打开眼镜热点」，重试还被 `task != nil` 挡住。看门狗把不可见的死锁换成
    /// 可见的失败：到点放行等待者，流程继续走到 `awaitSSID` 的 15 秒超时并如实报错。
    private static let writeAckTimeout: TimeInterval = 8
    private var ackWatchdog: Task<Void, Never>?

    private func armAckWatchdog() {
        guard ackWatchdog == nil else { return }
        ackWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.writeAckTimeout))
            guard !Task.isCancelled else { return }
            self?.ackTimedOut()
        }
    }

    private func disarmAckWatchdog() {
        ackWatchdog?.cancel()
        ackWatchdog = nil
    }

    /// 只有在没有任何 `write()` 还在等 ACK 时才撤掉看门狗。
    ///
    /// AA13 是所有流程共用的：实时画面和眼镜相册可以同时各写一条。先等到确认的那一
    /// 路返回时，另一路的槽位还在 FIFO 里 —— 那时把共用的看门狗掐掉，另一路就退回
    /// 「永久挂起」的老问题了。
    private func disarmAckWatchdogIfIdle() {
        let stillWaiting = pendingWrites.contains {
            if case .waiter = $0 { return true }
            return false
        }
        if !stillWaiting { disarmAckWatchdog() }
    }

    private func ackTimedOut() {
        ackWatchdog = nil
        failAllWrites()
    }

    /// Wait for the glasses to push their SSID (`0x25`), which arrives about
    /// `glassesTimingSsidArrivalMs()` after the open. Generous on purpose: the image
    /// processor has to power up first, and a slow one is not a broken one.
    func awaitSSID(timeout: TimeInterval = 15) async -> String? {
        if let ssid = wifiSSID, !ssid.isEmpty { return ssid }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(200))
            if let ssid = wifiSSID, !ssid.isEmpty { return ssid }
        }
        return nil
    }

    // MARK: - Connection plumbing

    /// The remembered peripheral if the system still knows it, else a scan.
    private func beginConnectAttempt() {
        guard wantsConnection else { return }
        // 蓝牙不可用时不发起连接、也不让 UI 停在「正在寻找眼镜」：didUpdateState 的
        // 恢复分支只在 phase 非 working 时才重启连接，谎报 .scanning 会让恢复供电后
        // 永远卡死。
        guard central.state == .poweredOn else {
            phase = .bluetoothOff(Self.label(central.state))
            return
        }
        if let id = Self.rememberedID(),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            scan()
        }
    }

    private func scan() {
        phase = .scanning
        // NAME FALLBACK: this unit does not advertise AA12, so the scan must not filter
        // by service. Matching happens in `didDiscover`; the GATT table is validated
        // after connecting, before anything is declared "the glasses".
        central.scanForPeripherals(withServices: nil)
    }

    private func scheduleReconnect() {
        guard wantsConnection, !userDisconnected else { return }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            // 窗口用尽（30 轮 × 10 秒 ≈ 5 分钟）：停在一个可见、可解释的失败上，绝不
            // 静默。用户点「重新连接」（start()）即重开一整轮完整窗口。
            phase = .failed("持续 5 分钟未找到眼镜，请确认眼镜已开机")
            reconnectAttempts = 0
            return
        }
        reconnectAttempts += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.reconnectInterval))
            guard !Task.isCancelled else { return }
            self?.beginConnectAttempt()
        }
        // 窗口内不让 UI 闪 .failed/.idle：保持 .scanning，用户始终看到「正在寻找眼镜…」。
        // 间歇广播意味着 10 秒后的下一轮很可能就命中；期间扫到/连上立即恢复
        //（didDiscover/didConnect 接管 phase，成功时 reconnectAttempts 清零）。
        // 蓝牙关着时不能谎称扫描：如实标 bluetoothOff，didUpdateState 恢复供电时
        // 会把连接流程从这里接回去。
        if central.state == .poweredOn {
            phase = .scanning
        } else {
            phase = .bluetoothOff(Self.label(central.state))
        }
    }

    private func resetConnectionState() {
        peripheral = nil
        writeCharacteristic = nil
        resetProtocolState()
        failAllWrites()
        wifiSSID = nil
        isTransferringCapture = false
    }

    /// 放开「刚刚用过的那台外设」，保留跨会话记忆（rememberedName / rememberedID 由
    /// 调用方决定要不要清）。
    ///
    /// 只要连接没有建立就必须调用。`didDiscover` 用 `peripheral == nil` 判定「有没有
    /// 候选在途」，残留的引用会让之后所有正确的广播都被静默丢弃 —— 表现为眼镜明明在
    /// 广播、App 却永远停在寻找状态，只能杀进程或手动断连才能恢复。
    private func detachPeripheral() {
        peripheral = nil
        writeCharacteristic = nil
        failAllWrites()
    }

    private func failAllWrites() {
        // Drain the WHOLE FIFO, not only the waiters: stale .untracked slots from a
        // dropped connection would steal the first ack of the next one.
        disarmAckWatchdog()
        let waiting = pendingWrites
        pendingWrites.removeAll()
        waiting.forEach { if case let .waiter(continuation) = $0 { continuation.resume() } }
    }

    /// The connect interrogation. `getSwitchStates` (`0x48`) answers with a TEN-FRAME BURST
    /// keyed by each setting's own setter opcode, never a `0x48` frame; the parser
    /// accumulates the burst and `switchStates` reports when all ten have landed.
    private func interrogate() {
        send("getVersions", glassesGetVersions())
        send("getProjectName", glassesGetProjectName())
        send("getBattery", glassesGetBattery())
        send("getCapabilities", glassesGetCapabilities())
        send("getSwitchStates", glassesGetSwitchStates())
    }

    private func send(_ name: String, _ frame: Data) {
        guard let p = peripheral, let c = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = gatt.writeWithResponse ? .withResponse : .withoutResponse
        // Fire-and-forget writes occupy an ack slot on AA13 too — mark them untracked so
        // `didWriteValueFor` pops them without resuming someone else's waiter.
        if type == .withResponse { pendingWrites.append(.untracked) }
        p.writeValue(frame, for: c, type: type)
    }

    // MARK: - Inbound

    private func ingest(_ data: Data, from uuid: CBUUID) {
        if uuid == fileNotifyUUID {
            for event in reassembler.push(chunk: data) { applyFileEvent(event) }
        } else {
            for event in parser.push(chunk: data) {
                apply(event)
                events.send(event)
            }
            let states = parser.switchStates()
            switchStates = states
            settingsComplete = states.isComplete
        }
    }

    /// Fold the events the app renders from. Everything else is stream-only.
    private func apply(_ event: FfiGlassesEvent) {
        switch event {
        case let .battery(percent, charging, _):
            batteryPercent = percent
            self.charging = charging
        case let .versions(v):
            firmware = "bt \(v.btMajor).\(v.btMinor).\(v.btPatch) · isp \(v.ispMajor).\(v.ispMinor).\(v.ispPatch) · hw \(v.hardware)"
        case let .identity(project, customer):
            self.project = "\(project) / \(customer)"
        case let .wifiCredentials(ssid, _):
            wifiSSID = ssid
        default:
            break
        }
    }

    private func applyFileEvent(_ event: FfiGlassesFileEvent) {
        switch event {
        case .started:
            isTransferringCapture = true
        case let .completed(_, kind, data):
            // `take_photo(ai)` sends the small preview over BLE; the kind is the honest
            // record of what this transfer actually was. Only image-shaped kinds become
            // `lastCapture` — a voice note or firmware chunk must not clobber the photo.
            switch kind {
            case .hdImage, .imageThumb:
                lastCapture = data
                lastCaptureAt = Date()
                CaptureStore.save(data, at: lastCaptureAt ?? Date())
            default:
                break
            }
            isTransferringCapture = false
        case .aborted, .desynced:
            isTransferringCapture = false
        }
    }

    // MARK: - Rendering helpers

    nonisolated private static func label(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "on"
        case .poweredOff: "off"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        case .resetting: "resetting"
        default: "unknown"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension GlassesLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            if state == .poweredOn {
                if self.wantsConnection, !self.phase.isConnected, !self.phase.isWorking {
                    self.beginConnectAttempt()
                }
            } else {
                self.phase = .bluetoothOff(Self.label(state))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard self.wantsConnection else { return }
            let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? peripheral.name ?? ""
            let remembered = Self.rememberedName()
            // Match: the glasses advertise the service (most units), or the name we
            // remember (this unit). Both are then GATT-validated after connecting.
            let matches = advertised.contains(self.serviceUUID)
                || (!localName.isEmpty && (localName == remembered || localName == Self.fallbackDeviceName))
            guard matches else { return }
            // 一轮只认一个候选：已有候选在途（peripheral 已设 = connecting/
            // discovering）或已连接时，持续到来的匹配广播不再重复发起连接——
            // 未过滤扫描对同一台眼镜会反复回调。
            guard self.peripheral == nil, !self.phase.isConnected else { return }
            self.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.phase = .discovering
            peripheral.discoverServices([self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error?.localizedDescription ?? "unknown error"
        Task { @MainActor in
            // 直连失败大概率意味着缓存的外设已不可直连（系统缓存失效/广播特征
            // 变化）：清掉记住的 ID，让窗口内的后续轮次走名称扫描回退——名称还
            // 记着（rememberedName 不清），重连成功后 remember() 会把 ID 记回来。
            // 不清的话 30 轮会全打在同一个连不上的对象上，扫描回退形同虚设。
            UserDefaults.standard.removeObject(forKey: Self.rememberedIDDefaultsKey)
            // 连不上就必须放掉这台外设的引用，否则重连窗内的每一轮都能扫到它、却又
            // 全被 `didDiscover` 的「已有候选在途」判据挡掉，30 轮白白烧完 —— 现场
            // 眼镜被反复开关机时这条路径几乎是必经之路。
            guard self.peripheral === peripheral else { return }
            self.detachPeripheral()
            self.phase = .failed(message)
            self.scheduleReconnect()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.resetConnectionState()
            if self.userDisconnected || !self.wantsConnection {
                self.phase = .idle
                return
            }
            // Unexpected drop: bounded, visible retries — never a silent loop.
            self.phase = .connecting
            self.scheduleReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension GlassesLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == self.serviceUUID }) else {
                // Wrong device: the advertisement matched but the table does not.
                self.central.cancelPeripheralConnection(peripheral)
                self.phase = .failed("不是可驱动的眼镜")
                return
            }
            peripheral.discoverCharacteristics(
                [self.writeUUID, self.controlNotifyUUID, self.fileNotifyUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            let chars = service.characteristics ?? []
            // The crate's own answer to "can this peripheral be driven?" — write plus at
            // least the control notify. This is what makes the name fallback safe: a
            // same-named impostor without the table is rejected here.
            let drivable = glassesIsDrivable(characteristicUuids: chars.map { $0.uuid.uuidString })
            guard drivable else {
                self.central.cancelPeripheralConnection(peripheral)
                self.phase = .failed("眼镜 GATT 校验未通过")
                return
            }
            for c in chars {
                if c.uuid == self.writeUUID { self.writeCharacteristic = c }
                if c.uuid == self.controlNotifyUUID || c.uuid == self.fileNotifyUUID {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            self.remember(peripheral)
            self.reconnectAttempts = 0
            self.phase = .connected
            self.interrogate()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in self.ingest(data, from: uuid) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            // FIFO: this ack belongs to the OLDEST in-flight write. Resume either way —
            // a failed write must not strand a flow awaiting its ack.
            guard !self.pendingWrites.isEmpty else { return }
            switch self.pendingWrites.removeFirst() {
            case let .waiter(continuation): continuation.resume()
            case .untracked: break
            }
            self.disarmAckWatchdogIfIdle()
        }
    }
}
