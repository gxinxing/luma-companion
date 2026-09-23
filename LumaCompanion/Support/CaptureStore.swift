//
//  CaptureStore.swift
//  BLE 回传的 AI 预览图的本地持久化。App 重启后拍摄页仍有上一张 ——
//  "记忆"的第一层：连不上眼镜也能翻到最近拍下的东西。
//

import Foundation
import Photos
import UIKit

enum CaptureStore {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 全部预览图（文件名即时间戳，最新在前）。
    static func captures() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
            .reversed()
            .map { directory.appendingPathComponent($0) }
    }

    /// 删除一张预览图（左滑动作）。
    @discardableResult
    static func delete(_ url: URL) -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// 保存到 iOS 相册（右滑动作）。需要 Info.plist 的 NSPhotoLibraryAddUsageDescription。
    /// 异步并把真实结果回传 —— 旧的 `UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)`
    /// 后台落盘、无条件返回成功，权限被拒时用户照样看到「已保存」，实际什么都没存。
    static func saveToPhotos(_ data: Data) async -> Bool {
        guard let image = UIImage(data: data) else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }

    /// 卡片右滑保存入口：磁盘读取放后台 Task（调用方在主线程，不能同步读文件），
    /// 再走真正的异步相册写入。
    static func saveToPhotosFromDisk(_ url: URL) async -> Bool {
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data else { return false }
        return await saveToPhotos(data)
    }

    /// 文件名时间戳的统一格式：秒级精度会在连拍/重传同秒时静默覆盖上一张（.atomic 直接
    /// 落盘同名文件），加毫秒位；locale 固定 POSIX，`latest()` 用同一 formatter 解析。
    private static let stampFormat = "yyyyMMdd_HHmmss_SSS"

    @discardableResult
    static func save(_ data: Data, at date: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = stampFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = directory.appendingPathComponent("capture_\(formatter.string(from: date)).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 最新一张预览图（按文件名时间戳），没有则 nil。
    static func latest() -> (data: Data, at: Date)? {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
        guard let name = files.last,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return (data, timestamp(of: name))
    }

    /// 把 `capture_…​.jpg` 文件名解析回拍摄时间。优先毫秒格式，再回落旧版秒级格式
    /// （历史文件仍以旧格式存在，解析失败会让拍摄页时间戳显示成 2001 年）。
    static func timestamp(of filename: String) -> Date {
        let stamp = filename
            .replacingOccurrences(of: "capture_", with: "")
            .replacingOccurrences(of: ".jpg", with: "")
        for format in [stampFormat, "yyyyMMdd_HHmmss"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: stamp) { return date }
        }
        return .distantPast
    }
}
