//
//  LiveAudioPlayer.swift
//  Plays the live stream's AAC track.
//
//  `GlassesAacDepacketizer` (in `LumaCore`) turns RTP payloads into raw AAC frames; this
//  file turns those frames into sound. AAC-LC decodes from a plain
//  `AudioStreamBasicDescription` with no magic cookie, so `AVAudioConverter` can drive it
//  straight into `AVAudioEngine` — no ADTS wrapper is needed for playback. (The crate's
//  `glassesAdtsHeader(frameLen:)` is for the other job: writing a playable `.aac` FILE.)
//
//  Everything here is best-effort by construction. `LiveStreamSession` never lets a failure
//  in this file touch the video path: the audio SETUP can be refused, the socket can fail to
//  bind, the engine can refuse to start, and the live view keeps running silently.
//
//  THREADING: `play(_:)` is called from the RTP receive queue and holds `lock` from
//  validation through scheduleBuffer, so it can never interleave with a concurrent
//  `stop()` — scheduling on a node that `stop()` already detached throws.
//

import AVFoundation
import Foundation

final class LiveAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var running = false
    /// 被系统抢占 audio session 期间为 true。见 `handleInterruption` —— 这段时间往
    /// 节点里排缓冲只会堆积内存并在恢复瞬间一次性喷出来，不如直接丢帧。
    private var interrupted = false

    /// 中断/恢复对用户可见。`LiveStreamSession` 把它接到 `audioState` 上，因为这里
    /// 的任何失败都不允许影响视频，但也不允许悄悄发生。
    var onStateChange: ((String) -> Void)?
    private var interruptionObserver: NSObjectProtocol?

    /// An AAC frame is 1024 samples; the decoder wants that as its packet size.
    private static let framesPerPacket: UInt32 = 1024

    /// `sampleRate` and `channels` come from the crate's `glassesAacConfig()`, or from
    /// `glassesAacParseConfig(hex:)` on the SDP's `config=` parameter — never from a
    /// constant typed here.
    func start(sampleRate: Double, channels: UInt8) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }

        // Route to the speaker rather than the receiver, and mix rather than take the
        // session over — the glasses may be playing their own audio at the same time.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audioSession.setActive(true)

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,                   // variable
            mFramesPerPacket: Self.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(channels, 1)),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &description) else {
            throw PlayerError.unsupportedInput
        }
        guard let output = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(max(channels, 1))
        ) else {
            throw PlayerError.unsupportedOutput
        }

        converter = AVAudioConverter(from: input, to: output)
        inputFormat = input
        outputFormat = output

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        try engine.start()
        player.play()
        running = true
        interrupted = false
        installInterruptionObserver()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        removeInterruptionObserver()
        guard running else { return }
        running = false
        interrupted = false
        player.stop()
        engine.stop()
        engine.detach(player)
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - System interruptions

    /// 来电、其他 App 抢占音频会话、甚至是某些系统的定时提醒，都会把 audio engine
    /// 直接停掉 —— 不抛错、不回调，画面照旧流动，声音从此消失，页面上还写着「AAC-LC
    /// 16000 Hz」这种假装正常的文案。演示现场来一条横幅通知就够触发。
    /// 所以：中断期间停排帧（不堆内存），并如实改一行状态；中断结束后原地重启。
    private func installInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func removeInterruptionObserver() {
        guard let interruptionObserver else { return }
        NotificationCenter.default.removeObserver(interruptionObserver)
        self.interruptionObserver = nil
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            lock.lock(); let wasRunning = running; interrupted = true; lock.unlock()
            if wasRunning { report("音频被系统中断（来电/提醒），等待恢复…") }
        case .ended:
            lock.lock()
            interrupted = false
            guard running else { lock.unlock(); return }
            do {
                // 中断把 audio session 和 engine 一起摁停了，恢复必须两个都重新拉起来。
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                player.play()
            } catch {
                lock.unlock()
                report("音频中断后未能自动恢复：\(error.localizedDescription)")
                return
            }
            lock.unlock()
            report("音频已恢复")
        @unknown default:
            break
        }
    }

    /// 通知回调可能在任意队列上，这里只负责把状态交给调用方，不去碰主线程。
    private func report(_ text: String) { onStateChange?(text) }

    /// Decode and schedule one AAC frame, exactly as the depacketizer handed it over.
    ///
    /// 全程持锁（含 convert 与 scheduleBuffer）：stop() 在同一把锁里 detach player，
    /// 若验参后就放锁、在锁外排缓冲，并发 stop() 会先一步 detach，随后的
    /// scheduleBuffer 落在已 detach 的节点上，AVAudioPlayerNode 直接抛 ObjC 异常。
    /// 此路径不做任何等待，放大锁粒度没有死锁风险。
    func play(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        guard running, !interrupted, let converter, let input = inputFormat, let output = outputFormat else { return }
        guard !frame.isEmpty else { return }

        let compressed = AVAudioCompressedBuffer(
            format: input,
            packetCapacity: 1,
            maximumPacketSize: frame.count
        )
        compressed.byteLength = UInt32(frame.count)
        compressed.packetCount = 1
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(compressed.data, base, frame.count)
        }
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(frame.count)
        )

        guard let decoded = AVAudioPCMBuffer(
            pcmFormat: output,
            frameCapacity: Self.framesPerPacket
        ) else { return }

        var supplied = false
        var error: NSError?
        let outcome = converter.convert(to: decoded, error: &error) { _, status in
            // One packet per call: hand the buffer over once, then report end-of-stream so
            // the converter returns instead of blocking for more.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return compressed
        }
        guard outcome != .error, decoded.frameLength > 0 else { return }
        player.scheduleBuffer(decoded, completionHandler: nil)
    }

    enum PlayerError: LocalizedError {
        case unsupportedInput, unsupportedOutput

        var errorDescription: String? {
            switch self {
            case .unsupportedInput: return "could not describe the AAC input format"
            case .unsupportedOutput: return "could not build a PCM output format"
            }
        }
    }
}
