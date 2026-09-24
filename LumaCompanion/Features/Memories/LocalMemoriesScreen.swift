import SwiftUI

/// BLE 拍照回传的小图。这个页面只读手机本地文件，不会启动眼镜热点。
struct LocalMemoriesScreen: View {
    let onCapture: () -> Void
    @EnvironmentObject private var link: GlassesLink
    @State private var captures: [URL] = []
    @State private var selected: LocalCapture?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("YOUR MOMENTS")
                                .font(.caption2.weight(.semibold))
                                .tracking(2)
                                .foregroundStyle(.lumaAccent)
                            Text("记忆")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("眼镜通过蓝牙回传的照片，保存在这台 iPhone。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.callout.weight(.semibold))
                                .frame(width: 42, height: 42)
                                .background(Color.lumaSurface, in: Circle())
                        }
                        .accessibilityLabel("刷新照片")
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(captures.count)")
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("张已保存的预览")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "iphone.gen3")
                            .font(.title3)
                            .foregroundStyle(.lumaAccent)
                    }
                    .padding(18)
                    .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 20))

                    if captures.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.lumaAccent)
                                .frame(width: 72, height: 72)
                                .background(Color.lumaAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                            Text("第一张照片，从这里开始")
                                .font(.title3.weight(.semibold))
                            Text("连接眼镜，在感知页按下快门。照片回来后会自动收藏在这里。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(action: onCapture) {
                                Label("去感知", systemImage: "arrow.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.lumaAccent)
                            .foregroundStyle(.black)
                            .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 24))
                    } else {
                        Text("全部照片")
                            .font(.headline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(captures, id: \.self) { url in
                                Button { selected = LocalCapture(url: url) } label: {
                                    CachedFileImage(url: url)
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(1, contentMode: .fill)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 110)
            }
            .background(Color.lumaBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selected) { capture in
                LocalCaptureDetail(url: capture.url) {
                    guard CaptureStore.delete(capture.url) else {
                        message = "删除失败"
                        return
                    }
                    ImageDecodeCache.invalidate(capture.url.path)
                    selected = nil
                    refresh()
                }
            }
            .alert("操作失败", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
        }
        .onAppear { refresh() }
        .onChange(of: link.lastCaptureAt) { refresh() }
    }

    private func refresh() { captures = CaptureStore.captures() }
}

private struct LocalCapture: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct LocalCaptureDetail: View {
    let url: URL
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var saveMessage: String?
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CachedFileImage(url: url, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(CaptureStore.timestamp(of: url.lastPathComponent)
                    .formatted(.dateTime.year().month().day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let saveMessage { Text(saveMessage).font(.caption) }
                HStack(spacing: 12) {
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    Button {
                        saving = true
                        Task {
                            let saved = await CaptureStore.saveToPhotosFromDisk(url)
                            saveMessage = saved ? "已存入系统相册" : "保存失败，请检查相册权限"
                            saving = false
                        }
                    } label: { Label("存相册", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("拍摄预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .confirmationDialog("删除这张照片？", isPresented: $confirmingDelete) {
                Button("删除", role: .destructive, action: onDelete)
            }
        }
    }
}
