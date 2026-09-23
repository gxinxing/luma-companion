//
//  MemoriesScreen.swift
//  记忆：眼镜相册 —— 浏览、下载、分享、删除。
//
//  流程与 demo 的 Gallery 完全一致（那是已验证的路线）：
//    0x39 打开热点 → 等 SSID(0x25) → 静置 → 加入网络 → 列表/缩略图/下载/删除
//    → 任何退出路径都写 0x44（否则眼镜停在 SoftAP 模式持续耗电）。
//
//  与 demo 不同的只有 UI：去掉教学式步骤清单，换成按文件夹分组的网格 + 查看器。
//

import Combine
import SwiftUI
import LumaCore

@MainActor
final class MemoriesModel: ObservableObject {

    /// Bring-up 过程的六步。分开命名是因为一个"加载中"分不清是慢还是死。
    enum Step: Int, CaseIterable {
        case openingWifi
        case awaitingSsid
        case settling
        case joining
        case listing
        case browsing

        var title: String {
            switch self {
            case .openingWifi: return "正在打开眼镜热点"
            case .awaitingSsid: return "等待网络名称"
            case .settling: return "等待热点就绪"
            case .joining: return "正在加入网络"
            case .listing: return "正在读取相册"
            case .browsing: return "就绪"
            }
        }
    }

    @Published private(set) var step: Step = .openingWifi
    @Published private(set) var status: String = ""
    @Published private(set) var failure: String?
    /// 单个操作（缩略图/下载/删除/刷新）的失败。与 `failure`（bring-up 流程失败）
    /// 分开：一次删除失败不该把整个图库打回热点拉起页。
    @Published private(set) var actionError: String?
    @Published private(set) var sections: [GallerySection] = []
    @Published private(set) var thumbnails: [String: Data] = [:]
    @Published private(set) var busyItem: String?
    @Published private(set) var savedFiles: [URL] = []
    @Published private(set) var finished = false
    /// 手动加入热点的引导文案。免费签名没有 Hotspot 权限，程序化加入不可用——
    /// 首次需要用户到 设置▸Wi-Fi 手动加入（SSID+密码来自 0x25 推送与 crate）。
    @Published private(set) var joinHint: String?
    /// 本地相册模式：眼镜 WiFi 不可用时，展示拍摄页拍到的本地照片。
    /// 这是观众体验的保底——不让他们看到一个空白的"失败"页。
    @Published private(set) var localMode = false
    /// 本地相册的照片（来自 CaptureStore）。
    @Published private(set) var localCaptures: [URL] = []

    private let link: GlassesLink
    private var session: URLSession?
    private var client: FileApiClient?
    private var ssid: String?
    private var task: Task<Void, Never>?

    /// 文件 API 是纯 HTTP，可达性探测就是往 80 端口插一个 socket。
    private static let httpPort: UInt16 = 80

    init(link: GlassesLink) {
        self.link = link
    }

    /// 浏览中只看 step —— 操作失败走 `actionError` 弹提示，不再连坐整个图库。
    var isBrowsing: Bool { step == .browsing }

    /// 刷新本地相册（从 CaptureStore 读取）。
    func refreshLocalCaptures() {
        localCaptures = CaptureStore.captures()
    }

    // MARK: - The flow

    func start() {
        // 自愈：上一轮已 finish 过（查看器 sheet 场景下 onDisappear 曾把会话拆掉）
        // 时从头再来，而不是永远卡在死网格上。
        if finished { reset() }
        guard task == nil else { return }
        guard link.phase.isConnected else {
            failure = "眼镜未连接，先回「拍摄」页等它连上"
            return
        }
        // 上一轮的失败文案必须在这里清：「未连接」这种立刻返回的路径走不到 run()，
        // 不清的话用户点了重试，屏幕上还留着上一次的失败原因。
        failure = nil
        task = Task { await run() }
    }

    /// 「眼镜连上了」之后由视图调用。
    ///
    /// 场景：用户在眼镜还没连好时先切进了记忆 tab，于是只能看到一句「眼镜未连接」；
    /// 由于这里原先没有 `.onChange(of: link.phase)`，眼镜稍后连上也永远不会重试，必须
    /// 手动重进一次 tab。LiveScreen 早有这个入口，记忆页补上同一个。
    func retryIfIdle() {
        guard !finished, task == nil, !isBrowsing else { return }
        start()
    }

