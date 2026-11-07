import AppKit
import SwiftUI

// MARK: - 引导的翻页状态

@MainActor
final class OnboardingModel: ObservableObject {
    static let pageCount = 3
    @Published var page = 0

    var isLast: Bool { page == Self.pageCount - 1 }

    func next() { page = min(page + 1, Self.pageCount - 1) }
    func back() { page = max(page - 1, 0) }
}

// MARK: - 独立的欢迎窗口

/// 首次安装后弹一次的欢迎窗口：三页，讲清楚是什么、怎么用、要不要开通知和登录项。
/// 看过（或直接关窗）就记一笔，之后不再打扰。
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private static let doneKey = "ur.didShowOnboarding"
    /// 窗口自己不 retain 自己，用这个静态引用托住，关掉时释放
    private static var current: OnboardingWindow?

    static var isNeeded: Bool { !UserDefaults.standard.bool(forKey: doneKey) }

    static func presentIfNeeded() {
        guard isNeeded, current == nil else { return }
        let controller = OnboardingWindow()
        current = controller
        controller.show()
    }

    private let window: NSWindow
    private let model = OnboardingModel()

    override init() {
        let size = NSSize(width: 480, height: 566)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "欢迎使用更新雷达"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, onFinish: { [weak self] in
            self?.finish()
        }))
        window.center()
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        // 引导里没点「允许通知」的话，收尾时补问一次（跟以前启动就问的行为对齐）
        if Notifier.shared.authorization == .notDetermined {
            Notifier.shared.requestPermission()
        }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        Self.current = nil
    }
}

// MARK: - 窗口内容

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onFinish: () -> Void

    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.page == 0 {
                    welcomePage.transition(.opacity)
                } else if model.page == 1 {
                    usagePage.transition(.opacity)
                } else {
                    setupPage.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.18), value: model.page)

            Divider()

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<OnboardingModel.pageCount, id: \.self) { i in
                        Circle()
                            .fill(Color.primary.opacity(i == model.page ? 0.55 : 0.15))
                            .frame(width: 6, height: 6)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: model.page)

                Spacer(minLength: 0)

                if model.page > 0 {
                    Button("上一步") { withAnimation(.easeInOut(duration: 0.18)) { model.back() } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button(model.isLast ? "开始使用" : "下一步") {
                    if model.isLast {
                        onFinish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { model.next() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
        }
        .padding(.top, 32)
        .frame(width: 480, height: 566)
        .onAppear {
            launchAtLogin.refresh()
            notifier.refreshAuthorization()
        }
    }

    // MARK: 第 1 页

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)

            Text("更新雷达")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 16)

            Text("扫一眼菜单栏，就知道哪些 App 有新版本。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(spacing: 14) {
                highlight("menubar.rectangle", "常驻菜单栏",
                          "图标旁边的数字就是待更新数量，点一下弹出列表。")
                highlight("clock.arrow.circlepath", "自动扫描",
                          "启动后自动检查一遍，之后按设置里的间隔定时再看。")
                highlight("cursorarrow", "右键就能处理",
                          "忽略某个版本、恢复提醒，或直接打开下载页。")
            }
            .padding(.top, 28)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
    }

    // MARK: 第 2 页

    private var usagePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text("三步用起来")
                .font(.system(size: 20, weight: .semibold))

            VStack(spacing: 20) {
                step(1, "点图标打开列表",
                     "左边「可更新」是有新版本的，右边「其他」都是最新的；顶栏搜索框随时能查。")
                step(2, "点一行看更新说明",
                     "展开能看到这个版本改了什么，也可以直接跳到下载页。")
                step(3, "「扫描」随时重扫",
                     "底部胶囊按钮立刻重扫一遍；扫描间隔、隐藏项都在齿轮设置里。")
            }
            .padding(.top, 30)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
    }

    // MARK: 第 3 页

    private var setupPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text("最后两件小事")
                .font(.system(size: 20, weight: .semibold))
            Text("都随时能在设置里改。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("有新版本时通知我")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(notificationStatusText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    notificationControl
                }
                .padding(.vertical, 12)

                Divider().padding(.leading, 34)

                HStack(spacing: 12) {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时打开")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(launchHint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(launchHintColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: loginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .padding(.top, 26)
            .frame(width: 360)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
    }

    // MARK: 碎片

    private func highlight(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 20, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 330)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.09)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private var notificationControl: some View {
        switch notifier.authorization {
        case .notDetermined:
            Button("允许通知") { notifier.requestPermission() }
                .controlSize(.small)
        case .denied:
            Button("打开设置…") { openNotificationSettings() }
                .controlSize(.small)
        default:
            Label("已开启", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        }
    }

    private var notificationStatusText: String {
        switch notifier.authorization {
        case .notDetermined: return "还没有决定，点右边按钮授权"
        case .denied: return "已在系统设置里关闭"
        case .provisional: return "已静默授权"
        default: return "已开启，有新版会弹横幅提醒"
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) })
    }

    private var launchHint: String {
        if let error = launchAtLogin.lastError { return error }
        if launchAtLogin.requiresApproval {
            return "已加入登录项，还需在「系统设置 → 通用 → 登录项」里允许一次。"
        }
        return "开机后在菜单栏待命，不用手动打开。"
    }

    private var launchHintColor: Color {
        if launchAtLogin.lastError != nil { return .red }
        return launchAtLogin.requiresApproval ? .orange : .secondary
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
