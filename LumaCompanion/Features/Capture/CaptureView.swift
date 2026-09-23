//
//  CaptureView.swift
//  首页：状态 + 电量 + 大拍摄键 + 最近一张 AI 预览。
//
//  只放四样东西，其余一切在别的 tab：连接状态、眼镜电量、拍摄、刚刚拍到的东西。
//  不放协议字节、不放事件日志、不放九宫格工具 —— 那些是原厂 App 的包袱。
//

import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var link: GlassesLink
    @State private var recentCaptures: [URL] = []
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ——— Viewfinder: the last AI preview fills the frame ———
                ZStack {
                    Rectangle().fill(.black)
                    // 解码走后台 + 缓存：这一屏每来一次状态/电量/Toast 变化都要重算
                    // body，原先每次都在主线程重新解一遍 JPEG。
                    if let data = link.lastCapture {
                        CachedImage(data: data, key: "lastCapture.\(data.count)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .overlay(alignment: .topLeading) { timestampBadge(data) }
                    } else {
                        placeholder
                    }
                }
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // ——— 最近拍摄：右滑保存到相册，左滑删除 ———
                if let latest = recentCaptures.first {
                    // .id 给每张卡稳定身份：删除后 first 换成下一张时，SwiftUI 会
                    // 重建视图而不是复用旧卡片的 @State（否则新卡片继承「已飞出屏幕」
                    // 状态，0.3 秒内先飞出再弹回）。
                    SwipeableCaptureCard(
                        captureURL: latest,
                        onDelete: { url in
                            if CaptureStore.delete(url) {
                                // 文件已经不在了，缓存里那张图必须一起失效：留下的话下
                                // 一个复用到同名的文件会直接显示上一张的像素。
                                ImageDecodeCache.invalidate(url.path)
                                showToast("已删除")
                                refreshCaptures()
                            } else {
                                // 删除失败时列表不动，只如实报错 —— 卡片原样回来
                                // 比假成功后照片"复活"更不困惑。
                                showToast("删除失败")
                            }
                        },
                        onSave: { url in
                            showToast("保存中…")
                            Task {
                                // 相册写入是异步的（PHPhotoLibrary），真实成败必须等
                                // 回调 —— 先报「保存中」，结果回来再更新 toast。
                                let ok = await CaptureStore.saveToPhotosFromDisk(url)
                                showToast(ok ? "已保存到相册" : "保存失败（检查相册权限）")
                            }
                        }
                    )
                    .id(latest)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ——— The shutter ———
                VStack(spacing: 14) {
                    captureButton

                    StatusPill()

                    if case let .failed(reason) = link.phase {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !link.phase.isConnected {
                        Button("重新连接") { link.start() }
                            .font(.subheadline.weight(.medium))
                    }
                }
                .padding(.vertical, 18)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Luma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: toast)
            .onAppear { refreshCaptures() }
            // iOS 17 起带参数的 onChange 已废弃，改用零参形式（语义完全一致）。
            .onChange(of: link.lastCaptureAt) { refreshCaptures() }
        }
    }

    private func refreshCaptures() {
        recentCaptures = CaptureStore.captures()
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == text { toast = nil }
        }
    }

    // MARK: - Pieces

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(link.phase.isConnected ? "按下快门，拍下你看见的" : "连接眼镜后开始拍摄")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func timestampBadge(_ data: Data) -> some View {
        Group {
            if let at = link.lastCaptureAt {
                Text(at.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
            }
        }
    }

    private var captureButton: some View {
        Button {
            link.takePhoto()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(link.phase.isConnected ? Color.lumaAccent : .secondary, lineWidth: 5)
                    .frame(width: 84, height: 84)
                Circle()
                    .fill(link.phase.isConnected ? Color.lumaAccent : Color.secondary.opacity(0.4))
                    .frame(width: 68, height: 68)
                if link.isTransferringCapture {
                    ProgressView().tint(.black).controlSize(.large)
                } else {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                        .foregroundStyle(link.phase.isConnected ? .black : .white.opacity(0.5))
                }
            }
        }
        .disabled(!link.phase.isConnected)
        .accessibilityLabel("拍摄")
    }
}