    /// 失败路径的收尾：0x44 + 退出网络。
    ///
    /// `finish()` 只在切走 tab 和点「完成」时被走到，而 bring-up 失败之后用户通常是
    /// 直接切走或者连点重试 —— 0x39 已经把 SoftAP 拉起来了却没人用 0x44 收回去，
    /// 眼镜会一直停在热点模式耗电。
    private func abandon() {
        session?.finishTasksAndInvalidate()
        session = nil
        client = nil
        let leaving = ssid
        ssid = nil
        Task {
            await link.write("fileDownloadComplete", glassesFileDownloadComplete())
            if let leaving { GlassesWiFi.leave(ssid: leaving) }
        }
    }

    private func run() async {
        do {
            step = .openingWifi
            link.clearWifiSSID()
            await link.write("openWifi(files)", glassesOpenWifi(service: .files, p2p: false))

            step = .awaitingSsid
            guard let ssid = await link.awaitSSID() else {
                throw GlassesWiFi.WiFiError.noSSID
            }
            self.ssid = ssid

            step = .settling
            try await Task.sleep(for: GlassesWiFi.ssidSettle)

            step = .joining
            // 免费个人团队没有 Hotspot 权限：join() 会静默失败，真正判据是下面的
            // waitForHost TCP 探测。给用户展示 SSID+密码引导手动加入；手动加入一次
            // 后 iOS 会记住该网络，之后热点一起来就自动关联，无需再引导。
            joinHint = "首次使用请到 iPhone「设置▸Wi-Fi」\n手动加入眼镜网络「\(ssid)」\n密码：\(glassesWifiPassphrase())"
            try await GlassesWiFi.join(ssid: ssid)
            // 先用 15 秒快速探测：之前手动加入过的话 iOS 会记住网络，秒级自动关联。
            // 从未连过则快速失败，展示手动加入引导而非干等 75 秒。
            do {
                _ = try await GlassesWiFi.waitForHostQuick(port: Self.httpPort) { [weak self] seconds in
                    self?.status = "等待接入眼镜网络（\(seconds)s）— 加入后自动继续"
                }
            } catch {
                // 快速探测失败，再给一次长窗口（用户可能正在手动加入中）
                status = "等待手动加入眼镜网络…"
                _ = try await GlassesWiFi.waitForHost(port: Self.httpPort) { [weak self] seconds in
                    self?.status = "等待接入眼镜网络（\(seconds)s）— 加入后自动继续"
                }
            }
            joinHint = nil

            step = .listing
            let session = GlassesWiFi.makeSession()
            self.session = session
            let client = FileApiClient(session: session)
            self.client = client

            let listing = try await client.list()
            sections = listing.sections
            step = .browsing
            await loadThumbnails()
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            status = "已取消"
        } catch {
            // 被取消意味着 finish() 那一路已经在写 0x44、退网络了，不要再写一遍。
            guard !Task.isCancelled else { return }
            // WiFi 探测超时 → 切本地相册 fallback，让观众至少能看到拍摄页拍的照片。
            // 不展示一个死气沉沉的"失败"页——那会让评委觉得这 tab 彻底坏了。
            refreshLocalCaptures()
            if !localCaptures.isEmpty {
                localMode = true
                step = .browsing
                status = "本地相册（眼镜网络不可用）"
            } else {
                failure = error.localizedDescription
                status = "失败"
            }
            abandon()
        }
        // 被 finish() 取消的旧任务不清引用：它恢复时 start() 可能已挂上新任务，
        // 无条件清 nil 会抹掉新任务的句柄（stop 就再也取消不了它）。
        if !Task.isCancelled { task = nil }
    }

    /// 删除后不重连网络、只重拉列表。
    func refresh() async {
        guard let client else { return }
        do {
            let listing = try await client.list()
            sections = listing.sections
            await loadThumbnails()
        } catch {
            actionError = "刷新失败：\(error.localizedDescription)"
        }
    }

    /// 缩略图尽力而为、刻意串行：眼镜上是个小 HTTP 服务器，刚入网时一打并发 GET
    /// 就是把列表变成卡死。
    private func loadThumbnails() async {
        guard let client else { return }
        for section in sections {
            for item in section.items where thumbnails[item.id] == nil && item.hasThumbnail {
                if Task.isCancelled { return }
                if let data = await client.thumbnail(for: item) {
                    thumbnails[item.id] = data
                }
            }
        }
    }

