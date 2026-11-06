import AppKit
import SwiftUI

private let warnAmber = Color.orange

extension Notification.Name {
    /// ⌘F：菜单栏点「搜索」后，让搜索框成为第一响应者
    static let updateRadarFocusSearch = Notification.Name("UpdateRadarFocusSearch")
    /// 从外面改写搜索框内容（点清除按钮、点最近搜索里的一条）。
    /// 必须走通知：NSTextField 正在编辑时，SwiftUI 的 binding 回写到不了编辑器里，
    /// 不清掉编辑器里的字，界面就会和 ui.query 对不上。
    static let updateRadarSetSearch = Notification.Name("UpdateRadarSetSearch")

    /// 点更新通知后传过来的 App id：列表翻到「可更新」并定位到那一行。
    static let urRevealRow = Notification.Name("URRevealRow")
}

/// 顶栏/分段控件/设置页这些「界面壳」的状态。
/// 单独拎成一只对象，是因为列表页用 @ObservedObject 盯着整个 UIState：
/// 任何 @Published 变化都会让两页上百行全部重新求值（实测一次 ~100ms）。
/// 切页签、聚焦搜索框都属于只看壳的事，
/// 放到这边就不会惊动列表了。UIState 里留了同名转发属性，调用方照旧写 ui.tab。
final class ChromeState: ObservableObject {
    @Published var tab: Int = 0
    /// 分段控件里鼠标正停在那一格（nil = 鼠标不在轨道上）
    @Published var hoverTab: Int?
    /// 两格各自在轨道里的位置，用来让选中胶囊滑过去
    @Published var tabFrames: [Int: CGRect] = [:]
    /// 分段轨道整条的宽度（底栏扫描胶囊按它算）
    @Published var tabTrackWidth: CGFloat = 0
    /// 搜索框是不是正在编辑：决定要不要把「最近搜索」列出来
    @Published var searchActive = false
    /// 面板当前显示的是设置页（点齿轮翻过去，点「返回」翻回来）
    @Published var showSettings = false
    /// 面板当前显示的是「关于」页（点「•••」翻过去，不弹独立窗口）
    @Published var showAbout = false
    /// 关于页是从设置页翻过来的：返回时回到设置页，而不是列表
    @Published var aboutFromSettings = false
}

/// 界面自身的小状态。用 ObservableObject 而不是 @State，因为这台机器只有
/// Command Line Tools，SwiftUI 的宏插件（@State 依赖它）不可用。
final class UIState: ObservableObject {
    /// 界面壳的状态（见 ChromeState 的注释）
    let chrome = ChromeState()
    /// 底栏「扫描」按钮的鼠标悬停状态（自绘玻璃按钮，明暗要自己给）
    let scanHover = HoverBox()
    /// 「当前哪个页签」。真正的发布源在 chrome 里，列表页不受影响
    var tab: Int {
        get { chrome.tab }
        set { chrome.tab = newValue }
    }
    var hoverTab: Int? {
        get { chrome.hoverTab }
        set { chrome.hoverTab = newValue }
    }
    var tabFrames: [Int: CGRect] {
        get { chrome.tabFrames }
        set { chrome.tabFrames = newValue }
    }
    var tabTrackWidth: CGFloat {
        get { chrome.tabTrackWidth }
        set { chrome.tabTrackWidth = newValue }
    }
    var searchActive: Bool {
        get { chrome.searchActive }
        set { chrome.searchActive = newValue }
    }
    var showSettings: Bool {
        get { chrome.showSettings }
        set { chrome.showSettings = newValue }
    }
    var showAbout: Bool {
        get { chrome.showAbout }
        set { chrome.showAbout = newValue }
    }
    var aboutFromSettings: Bool {
        get { chrome.aboutFromSettings }
        set { chrome.aboutFromSettings = newValue }
    }

    @Published var query: String = ""
    /// 全部页里每一组是不是收起来了（key -> 收起了没）
    @Published var collapsedGroups: [String: Bool] = [:]
    /// 哪几行展开了更新说明（左键点一下展开，再点收起）
    @Published var expanded: Set<String> = []
    /// 每一行一个独立的小对象：鼠标划过时只重绘那一行，不动整个列表
    let hovers = HoverStore()

    /// 刚点开的那一行：列表要把它滚进视野
    private(set) var lastToggled: String?
    /// 键盘（↑↓）选中的行；Return 打开它的下载页 / 在 Finder 中显示。
    /// 同时作为 List 的 selection 绑定，选中底色由系统画。
    @Published var keyRow: String?
    /// 每一行在列表可视区里的位置（不发布，只给「要不要滚」用，避免滚动时反复重绘）
    var rowFramesByTab: [Int: [String: CGRect]] = [:]

    /// 最近搜索过的关键词，最新的在前，最多 5 条
    @Published var recentSearches: [String] =
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []

    private static let recentKey = "recentSearches"
    private static let recentLimit = 5

    /// 回车时记一条。已经搜过的词再搜一次会挪到最前面，不重复占位。
    func commitSearch(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        list.insert(word, at: 0)
        recentSearches = Array(list.prefix(Self.recentLimit))
        UserDefaults.standard.set(recentSearches, forKey: Self.recentKey)
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    /// 用一条历史记录（或空串）改写搜索框，并让输入框继续拿着焦点
    func applySearch(_ word: String) {
        query = word
        NotificationCenter.default.post(name: .updateRadarSetSearch, object: word)
    }

    func toggleExpanded(_ id: String) {
        // 注意：这里必须整体赋值。对 @Published 的 Set 调 insert/remove 是原地改，
        // 不会经过 setter，也不会发通知，界面（和下面的 onChange）都不会动。
        let wasOpen = expanded.contains(id)
        expanded = wasOpen ? expanded.subtracting([id]) : expanded.union([id])
        lastToggled = id
    }

    init() {
        // 调试用：UPDATERADAR_TAB=1 直接打开「全部」页
        if ProcessInfo.processInfo.environment["UPDATERADAR_TAB"] == "1" { tab = 1 }
        // 调试用：UPDATERADAR_COLLAPSE=latest,unknown 直接收起这几组，方便看下面的组
        if let keys = ProcessInfo.processInfo.environment["UPDATERADAR_COLLAPSE"] {
            for k in keys.split(separator: ",") { collapsedGroups[String(k)] = true }
        }
        // 调试用：UPDATERADAR_EXPAND=com.apple.Keynote,... 直接展开这几行，方便截图
        let env = ProcessInfo.processInfo.environment
        if let ids = env["UPDATERADAR_EXPAND"] {
            for id in ids.split(separator: ",") { expanded.insert(String(id)) }
        }
        // 调试用：UPDATERADAR_EXPAND_LATE=... 起来五秒后展开，用来看展开时的自动滚动
        if let ids = env["UPDATERADAR_EXPAND_LATE"], let id = ids.split(separator: ",").first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.toggleExpanded(String(id))
            }
        }
    }
}

