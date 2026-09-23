//
//  LiveStreamSession.swift
//  The live camera view: RTSP over TCP, RTP over UDP, H.264 into CoreMedia.
//
//  The whole chain (PROTOCOL.md §12 and §14):
//
//    1. write `0x67` over BLE      glassesOpenWifi(service: .live, p2p: false)
//    2. wait for the SSID          the `.wifiCredentials` event
//    3. settle, then join          glassesTimingSsidSettleMs(), then NEHotspotConfiguration
//    4. RTSP OPTIONS → DESCRIBE → SETUP → PLAY over TCP :554
//    5. RTP on the client UDP ports → Annex-B access units → CMSampleBuffer
//    6. stop: RTSP TEARDOWN, BLE `0x44`, drop the network
//
//  Not one byte of that conversation is parsed here. `GlassesRtspSession` is the state
//  machine: `pendingRequest()` hands out the bytes to write, `feed()` takes whatever the
//  socket returned and reports typed events, `teardown()` produces the last request.
//  `glassesParseSdp` reads the DESCRIBE body, `GlassesH264Depacketizer` turns RTP packets
//  into whole pictures, and `GlassesAacDepacketizer` does the same for the audio track.
//
//  This file owns three sockets, one queue and the CoreMedia plumbing. Where it does look
//  at bytes — splitting Annex-B into NAL units, rewriting the start codes as AVCC lengths —
//  that is a CONTAINER conversion for VideoToolbox, not protocol work, and even there the
//  start code and NAL type come from `glassesH264StartCode()` and `glassesH264NalType`.
//
//  Decoding is left to `AVSampleBufferDisplayLayer`, which is hardware-backed. A software
//  decode of 1600×1200 at 25 fps drowns in jitter.
//

import AVFoundation
import Combine
import CoreMedia
import Foundation
import Network
import LumaCore

@MainActor
final class LiveStreamSession: ObservableObject {

    /// The bring-up sequence, named step by step. Four waits that can each take seconds,
    /// and telling a slow one from a dead one is most of the debugging.
    enum Step: Int, CaseIterable {
        case openingWifi
        case awaitingSsid
        case joining
        case handshaking
        case streaming

        var title: String {
            switch self {
            case .openingWifi: return "Opening the glasses Wi-Fi"
            case .awaitingSsid: return "Waiting for the network name"
            case .joining: return "Joining the network"
            case .handshaking: return "RTSP handshake"
            case .streaming: return "Live"
            }
        }

        var detail: String {
            switch self {
            case .openingWifi: return "BLE 0x67 — glassesOpenWifi(service: .live)"
            case .awaitingSsid: return "the glasses push 0x25 with the SSID"
            case .joining: return "settle for glassesTimingSsidSettleMs(), then join"
            case .handshaking: return "GlassesRtspSession: OPTIONS → DESCRIBE → SETUP → PLAY"
            case .streaming: return "RTP → GlassesH264Depacketizer → AVSampleBufferDisplayLayer"
            }
        }
    }

    /// What the overlay reads out. Everything here is the depacketizer's own counters plus
    /// a frame clock kept on this side.
    struct Stats: Equatable {
        var frames: UInt64 = 0
        var keyframes: UInt64 = 0
        var droppedFragments: UInt64 = 0
        var unitsClosedWithoutMarker: UInt64 = 0
        var unsupportedPackets: UInt64 = 0
        var fps: Double = 0
        var audioFrames: UInt64 = 0

        /// Access units that closed on a timestamp change rather than the marker bit, plus
        /// fragments whose start packet never arrived: the two shapes packet loss takes.
        var lossText: String {
            "\(droppedFragments) dropped frag · \(unitsClosedWithoutMarker) no-marker · \(unsupportedPackets) unsupported"
        }
    }

    @Published private(set) var step: Step = .openingWifi
    @Published private(set) var status = "starting"
    @Published private(set) var failure: String?
    @Published private(set) var stats = Stats()
    @Published private(set) var dimensions: CMVideoDimensions?
    @Published private(set) var audioState = "not requested"
    @Published private(set) var finished = false
    /// 与记忆页一样：首次使用时展示眼镜 WiFi 的 SSID + 密码，引导用户手动加入。
    @Published private(set) var joinHint: String?

    /// Sample buffers for the display layer. The view subscribes; nothing else does.
    let frames = PassthroughSubject<CMSampleBuffer, Never>()

