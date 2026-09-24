//
//  ImageDecodeCache.swift
//  图片解码缓存：把 JPEG 的解码与磁盘读取挪出主线程，并把结果缓存起来。
//
//  原先三处视图都直接在 `body` 里解图：
//
//      CaptureView         UIImage(data: link.lastCapture)
//      SwipeableCaptureCard  UIImage(contentsOfFile:)
//      MemoriesScreen.Cell   UIImage(data: thumbnail)
//
//  `body` 不是只跑一次的地方 —— 连接状态、电量、Toast、手势位移（拖动时每帧）都会
//  触发重算，于是同一张 JPEG 每帧被解码一次，全部落在主线程上。表现为：拍摄页出 Toast
//  时抖一下、记忆页网格滚动发涩、最近拍摄卡片拖动不跟手。
//
//  这里只做两件事：后台解码 + NSCache 缓存。没有动画、没有占位骨架 —— 第一次解出来之前
//  该空就空着，比用假图糊过去诚实。
//

import SwiftUI
import UIKit

enum ImageDecodeCache {

    private static let images = NSCache<NSString, UIImage>()
    private static let setupLock = NSLock()
    private static var configured = false

    private static func prepare() {
        setupLock.lock()
        defer { setupLock.unlock() }
        guard !configured else { return }
        configured = true
        // 够放下整个相册网格外加若干张预览，再多就该被淘汰了。
        images.countLimit = 240
        // 缩略图可以从 Data 重解，属于可再生资源：内存告警时整批丢掉，别把峰值顶上去。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in images.removeAllObjects() }
    }

    /// 已经解过的直接给。`key` 必须能唯一代表内容（文件名 / 服务端条目的 id）。
    static func cached(_ key: String) -> UIImage? {
        prepare()
        return images.object(forKey: key as NSString)
    }

    /// 后台线程解码 `Data` 后回填。UIKit 允许在任意线程解码，只要最终显示在主线程。
    static func image(from data: Data, key: String) async -> UIImage? {
        if let hit = cached(key) { return hit }
        prepare()
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let decoded = UIImage(data: data) else { return nil }
            ImageDecodeCache.images.setObject(decoded, forKey: key as NSString)
            return decoded
        }.value
    }

    /// 从磁盘读 + 解码。卡片展示的是本地 Captures 目录下的文件，读盘也不能在主线程。
    static func image(at url: URL) async -> UIImage? {
        let key = url.path
        if let hit = cached(key) { return hit }
        prepare()
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url),
                  let decoded = UIImage(data: data) else { return nil }
            ImageDecodeCache.images.setObject(decoded, forKey: key as NSString)
            return decoded
        }.value
    }

    /// 忘记一张图（对应的本地文件被删掉时必须调用，否则缓存会把死去的文件留多久都不知道）。
    static func invalidate(_ key: String) {
        prepare()
        images.removeObject(forKey: key as NSString)
    }
}

// MARK: - Views

/// 异步解码 + 缓存的图片。`key` 变化时自动重解。
struct CachedImage: View {
    let data: Data
    let key: String
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: key) {
            image = ImageDecodeCache.cached(key)
            if image == nil { image = await ImageDecodeCache.image(from: data, key: key) }
        }
    }
}

/// 异步读盘 + 解码 + 缓存。给本地 Captures 里的文件用；读不到就 fallback。
struct CachedFileImage: View {
    let url: URL
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = ImageDecodeCache.cached(url.path)
            if image == nil { image = await ImageDecodeCache.image(at: url) }
        }
    }
}
