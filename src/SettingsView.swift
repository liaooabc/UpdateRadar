import AppKit
import SwiftUI

/// 设置窗口的内容。这里一个卡片、一条描边、一层渐变都不自己画：
/// 全部交给 SwiftUI 的 `Form` + `.formStyle(.grouped)`——系统设置（System Settings）
/// 用的就是这套分组卡片。圆角、分组标题、内外边距、行距、强调色、深色模式、
/// 键盘导航、VoiceOver 标签都归系统管，我们只把原生控件摆进分组里。
/// 窗口可以自由拉大拉小：卡片跟着变宽，内容放不下时表单自己滚。
struct SettingsView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject var updater: SelfUpdater

    // MARK: - 绑定（直接落到 UpdateService 的 setter 上，改完立刻存盘）

    private var interval: Binding<Double> {
        Binding(get: { service.settings.intervalHours }, set: { service.setInterval($0) })
    }
    private var receiveBeta: Binding<Bool> {
        Binding(get: { service.settings.receiveBetaEnabled }, set: { service.setReceiveBeta($0) })
    }
    private var showCount: Binding<Bool> {
        Binding(get: { service.settings.countVisible }, set: { service.setShowCount($0) })
    }
    private var hideUnknown: Binding<Bool> {
        Binding(get: { service.settings.hideUnknown }, set: { service.setHideUnknown($0) })
    }
    private var notifyOnUpdates: Binding<Bool> {
        Binding(get: { service.settings.notifyEnabled }, set: { service.setNotify($0) })
    }

    // MARK: - 文案

    /// 「3 分钟前」这种相对时间由系统算，别自己拼
    private var lastCheckText: String {
        guard let date = service.settings.lastCheck else { return "尚未检测" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var currentVersionText: String {
        "\(updater.currentVersion)（构建 \(updater.currentBuild)）"
    }

    private var ignoredCount: Int { service.settings.ignored.count }

    // MARK: - 本软件的更新状态

    private var updateStatusText: String {
        switch updater.phase {
        case .idle: return "尚未检查"
        case .checking: return "正在检查…"
        case .upToDate: return "已是最新"
        case .available(let version, _, _, _): return "有新版本 \(version)"
        case .downloading(_, let progress): return "正在下载 \(Int(progress * 100))%"
        case .installing: return "正在装新版本…"
        case .failed(let message): return message
        }
    }

    private var isNewVersionAvailable: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    private var releasePageURL: URL? {
        if case let .available(_, _, page, _) = updater.phase { return URL(string: page) }
        return nil
    }

    private var downloadProgress: Double? {
        if case let .downloading(_, progress) = updater.phase { return progress }
        return nil
    }

    // MARK: - 更新那一行的控件

    @ViewBuilder
    private var updateStatus: some View {
        // 有新版本时，「有新版本 x.y.z」本身就是去发布说明的链接
        if let page = releasePageURL {
            Button(updateStatusText) { NSWorkspace.shared.open(page) }
                .buttonStyle(.link)
                .help("在 GitHub 上看看这版改了什么")
        } else {
            Text(updateStatusText)
                .foregroundStyle(isNewVersionAvailable ? Color.accentColor : Color.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var updateActions: some View {
        switch updater.phase {
        case let .available(version, downloadURL, _, hasDMG):
            if hasDMG {
                Button("更新并重启") { updater.install(version: version, downloadURL: downloadURL) }
                    .help("自动下载、替换并重新打开")
            } else if let url = URL(string: downloadURL) {
                Button("下载") { NSWorkspace.shared.open(url) }
                    .help("这版没有 DMG，去发布页下载")
            }
            Button("检查更新") { updater.check() }
                .disabled(updater.isChecking)
        case .downloading, .installing:
            Button("更新中…") {}
                .disabled(true)
        default:
            Button("检查更新") { updater.check() }
                .disabled(updater.isChecking)
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("上次检测", value: lastCheckText)
                Picker("检测频率", selection: interval) {
                    Text("每小时").tag(1.0)
                    Text("每 6 小时").tag(6.0)
                    Text("每 12 小时").tag(12.0)
                    Text("每天").tag(24.0)
                }
                Toggle("接收测试版更新", isOn: receiveBeta)
            } header: {
                Text("检测")
            } footer: {
                Text("按这个间隔在后台自动检测。打开测试版后，Beta、RC 构建也会提醒。")
            }

            Section {
                Toggle("在菜单栏显示更新数量", isOn: showCount)
                Toggle("只显示有检测源的 App", isOn: hideUnknown)
            } header: {
                Text("显示")
            } footer: {
                Text("关掉第二项后，查不到更新源的 App 会留在「其他」页里，不会被藏起来。")
            }

            Section {
                Toggle("有新版本时通知我", isOn: notifyOnUpdates)
                LabeledContent("系统通知") {
                    Button("打开通知设置…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("通知")
            } footer: {
                Text("只在可更新清单发生变化时提醒一次，不会每轮检测都弹。")
            }

            Section {
                LabeledContent("已忽略的 App") {
                    HStack(spacing: 10) {
                        Text("\(ignoredCount) 个")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("全部恢复提醒") { service.unignoreAll() }
                            .disabled(ignoredCount == 0)
                    }
                }
                LabeledContent("数据文件夹") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.open(UpdateService.supportDir)
                    }
                }
            } header: {
                Text("数据")
            } footer: {
                Text("设置和检测结果只存在本机，不上传。")
            }

            Section {
                LabeledContent("当前版本", value: currentVersionText)
                LabeledContent("最新版本") {
                    HStack(spacing: 10) {
                        if let progress = downloadProgress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 72)
                        }
                        updateStatus
                        updateActions
                    }
                }
            } header: {
                Text("更新雷达")
            } footer: {
                Text("新版本从 GitHub 的 Release 里查。「更新并重启」会自动下载、替换本 App 并重新打开。")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .defaultScrollAnchor(.top)
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 设置窗口。窗口本身只做三件事：定标题、定初始大小、记住用户拉的尺寸；
/// 材质、圆角、阴影、标题栏、关闭按钮、缩放行为全由 AppKit 负责。
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let service: UpdateService
    private let updater: SelfUpdater

    init(service: UpdateService, updater: SelfUpdater) {
        self.service = service
        self.updater = updater
    }

    func show() {
        let w = window ?? build()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(service: service, updater: updater))
        // NSHostingView 会按内容的理想尺寸自己改窗口大小（面板曾只剩 248pt 高），
        // 这里关掉，初始尺寸和后续缩放都归窗口自己。
        hosting.sizingOptions = []

        var initial = NSSize(width: 460, height: 856)
        // 调试用：UPDATERADAR_SETTINGS_SIZE=520x700 换初始尺寸
        if let raw = ProcessInfo.processInfo.environment["UPDATERADAR_SETTINGS_SIZE"] {
            let parts = raw.lowercased().split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                initial = NSSize(width: w, height: h)
            }
        }

        let w = NSWindow(contentViewController: hosting)
        // .resizable：窗口能自由拉大拉小，表单跟着变宽、放不下就自己滚
        w.styleMask = [.titled, .closable, .resizable]
        w.title = "设置"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        // 交给系统记尺寸和位置（跟系统设置一样，下次打开还是你上次拉的样子）
        w.contentMinSize = NSSize(width: 420, height: 380)
        w.setContentSize(initial)
        let autosave = "UpdateRadarSettingsWindow"
        if !w.setFrameUsingName(autosave) { w.center() }
        w.setFrameAutosaveName(autosave)
        return w
    }
}