    // MARK: - Per-file actions

    func download(_ item: GalleryItem) async -> URL? {
        guard let client, busyItem == nil else { return nil }
        busyItem = item.id
        defer { busyItem = nil }
        do {
            let url = try await client.download(item)
            savedFiles.removeAll { $0.lastPathComponent == url.lastPathComponent }
            savedFiles.insert(url, at: 0)
            return url
        } catch {
            actionError = "下载失败：\(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ item: GalleryItem) async {
        guard let client, busyItem == nil else { return }
        busyItem = item.id
        defer { busyItem = nil }
        do {
            try await client.delete(item)
            // 先本地剔除，再尽力 refresh：refresh 若失败，已删项不能复活在网格里。
            // （GallerySection 是 let 字段结构体，只能整段重建。）
            sections = sections.map { section in
                guard section.items.contains(where: { $0.id == item.id }) else { return section }
                return GallerySection(
                    folder: section.folder,
                    items: section.items.filter { $0.id != item.id },
                    deviceCount: section.deviceCount
                )
            }
            thumbnails[item.id] = nil
            await refresh()
        } catch {
            actionError = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Teardown

    /// `0x44` ——"都拿完了"。眼镜关掉图像处理器、撤掉热点；然后删掉热点配置让手机
    /// 回到正常 Wi-Fi。幂等：从 tab 切走和失败路径都会走到这里。
    func finish() {
        guard !finished else { return }
        finished = true
        task?.cancel()
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        client = nil
        let leaving = ssid
        ssid = nil
        Task {
            await link.write("fileDownloadComplete", glassesFileDownloadComplete())
            if let leaving { GlassesWiFi.leave(ssid: leaving) }
        }
    }

    func dismissFailure() { failure = nil }

    func dismissActionError() { actionError = nil }

    /// 下次进入 tab 重新走一遍流程。
    func reset() {
        finished = false
        failure = nil
        actionError = nil
        step = .openingWifi
        sections = []
        thumbnails = [:]
        savedFiles = []
        localMode = false
        localCaptures = []
        // 上轮的行内状态不清零会串台：busyItem 残留会锁死所有行按钮，
        // status/joinHint 残留会把上一轮的等待文案带进新一轮。
        busyItem = nil
        status = ""
        joinHint = nil
    }

    /// 进入 tab 时调用：只有上一轮已经 finish 过才从头再来。
    func resetIfNeeded() {
        guard finished else { return }
        reset()
    }
}

// MARK: - The screen

struct MemoriesScreen: View {
    @StateObject private var model: MemoriesModel
    @EnvironmentObject private var link: GlassesLink
    @State private var selected: GalleryItem?
    @State private var selectedLocal: URL?

    init(link: GlassesLink) {
        _model = StateObject(wrappedValue: MemoriesModel(link: link))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isBrowsing && !model.localMode {
                    grid
                } else if model.isBrowsing && model.localMode {
                    localGrid
                } else if model.finished {
                    finishedView
                } else {
                    bringUp
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.isBrowsing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { model.finish() }
                    }
                }
            }
            // 操作级失败（下载/删除/刷新）只弹提示，不打回 bring-up。
            .alert(
                "操作失败",
                isPresented: Binding(
                    get: { model.actionError != nil },
                    set: { if !$0 { model.dismissActionError() } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
        }
        // 进入 tab 才拉起热点，离开就撤 —— 眼镜不陪你在 SoftAP 模式里耗电。
        .onAppear { model.resetIfNeeded(); model.start() }
        // 眼镜连上之前进过这个 tab 的人不必重进一次才能用 —— 这里补的连接重试入口，
        // LiveScreen 早就有。
        // iOS 17 起带单个参数的 onChange 已废弃，改两参形式（语义完全一致）。
        .onChange(of: link.phase) { _, phase in
            if phase.isConnected { model.retryIfIdle() }
        }
        // App 退到后台后 iPhone 会挂起 TCP/UDP，回来时链路是死的，而眼镜还留在热点
        // 模式耗电 —— 后台等同于离开，按同一套收尾处理。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            guard selected == nil else { return }
            model.finish()
        }
        // sheet 呈现时部分 iOS 版本会给底层视图发 onDisappear：查看器开着的时候
        // 绝不能把 Wi-Fi 会话拆掉（否则关闭查看器后网格全是死按钮）。
        .onDisappear { if selected == nil { model.finish() } }
        .sheet(item: $selected) { item in
            MemoryViewer(item: item, model: model)
        }
        .sheet(item: $selectedLocal) { url in
            LocalPhotoViewer(url: url)
        }
    }

    // MARK: - Finished

    /// 点过「完成」之后：热点已撤，网格是死的，与其留一张点不动的图，
    /// 不如给一个明确的终态 + 一键重来。
    private var finishedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("已断开眼镜相册")
                .font(.callout)
            Text("眼镜已退出热点模式省电")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新连接") { model.reset(); model.start() }
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bring-up

    private var bringUp: some View {
        VStack(spacing: 14) {
            if let failure = model.failure {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.lumaRecording)
                Text(failure)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if !model.finished {
                    Button("重试") { model.dismissFailure(); model.start() }
                }
            } else {
                ProgressView().controlSize(.large)
                Text(MemoriesModel.Step.allCases[model.step.rawValue].title)
                    .font(.callout)
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else {
                    Text("正在接入眼镜的专属网络…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let hint = model.joinHint {
                    Text(hint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                ForEach(model.sections) { section in
                    if !section.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            Text(section.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(section.items) { item in
                                    Cell(item: item, thumbnail: model.thumbnails[item.id])
                                        .onTapGesture { selected = item }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if model.sections.allSatisfy({ $0.items.isEmpty }) {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("眼镜里还没有照片或录音")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("戴上眼镜拍一张，它就会出现在这里")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 12)
        }
    }


    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    }

    // MARK: - Local Gallery (fallback when glasses WiFi is unreachable)

    /// 本地相册网格：展示拍摄页拍到的所有照片。
    /// 眼镜 WiFi 连不上时，这里至少让观众看到"东西"，而不是一个死气沉沉的失败页。
    private var localGrid: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("本地相册")
                    .font(.headline)
                Text("眼镜网络不可用，展示本机已拍照片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            if model.localCaptures.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有照片")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("先到「拍摄」页用眼镜拍几张")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.localCaptures, id: \.self) { url in
                        CachedFileImage(url: url)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onTapGesture { selectedLocal = url }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // 重试连接眼镜
            Button("重试连接眼镜相册") {
                model.localMode = false
                model.reset()
                model.start()
            }
            .font(.subheadline)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Grid cell

private struct Cell: View {
    let item: GalleryItem
    let thumbnail: Data?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let thumbnail {
                // 网格滚动时每个 cell 每帧都会重算；直接解 Data 会把整屏的滑动顶住。
                CachedImage(data: thumbnail, key: item.id)
            } else {
                Image(systemName: item.systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Viewer

private struct MemoryViewer: View {
    let item: GalleryItem
    @ObservedObject var model: MemoriesModel
    @Environment(\.dismiss) private var dismiss

    @State private var downloadedURL: URL?
    @State private var downloading = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(.black)
                    if let thumbnail = model.thumbnails[item.id] {
                        CachedImage(data: thumbnail, key: "viewer.\(item.id)", contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    } else {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 52))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.basename).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(item.sizeText) · \(item.createdText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                HStack(spacing: 12) {
                    // 下载 —— 下载完才能分享；原厂 App 没有分享，我们有。
                    Button {
                        guard !downloading else { return }
                        downloading = true
                        Task {
                            downloadedURL = await model.download(item)
                            downloading = false
                        }
                    } label: {
                        Label(downloadedURL == nil ? "下载" : "已下载",
                              systemImage: downloadedURL == nil ? "arrow.down.circle" : "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(downloading || model.busyItem == item.id)

                    if let url = downloadedURL {
                        ShareLink(item: url) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.busyItem == item.id)

                    if downloading || model.busyItem == item.id {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(item.basename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "删除后无法恢复",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("删除「\(item.basename)」", role: .destructive) {
                    Task { await model.delete(item) }
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

// MARK: - Local photo viewer (fallback mode)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// 展示本地拍摄的照片（CaptureStore 存的），带分享和保存到相册。
/// 这是在眼镜 WiFi 不可用时的 fallback 查看器——让观众至少能看、能分享。
struct LocalPhotoViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CachedFileImage(url: url, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(CaptureStore.timestamp(of: url.lastPathComponent)
                            .formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            await CaptureStore.saveToPhotosFromDisk(url)
                        }
                    } label: {
                        Label("存相册", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("本地照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