    private let link: GlassesLink
    private var task: Task<Void, Never>?
    private var ssid: String?
    private var video: RtpReceiver?
    private var audio: RtpReceiver?
    private var audioPlayer: LiveAudioPlayer?
    private var transport: TcpTransport?
    private var rtsp: GlassesRtspSession?
    /// Held here for its lifetime, not just by the receiver's callback: the pipeline owns
    /// the depacketizer's rolling state and the format description, and a stream that lost
    /// it would restart from grey at every keyframe.
    private var pipeline: VideoPipeline?

    /// How long after PLAY we wait for the first picture before calling the stream dead.
    /// The glasses normally push an IDR within a second.
    private static let firstFrameTimeout: TimeInterval = 12

    init(link: GlassesLink) {
        self.link = link
    }

    /// 也必须以 `finished` 收口：stop() 刻意保留 step（"停在哪一步"是有信息量的），
    /// 单看 step 会让停止之后的界面继续摆出「正在直播」的姿态 —— 统计浮层不撤、
    /// 文案还写着"实时画面"，而那个"停止"按钮按下去毫无反应。
    var isStreaming: Bool { step == .streaming && failure == nil && !finished }

    // MARK: - Start

    /// 支持重复启动：stop() 之后 finished 永久为 true 会把 Live tab 变成一次性页面
    /// （第二次进入永远无法再开播）。重开一轮时先复位全部运行态。
    func start() {
        guard task == nil else { return }
        // 失败路径不置 finished（它只由 stop() 置位），重试时走不到 resetForRestart，
        // 上一轮的 RtpReceiver 还 bind 着 UDP 端口 —— 不清理的话第二轮 bind() 直接
        // port in use。teardownResources 幂等（字段全可选、nil 安全），先清一轮再开。
        // 放在 task 判空之后：直播进行中 onChange(link.phase) 也会调 start()，
        // 那时不能拆掉正在使用的接收器。
        teardownResources()
        if finished { resetForRestart() }
        task = Task { await run() }
    }

    private func resetForRestart() {
        finished = false
        failure = nil
        step = .openingWifi
        status = "starting"
        stats = Stats()
        dimensions = nil
        audioState = "not requested"
        teardownResources()
    }

    /// 释放上一轮占住的资源：两个 RtpReceiver 的 UDP 端口、音频引擎、RTSP 会话与
    /// TCP 连接。字段全可选且 nil 安全，重复调用无害。
    private func teardownResources() {
        video?.stop(); video = nil
        audio?.stop(); audio = nil
        audioPlayer?.stop(); audioPlayer = nil
        pipeline = nil
        rtsp = nil
        transport = nil
        ssid = nil
    }

    /// 失败路径的收尾。
    ///
    /// 拉起失败时没人替眼镜关热点：`stop()` 只在用户主动停止 / 离开 tab 时被走到，
    /// 而失败之后用户通常是直接切走或者连点重试。于是 0x67 已经把 SoftAP 拉起来了，
    /// 却没有 0x44 把它收回去 —— 摄像头与射频一直供电，演示日里这是最贵的一种失败。
    /// UDP 端口与 RTSP/TCP 也必须在这里放开：它们同样只活在 stop() 里，留着会让下
    /// 一轮 bind() 撞上 port in use。
    private func abandon() {
        teardownResources()
        let leaving = ssid
        ssid = nil
        Task {
            // 0x44 无条件发：告诉眼镜"都拿完了"，让它关掉图像处理器、撤掉热点。
            await link.write("fileDownloadComplete", glassesFileDownloadComplete())
            if let leaving { GlassesWiFi.leave(ssid: leaving) }
        }
    }