/// 每一行在列表里的位置，用来判断「展开后会不会超出面板底部」
struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

final class HoverBox: ObservableObject {
    @Published var on = false
}

final class HoverStore {
    private var boxes: [String: HoverBox] = [:]
    func box(for id: String) -> HoverBox {
        if let b = boxes[id] { return b }
        let b = HoverBox()
        boxes[id] = b
        return b
    }
}

/// 「全部」页的一组
private struct RowGroup {
    let key: String
    let title: String
    let rows: [AppRow]
}

private func byName(_ a: AppRow, _ b: AppRow) -> Bool {
    a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending
}

/// 「可更新」页的行：只列有新版本的，按名字排
@MainActor
private func computeVisibleRows(_ service: UpdateService, _ ui: UIState) -> [AppRow] {
    service.rows
        .filter { !service.settings.ignored.contains($0.id) && $0.isUpdate }
        .sorted(by: byName)
}

/// 顺序照用户要的：可更新 → 已是最新 → 无检测源 → 检测失败（放最后）→ 已忽略
@MainActor
private func computeRowGroups(_ service: UpdateService, _ ui: UIState) -> [RowGroup] {
    let ignoredIds = Set(service.settings.ignored)
    var base = service.rows
    if service.settings.hideUnknownEnabled {
        base = base.filter { $0.hasSource || ignoredIds.contains($0.id) }
    }
    if service.settings.hideFailedEnabled {
        base = base.filter { $0.status != .failed || ignoredIds.contains($0.id) }
    }
    if !ui.query.isEmpty {
        base = base.filter { $0.app.name.localizedCaseInsensitiveContains(ui.query) }
    }
    let ignored = base.filter { ignoredIds.contains($0.id) }.sorted(by: byName)
    let live = base.filter { !ignoredIds.contains($0.id) }
    var groups = [
        RowGroup(key: "update", title: "可更新", rows: live.filter { $0.status == .updateAvailable }.sorted(by: byName)),
        RowGroup(key: "latest", title: "已是最新", rows: live.filter { $0.status == .upToDate }.sorted(by: byName)),
        RowGroup(key: "unknown", title: "无检测源", rows: live.filter { $0.status == .unknown }.sorted(by: byName)),
        RowGroup(key: "failed", title: "检测失败", rows: live.filter { $0.status == .failed }.sorted(by: byName)),
        RowGroup(key: "ignored", title: "已忽略", rows: ignored),
    ]
    // 这一页叫「其他」，平时就不列有更新的 App（它们在上一个页签里）；
    // 但当用户在搜索时得能搜到全部，不然"搜不到"会被当成软件坏了。
    if ui.query.isEmpty { groups.removeAll { $0.key == "update" } }
    return groups.filter { !$0.rows.isEmpty }
}

