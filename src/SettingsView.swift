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
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

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
    /// 登录项：状态归系统（SMAppService）管，不落到 state.json，所以每次打开窗口都重读一次
    private var openAtLogin: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
    }

    // MARK: - 文案

    /// 「3 分钟前」这种相对时间由系统算，别自己拼。
    /// 传 now 进来，是为了让外面用 TimelineView 定时刷新，而不是停在窗口打开那一刻。
    private func lastCheckText(at now: Date) -> String {
        guard let date = service.settings.lastCheck else { return "尚未检测" }
        let f = RelativeDateTimeFormatter()
        f.locale = .current
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    private var currentVersionText: String {
        "\(updater.currentVersion)（构建 \(updater.currentBuild)）"
    }

    private var ignoredCount: Int { service.settings.ignored.count }

    /// 系统里真实的授权状态，跟上面的开关不是一回事
    private var notificationStatusText: String {
        switch notifier.authorization {
        case .authorized: return "已允许"
        case .provisional: return "已允许（安静提醒）"
        case .denied: return "已在系统设置中关闭"
        case .notDetermined: return "尚未询问"
        @unknown default: return "状态未知"
        }
    }

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
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(updateStatusText)
        }
    }

    @ViewBuilder
    private var updateActions: some View {
        switch updater.phase {
        case let .available(version, downloadURL, _, hasDMG):
            if hasDMG {
                ConfirmingButton(
                    title: "更新并重启",
                    dialogTitle: "现在下载并安装 \(version)？",
                    confirmTitle: "更新并重启",
                    message: "会下载安装包、替换当前 App，然后自动重新打开。"
                ) {
                    updater.install(version: version, downloadURL: downloadURL)
                }
                .help("自动下载、替换并重新打开")
            } else if let url = URL(string: downloadURL) {
                Button("下载") { NSWorkspace.shared.open(url) }
                    .help("这版没有 DMG，去发布页下载")
            }
            Button("检查更新") { updater.check() }
                .disabled(updater.isChecking)
        case .downloading, .installing:
            // 下载进度在上面的「下载进度」行，这里不再放一个空动作的假按钮
            EmptyView()
        default:
            Button("检查更新") { updater.check() }
                .disabled(updater.isChecking)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("登录时打开", isOn: openAtLogin)
                // 失败原因必须就地显示：开关会自己弹回去，不写清楚用户只会以为「点了没反应」
                if launchAtLogin.requiresApproval {
                    Text("已加入登录项，但还要去「系统设置 → 通用 → 登录项」里允许一次，才会真的开机启动。")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("启动")
            } footer: {
                Text("登录 macOS 后在菜单栏自动运行。这项状态由系统管，也可以在「系统设置 → 通用 → 登录项」里改。")
            }

            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent("上次检测", value: lastCheckText(at: context.date))
                }
                LabeledContent("手动检测") {
                    Button(service.checking ? "正在检测…" : "立即检测") {
                        service.rescan(thenCheck: true, force: true)
                    }
                    .disabled(service.checking)
                }
                Picker("扫描间隔", selection: interval) {
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
                Toggle("隐藏没有检测源的 App", isOn: hideUnknown)
            } header: {
                Text("显示")
            } footer: {
                Text("打开后，查不到更新源的 App 不会出现在列表里；关掉则在「其他」页里照常显示。")
            }

            Section {
                Toggle("有新版本时通知我", isOn: notifyOnUpdates)
                    .disabled(notifier.authorization == .denied)
                LabeledContent("系统通知") {
                    HStack(spacing: 10) {
                        Text(notificationStatusText)
                            .foregroundStyle(.secondary)
                        Button("打开通知设置…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
            } header: {
                Text("通知")
            } footer: {
                Text("只在可更新清单发生变化时提醒一次，不会每轮检测都弹。系统通知被关闭时，上面的开关不会有实际效果。")
            }

            Section {
                LabeledContent("已忽略的 App") {
                    HStack(spacing: 10) {
                        Text("\(ignoredCount) 个")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        ConfirmingButton(
                            title: "恢复全部忽略的 App",
                            dialogTitle: "恢复 \(ignoredCount) 个 App 的更新提醒？",
                            confirmTitle: "恢复提醒",
                            message: "这些 App 一旦有新版本，会重新出现在「可更新」里。",
                            isEnabled: ignoredCount > 0
                        ) {
                            service.unignoreAll()
                        }
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
                    updateStatus
                }
                if let progress = downloadProgress {
                    LabeledContent("下载进度") {
                        HStack(spacing: 8) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                            Text("\(Int(progress * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    updateActions
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
        // 用户可能刚在系统设置里关掉过它，窗口一露脸就按系统的真实状态重画
        .onAppear { launchAtLogin.refresh() }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 带确认的按钮：批量、会打断手上的工作这类操作，先弹一句系统确认。
/// 单独做成一个小视图，设置页本身就不用为每个「是否确认」各存一份状态。
///
/// 这里的「问过没」存在一个小 ObservableObject 里，而不是 @State：
/// 本机是 Command Line Tools，shim 里没有 SwiftUI 的宏插件，@State 编不过。
private final class ConfirmState: ObservableObject {
    @Published var asking = false
}

private struct ConfirmingButton: View {
    let title: String
    let dialogTitle: String
    let confirmTitle: String
    let message: String
    var isEnabled = true
    let action: () -> Void

    @ObservedObject private var state = ConfirmState()

    var body: some View {
        Button(title) { state.asking = true }
            .disabled(!isEnabled)
            .confirmationDialog(dialogTitle, isPresented: $state.asking, titleVisibility: .visible) {
                Button(confirmTitle) { action() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(message)
            }
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
        // 用户可能刚在系统设置里改过通知权限，打开设置页时重新读一次真实状态
        Notifier.shared.refreshAuthorization()
        // 登录项同理：用户也可能在「系统设置 → 登录项」里直接关掉
        LaunchAtLogin.shared.refresh()
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

        var initial = NSSize(width: 460, height: 620)
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
        w.title = "更新雷达设置"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        // 交给系统记尺寸和位置（跟系统设置一样，下次打开还是你上次拉的样子）
        w.contentMinSize = NSSize(width: 420, height: 380)
        w.setContentSize(initial)
        // 换了默认高度（856 → 620），autosave 名字跟着换代一次，
        // 否则会一直沿用旧版本记住的超高窗口
        let autosave = "UpdateRadarSettingsWindow2"
        if !w.setFrameUsingName(autosave) { w.center() }
        w.setFrameAutosaveName(autosave)
        return w
    }
}