    private func run() async {
        failure = nil
        do {
            step = .openingWifi
            status = "writing 0x67…"
            link.clearWifiSSID()
            await link.write("openWifi(live)", glassesOpenWifi(service: .live, p2p: false))

            step = .awaitingSsid
            status = "waiting for the 0x25 push…"
            guard let ssid = await link.awaitSSID() else { throw GlassesWiFi.WiFiError.noSSID }
            self.ssid = ssid

            step = .joining
            status = "\(ssid) — settling \(glassesTimingSsidSettleMs()) ms"
            try await Task.sleep(for: GlassesWiFi.ssidSettle)
            status = "joining \(ssid)…"
            try await GlassesWiFi.join(ssid: ssid)

            // 先用 15 秒快速探测：之前手动加入过的话 iOS 会记住网络，秒级自动关联。
            // 从未连过则快速失败，展示手动加入引导而非干等 75 秒。
            joinHint = "首次使用请到 iPhone「设置▸Wi-Fi」\n手动加入眼镜网络「\(ssid)」\n密码：\(glassesWifiPassphrase())"
            let host: String
            do {
                host = try await GlassesWiFi.waitForHostQuick(port: 554) { [weak self] seconds in
                    self?.status = "joined \(ssid) — waiting for the RTSP server (\(seconds)s)"
                }
            } catch {
                // 快速探测失败，再给一次长窗口（用户可能正在手动加入中）
                status = "等待手动加入眼镜网络…"
                host = try await GlassesWiFi.waitForHost(port: 554) { [weak self] seconds in
                    self?.status = "joined \(ssid) — waiting for the RTSP server (\(seconds)s)"
                }
            }
            joinHint = nil

            try await stream(host: host)
        } catch is CancellationError {
            // 取消几乎总来自 stop()，而它已写下 "TEARDOWN, then 0x44"：
            // 再写 "stopped" 会把它覆盖掉。未被取消而收到 CancellationError 的
            // 少见路径（如对端把连接当取消处理）仍需要一句状态。
            if !Task.isCancelled { status = "stopped" }
        } catch {
            // 被取消说明是 stop() 那一路，它的 Task 已经在发 TEARDOWN + 0x44 + leave，
            // 这里再补一遍只是让眼镜收到两条 0x44。
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            status = "failed"
            abandon()
        }
        // 只在自身正常收尾时清引用：被 stop() 取消的一轮稍后恢复执行时，
        // start() 可能已挂上新 task，无条件置 nil 会抹掉新任务引用，新任务从此
        // cancel 不掉。只有 stop() 会取消任务、替换前必先取消，所以 isCancelled
        // 足以区分「自己收尾」和「已被换下」。
        if !Task.isCancelled { task = nil }
    }

    // MARK: - The RTSP conversation

