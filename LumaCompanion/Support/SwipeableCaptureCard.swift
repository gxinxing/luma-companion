//
//  SwipeableCaptureCard.swift
//  「最近拍摄」可滑动卡片：右滑保存到相册，左滑删除。
//
//  自绘手势（SwiftUI 的 .swipeActions 只在 List 里可用）。拖动时露出底层动作色，
//  越过阈值松手即执行并飞出；未过阈值弹回。触觉反馈在动作触发瞬间给出。
//

import SwiftUI

struct SwipeableCaptureCard: View {
    let captureURL: URL
    var onDelete: (URL) -> Void
    var onSave: (URL) -> Void

    @State private var offsetX: CGFloat = 0
    @State private var flying = false

    private let threshold: CGFloat = 110

    var body: some View {
        ZStack {
            // 底层动作色：拖向右露出左边的绿色「保存」，拖向左露出右边的红色「删除」
            HStack {
                if offsetX > 10 {
                    Label("保存到相册", systemImage: "square.and.arrow.down.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .transition(.opacity)
                }
                Spacer()
                if offsetX < -10 {
                    Label("删除", systemImage: "trash.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 18)
                        .transition(.opacity)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(offsetX > 10 ? Color.lumaAccent : Color.lumaRecording)
            )

            cardFace
                .offset(x: flying ? (offsetX < 0 ? -500 : 500) : offsetX)
                .opacity(flying ? 0 : 1)
                .gesture(drag)
        }
        .frame(height: 96)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: offsetX)
        .animation(.easeOut(duration: 0.25), value: flying)
    }

    private var cardFace: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
                // 拖动时 body 每帧重算，原先每帧都在主线程做一次 `contentsOfFile`
                // 磁盘读 + JPEG 解码 —— 手势不跟手的直接原因。
                CachedFileImage(url: captureURL)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("眼镜拍摄")
                    .font(.subheadline.weight(.medium))
                Text(Self.timeLabel(of: captureURL))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("右滑保存 · 左滑删除")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "arrow.left.and.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 只响应水平主导的拖动，避免和纵向滚动打架
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offsetX = value.translation.width
            }
            .onEnded { value in
                // 松手时同样要纵向校验： onChanged 的 guard 在松手前最后一次事件可能
                // 已经是纵向主导，不校验的话斜向甩动只要横向位移过阈值就会触发动作
                // （删除不可恢复，宁可少触发）。
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    offsetX = 0
                    return
                }
                let width = value.translation.width
                if width > threshold {
                    flying = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSave(captureURL)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { flying = false; offsetX = 0 }
                } else if width < -threshold {
                    flying = true
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    onDelete(captureURL)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { flying = false; offsetX = 0 }
                } else {
                    offsetX = 0
                }
            }
    }

    /// 卡片副标题：把文件名时间戳解析成人类可读时间；解析失败（异常文件名）时
    /// 原样显示文件名而不是 2001 年这种误导值。
    private static func timeLabel(of url: URL) -> String {
        let date = CaptureStore.timestamp(of: url.lastPathComponent)
        guard date != .distantPast else {
            return url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "capture_", with: "")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
