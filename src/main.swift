import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private let service = UpdateService()
    private let aboutController = AboutWindowController()
    private let ui = UIState()
    private var cancellable: AnyCancellable?

    private let panelSize = NSSize(width: 364, height: 548)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        buildPopover()

        // 面板开着的时候别弹"全部都是最新的"这种悬停提示，会盖在面板上
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateBadge() }
        }

        Notifier.shared.setup()
        Notifier.shared.onOpen = { [weak self] in self?.showPanel() }

        // 后台查完就刷新角标/图标，不用等用户点一下
        cancellable = service.$updateCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateBadge() }
            }

        updateBadge()
        service.bootstrap()

        let env = ProcessInfo.processInfo.environment
        if env["UPDATERADAR_FORCE_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if env["UPDATERADAR_FORCE_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["UPDATERADAR_SHOW_ABOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.aboutController.show() }
        }
        if env["UPDATERADAR_SHOW_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showStatusMenu() }
        }
        // 调试用：UPDATERADAR_SET_BETA=0/1 起来 4 秒后按下/松开「接收测试版」开关，
        // 用来看「切开关只重查受影响的 App」这条路径
        if let v = env["UPDATERADAR_SET_BETA"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.service.setReceiveBeta(v == "1")
            }
        }
        if env["UPDATERADAR_SHOW_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showPanel() }
            if env["UPDATERADAR_AUTOCLOSE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.hidePanel() }
            }
        }
        // 调试用：不需要看屏幕，直接把面板渲染成 PNG
        // UPDATERADAR_SNAPSHOT=/tmp/panel.png  （常配合 UPDATERADAR_TAB / UPDATERADAR_COLLAPSE）
        if let path = env["UPDATERADAR_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.writeSnapshot(to: path)
            }
        }
        if env["UPDATERADAR_TEST_NOTIFY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Notifier.shared.post(title: "更新雷达 · 通知测试",
                                     body: "看到这条说明通知已经能用了", id: "test")
            }
        }
    }

    // MARK: - 面板

    /// 面板用系统自己的 NSPopover：材质、圆角、阴影、弹出动画全由 AppKit 负责，
    /// 不会出现"自己画的圆角 + 露出来的直角底"那种事。
    private func buildPopover() {
        let pop = NSPopover()
        pop.behavior = .transient          // 点别处 / 按 Esc 自动收起
        pop.animates = true
        let host = NSHostingController(rootView: ContentView(service: service, ui: ui))
        pop.contentViewController = host
        pop.contentSize = panelSize
        popover = pop
    }

    private func showPanel() {
        guard let popover, !popover.isShown, let button = statusItem.button else { return }
        button.toolTip = nil
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func hidePanel() {
        popover?.performClose(nil)
    }

    /// 把面板离屏渲染成 PNG，用于截图核对界面（锁屏也照样能出图）
    private func writeSnapshot(to path: String) {
        let host = NSHostingView(rootView: ContentView(service: service, ui: ui))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    private func updateBadge() {
        guard let button = statusItem.button else { return }
        let n = service.updateCount
        button.image = makeStatusIcon()
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.title = (n > 0 && service.settings.countVisible) ? " \(n)" : ""
        button.toolTip = n > 0 ? "\(n) 个 App 有新版本" : "更新雷达 · 全部都是最新的"
    }

    /// 菜单栏图标：18pt 的自绘模板图（圆圈 + 圆润箭头），跟最初那版一模一样。
    /// 走模板图，黑色由系统按菜单栏明暗自动换成白 —— 不做彩色、不缩放。
    private func makeStatusIcon() -> NSImage {
        // 优先用 asset catalog 里的模板图（Resources/Assets.xcassets/UpdateRadarMenuBar.svg）：
        // 矢量、任意缩放都清晰，设计师能直接改。template 渲染，系统按菜单栏明暗自动反色。
        //
        // 尺寸：SVG 的外框是 22，圆环只占 17.2/22；按 22pt 画出来圆环才是 17.2pt，
        // 跟旧版自绘（18pt 框、环 ≈17.4pt）视觉一样大。改成 18pt 会明显小一圈。
        let assetSide: CGFloat = 22
        if let asset = NSImage(named: "UpdateRadarMenuBar")?.copy() as? NSImage {
            asset.size = NSSize(width: assetSide, height: assetSide)
            asset.isTemplate = true
            return asset
        }

        // 兜底：asset 没编进去时（比如 actool 失败），继续用代码现画的 18pt 那版
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let cx = side / 2
            let cy = side / 2

            let ringInset: CGFloat = 1.1
            let ring = NSBezierPath(ovalIn: NSRect(x: ringInset, y: ringInset,
                                                   width: side - ringInset * 2,
                                                   height: side - ringInset * 2))
            ring.lineWidth = 1.6
            ring.stroke()

            let shaftW: CGFloat = 2.8
            let shaft = NSRect(x: cx - shaftW / 2, y: cy - 1.6, width: shaftW, height: 6.4)
            NSBezierPath(roundedRect: shaft, xRadius: shaftW / 2, yRadius: shaftW / 2).fill()

            let head = NSBezierPath()
            head.move(to: NSPoint(x: cx - 3.9, y: cy - 1.2))
            head.line(to: NSPoint(x: cx + 3.9, y: cy - 1.2))
            head.line(to: NSPoint(x: cx, y: cy - 5.0))
            head.close()
            head.lineJoinStyle = .round
            head.lineWidth = 1.5
            head.fill()
            head.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - 点击

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            hidePanel()
            showStatusMenu()
        } else {
            if popover?.isShown == true {
                hidePanel()
            } else {
                showPanel()
                if service.lastCheck == nil { service.checkAll() }
            }
        }
        updateBadge()
    }

    // MARK: - 右键菜单

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let about = NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let freqItem = NSMenuItem(title: "检查频率", action: nil, keyEquivalent: "")
        let freqMenu = NSMenu()
        for (hours, title) in [(1.0, "每小时"), (6.0, "每 6 小时"), (12.0, "每 12 小时"), (24.0, "每天")] {
            let item = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hours
            item.state = abs(service.settings.intervalHours - hours) < 0.01 ? .on : .off
            freqMenu.addItem(item)
        }
        freqItem.submenu = freqMenu
        menu.addItem(freqItem)

        // 顺序按用户定稿：检查频率 → 菜单栏显示数量 → 有新版本时通知我
        let showCount = NSMenuItem(title: "菜单栏显示数量", action: #selector(toggleShowCount), keyEquivalent: "")
        showCount.target = self
        showCount.state = service.settings.countVisible ? .on : .off
        menu.addItem(showCount)

        let notify = NSMenuItem(title: "有新版本时通知我", action: #selector(toggleNotify), keyEquivalent: "")
        notify.target = self
        notify.state = service.settings.notifyEnabled ? .on : .off
        menu.addItem(notify)

        menu.addItem(.separator())

        let check = NSMenuItem(title: "检查更新", action: #selector(checkNow), keyEquivalent: "r")
        check.target = self
        check.isEnabled = !service.checking
        menu.addItem(check)

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showAbout() { aboutController.show() }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let hours = sender.representedObject as? Double else { return }
        service.setInterval(hours)
    }

    @objc private func toggleHideUnknown() { service.setHideUnknown(!service.settings.hideUnknown) }
    @objc private func toggleNotify() { service.setNotify(!service.settings.notifyEnabled) }
    @objc private func toggleShowCount() {
        service.setShowCount(!service.settings.countVisible)
        updateBadge()
    }

    @objc private func openDataFolder() { NSWorkspace.shared.open(UpdateService.supportDir) }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkNow() {
        service.rescan()
        service.checkAll(force: true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