    private func stream(host: String) async throws {
        step = .handshaking
        status = "connecting to \(glassesRtspStreamUrl(host: host))"

        // The client ports are the crate's defaults; the session is asked for them back so
        // the SETUP header and the bound socket can never disagree.
        let videoPorts = glassesRtspDefaultVideoPorts()
        let audioPorts = glassesRtspDefaultAudioPorts()
        let session = GlassesRtspSession.withOptions(
            url: glassesRtspStreamUrl(host: host),
            videoRtpPort: videoPorts.first ?? 8712,
            audioRtpPort: audioPorts.first ?? 8714,
            wantAudio: true
        )
        rtsp = session

        let videoReceiver = RtpReceiver(port: session.videoClientPort())
        try videoReceiver.bind()
        video = videoReceiver

        // Audio's socket is bound best-effort. A refused bind simply means no audio; it
        // must never take video down with it.
        let audioReceiver = RtpReceiver(port: session.audioClientPort())
        let audioBound = (try? audioReceiver.bind()) != nil
        if audioBound { audio = audioReceiver }

        let transport = TcpTransport(host: host, port: 554)
        self.transport = transport
        try await transport.start()

        var videoPayloadType: UInt8 = 96
        var audioPayloadType: UInt8?
        var aacFmtp: [FfiGlassesKeyValue] = []

        // The loop the crate documents: pendingRequest → write → read → feed → repeat.
        while !session.isPlaying() {
            try Task.checkCancellation()
            if let request = session.pendingRequest() {
                status = Self.firstLine(of: request)
                try await transport.send(request)
            }
            let chunk = try await transport.receive()
            switch session.feed(bytes: chunk) {
            case let .err(reason):
                throw LiveError.rtsp(reason)
            case let .ok(events):
                for event in events {
                    switch event {
                    case let .described(sdp):
                        for media in sdp.media {
                            if media.kind == "video" { videoPayloadType = media.payloadType }
                            if media.kind == "audio" {
                                audioPayloadType = media.payloadType
                                aacFmtp = media.fmtp
                            }
                        }
                        let names = sdp.media.map { "\($0.kind) pt \($0.payloadType)" }
                        status = "DESCRIBE: \(names.joined(separator: ", "))"
                    case let .setUpRefused(track, code):
                        // Documented and expected for audio; a refused VIDEO setup would
                        // have come back as an error from `feed`, not as this event.
                        if track == .audio { audioState = "refused by the glasses (\(code))" }
                    case .playing:
                        status = "PLAY accepted"
                    default:
                        break
                    }
                }
            }
        }

        // Video first, and unconditionally.
        let pipeline = VideoPipeline()
        self.pipeline = pipeline
        pipeline.onFormat = { [weak self] dimensions in
            Task { @MainActor in self?.dimensions = dimensions }
        }
        pipeline.onSample = { [weak self] sample, snapshot in
            Task { @MainActor in
                guard let self else { return }
                if self.step != .streaming { self.step = .streaming; self.status = "streaming" }
                // 统计以 2 Hz 落地：25 fps 每帧写一次 @Published，等于让 SwiftUI 每秒
                // 重算 25 次整棵 body（叠加、转录这些本来就跑在 CPU 主线程上），直接表现
                // 是画面发涩。样本本身不等，仍旧一帧一发。
                self.pendingSnapshot = snapshot
                self.flushStatsIfNeeded()
                self.frames.send(sample)
            }
        }
        videoReceiver.expectedPayloadType = videoPayloadType
        videoReceiver.onDatagram = { data in pipeline.push(data) }
        videoReceiver.start()

        // Then audio, and only if everything about it worked.
        if audioBound, let audioPayloadType, audioState == "not requested" {
            startAudio(on: audioReceiver, payloadType: audioPayloadType, fmtp: aacFmtp)
        } else if !audioBound {
            audioState = "no socket"
        }

        // Hold the session open. PLAY succeeding is not proof that video is coming: the
        // image processor can stay dark and the access point can drop, and without this
        // watchdog the screen sat on "RTSP handshake" forever with no way back.
        let deadline = Date().addingTimeInterval(Self.firstFrameTimeout)
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(250))
            if let reason = videoReceiver.failure { throw LiveError.socket(reason) }
            if step == .streaming { continue }
            if Date() >= deadline { throw LiveError.noFirstFrame }
        }
        throw CancellationError()
    }

    /// The AAC track, entirely best-effort. `GlassesAacDepacketizer` unpacks the RTP
    /// payloads into raw AAC frames; `LiveAudioPlayer` decodes them. Any failure at all
    /// leaves the video stream untouched and says so in `audioState`.
    private func startAudio(on receiver: RtpReceiver, payloadType: UInt8, fmtp: [FfiGlassesKeyValue]) {
        // The widths come out of the SDP's `a=fmtp:` line. The server spells two of RFC
        // 3640's three field names in lower case, so the lookup is case-insensitive — the
        // crate's own doc comment on `FfiGlassesSdpMedia.fmtp` says as much.
        func width(_ key: String, default fallback: UInt8) -> UInt8 {
            let hit = fmtp.first { $0.key.lowercased() == key }
            return hit.flatMap { UInt8($0.value) } ?? fallback
        }
        let depacketizer = GlassesAacDepacketizer.withWidths(
            sizeLength: width("sizelength", default: 13),
            indexLength: width("indexlength", default: 3),
            indexDeltaLength: width("indexdeltalength", default: 3)
        )

        // `config=1408` is the AudioSpecificConfig as hex; the crate decodes it, and falls
        // back to the glasses' known 16 kHz mono AAC-LC when the line is absent.
        let configHex = fmtp.first { $0.key.lowercased() == "config" }?.value
        let config = configHex.flatMap { glassesAacParseConfig(hex: $0) } ?? glassesAacConfig()

        let player = LiveAudioPlayer()
        do {
            try player.start(sampleRate: Double(config.sampleRateHz), channels: config.channelConfiguration)
        } catch {
            audioState = "decoder unavailable: \(error.localizedDescription)"
            return
        }
        // 中断/恢复由播放器回调：它跑在 audio session 的通知队列上，这里接入 @MainActor。
        player.onStateChange = { [weak self] text in
            Task { @MainActor in self?.audioState = text }
        }
        audioPlayer = player
        audioState = "AAC-LC \(config.sampleRateHz) Hz, \(config.channelConfiguration) ch"

        receiver.expectedPayloadType = payloadType
        receiver.onDatagram = { [weak self] data in
            let units = depacketizer.push(packet: data)
            guard !units.isEmpty else { return }
            units.forEach(player.play)
            let count = depacketizer.frames()
            Task { @MainActor in self?.stats.audioFrames = count }
        }
        receiver.start()
    }

    private func apply(_ snapshot: VideoPipeline.Snapshot) {
        stats.frames = snapshot.stats.accessUnits
        stats.keyframes = snapshot.stats.keyframes
        stats.droppedFragments = snapshot.stats.droppedFragments
        stats.unitsClosedWithoutMarker = snapshot.stats.unitsClosedWithoutMarker
        stats.unsupportedPackets = snapshot.stats.unsupportedPackets
        stats.fps = snapshot.fps
    }

    // MARK: - Stats throttling

    private var pendingSnapshot: VideoPipeline.Snapshot?
    private var lastStatsFlush = Date.distantPast

    private func flushStatsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastStatsFlush) >= 0.5 else { return }
        lastStatsFlush = now
        if let snapshot = pendingSnapshot { apply(snapshot) }
    }

    // MARK: - Stop

    /// TEARDOWN, `0x44`, drop the network. Runs from the button and from `onDisappear`,
    /// so it has to be idempotent.
    func stop() {
        guard !finished else { return }
        finished = true
        task?.cancel()
        task = nil

        video?.stop(); video = nil
        audio?.stop(); audio = nil
        audioPlayer?.stop(); audioPlayer = nil
        pipeline = nil

        let session = rtsp
        let transport = self.transport
        rtsp = nil
        self.transport = nil
        let leaving = ssid
        ssid = nil

        // The step is left where it was on purpose: stopping during the handshake should
        // read as "stopped there", not as a completed checklist.
        status = "TEARDOWN, then 0x44"
        Task {
            if let session, let transport {
                // Best effort: the socket may already be gone with the access point.
                try? await transport.send(session.teardown())
            }
            transport?.cancel()
            session?.close()
            await link.write("fileDownloadComplete", glassesFileDownloadComplete())
            if let leaving { GlassesWiFi.leave(ssid: leaving) }
        }
    }

    func dismissFailure() { failure = nil }

    private static func firstLine(of request: Data) -> String {
        String(decoding: request, as: UTF8.self)
            .split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? "…"
    }

    enum LiveError: LocalizedError {
        case rtsp(String)
        case socket(String)
        case noFirstFrame

        var errorDescription: String? {
            switch self {
            case let .rtsp(reason): return "RTSP 握手失败：\(reason)"
            case let .socket(reason): return "视频 socket 异常：\(reason)"
            case .noFirstFrame: return "已开始播放但没有收到画面，请重试。"
            }
        }
    }
}

