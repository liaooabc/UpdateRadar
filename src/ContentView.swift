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
}

/// 界面自身的小状态。用 ObservableObject 而不是 @State，因为这台机器只有
/// Command Line Tools，SwiftUI 的宏插件（@State 依赖它）不可用。
final class UIState: ObservableObject {
    @Published var tab: Int = 0
    @Published var query: String = ""
    /// 全部页里每一组是不是收起来了（key -> 收起了没）
    @Published var collapsedGroups: [String: Bool] = [:]
    /// 每一行一个独立的小对象：鼠标划过时只重绘那一行，不动整个列表
    let hovers = HoverStore()
    /// 哪几行展开了更新说明（左键点一下展开，再点收起）
    @Published var expanded: Set<String> = []
    /// 分段控件里鼠标正停在那一格（nil = 鼠标不在轨道上）
    @Published var hoverTab: Int?
    /// 两格各自在轨道里的位置，用来让「提前选框」滑过去
    @Published var tabFrames: [Int: CGRect] = [:]

    /// 刚点开的那一行：列表要把它滚进视野
    private(set) var lastToggled: String?
    /// 键盘（↑↓）选中的行；Return 打开它的下载页 / 在 Finder 中显示
    @Published var keyRow: String?
    /// 每一行在列表可视区里的位置（不发布，只给「要不要滚」用，避免滚动时反复重绘）
    var rowFrames: [String: CGRect] = [:]

    /// 搜索框是不是正在编辑：决定要不要把「最近搜索」列出来
    @Published var searchActive = false
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

struct ContentView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject var ui: UIState
    /// 底栏齿轮：打开设置窗口（窗口由 AppDelegate 持有）
    var onOpenSettings: () -> Void = {}

    /// 「可更新」页的行：只列有新版本的，按名字排
    private var visibleRows: [AppRow] {
        service.rows
            .filter { !service.settings.ignored.contains($0.id) && $0.isUpdate }
            .sorted(by: byName)
    }

    private func byName(_ a: AppRow, _ b: AppRow) -> Bool {
        a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending
    }

    /// 「全部」页的一组
    private struct RowGroup {
        let key: String
        let title: String
        let rows: [AppRow]
    }

