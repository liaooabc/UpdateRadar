import AppKit
import SwiftUI

private let accentMint = Color(red: 0.16, green: 0.72, blue: 0.62)
private let warnAmber = Color(red: 0.98, green: 0.62, blue: 0.16)

/// 界面自身的小状态。用 ObservableObject 而不是 @State，因为这台机器只有
/// Command Line Tools，SwiftUI 的宏插件（@State 依赖它）不可用。
final class UIState: ObservableObject {
    @Published var tab: Int = 0
    @Published var query: String = ""
    /// 全部页里每一组是不是收起来了（key -> 收起了没）
    @Published var collapsedGroups: [String: Bool] = [:]
    /// 每一行一个独立的小对象：鼠标划过时只重绘那一行，不动整个列表
    let hovers = HoverStore()

    init() {
        // 调试用：UPDATERADAR_TAB=1 直接打开「全部」页
        if ProcessInfo.processInfo.environment["UPDATERADAR_TAB"] == "1" { tab = 1 }
        // 调试用：UPDATERADAR_COLLAPSE=latest,unknown 直接收起这几组，方便看下面的组
        if let keys = ProcessInfo.processInfo.environment["UPDATERADAR_COLLAPSE"] {
            for k in keys.split(separator: ",") { collapsedGroups[String(k)] = true }
        }
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
        VStack(spacing: 0) {
            header
            if service.checking {
                ProgressView(value: service.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            tabBar
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 364, height: 548)
        // 不铺不透明底色：让 NSPopover 自己的液态玻璃材质透过来
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                service.rescan()
                service.checkAll(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(service.checking ? Color.secondary : Color.primary)
            .disabled(service.checking)
            .help("立即检查")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var titleText: String {
        if service.checking && service.updateCount == 0 && service.lastCheck == nil {
            return "正在检查…"
        }
        if service.updateCount == 0 { return "全部都是最新的" }
        return "\(service.updateCount) 个 App 有新版本"
    }

    private var subtitleText: String {
        let time: String
        if let d = service.lastCheck {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            time = "上次检查 \(f.string(from: d))"
        } else {
            time = "还没有检查过"
        }
        let checking = service.checking ? " · 正在检查" : ""
        return "\(time) · 共 \(service.appCount) 个 App\(checking)"
    }

    // MARK: - 分段

    private var tabBar: some View {
        HStack(spacing: 6) {
            segButton("可更新 \(service.updateCount)", index: 0)
            segButton("其他 \(service.rows.filter { !$0.isUpdate }.count)", index: 1)
            Spacer(minLength: 0)
            if ui.tab == 1 {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $ui.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 78)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func segButton(_ label: String, index: Int) -> some View {
        Button {
            ui.tab = index
        } label: {
            Text(label)
                .font(.system(size: 11, weight: ui.tab == index ? .semibold : .regular))
                .foregroundStyle(ui.tab == index ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(ui.tab == index ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 列表

    private var list: some View {
        Group {
            if ui.tab == 0 ? visibleRows.isEmpty : rowGroups.isEmpty {
                emptyState
            } else {
                // 结果行是检查过程中陆续插进来的，滚动位置不会自动回到顶部，所以要手动归位
                ScrollViewReader { proxy in
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
                    .defaultScrollAnchor(.top)
                    .onChange(of: visibleRows.count) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                    .onChange(of: ui.tab) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowsSection(_ rows: [AppRow], ignored: Bool = false) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            RowView(row: row, service: service, hover: ui.hovers.box(for: row.id), ignored: ignored)
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
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(group.rows.count)")
                    .font(.system(size: 10.5))
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: ui.tab == 0 ? "checkmark.seal.fill" : "square.stack.3d.up.slash")
                .font(.system(size: 30))
                .foregroundStyle(ui.tab == 0 ? accentMint : Color.secondary)
            Text(ui.tab == 0 ? "没有待更新的 App" : "没有匹配的 App")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 8) {
            let unknown = service.rows.filter {
                !service.settings.ignored.contains($0.id) && !$0.hasSource
            }.count
            Text(unknown > 0 ? "\(unknown) 个 App 暂无自动检测源" : "所有 App 均有检测源")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Picker("检查频率", selection: Binding(
                    get: { service.settings.intervalHours },
                    set: { service.setInterval($0) }
                )) {
                    Text("每小时").tag(1.0)
                    Text("每 6 小时").tag(6.0)
                    Text("每 12 小时").tag(12.0)
                    Text("每天").tag(24.0)
                }
                Divider()
                // 顺序（用户定稿）：菜单栏显示数量 → 打开系统通知设置 → 有新版本时通知我 → 只显示有检测源的 App
                Toggle("菜单栏显示数量", isOn: Binding(
                    get: { service.settings.countVisible },
                    set: { service.setShowCount($0) }
                ))
                Button("打开系统通知设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Toggle("有新版本时通知我", isOn: Binding(
                    get: { service.settings.notifyEnabled },
                    set: { service.setNotify($0) }
                ))
                Toggle("只显示有检测源的 App", isOn: Binding(
                    get: { service.settings.hideUnknown },
                    set: { service.setHideUnknown($0) }
                ))
                Divider()
                Button("打开数据文件夹") {
                    NSWorkspace.shared.open(UpdateService.supportDir)
                }
                Button("退出") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - 单行

struct RowView: View {
    let row: AppRow
    let service: UpdateService
    @ObservedObject var hover: HoverBox
    var ignored: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: row.app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(row.subtitle)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if ignored {
                    Text("已忽略")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    trailing
                }
            }

            // 更新说明：只取第一行，左边缘与图标对齐（跟 App Store 一样）
            if let notes = row.result?.notes, !notes.isEmpty, row.isUpdate {
                Text(notes)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // 右边多留一点：滚动时系统的滚动条会浮在上面，胶囊贴太近会显得挤
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .background(hover.on ? Color.primary.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture {
            // 左键：去官网（不是商店产品页、也不是直接下 dmg）
            service.openSite(for: row)
        }
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

    /// 状态字只有这一处定义：「已是最新版本」和「检测失败」共用，字体永远一致
    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .updateAvailable:
            // 照 App Store 的样子：强调色胶囊 + 白字
            Text("更新")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(Color.accentColor))
        case .upToDate:
            statusText("已是最新版本")
        case .failed:
            // 图标在前、字在后。图标沿用之前那一版：9pt 三角、不额外偏移。
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(warnAmber)
                statusText("检测失败")
            }
            // 为什么失败：副标题只放得下一句短的，完整原文（限流、超时…）放悬停提示
            .help(row.result?.note ?? "检测失败")
        case .unknown:
            Text("无检测源")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }
}
