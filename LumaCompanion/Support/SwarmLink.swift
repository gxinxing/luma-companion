//
//  SwarmLink.swift
//  把眼镜拍摄的画面交给蜂群中的 Jev 眼镜 Agent 做判断。
//
//  链路与既有事实源完全对齐（aria-swarm origin/main）：
//    1. 特征提取：与 src/glasses-stimulus-source.py 相同的语义 —— 32×32 下采样、
//       Rec.709 亮度均值、平均色 HSL（色相桶）、Sobel 边缘密度、8×8 aHash。
//    2. 合同：src/glasses-stimulus.schema.json（glasses-stimulus/v1）的字段形状。
//    3. 输入：只发送 brightness / edge_density / saturation，不上传原始图像。
//    4. 决策：POST /api/glasses-agent/observe；由 Jev 决定是否值得刺激蜂群，
//       runId 从 GET /api/snapshot 自动发现。Agent 端点随 aria-swarm PR #54 部署。
//
//  用户设备不能信任本地 intensity 直接刺激：最终是否刺激与刺激强度由 Jev Agent 决定。
//

import CoreGraphics
import CryptoKit
import Foundation
import UIKit

enum SwarmLink {

    // MARK: - Config（UserDefaults 持久化）

    static let defaultBaseURL = "https://ytd.rickyke.com"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "swarm.baseURL") ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "swarm.baseURL") }
    }
    // MARK: - 特征提取（32×32 网格，语义对齐 glasses-stimulus-source.py）

    struct Features {
        var brightness: Double
        var saturation: Double
        var dominantHue: Double
        var hueBucket: String
        var edgeDensity: Double
        var perceptualHash: String
        var pixels: Int
    }

    private struct RGB { var r: Double; var g: Double; var b: Double }

    /// CoreGraphics 下采样到 32×32 并提取特征。实现语义与 Python 生产者一致。
    static func features(from data: Data) -> Features? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let size = 32
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let buffer = context.data else { return nil }

        var pixels: [RGB] = []
        pixels.reserveCapacity(size * size)
        let ptr = buffer.bindMemory(to: UInt8.self, capacity: size * size * 4)
        for i in 0..<(size * size) {
            // premultipliedLast + DeviceRGB → 内存布局为 R,G,B,A（R 在偏移 0）
            pixels.append(RGB(r: Double(ptr[i * 4]), g: Double(ptr[i * 4 + 1]), b: Double(ptr[i * 4 + 2])))
        }
        return features(fromPixels: pixels, w: size, h: size)
    }

    private static func features(fromPixels pixels: [RGB], w: Int, h: Int) -> Features {
        let n = Double(pixels.count)
        let mr = pixels.reduce(0) { $0 + $1.r } / n
        let mg = pixels.reduce(0) { $0 + $1.g } / n
        let mb = pixels.reduce(0) { $0 + $1.b } / n
        let brightness = ((0.2126 * mr + 0.7152 * mg + 0.0722 * mb) / 255.0)
        let (hue, sat, lum) = rgbToHSL(Int(mr), Int(mg), Int(mb))
        return Features(
            brightness: (brightness * 10_000).rounded() / 10_000,
            saturation: (sat * 10_000).rounded() / 10_000,
            dominantHue: (hue * 10).rounded() / 10,
            hueBucket: hueBucket(hue, sat, lum),
            edgeDensity: sobelEdgeDensity(pixels, w, h),
            perceptualHash: averageHash(pixels, w, h),
            pixels: pixels.count
        )
    }

    private static func rgbToHSL(_ rIn: Int, _ gIn: Int, _ bIn: Int) -> (Double, Double, Double) {
        let r = Double(rIn) / 255.0, g = Double(gIn) / 255.0, b = Double(bIn) / 255.0
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2.0
        if mx == mn { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn)
        var hh: Double
        if mx == r { hh = (g - b) / d + (g < b ? 6.0 : 0.0) }
        else if mx == g { hh = (b - r) / d + 2.0 }
        else { hh = (r - g) / d + 4.0 }
        return (hh * 60.0, s, l)
    }

    private static let hueBuckets: [(String, Double, Double)] = [
        ("red", 0, 15), ("orange", 15, 45), ("yellow", 45, 70),
        ("green", 70, 160), ("cyan", 160, 200), ("blue", 200, 255),
        ("violet", 255, 290), ("magenta", 290, 345), ("red", 345, 360),
    ]

    private static func hueBucket(_ hue: Double, _ sat: Double, _ lum: Double) -> String {
        if sat < 0.08 || lum < 0.06 || lum > 0.96 { return "neutral" }
        for (name, lo, hi) in hueBuckets where lo <= hue && hue < hi { return name }
        return "neutral"
    }

    private static func sobelEdgeDensity(_ pixels: [RGB], _ w: Int, _ h: Int) -> Double {
        let lum = pixels.map { 0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b }
        var mag = 0.0
        guard w > 2, h > 2 else { return 0 }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (lum[i - w + 1] - lum[i - w - 1]) + 2 * (lum[i + 1] - lum[i - 1]) + (lum[i + w + 1] - lum[i + w - 1])
                let gy = (lum[i + w - 1] - lum[i - w - 1]) + 2 * (lum[i + w] - lum[i - w]) + (lum[i + w + 1] - lum[i - w + 1])
                mag += (abs(gx) + abs(gy)) / 1020.0
            }
        }
        let n = max(1, (w - 2) * (h - 2))
        // 单像素 |gx|+|gy| 理论上限是 2（各 1020/1020），平均可超 1 —— 但合同约定
        // 每个特征 ∈ [0,1]，服务端对越界是拒绝而非吸顶，这里必须自己 clamp。
        return min(1.0, (mag / Double(n) * 10_000).rounded() / 10_000)
    }

    private static func averageHash(_ pixels: [RGB], _ w: Int, _ h: Int, size: Int = 8) -> String {
        let cellW = Double(w) / Double(size)
        let cellH = Double(h) / Double(size)
        var rows: [Double] = []
        for ry in 0..<size {
            for rx in 0..<size {
                let x0 = Int(Double(rx) * cellW), x1 = max(Int(Double(rx) * cellW) + 1, Int((Double(rx) + 1) * cellW))
                let y0 = Int(Double(ry) * cellH), y1 = max(Int(Double(ry) * cellH) + 1, Int((Double(ry) + 1) * cellH))
                var vals: [Double] = []
                for yy in y0..<min(y1, h) {
                    for xx in x0..<min(x1, w) {
                        let p = pixels[yy * w + xx]
                        vals.append(0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b)
                    }
                }
                rows.append(vals.reduce(0, +) / Double(max(1, vals.count)))
            }
        }
        let mean = rows.reduce(0, +) / Double(rows.count)
        let bits = rows.map { $0 >= mean ? "1" : "0" }.joined()
        // `%016x` 按 unsigned int（32 位）取值，而这里给它的是 UInt64 —— 64 位平台上
        // 只会印出低 32 位，剩下一半信息被静默丢掉，dedup_id 的碰撞概率凭空涨 2^32 倍。
        // UInt64 对应的长度修饰符是 ll。
        return String(format: "%016llx", UInt64(bits, radix: 2) ?? 0)
    }

    // MARK: - 中台交互

    struct SendReport {
        var ok: Bool
        var message: String
    }

    struct SwarmSnapshot {
        let runId: String?
        let status: String
        let aiStatus: String
        let apiConfigured: Bool
        let modelCalls: Int?
        let decisions: Int?
        let appliedBees: Int?
        let noChange: Int?
        let traceCount: Int?
        let generation: Int?
        let deviceStatus: String
        let lastStimulusId: String?
    }

    /// 只读运行快照。数字完全来自中台账本；缺失保持 nil，界面显示「未采集」。
    static func fetchSnapshot(baseURL rawBaseURL: String) async throws -> SwarmSnapshot {
        guard let url = URL(string: normalizedBaseURL(rawBaseURL) + "/api/snapshot") else {
            throw SwarmError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwarmError.server("无法读取蜂群运行快照")
        }
        let ai = root["ai"] as? [String: Any] ?? [:]
        let metrics = root["metrics"] as? [String: Any] ?? [:]
        let music = root["music"] as? [String: Any] ?? [:]
        let device = root["device"] as? [String: Any] ?? [:]
        func count(_ key: String) -> Int? { (metrics[key] as? NSNumber)?.intValue }
        return SwarmSnapshot(
            runId: root["runId"] as? String,
            status: root["status"] as? String ?? "unknown",
            aiStatus: ai["status"] as? String ?? "unknown",
            apiConfigured: root["apiConfigured"] as? Bool ?? false,
            modelCalls: count("modelCalls"),
            decisions: count("decisions"),
            appliedBees: count("appliedBees"),
            noChange: count("noChange"),
            traceCount: (music["traces"] as? [Any])?.count,
            generation: (music["generation"] as? NSNumber)?.intValue,
            deviceStatus: device["status"] as? String ?? "unknown",
            lastStimulusId: device["lastStimulusId"] as? String
        )
    }

    /// 把「中台地址」输入框里可能写出的各种形态整理成能用的 base：空 scheme
    /// （`ytd.rickyke.com`）、结尾多带一个斜杠、前后空格。不整理的话 `URL(string:)`
    /// 要么构造失败抛 badURL，要么拼出 `https://host//api/snapshot` 这种可疑路径。
    static func normalizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultBaseURL }
        var base = trimmed
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// 从 /api/snapshot 发现当前运行的 runId（status=running 才有效）。
    static func currentRunID(baseURL rawBaseURL: String) async throws -> String {
        let baseURL = normalizedBaseURL(rawBaseURL)
        guard let url = URL(string: baseURL + "/api/snapshot") else {
            throw SwarmError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SwarmError.server("快照获取失败")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwarmError.server("快照不是 JSON")
        }
        guard let runId = obj["runId"] as? String, !runId.isEmpty else {
            throw SwarmError.noRun("中台当前没有正在运行的场次——先在中台 UI 里启动一场演出")
        }
        // 有 runId ≠ 有演出在跑：场次结束或被取代之后 snapshot 依旧带着上一个 runId，
        // 照它上报会拿到 HTTP 200 并显示"已上报 xxx"，而音乐侧什么都没发生 —— 这正好是
        // 最容易被当成成功的那类假成功。status 给了就校验。
        if let status = obj["status"] as? String, status != "running" {
            throw SwarmError.noRun("中台当前场次状态为 \(status)（需要 running）——先在中台 UI 里启动一场演出")
        }
        return runId
    }

    /// 将 BLE 照片特征交给服务器上的 Jev 眼镜 Agent。原始照片留在手机；
    /// Agent 决定不刺激也是一次成功且可解释的感知结果。
    static func sendCaptureToAgent(
        _ imageData: Data,
        deviceName: String,
        baseURL: String,
        runId: String,
        capturedAt: Date
    ) async throws -> String {
        guard let features = features(from: imageData) else { throw SwarmError.badImage }

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = timestampFormatter.string(from: capturedAt)
        let captureFingerprint = sha256Hex(imageData)
        let captureId = "glasses-\(String(sha256Hex("\(deviceName)|\(timestamp)|\(captureFingerprint)").prefix(20)))"
        let body: [String: Any] = [
            "runId": runId,
            "captureId": captureId,
            "features": [
                "brightness": features.brightness,
                "edge_density": features.edgeDensity,
                "saturation": features.saturation,
            ],
        ]
        guard let url = URL(string: normalizedBaseURL(baseURL) + "/api/glasses-agent/observe"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw SwarmError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.flatMap { $0.isEmpty ? nil : String($0.prefix(180)) } ?? "无回复体"
            if code == 401 {
                throw SwarmError.server("线上中台尚未部署 Jev 眼镜 Agent 接口（aria-swarm PR #54 需先合入并发布）；普通设备刺激接口不能替代 Agent 判断")
            }
            throw SwarmError.server("眼镜 Agent 未接通（HTTP \(code)）：\(message)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decision = root["decision"] as? [String: Any],
              let willSignal = decision["willSignal"] as? Bool else {
            throw SwarmError.server("眼镜 Agent 返回内容不完整，未确认本帧是否进入蜂群")
        }

        if willSignal {
            guard let stimulus = root["stimulus"], !(stimulus is NSNull) else {
                throw SwarmError.server("Jev 判定应通知蜂群，但本轮演出未接收刺激；请刷新场次后重试")
            }
            let intensity = decision["intensity"] as? Double ?? 0
            return "Jev 已通知蜂群 · 强度 \(String(format: "%.2f", intensity)) · \(captureId)"
        }

        let model = decision["model"] as? String ?? "Jev"
        let fallback = model == "fallback" ? "（本次使用本地降级规则）" : ""
        return "Jev 判断本帧无需打扰音乐\(fallback) · \(captureId)"
    }

    enum SwarmError: LocalizedError {
        case badURL, badImage, noRun(String), server(String)

        var errorDescription: String? {
            switch self {
            case .badURL: "中台地址无效"
            case .badImage: "无法解码图片"
            case let .noRun(reason): reason
            case let .server(reason): reason
            }
        }
    }

    private static func sha256Hex(_ s: String) -> String { sha256Hex(Data(s.utf8)) }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