// MARK: - The RTSP control socket

/// A TCP connection with `send`/`receive` as plain async calls. RTSP is request/response
/// over a stream, and `GlassesRtspSession.feed` re-assembles whatever chunking the socket
/// happens to produce, so nothing here needs to buffer.
final class TcpTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "luma.rtsp")

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 554,
            using: .tcp
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case let .failed(error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.send(content: data, completion: .contentProcessed { error in
                once.run {
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = ResumeOnce()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                once.run {
                    if let error { continuation.resume(throwing: error); return }
                    if let data, !data.isEmpty { continuation.resume(returning: data); return }
                    if isComplete {
                        continuation.resume(throwing: LiveStreamSession.LiveError.socket("the server closed the connection"))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        }
    }

    func cancel() { connection.cancel() }
}

// MARK: - The RTP sockets

/// Binds one UDP port and hands whole datagrams to `onDatagram` on its own queue.
///
/// Datagrams whose RTP payload type is not the expected one are dropped: RTCP shares the
/// neighbourhood and the access point is not private. `glassesParseRtp` reads the header —
/// there is no RTP parsing in this file.
final class RtpReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "luma.rtp", qos: .userInitiated)
    private let port: UInt16

    var expectedPayloadType: UInt8?
    var onDatagram: ((Data) -> Void)?

    private let lock = NSLock()
    private var failureReason: String?
    private var stopped = false

    var failure: String? {
        lock.lock(); defer { lock.unlock() }
        return failureReason
    }

    init(port: UInt16) { self.port = port }

    /// The initializer only fails on bad parameters; a port already in use surfaces later
    /// as `.failed` on the state handler, which is why one is installed here. With no
    /// handler that failure is invisible: the socket looks bound and nothing ever arrives.
    func bind() throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error): self?.record("listener failed: \(error.localizedDescription)")
            case .cancelled: self?.record("listener cancelled")
            default: break
            }
        }
        self.listener = listener
    }

    func start() {
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // connections 同时会被其他线程的 stop() 遍历并清空：数组操作必须持锁。
            // 启动连接、收包是重活，留在锁外。
            lock.lock()
            connections.append(connection)
            lock.unlock()
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener?.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, self.accepts(data) { self.onDatagram?(data) }
            if let error {
                self.record("receive failed: \(error.localizedDescription)")
                return
            }
            self.receive(on: connection)
        }
    }

    private func accepts(_ datagram: Data) -> Bool {
        guard let expected = expectedPayloadType else { return true }
        guard case let .ok(header) = glassesParseRtp(packet: datagram) else { return false }
        return header.payloadType == expected
    }

    private func record(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failureReason == nil else { return }
        failureReason = reason
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        listener?.cancel()
        listener = nil
        // 锁内只做数组操作（快照 + 清空）；socket 的 cancel 拿快照到锁外执行。
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
        onDatagram = nil
    }
}