    /// 顺序照用户要的：可更新 → 已是最新 → 无检测源 → 检测失败（放最后）→ 已忽略
    private var rowGroups: [RowGroup] {
        let ignoredIds = Set(service.settings.ignored)
        var base = service.rows
        if service.settings.hideUnknown {
            base = base.filter { $0.hasSource || ignoredIds.contains($0.id) }
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

    var body: some View {
        // 顶部条和底栏不再作为"占位"排在列表上下，而是挂成列表的安全区内嵌：
        // 行能从条底下穿过去，条自己那层 ultraThinMaterial 把穿过的那几行糊掉，
        // 再叠上 macOS 26 的滚动边缘效果，滑到边上的内容就有一段渐隐，这就是透视感。
        // 老系统没有那条系统 API，纯靠材质兜底，效果弱一点但不会破。
        list
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .frame(width: 364, height: 548)
        // 不铺不透明底色：让 NSPopover 自己的液态玻璃材质透过来
    }

    private var topBar: some View {
        // 扫描中不再显示进度条：试过三种做法（直接绑值、SwiftUI 补间、Core Animation），
        // 弹层里都换不来"匀速"，反而更卡。进度改成由底栏那颗扫描图标转圈表示。
        tabBar
        // 这里故意不再垫 .ultraThinMaterial：弹层本身已经是系统液态玻璃，
        // 再叠一层材质就是"玻璃上贴磨砂膜"，越叠越不透，透明度也不跟系统设置了。
        // 边缘那层糊化交给 ScrollEdgeBlur 的系统边缘效果，只留一层玻璃。
    }

    // MARK: - 分段

    private static let barControlHeight: CGFloat = 26      // 分段轨道和搜索框的统一高度

    private var tabBar: some View {
        HStack(spacing: 8) {
            // 轨道是真的液态玻璃（系统 glassEffect），选中的那一段只是一层淡淡的中性胶囊：
            // 不用系统蓝，才对得上照片 App 那个 日/周/月/年。
            HStack(spacing: 2) {
                segButton("可更新 \(service.updateCount)", index: 0)
                segButton("其他 \(service.rows.filter { !$0.isUpdate }.count)", index: 1)
            }
            .padding(3)
            .coordinateSpace(name: "tabTrack")
            .background(alignment: .topLeading) { tabPreview }
            .onPreferenceChange(TabFrameKey.self) { ui.tabFrames = $0 }
            .modifier(GlassTrack())

            Spacer(minLength: 0)

            // 搜索框常驻：原来只在「其他」页签出现，切到「可更新」就消失，
            // 想搜个名字还得先换页。现在两个页签下都在，⌘F 也随时能落到它上面。
            // 尺寸/字号必须跟左边那条轨道一模一样：同一个高度、同一个正文字号，
            // 只靠 padding 凑容易差 2pt，所以两边都写死高度。
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SearchField(ui: ui)
                    .frame(width: 64)
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
            .frame(height: Self.barControlHeight)
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
        // 换页签时键盘选中的行作废，免得按 ↓ 从上一个页签的位置开始数
        .onChange(of: ui.tab) { ui.keyRow = nil }
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

    /// 「提前选框」：选中的胶囊永远在原来的格子里，鼠标停到**另一格**时，
    /// 那一格先浮出一层更淡的胶囊（预览），移开就消失。点下去才真正切过去。
    /// 直接把唯一的胶囊滑到鼠标下面会让「已选中」看着像丢了，所以分成两层。
    private var tabPreview: some View {
        ZStack(alignment: .topLeading) {
            if let f = ui.tabFrames[ui.tab] {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
            if let h = ui.hoverTab, h != ui.tab, let f = ui.tabFrames[h] {
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.03), lineWidth: 0.5))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: ui.hoverTab)
        .animation(.easeInOut(duration: 0.18), value: ui.tab)
        .allowsHitTesting(false)
    }

    // MARK: - 列表

    /// 归顶要**不带**动画：带 0.18s 动画的归顶会让整列行从旧位置滑到顶部，
    /// 用户看到的就是一次抖动。这里把动画显式关掉。
    private func scrollTop(_ proxy: ScrollViewProxy) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { proxy.scrollTo("top", anchor: .top) }
    }

    private var list: some View {
        Group {
            if ui.tab == 0 ? visibleRows.isEmpty : rowGroups.isEmpty {
                emptyState
            } else {
                // 结果行是检查过程中陆续插进来的，滚动位置不会自动回到顶部，所以要手动归位
                GeometryReader { geo in
                let viewHeight = geo.size.height
                ScrollViewReader { proxy in
                    // .id(ui.tab)：两个页签各用各的滚动视图。否则共用一个时，
                    // 切过去会带着上一个页签的滚动位置，再被 scrollTo 拽回顶部，中间就跳一下。
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            Color.clear.frame(height: 0).id("top")
                            if ui.tab == 0 {
                                rowsSection(visibleRows)
                            } else {
                                ForEach(Array(rowGroups.enumerated()), id: \.element.key) { index, group in
                                    if index > 0 {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.30))
                                            .frame(height: 2)
                                            .padding(.leading, 10)
                                            .padding(.trailing, 18)
                                            .padding(.top, 8)
                                    }
                                    groupHeader(group)
                                    if !isCollapsed(group.key) {
                                        rowsSection(group.rows, ignored: group.key == "ignored")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .id(ui.tab)
                    .defaultScrollAnchor(.top)
                    .onChange(of: visibleRows.count) {
                        // 正在读某一行展开的说明时，别因为后台查完了就把列表甩回顶部
                        if ui.expanded.isEmpty { scrollTop(proxy) }
                    }
                    .onPreferenceChange(RowFrameKey.self) { ui.rowFrames = $0 }
                    // 键盘选中的行滚进视野中间；两个页签各滚各的
                    .onChange(of: ui.keyRow) {
                        guard let id = ui.keyRow else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    // 点开一行时，只有说明会长到面板外面才滚一下；本来整行就在视野里就不动，
                    // 免得点一下整页跳一格
                    .onChange(of: ui.expanded) {
                        guard let id = ui.lastToggled, ui.expanded.contains(id) else { return }
                        // 等这一帧长高之后再看位置，不然量到的还是展开前的高度
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                            guard let rect = ui.rowFrames[id], rect.maxY > viewHeight - 4 else { return }
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                    // 系统的滚动边缘效果：滑到顶/底时，被条遮住的那一段由系统做渐隐，
                    // 不是我们自己画的渐变，所以深浅色、壁纸、透明度都跟系统一致。
                    .modifier(ScrollEdgeBlur())
                }
                }
                .coordinateSpace(name: "urList")
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowsSection(_ rows: [AppRow], ignored: Bool = false) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            RowView(row: row,
                    service: service,
                    hover: ui.hovers.box(for: row.id),
                    ignored: ignored,
                    expanded: ui.expanded.contains(row.id),
                    focused: ui.keyRow == row.id,
                    onToggle: {
                        // 展开/收起也走动画，行高变化才不生硬
                        withAnimation(.easeInOut(duration: 0.16)) { ui.toggleExpanded(row.id) }
                    })
            .background(GeometryReader { g in
                Color.clear.preference(key: RowFrameKey.self,
                                       value: [row.id: g.frame(in: .named("urList"))])
            })
            .id(row.id)
            if index < rows.count - 1 {
                Divider().opacity(0.35).padding(.leading, 46).padding(.trailing, 18)
            }
        }
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
        // 底栏只留两颗按钮。原来那句「共 N 个 App · N 个暂无检测源 · 18:47 检测」删了：
        // 底栏现在是透明的，行要从底下穿过去，文字压在上面翻来翻去永远看不清。
        // 这三样信息也都有正经去处——App 总数看两个页签的数字，无检测源的条数在「其他」
        // 页里就是一个分组，上次检测时间在设置窗口「上次检测」那一行。
        // Apple 自己的弹层底部也很少放状态文字，留一排控件更干净。
        HStack(spacing: 8) {
            Spacer()

            footerButton("arrow.triangle.2.circlepath",
                         spinning: service.checking,
                         help: service.checking ? "正在扫描" : "立即扫描") {
                service.rescan(thenCheck: true, force: true)
            }
            .disabled(service.checking)

            footerButton("gearshape", help: "设置") { onOpenSettings() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // 同样不垫材质：底栏靠弹层自己的玻璃 + 系统边缘效果，
        // 这样"降低透明度 / 增强对比度"这些辅助功能设置才会原样作用到这一条上。
    }

    /// 底栏按钮：还是之前那两颗 28pt 玻璃圆（GlassIcon）。
    /// 玻璃本身仍然交给系统（glassEffect），但我们不加任何额外材质、底色或描边，
    /// 透明度完全由系统决定，这样「降低透明度 / 增强对比度」会原样作用在它们身上。
    /// 上一版换成的 .glass 按钮样式圆角和高光跟这两个不一样，看着不统一，已退回。
    @ViewBuilder
    private func footerButton(_ systemName: String,
                              spinning: Bool = false,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassIcon(systemName: systemName, spinning: spinning)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 分段控件两格的几何，用偏好值从子视图传上来
private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - 玻璃

/// 列表的滚动边缘效果（macOS 26 的液态玻璃）：内容滑到被顶部条 / 底栏遮住的那一段时，
/// 由系统做一层渐进模糊 + 淡出，不是我们自己画渐变，所以深浅色和透明度都跟系统一致。
/// 老系统没有这个 API，就什么都不加——那时靠条自己的 ultraThinMaterial 兜住。
private struct ScrollEdgeBlur: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            content
        }
    }
}

/// 真·液态玻璃：macOS 26 起系统提供 `.glassEffect`，材质、折射、边缘高光全由系统画。
/// 自己叠 material + 描边 + 投影只能做出"磨砂塑料"，这就是前面那版不像的原因。
/// 老系统（15 及以下）退回一个朴素的浅灰胶囊。
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
        .frame(width: 28, height: 28)
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

struct RowView: View {
    let row: AppRow
    let service: UpdateService
    @ObservedObject var hover: HoverBox
    var ignored: Bool = false
    /// 更新说明展开着没
    var expanded: Bool = false
    /// 键盘选中的行（↑↓），画一层更实的底 + 焦点描边，和鼠标悬停区分开
    var focused: Bool = false
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
                        Image(nsImage: row.app.icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.app.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.tertiary)
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
        // 右边多留一点：滚动时系统的滚动条会浮在上面，胶囊贴太近会显得挤
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        // 悬停/展开的底色做成左右内缩的圆角块（访达、App Store、系统设置的列表都是这样），
        // 不再铺满整行，行与行之间的分隔线就不会被色块顶掉。
        // 颜色用系统语义色，深色模式、提高对比度时自动跟着变。
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(focused ? Color.accentColor.opacity(0.14)
                      : hover.on ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                      : (expanded ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
                                  : Color.clear))
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
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
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(noteLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// 状态字只有这一处定义：「已是最新版本」和「检测失败」共用，字体永远一致
    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .updateAvailable:
            // 照 App Store 的样子：强调色胶囊 + 白字。这个是真按钮：
            // 点了直接去这个 App 的下载页（dmg / 商店页 / GitHub Release）。
            // 只想看「改了什么」，点行左边那片，别点这里。
            Button {
                service.openUpdate(for: row)
            } label: {
                Text("更新")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressablePlainButton())
            .help("打开「\(row.app.name)」的下载页")
        case .upToDate:
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
                .foregroundStyle(.tertiary)
        }
    }
}