struct ContentView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject var ui: UIState
    /// 设置页要显示本软件的版本和自更新状态
    @ObservedObject var updater: SelfUpdater
    /// 界面壳的状态（顶栏、分段控件、设置页）。列表页不看它，切页签才不惊动列表
    @ObservedObject private var chrome: ChromeState
    /// 底栏「⏻」：退出
    var onQuit: () -> Void = {}

    init(service: UpdateService, ui: UIState, updater: SelfUpdater,
         onQuit: @escaping () -> Void = {}) {
        _service = ObservedObject(wrappedValue: service)
        _ui = ObservedObject(wrappedValue: ui)
        _updater = ObservedObject(wrappedValue: updater)
        _chrome = ObservedObject(wrappedValue: ui.chrome)
        self.onQuit = onQuit
    }

    private var visibleRows: [AppRow] { computeVisibleRows(service, ui) }
    private var rowGroups: [RowGroup] { computeRowGroups(service, ui) }

    var body: some View {
        // 顶部条和底栏不再作为"占位"排在列表上下，而是挂成列表的安全区内嵌：
        // 行能从条底下穿过去，条自己那层 ultraThinMaterial 把穿过的那几行糊掉，
        // 再叠上 macOS 26 的滚动边缘效果，滑到边上的内容就有一段渐隐，这就是透视感。
        // 老系统没有那条系统 API，纯靠材质兜底，效果弱一点但不会破。
        // 设置不再是独立窗口：点齿轮后内容横向翻过去，点「返回」再翻回列表。
        ZStack {
            // 列表不再用 if/else 换进换出：从设置页点「返回」时如果重新搭 listPage，
            // 两个 PageHost 里的 NSHostingView 都要从头排一遍，采样实测 144ms，就是那个卡顿。
            // 让它一直挂在树上，只用透明度做进出场，页面的显示列表始终是热的。
            listPage
                .opacity(ui.showSettings || ui.showAbout ? 0 : 1)
                // 不要位移：之前列表整体左移 24pt 淡出，底栏那颗齿轮会跟着往左跳一下。
                // 只做淡入淡出，按钮原地不动。
                // 透明时也别接活：设置页没有整块底色，点在空白处不该落到下面的列表行上
                .allowsHitTesting(!ui.showSettings && !ui.showAbout)
                // 进/出用不同节奏：点齿轮进设置页时列表（连同底栏那排按钮）要立刻收掉，
                // 否则设置页是透明地滑过来的，旧底栏会在原地多停一拍才被盖住，看着像没收干净。
                .animation(ui.showSettings || ui.showAbout ? .easeIn(duration: 0.08) : .snappy(duration: 0.26),
                           value: ui.showSettings || ui.showAbout)

            if ui.showSettings {
                settingsPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
            if ui.showAbout {
                aboutPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .frame(width: 364, height: 548)
        .clipped()
        .animation(.snappy(duration: 0.26), value: ui.showSettings)
        .animation(.snappy(duration: 0.26), value: ui.showAbout)
        // 图标先在后台暖进缓存：列表里是现取的，第一次切到「其他」页要在主线程上
        // 依次光栅化近百个图标，点一下能卡半秒
        .onChange(of: service.rows.count) {
            IconCache.shared.preload(service.rows.map { $0.app.path })
        }
        // 不铺不透明底色：让 NSPopover 自己的液态玻璃材质透过来
    }

    private var listPage: some View {
        list
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    // MARK: - 设置页

    private var settingsPage: some View {
        // 设置页不用「内容从底栏底下穿过去」那套：这里行比较密，穿过去会糊成一团。
        // 直接把滚动区和底栏分成上下两块，内容滚到底就停在底栏上方。
        VStack(spacing: 0) {
            ScrollView {
                PanelSettingsView(service: service)
            }
            .scrollIndicators(.never)
            .modifier(ScrollEdgeBlur())

            settingsFooter
        }
    }

    /// 设置页的底栏：返回 · 版本号 · 关于 · 退出（跟参考图同一套排列）。
    /// 返回用文字胶囊，右边圆钮仍然交给系统玻璃。
    private var settingsFooter: some View {
        HStack(spacing: 8) {
            backCapsule(help: "回到更新列表") { ui.showSettings = false }

            Text("版本 \(updater.currentVersion)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            footerButton("ellipsis", help: "关于") {
                ui.aboutFromSettings = true
                // 设置页收起来：两页都透明底色，叠在一起会透出下面的设置内容
                ui.showSettings = false
                ui.showAbout = true
            }
            footerButton("power", help: "退出更新雷达") { onQuit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // 同顶部条：底栏直接坐在系统液态玻璃上，不再另垫材质
    }

    /// 关于页：跟设置页同一套语言——顶部图标 + 名称，下面「信息」「反馈」两张玻璃卡片，
    /// 版权落在卡片和底栏之间。
    private var aboutPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 72, height: 72)

                Text("更新雷达")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 2)

                Text("有新版就提醒你，数据只存在本机。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 18)

            // 版本 / 检查更新这一行原来在设置页，现在搬到关于页——设置页里就不必再放一份
            aboutSection("信息") {
                AboutControlRow(symbol: "number", title: "当前版本") {
                    HStack(spacing: 8) {
                        Text("\(updater.currentVersion)（\(appBuild)）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let page = releasePageURL {
                            Button("发布说明") { NSWorkspace.shared.open(page) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Button("检查更新") { updater.check() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(updater.isChecking)
                        }
                    }
                }
                AboutValueRow(symbol: "laptopcomputer", title: "系统",
                              value: macOSName, showDivider: hasAvailableUpdate)
                if case let .available(version, downloadURL, _, hasDMG) = updater.phase {
                    AboutControlRow(symbol: "square.and.arrow.down",
                                    title: "安装 \(version)", showDivider: false) {
                        if hasDMG {
                            ConfirmingButton(title: "更新并重启",
                                             dialogTitle: "现在下载并安装 \(version)？",
                                             confirmTitle: "更新并重启",
                                             message: "会下载安装包、替换当前 App，然后自动重新打开。") {
                                updater.install(version: version, downloadURL: downloadURL)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else if let url = URL(string: downloadURL) {
                            Button("下载") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            aboutSection("反馈") {
                AboutLinkRow(symbol: "envelope", title: "邮件反馈",
                             value: "2598492427@qq.com") {
                    NSWorkspace.shared.open(feedbackMail)
                }
                AboutLinkRow(symbol: "link", title: "GitHub",
                             value: "在浏览器打开", showDivider: false) {
                    NSWorkspace.shared.open(githubIssues)
                }
            }

            Spacer(minLength: 0)

            Text(appCopyright)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)

            aboutFooter
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// 和设置页 section 同款：小号标题 + 系统玻璃卡片 + 行内细分隔线
    private func aboutSection<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .modifier(SettingsCard())
        }
        .padding(.bottom, 14)
    }

    private var aboutFooter: some View {
        HStack(spacing: 8) {
            // 从设置页翻过来的，返回就落回设置页；从列表翻过来的，返回就落回列表
            backCapsule(help: "返回上一页") {
                ui.showAbout = false
                if ui.aboutFromSettings { ui.showSettings = true }
            }
            Spacer(minLength: 0)
            footerButton("power", help: "退出更新雷达") { onQuit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func backCapsule(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("返回")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            // 系统玻璃按钮会在内容外补 4pt/边，所以内容给 18pt，画出来正好 26pt
            .frame(height: 18)
            .contentShape(Capsule())
        }
        .modifier(GlassCapsuleButton())
        .help(help)
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var appCopyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 更新雷达 · 保留所有权利"
    }

    /// 反馈邮件入口：收件人、标题、版本和系统版本都预填好，用户只补问题描述。
    /// 用 mailto 而不是只有 GitHub Issues，是因为不少用户打不开 GitHub。
    private var feedbackMail: URL {
        let version = "\(updater.currentVersion)（\(appBuild)）"
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = "2598492427@qq.com"
        mail.queryItems = [
            URLQueryItem(name: "subject", value: "更新雷达反馈（版本 \(updater.currentVersion)）"),
            URLQueryItem(name: "body",
                         value: "\n\n\n——\n版本：\(version)\nmacOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        ]
        return mail.url!
    }

    /// 「关于」页里的系统行：只留主次版本号，完整 build 号太长会把一行撑满
    private var macOSName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    private var githubIssues: URL {
        URL(string: "https://github.com/liaooabc/UpdateRadar/issues")!
    }

    /// 有新版本时，关于页的版本行改显示「发布说明」，顺带把安装行一起露出来
    private var releasePageURL: URL? {
        if case let .available(_, _, page, _) = updater.phase { return URL(string: page) }
        return nil
    }

    private var hasAvailableUpdate: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    private var topBar: some View {
        // 扫描中不再显示进度条：试过三种做法（直接绑值、SwiftUI 补间、Core Animation），
        // 弹层里都换不来"匀速"，反而更卡。进度改成由底栏那颗扫描图标转圈表示。
        tabBar
        // 不垫任何自绘材质：上下栏就是 Apple 液态玻璃本身，
        // 滚动边缘的糊化交给系统 ScrollEdgeBlur。
    }

    // MARK: - 分段

    private static let barControlHeight: CGFloat = 26      // 分段轨道和搜索框的统一高度

    private var tabBar: some View {
        HStack(spacing: 8) {
            // 轨道是真的液态玻璃（系统 glassEffect），选中的那一段只是一层淡淡的中性胶囊：
            // 不用系统蓝，才对得上照片 App 那个 日/周/月/年。
            HStack(spacing: 2) {
                segButton("可更新 \(service.updateCount)", index: 0)
                segButton("其他 \(rowGroups.reduce(0) { $0 + $1.rows.count })", index: 1)
            }
            .padding(3)
            .coordinateSpace(name: "tabTrack")
            .background(alignment: .topLeading) { tabPreview }
            .onPreferenceChange(TabFrameKey.self) { ui.tabFrames = $0 }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: TrackWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(TrackWidthKey.self) { ui.tabTrackWidth = $0 }
            .modifier(GlassTrack())

            Spacer(minLength: 0)

            // 搜索框常驻：两个页签下都在，⌘F 随时能落到它上面。
            // 宽度跟右下三颗圆钮那一排同宽（26×3 + 间距 8×2 = 94），右边缘齐平。
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SearchField(ui: ui)
                    .frame(maxWidth: .infinity)
                // 清除按钮的位置常驻（没字的时候只是透明）：一出现一消失，
                // 整条胶囊的宽度就会跟着跳一下，段落轨道也会跟着挤。
                Button {
                    ui.applySearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(ui.query.isEmpty ? 0 : 1)
                .disabled(ui.query.isEmpty)
                .help("清除搜索")
            }
            .padding(.horizontal, 10)
            .frame(width: Self.barControlHeight * 3 + 16, height: Self.barControlHeight)
            .modifier(GlassSearchField())
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // 最近搜索：贴在搜索框正下方，只在「正在搜索、还没打字、有历史」时出现
        .overlay(alignment: .topTrailing) {
            if ui.searchActive, ui.query.isEmpty, !ui.recentSearches.isEmpty {
                recentSearchesPanel
                    .padding(.trailing, 14)
                    .offset(y: Self.barControlHeight + 18)
            }
        }
        // 只让这一条的胶囊和搜索框做过渡，列表不参与
        .animation(.easeInOut(duration: 0.18), value: ui.tab)
        // 换页签时键盘选中的行作废，免得按 ↓ 从上一个页签的位置开始数。
        // 注意要先判空再写：@Published 不管值变没变都会发通知，
        // 无脑赋值会让两页上百行跟着重新求值（切页签那 100ms 有一半是这里来的）
        .onChange(of: ui.tab) {
            if ui.keyRow != nil { ui.keyRow = nil }
        }
    }

    /// 搜索框下面的「最近搜索」浮层。宽度比搜索框宽一些，右边缘与搜索框对齐。
    private var recentSearchesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("最近搜索")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("清除") { ui.clearRecentSearches() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .help("清空最近搜索")
            }
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 5)

            ForEach(ui.recentSearches, id: \.self) { word in
                Button {
                    ui.applySearch(word)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(word)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressablePlainButton())
            }
        }
        .frame(width: 210)
        .padding(.bottom, 7)
        .modifier(GlassCard())
        .zIndex(2)
    }

    private func segButton(_ label: String, index: Int) -> some View {
        let selected = ui.tab == index
        return Button {
            // 切页签一定不能包在 withAnimation 里：整个列表会跟着换内容，
            // 一动画就成了「旧行淡出、新行滑动入场」，看起来就是列表在抖。
            // 动画只留给 tabBar 自己（见 tabBar 的 .animation）。
            // 两份列表一直挂着，这里只切可见性，不触发任何插入/删除，点下去立刻响应。
            ui.tab = index
        } label: {
            // 透明的那份半粗文本只是占位：选中要变粗，字一变粗字宽就变，
            // 玻璃轨道跟着一两个点地伸缩，切页签时看着就「晃」。锁住宽度最省事。
            ZStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .opacity(0)
                Text(label)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.barControlHeight - 6)   // 轨道上下各留 3pt
            .background {
                // 只量位置，不画背景：胶囊统一由 tabPreview 画，才能在两格之间滑动
                GeometryReader { proxy in
                    Color.clear.preference(key: TabFrameKey.self,
                                           value: [index: proxy.frame(in: .named("tabTrack"))])
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { ui.hoverTab = index }
            else if ui.hoverTab == index { ui.hoverTab = nil }
        }
    }

    /// 选中/悬停胶囊：选中的那格永远有一层 13% 的中性填充，鼠标停到**另一格**时
    /// 那一格先浮出一层更淡的 5% 预览，移开就消失。点下去才真正切过去。
    /// 只留一层柔和填充、不描边——外面已经有轨道那圈边框了，里面再描一圈就是「框中框」。
    private var tabPreview: some View {
        ZStack(alignment: .topLeading) {
            if let f = ui.tabFrames[ui.tab] {
                Capsule()
                    .fill(Color.primary.opacity(0.13))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
            if let h = ui.hoverTab, h != ui.tab, let f = ui.tabFrames[h] {
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: ui.hoverTab)
        .allowsHitTesting(false)
    }

    // MARK: - 列表

    private var list: some View {
        // 两个页签各挂一份 List，且一直活着：换页签只切可见性，
        // 不会再让 NSTableView 插入/删除几十行（切到「其他」那半拍的迟钝就是这个），
        // 两份还各自记住自己的滚动位置。
        GeometryReader { _ in
            ZStack(alignment: .top) {
                // 每一页各自住在一个 NSHostingView 里（见 PageHost）：切页签只把宿主左右挪一下，
                // 页面内容既不会因为 ui.tab 变化而重新求值，也不会被裁掉不生成显示列表。
                // 之前两份 List 直接堆在 SwiftUI 里，切一次页签整页近百行全部重算，实测 100ms。
                PageHost(index: 0, ui: ui, service: service, visible: ui.tab == 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PageHost(index: 1, ui: ui, service: service, visible: ui.tab == 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if ui.tab == 0 ? visibleRows.isEmpty : rowGroups.isEmpty {
                    emptyState
                }
            }
        }
        .frame(maxHeight: .infinity)
        // 点更新通知：翻到「可更新」页，把那一行滚到中间并套上焦点框
        .onReceive(NotificationCenter.default.publisher(for: .urRevealRow)) { note in
            guard let id = note.object as? String else { return }
            ui.tab = 0
            // 等页签切换渲染完再滚
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                ui.keyRow = id
            }
        }
    }



    /// 空状态按 App Store「更新」页那张空图来：一句大字标题 + 一句灰色说明，不放图标。
    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(ui.tab == 0 ? "无更新" : "没有匹配的 App")
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text(ui.tab == 0 ? "所有 App 均为最新版本。" : "换个关键词试试")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 底栏

    private var footer: some View {
        // 右键菜单已经取消，原来的「设置 / 检测更新 / 退出」全搬到底栏：
        // 左下扫描（带文字），右下三颗玻璃圆：关于、设置、退出。
        HStack(spacing: 8) {
            // 扫描放左下（用户指定位置），带文字；宽度取「可更新 / 其他」整条轨道的一半。
            // 扫描中文字变「扫描中」并显示系统转圈
            Button {
                service.rescan(thenCheck: true, force: true)
            } label: {
                HStack(spacing: 5) {
                    if service.checking {
                        NativeSpinner().frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text(service.checking ? "扫描中" : "扫描")
                        .font(.system(size: 12, weight: .medium))
                }
                // 宽度直接等于「可更新」那一格：胶囊由 glassEffect 自绘，
                // 系统玻璃按钮在窄内容下会强制内缩导致文字被截，只能用自绘那层
                .frame(width: max(ui.tabFrames[0]?.width ?? 80, 56), height: 26)
                .modifier(ScanHoverTint(box: ui.scanHover))
                .modifier(ScanGlassCapsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { ui.scanHover.on = $0 }
            .disabled(service.checking)
            .help(service.checking ? "正在扫描" : "立即扫描")

            Spacer()

            // 「关于 → 设置 → 退出」顺序，跟参考图同一套排列
            footerButton("ellipsis", help: "关于") {
                ui.aboutFromSettings = false
                ui.showAbout = true
            }
            footerButton("gearshape", help: "设置") { ui.showSettings = true }
            footerButton("power", help: "退出更新雷达") { onQuit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 底栏按钮：用系统的玻璃按钮样式，悬停明暗由系统给；
    /// 内容框 18pt + 系统补充的 8pt = 画出来 26pt，和原来的尺寸一致
    private func footerButton(_ systemName: String,
                              spinning: Bool = false,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            footerGlyph(systemName, spinning: spinning)
        }
        .modifier(GlassCircleButton())
        .help(help)
    }

    private func footerGlyph(_ systemName: String, spinning: Bool) -> some View {
        Group {
            if spinning {
                NativeSpinner()
                    .allowsHitTesting(false)
            } else {
                Image(systemName: systemName)
                    .font(.footnote.weight(.medium))
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
    }
}

/// 一页列表（「可更新」或「其他」）。它住在自己的 NSHostingView 里（见 PageHost），
/// 所以这里只关心「这一页怎么画」，不用管页签切换。
/// 行数据、搜索、展开这些由 @ObservedObject 的发布自动驱动。
private struct ListPage: View {
    let index: Int
    @ObservedObject var ui: UIState
    @ObservedObject var service: UpdateService

    private var rows: [AppRow] { computeVisibleRows(service, ui) }
    private var groups: [RowGroup] { computeRowGroups(service, ui) }

    var body: some View {
        GeometryReader { geo in
            let viewHeight = geo.size.height
            ScrollViewReader { proxy in
                List {
                Color.clear.frame(height: 0).id("top")
                    .listChrome()

                if index == 0 {
                    rowsSection(rows, tabIndex: 0)
                } else {
                    ForEach(Array(groups.enumerated()), id: \.element.key) { groupIndex, group in
                        if groupIndex > 0 {
                            Color.clear.frame(height: 8).listChrome()
                        }
                        // 「已是最新」不画分组标题：每行右侧已经写了「已是最新版本」，
                        // 再顶一行「已是最新 93」就是同一句话说两遍。其余分组标题照旧。
                        if group.key != "latest" {
                            groupHeader(group).listChrome()
                        }
                        // 没有标题就点不到折叠，这一组始终展开
                        if group.key == "latest" || !isCollapsed(group.key) {
                            rowsSection(group.rows,
                                        ignored: group.key == "ignored",
                                        tabIndex: 1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .defaultScrollAnchor(.top)
            .onChange(of: rows.count) {
                // 正在读某一行展开的说明时，别因为后台查完了就把列表甩回顶部
                if index == 0, ui.expanded.isEmpty { scrollTop(proxy) }
            }
            // 两份列表都在上报位置，所以用「页签|行 id」拼 key，分开存
            .onPreferenceChange(RowFrameKey.self) {
                var frames: [String: CGRect] = [:]
                let prefix = "\(index)|"
                for (key, rect) in $0 where key.hasPrefix(prefix) {
                    frames[String(key.dropFirst(prefix.count))] = rect
                }
                ui.rowFramesByTab[index] = frames
            }
            // 键盘选中的行滚进视野中间；只由当前显示的这份列表来做
            .onChange(of: ui.keyRow) {
                guard index == ui.tab, let id = ui.keyRow else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // 点开一行时，只有说明会长到面板外面才滚一下；本来整行就在视野里就不动，
            // 免得点一下整页跳一格
            .onChange(of: ui.expanded) {
                guard index == ui.tab,
                      let id = ui.lastToggled,
                      ui.expanded.contains(id) else { return }
                // 等这一帧长高之后再看位置，不然量到的还是展开前的高度
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    guard let rect = ui.rowFramesByTab[ui.tab]?[id], rect.maxY > viewHeight - 4 else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            // 系统的滚动边缘效果：滑到顶/底时，被条遮住的那一段由系统做渐隐，
            // 不是我们自己画的渐变，所以深浅色、壁纸、透明度都跟系统一致。
            .modifier(ScrollEdgeBlur())
            }
            .coordinateSpace(name: "urList")
        }
    }

    /// 归顶要**不带**动画：带 0.18s 动画的归顶会让整列行从旧位置滑到顶部，
    /// 用户看到的就是一次抖动。这里把动画显式关掉。
    private func scrollTop(_ proxy: ScrollViewProxy) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { proxy.scrollTo("top", anchor: .top) }
    }

    @ViewBuilder
    private func rowsSection(_ rows: [AppRow],
                             ignored: Bool = false,
                             tabIndex: Int) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            RowView(row: row,
                    service: service,
                    hover: ui.hovers.box(for: row.id),
                    ignored: ignored,
                    expanded: ui.expanded.contains(row.id),
                    // 分隔线自己画：系统的会铺满整行，从图标左边就起，跟名字对不齐
                    showsDivider: index < rows.count - 1,
                    onToggle: {
                        // 点这一行只展开/收起更新说明。选中框已经去掉，
                        // keyRow 只留给键盘 ↑↓ 记住当前行，不再画任何底色
                        ui.keyRow = row.id
                        withAnimation(.easeInOut(duration: 0.16)) { ui.toggleExpanded(row.id) }
                    })
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // 选中色块的左边要压在「可更新」框的左边缘、右边压在搜索框的右边缘，
            // 也就是顶部条那 14pt 内边距。List 自己还会在左右各加 8pt / 9pt，
            // 这里补差：6 + 8 = 14，5 + 9 = 14。系统滑动时的裁剪边界也落在色块边上。
            .padding(.leading, 6)
            .padding(.trailing, 5)
            .background {
                // 两份列表都会上报行位置，key 里带页签号，避免同名行互相覆盖；
                // 注意这里不能读 ui.tab，否则切页签会让上百行全部重新求值
                GeometryReader { g in
                    Color.clear.preference(key: RowFrameKey.self,
                                           value: ["\(tabIndex)|\(row.id)": g.frame(in: .named("urList"))])
                }
            }
            .id(row.id)
            // 滑动操作用系统的 swipeActions：跟手位移、越界回弹、松手动画都是 SwiftUI 自己做的。
            // 按钮里只放文字：用 Label 的话系统会把图标塞进胶囊、标题甩到胶囊外面，
            // 行又比系统默认行高得多，那个大胶囊 + 底下孤零零一行字就是最丑的地方。
            // 高度固定 56 = 图标 40 + 上下内边距 8×2，让滑出来的胶囊跟整行一样高
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if row.isUpdate {
                    Button { service.dismiss(row) } label: {
                        swipeLabel("已是最新")
                    }
                    .tint(.green)
                } else if service.isDismissed(row.id) {
                    Button { service.undismiss(row.id) } label: {
                        swipeLabel("恢复提醒")
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if ignored {
                    Button { service.unignore(row.id) } label: {
                        swipeLabel("恢复提醒")
                    }
                    .tint(.blue)
                } else {
                    Button { service.ignore(row.app) } label: {
                        swipeLabel("忽略")
                    }
                    .tint(.gray)
                }
            }
        }
    }

    /// 滑动操作的按钮标签：尺寸交给系统决定，不自己撑高度
    private func swipeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
    }

    /// 搜索的时候强制展开，不然搜到的东西会藏在收起来的组里
    private func isCollapsed(_ key: String) -> Bool {
        ui.query.isEmpty && (ui.collapsedGroups[key] ?? false)
    }

    private func groupHeader(_ group: RowGroup) -> some View {
        let collapsed = isCollapsed(group.key)
        return Button {
            ui.collapsedGroups[group.key] = !(ui.collapsedGroups[group.key] ?? false)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(group.rows.count)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.trailing, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 页签宿主：把一页列表放进独立的 NSHostingView，SwiftUI 这边只负责「这一页露出来还是藏起来」。
/// 藏的时候用 AppKit 的 alphaValue = 0，宿主始终待在原位、尺寸不变：
///   · SwiftUI 眼里这一页一直在显示，内容一直是渲染好的 —— 切回来只是把 alpha 从 0 拨回 1，
///     不用重新求值，摸过的滚轮位置也还在；
///   · 用 SwiftUI 的 opacity(0) 藏是不行的：SwiftUI 只把可见的那份生成显示列表，
///     藏起来的那页切回来是白的（踩过）；挪出边界也不行，首次显示要现算，第一次切换照样卡 100ms。
///   · 每次切页签让整页重新求值更不行：近百行全重算，实测 100ms，就是那个"慢半拍"。
private struct PageHost: NSViewRepresentable {
    let index: Int
    let ui: UIState
    let service: UpdateService
    let visible: Bool

    func makeNSView(context: Context) -> PageClipView {
        let page = NSHostingView(rootView: ListPage(index: index, ui: ui, service: service))
        page.autoresizingMask = [.width, .height]
        let clip = PageClipView()
        clip.addSubview(page)
        clip.page = page
        clip.setVisible(visible)
        return clip
    }

    func updateNSView(_ clip: PageClipView, context: Context) {
        clip.setVisible(visible)
    }
}

private final class PageClipView: NSView {
    weak var page: NSView?
    private var visible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setVisible(_ v: Bool) {
        guard v != visible else { return }
        visible = v
        page?.alphaValue = v ? 1 : 0
    }

    override func layout() {
        super.layout()
        page?.frame = bounds
        page?.alphaValue = visible ? 1 : 0
    }

    /// 透明（alpha 0）的页在 AppKit 里仍然参与点击命中：它会盖在当前页上面把点击全吃掉。
    /// 所以隐藏的那一页必须在这里直接放行。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visible else { return nil }
        return super.hitTest(point)
    }
}

/// List 的默认装饰（行内边距、白色底、分隔线）全部去掉，
/// 这样行外观完全由 RowView 自己决定，跟改造前的自绘列表一致。
private struct ListChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

extension View {
    func listChrome() -> some View { modifier(ListChrome()) }
}

// MARK: - 玻璃

/// 列表的滚动边缘效果（macOS 26 的液态玻璃）：内容滑到被顶部条 / 底栏遮住的那一段时，
/// 由系统做一层渐进模糊 + 淡出，不是我们自己画渐变，所以深浅色和透明度都跟系统一致。
/// 老系统没有这个 API，就什么都不加——那时靠条自己的 ultraThinMaterial 兜住。
private struct ScrollEdgeBlur: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // .soft 太透，滚到条底下的内容还看得清；.hard 是系统工具栏那档，糊得更实
            content.scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
        } else {
            content
        }
    }
}

/// 自绘玻璃按钮的悬停明暗：鼠标经过时叠一层中性色（深色下变亮、浅色下变暗）
private struct ScanHoverTint: ViewModifier {
    @ObservedObject var box: HoverBox
    func body(content: Content) -> some View {
        content.background {
            Capsule()
                .fill(Color.primary.opacity(box.on ? 0.09 : 0))
                .animation(.easeOut(duration: 0.12), value: box.on)
        }
    }
}

/// 底栏「扫描」胶囊：自绘玻璃（悬停由 interactive 给），宽度能精确控制
private struct ScanGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
}

/// 顶部页签：整条是系统的液态玻璃（glassEffect），悬停/选中胶囊是我们自绘的中性色
private struct GlassTrack: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }
}

/// 两格在轨道里的位置，用偏好值从子视图传上来
private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 轨道整条的宽度（底栏扫描胶囊按它的一半算）
private struct TrackWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 圆形玻璃图标（扫描 / 设置齿轮共用）：同一个 28pt 圆、同一套玻璃材质。
/// 玻璃必须画在 label **里面**——Menu 的 borderlessButton 会自己接管外层背景，
/// 加在 Menu 外面的 glassEffect 完全不会出现（齿轮之前就是一坨平面图标的原因）。
private struct GlassIcon: View {
    let systemName: String
    /// 扫描中：换成系统自带的转圈进度指示器
    var spinning: Bool = false

    var body: some View {
        Group {
            if spinning {
                NativeSpinner()
                    .allowsHitTesting(false)
            } else {
                Image(systemName: systemName)
                    .font(.callout.weight(.medium))
            }
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .modifier(GlassCircle())
    }
}

/// 系统自己的不确定进度指示器（NSProgressIndicator 的 spinning 样式）。
/// 之前是想让箭头符号自己转：可箭头是方块状的字形，转起来按对角线扫，
/// 角尖必然扫出圆框；缩小字号又跟旁边的齿轮不一样大。转圈这件事交给系统，
/// 尺寸、转速、透明度（包括"降低动态效果"）都由它按自身设置来。
private struct NativeSpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context: Context) {
        indicator.startAnimation(nil)
    }
}

/// 圆形玻璃按钮（刷新 / 设置齿轮用）：跟分段控件、搜索框同一套材质
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }
}

/// 圆形按钮（底栏关于 / 设置 / 退出）：用系统的玻璃按钮样式，悬停明暗由系统给
private struct GlassCircleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.plain)
        }
    }
}

/// 胶囊按钮（扫描 / 返回）：用系统的玻璃按钮样式，悬停明暗由系统给
private struct GlassCapsuleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.plain)
        }
    }
}

/// 圆角玻璃卡片（「最近搜索」浮层用）：跟搜索框同一个材质，形状换成矩形圆角
private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }
}

/// 搜索输入框包成 NSTextField，是为了两件 SwiftUI 做不到的事：
/// 1) placeholder 的字号——SwiftUI 的 TextField 会把「搜索」按系统 13 号画，跟左边 11.5 号的分段不一致；
/// 2) 中文输入法打字时，SwiftUI 的 binding 要等选字/回车才更新，自己画的占位文字就会一直压在拼音上面。
///    包成 AppKit 之后 placeholder 由系统管，一有字（包括还没上屏的拼音）就消失。
private struct SearchField: NSViewRepresentable {
    let ui: UIState

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var focusObserver: NSObjectProtocol?
        var setObserver: NSObjectProtocol?
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // 中文输入法还没上屏时，marked text 在 field editor 里，field.stringValue 还是空的；
            // 读编辑器的 string 才能跟着拼音实时过滤，而不是等回车。
            let editor = field.currentEditor() as? NSTextView
            parent.ui.query = editor?.string ?? field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.ui.searchActive = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // 延一小会儿再收起「最近搜索」：单击是 按下→抬起 两段，
            // 第一下就已经结束编辑了，立刻收掉的话抬起的动作落在空处，那一行就点不中。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                let field = obj.object as? NSTextField
                if field?.currentEditor() == nil { self.parent.ui.searchActive = false }
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            // 回车＝这次搜索告一段落，记进最近搜索；吃掉回车，别让系统响一声
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.ui.commitSearch(textView.string.isEmpty ? parent.ui.query : textView.string)
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.font = .systemFont(ofSize: 11.5)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: "搜索",
            attributes: [.font: NSFont.systemFont(ofSize: 11.5),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        field.delegate = context.coordinator
        // ⌘F 聚焦：面板由 AppDelegate 弹出后发通知，这里接住并把光标放进搜索框
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(
            forName: .updateRadarFocusSearch, object: nil, queue: .main
        ) { [weak field] _ in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        // 外部改写内容（清除按钮、点最近搜索里的一条）：连编辑器一起改，否则界面会两套字
        context.coordinator.setObserver = NotificationCenter.default.addObserver(
            forName: .updateRadarSetSearch, object: nil, queue: .main
        ) { [weak field] note in
            guard let field, let window = field.window else { return }
            let word = (note.object as? String) ?? ""
            field.stringValue = word
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = word
                editor.setSelectedRange(NSRange(location: word.count, length: 0))
            }
        }
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        if let token = coordinator.focusObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = coordinator.setObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // 只在外部真的改了内容时回写，别在用户打字（尤其拼音还没上屏）时去重置它
        if field.stringValue != ui.query, field.currentEditor() == nil {
            field.stringValue = ui.query
        }
    }
}

private struct GlassSearchField: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
    }
}

// MARK: - 单行

/// 无边框按钮：按下时压暗一点点并轻微缩小，胶囊才有「按到了」的反馈
private struct PressablePlainButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.10 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// 让 AppKit 自己画悬停底色：`.selection` 材质就是系统菜单、侧边栏里选中那一块的蓝，
/// 浓度、透明度、强调色跟随都由系统决定。我们只把它裁成 12 的圆角。
private struct SystemSelectionBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 图标交给 AppKit 自己画：缓存里那张图带浅色/深色两份表示，
/// 系统换外观时这个 NSView 会收到回调重绘，AppKit 按当前外观挑对应那份。
/// 之前用 SwiftUI 的 Image + colorScheme 取图，面板这套自建窗口里 body
/// 不随外观重算，图标就一直停着，非要重启才换。
private struct AppIcon: NSViewRepresentable {
    let icons: AppIconPair

    func makeNSView(context: Context) -> IconView {
        let view = IconView()
        view.icons = icons
        return view
    }

    func updateNSView(_ nsView: IconView, context: Context) {
        nsView.icons = icons
    }

    final class IconView: NSView {
        var icons: AppIconPair? {
            didSet { needsDisplay = true }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let icons else { return }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? icons.dark : icons.light).draw(in: bounds, from: .zero,
                                                   operation: .sourceOver, fraction: 1,
                                                   respectFlipped: true,
                                                   hints: [.interpolation: NSImageInterpolation.high])
        }

        // 别挡住行里的点击
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct RowView: View {
    let row: AppRow
    let service: UpdateService
    @ObservedObject var hover: HoverBox
    var ignored: Bool = false
    /// 更新说明展开着没
    var expanded: Bool = false
    /// 行底要不要画分隔线（最后一行不画）
    var showsDivider: Bool = false
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                // 左半：图标 + 名字 + 版本 + 空白。点这片 = 展开/收起更新说明。
                // 用真按钮（plain 样式、看不出按钮样）而不是 onTapGesture：
                // 一是无障碍能用 VoiceOver/键盘点到，二是不会跟右边的「更新」按钮抢点击。
                Button {
                    onToggle()
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        AppIcon(icons: row.app.icon)
                            .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 1) {
                            // 字重跟系统菜单一致：正文普通体，不额外加粗
                            Text(row.app.name)
                                .font(.body)
                                .foregroundStyle(hover.on ? Color.white : Color.primary)
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(hover.on ? Color.white.opacity(0.8) : Color.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "收起更新说明" : "看这个 App 这次的更新说明")

                // 右半：状态字 / 「更新」按钮
                if ignored {
                    Button { onToggle() } label: {
                        Text("已忽略")
                            .font(.footnote)
                            .foregroundStyle(hover.on ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if row.isUpdate {
                    trailing
                } else {
                    // 已是最新 / 检测失败 / 无检测源：这几个只是字，点一下也能展开说明。
                    // 用 Button 而不是 onTapGesture：VoiceOver 才认得出这是一个可点的目标。
                    Button { onToggle() } label: {
                        trailing.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 更新说明只在点开这一行之后才显示：收起的列表只留图标、名字、版本、状态，
            // 名单一眼扫得完；想看这次更新了什么，左击这一行展开。
            if expanded {
                notesBlock
            }
        }
        // 左右必须一样宽：之前右边多留 10pt 是为了躲滚动条，结果图标离左边 20pt、
        // 「更新」按钮离右边 23pt，看着就是歪的。外层的 8pt 已经够让滚动条错开了。
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        // 悬停态交给系统（NSVisualEffectView .selection），展开态仍用强调色的淡底。
        .background {
            if hover.on {
                // 交给系统画：.selection 材质就是菜单/侧边栏里那块蓝，
                // 颜色浓度和暗色适配都不归我们管，省得自己调出来的蓝比系统重
                SystemSelectionBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.vertical, 1)
            } else if expanded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.12))
                    .padding(.vertical, 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        // 分隔线：跟 App Store 的「最近更新」一致，从图标左边缘起、到内容右边缘止，
        // 也就是和整行的内容区同宽，不是对齐到文字。
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
                    // 跟整行内容的左右内边距一致，两头一样齐
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            // 顺序：打开下载页 → 打开这个 App → 在 Finder 中显示
            if row.result?.downloadURL != nil {
                Button("打开下载页") { service.openUpdate(for: row) }
            }
            Button("打开这个 App") { service.launch(row.app) }
            Button("在 Finder 中显示") { service.reveal(row.app) }
            Divider()
            if row.isUpdate {
                Button("这个已经是最新") { service.dismiss(row) }
            }
            if service.isDismissed(row.id) {
                Button("恢复提醒") { service.undismiss(row.id) }
            }
            if ignored {
                Button("恢复提醒") { service.unignore(row.id) }
            } else {
                Button("忽略它") { service.ignore(row.app) }
            }
        }
    }

    // MARK: - 展开后的更新说明

    /// 更新说明常是「A • B • C」一长串，展开时按 • 断行，读起来才像一份说明
    private var noteLines: [String] {
        guard let notes = row.result?.notes else { return [] }
        let bullet = notes.replacingOccurrences(of: "•", with: "\n• ")
        let lines = bullet
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "•" }
        return lines.isEmpty ? [notes] : lines
    }

    @ViewBuilder
    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if noteLines.isEmpty {
                Text("这个 App 的更新源没带更新说明")
                    .font(.footnote)
                    .foregroundStyle(hover.on ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(noteLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(hover.on ? Color.white.opacity(0.85) : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }

            // 左键不再跳官网，去处就摆在这里（右键菜单里也还在）
            HStack(spacing: 12) {
                if row.result?.downloadURL != nil {
                    textButton("打开下载页") { service.openUpdate(for: row) }
                }
                if row.result?.homepage != nil {
                    textButton("官网") { service.openSite(for: row) }
                }
                textButton("在 Finder 中显示") { service.reveal(row.app) }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                // 悬停时整行是强调蓝，链接再用强调色就看不见了，转白字
                .foregroundStyle(hover.on ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// 状态字只有这一处定义：行尾的「已是最新版本」「检测失败」都走它
    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            // 跟名字旁边那行版本号一样用系统的次要色：深色下是白、浅色下是黑，
            // 不再写死半透明白（浅色面板上那行字几乎看不见）
            .foregroundStyle(hover.on ? Color.white : Color.secondary)
    }

    /// 右侧这一列统一 82pt 宽、居中：「更新」「已是最新版本」「检测失败」的中线
    /// 都压在搜索框的中线上，不会各行右对齐得参差不齐。
    private var trailing: some View {
        trailingContent
            .frame(width: 82, alignment: .center)
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch row.status {
        case .updateAvailable:
            // 照系统菜单的做法：右侧那一列（快捷键 / 取值）在未高亮时是「次要色」，
            // 高亮后才提到纯白。次要色跟着明暗模式走，浅色面板下是黑、深色下是白。
            Button {
                service.openUpdate(for: row)
            } label: {
                Text("更新")
                    .font(.subheadline)
                    .foregroundStyle(hover.on ? Color.white : Color.secondary)
                    .padding(.vertical, 4.5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开「\(row.app.name)」的下载页")
        case .upToDate:
            // 行尾照旧写「已是最新版本」；页签里的分组标题不再重复这句话
            statusText("已是最新版本")
        case .failed:
            // 图标在前、字在后。图标沿用之前那一版：9pt 三角、不额外偏移。
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .imageScale(.small)
                    .foregroundStyle(warnAmber)
                statusText("检测失败")
            }
            // 为什么失败：副标题只放得下一句短的，完整原文（限流、超时…）放悬停提示
            .help(row.result?.note ?? "检测失败")
        case .unknown:
            Text("无检测源")
                .font(.caption2)
                .foregroundStyle(hover.on ? Color.white : Color.secondary)
        }
    }
}

/// 「关于」页的图标：跟设置行同一个尺寸和底色
private struct AboutIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.75))
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.primary.opacity(0.05)))
    }
}

/// 「关于」页的信息行：图标 + 标题 + 右侧只读值
private struct AboutValueRow: View {
    let symbol: String
    let title: String
    let value: String
    var showDivider = true

    var body: some View {
        HStack(spacing: 9) {
            AboutIcon(symbol: symbol)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if showDivider { RowDivider() }
        }
    }
}

/// 「关于」页的操作行：图标 + 标题 + 右侧控件（检查更新 / 安装按钮）
private struct AboutControlRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var showDivider = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 9) {
            AboutIcon(symbol: symbol)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if showDivider { RowDivider() }
        }
    }
}

/// 「关于」页的反馈行：整行可点，右侧值 + 小箭头
private struct AboutLinkRow: View {
    let symbol: String
    let title: String
    var value: String? = nil
    var showDivider = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AboutIcon(symbol: symbol)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                if let value {
                    Text(value)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                if showDivider { RowDivider() }
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 29)
    }
}