// MARK: - RTP → CMSampleBuffer

/// Confined to the RTP receive queue. Owns the depacketizer, the format description and
/// the frame clock; publishes finished sample buffers through `onSample`.
final class VideoPipeline: @unchecked Sendable {
    struct Snapshot {
        let stats: FfiGlassesH264Stats
        let fps: Double
    }

    var onSample: ((CMSampleBuffer, Snapshot) -> Void)?
    var onFormat: ((CMVideoDimensions) -> Void)?

    private let depacketizer = GlassesH264Depacketizer()
    private var formatDescription: CMFormatDescription?
    private var windowStart = Date()
    private var windowFrames = 0
    private var fps: Double = 0

    /// The crate's own start code. Every access unit it emits is `00 00 00 01 <nal>`
    /// repeated, so this is both the separator and the prefix width.
    private let startCode = glassesH264StartCode()

    func push(_ datagram: Data) {
        for unit in depacketizer.pushDetailed(packet: datagram) {
            // A decoder handed anything before the first IDR-with-parameter-sets renders
            // grey until the next keyframe, which reads as a decoder bug and is not one.
            if formatDescription == nil {
                guard unit.isDecodableStart else { continue }
                makeFormatDescription()
            }
            guard let sample = makeSampleBuffer(unit) else { continue }
            tickFrameClock()
            onSample?(sample, Snapshot(stats: depacketizer.stats(), fps: fps))
        }
    }

    /// SPS and PPS arrive in-band before every IDR; `parameterSets()` hands back the most
    /// recent pair as Annex B, which splits into exactly the two NALs VideoToolbox wants.
    private func makeFormatDescription() {
        let nals = splitAnnexB(depacketizer.parameterSets())
        let sps = nals.first { glassesH264NalType(headerByte: $0.first ?? 0) == 7 }
        let pps = nals.first { glassesH264NalType(headerByte: $0.first ?? 0) == 8 }
        guard let sps, let pps else { return }

        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                guard let s = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let p = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                var pointers = [s, p]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,          // AVCC, 4-byte length prefix
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { return }
        formatDescription = format
        onFormat?(CMVideoFormatDescriptionGetDimensions(format))
    }

    /// Annex B in, AVCC out: each `00 00 00 01` start code becomes a 4-byte big-endian
    /// length. SPS and PPS are dropped from the sample itself — they are already in the
    /// format description, and VideoToolbox wants slices here.
    private func makeSampleBuffer(_ unit: FfiGlassesAccessUnit) -> CMSampleBuffer? {
        guard let format = formatDescription else { return nil }
        var avcc = Data()
        for nal in splitAnnexB(unit.data) {
            let type = glassesH264NalType(headerByte: nal.first ?? 0)
            if type == 7 || type == 8 { continue }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return nil }

        // CoreMedia owns the storage and we copy into it — pointing a block buffer at a
        // `Data`'s buffer dangles the moment this scope ends.
        var block: CMBlockBuffer?
        let length = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }

        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length
            )
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // The SDP signals no frame rate (PROTOCOL.md §14), so there is no honest
        // presentation timestamp to compute: display each picture as it arrives.
        // createIfNecessary 也可能返回空数组：直接下标 0 会越界崩溃，先确认非空。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !unit.isKeyframe {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sample
    }

    private func tickFrameClock() {
        windowFrames += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            fps = Double(windowFrames) / elapsed
            windowFrames = 0
            windowStart = Date()
        }
    }

    /// Split `00 00 00 01`-delimited bytes into NAL units. A container detail, not protocol:
    /// the separator itself is `glassesH264StartCode()`.
    private func splitAnnexB(_ data: Data) -> [Data] {
        let code = [UInt8](startCode)
        guard !code.isEmpty, data.count > code.count else { return [] }
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + code.count <= bytes.count {
            if Array(bytes[i..<(i + code.count)]) == code {
                starts.append(i + code.count)
                i += code.count
            } else {
                i += 1
            }
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] - code.count : bytes.count
            guard end > start else { return nil }
            return Data(bytes[start..<end])
        }
    }
}
