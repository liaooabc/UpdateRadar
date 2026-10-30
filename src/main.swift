import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private let service = UpdateService()
    private let aboutController = AboutWindowController()
    private let updater = SelfUpdater()
    private lazy var settingsController = SettingsWindowController(service: service, updater: updater)
    private let ui = UIState()
    private var cancellable: AnyCancellable?
    private var bobCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var selfCheckScheduler: NSBackgroundActivityScheduler?
    /// 面板开着时的键盘监听（↑↓ / Return）；只有面板是 key window 才接管
    private var keyMonitor: Any?

    // 扫描时环不动，里面那支箭头往前滚（往下滑、从上面补进来，像滚轮往前滚）：
    // 转圈会把下载箭头转成朝上的箭头，认不出是谁；往前滚既看得出"在干活"，又是原来那个箭头。
    private var rippling = false
    private var iconLayer: CALayer?
    private var rippleLayers: [CAShapeLayer] = []
    private static let rippleStart: CGFloat = 6.4     // 从环的内沿起
    private static let rippleEnd: CGFloat = 11.2      // 扩到框边（22pt 的图标里环外径 8.6）
    private static let ripplePeriod: CFTimeInterval = 1.6
    static let iconInnerRadius: CGFloat = 6.3             // 环的内沿（22pt 图里环外径 17.2、线宽 2 → 内径 6.6）

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

        buildMainMenu()
        buildPopover()

        // 面板开着的时候别弹"全部都是最新的"这种悬停提示，会盖在面板上
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.removePanelKeyMonitor()
                self?.updateBadge()
            }
        }

        Notifier.shared.setup()
        Notifier.shared.onOpen = { [weak self] in self?.showPanel() }

        // 调试用：UPDATERADAR_RIPPLE_ALWAYS=1 一直荡波，用来单量这段动画本身的开销
        if ProcessInfo.processInfo.environment["UPDATERADAR_RIPPLE_ALWAYS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startRippling() }
        }

        // 扫描时菜单栏图标往外荡雷达波，扫完停回原样
        bobCancellable = service.$checking
            .receive(on: RunLoop.main)
            .sink { [weak self] checking in
                Task { @MainActor in
                    if checking { self?.startRippling() } else { self?.stopRippling() }
                }
            }

        // 后台查完就刷新角标/图标，不用等用户点一下
        cancellable = service.$updateCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateBadge() }
            }

        // 设置窗口里关掉「在菜单栏显示更新数量」时，这里立刻把角标收掉
        settingsCancellable = service.$settings
            .map(\.countVisible)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateBadge() }
            }

        updateBadge()
        service.bootstrap()

        // 本软件自己的更新：启动静默查一次，之后每 24 小时查一次（设置面板里也有手动按钮）
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.updater.checkIfStale()
        }
        // 同样交给 NSBackgroundActivityScheduler：24 小时是大周期，
        // 更需要系统根据睡眠/电量来挑时间，而不是开机时挂一个死循环 Timer。
        let selfCheck = NSBackgroundActivityScheduler(identifier: "com.hushixiong.updateradar.selfcheck")
        selfCheck.repeats = true
        selfCheck.interval = 24 * 3600
        selfCheck.tolerance = 2 * 3600
        selfCheck.qualityOfService = .utility
        selfCheck.schedule { [weak self] completion in
            Task { @MainActor in self?.updater.check() }
            completion(.finished)
        }
        selfCheckScheduler = selfCheck

        applyDebugEnvironment()
    }

    /// 调试用的环境变量开关。抽出来集中放一处，`applicationDidFinishLaunching` 只负责启动顺序。
    /// 这些开关只在从终端手动启动时生效，正常双击打开时全部为空。
    private func applyDebugEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if env["UPDATERADAR_FORCE_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if env["UPDATERADAR_FORCE_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["UPDATERADAR_SHOW_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showSettings() }
        }
        if env["UPDATERADAR_SHOW_ABOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.aboutController.show() }
        }
        if env["UPDATERADAR_SHOW_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showStatusMenu()
            }
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
        // 调试用：UPDATERADAR_PIN_PANEL=1 时面板不自动收，方便 screencapture 核对长相
        if ProcessInfo.processInfo.environment["UPDATERADAR_PIN_PANEL"] != nil {
            pop.behavior = .applicationDefined
        }
        pop.animates = true
        let host = NSHostingController(rootView: ContentView(service: service, ui: ui,
                                                             onOpenSettings: { [weak self] in
                                                                 self?.showSettings()
                                                             }))
        pop.contentViewController = host
        pop.contentSize = panelSize
        popover = pop
    }

    // MARK: - 设置

    /// 面板收起、窗口浮上来。设置窗口是独立窗口，打开时不必再留在面板里。
    private func showSettings() {
        hidePanel()
        settingsController.show()
    }

    /// 一句极简主菜单：只是为了让 ⌘, 和 ⌘Q 有地方挂。
    /// 菜单栏本身不显示（LSUIElement / .accessory），键等价物照样生效。
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let close = NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(close)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出更新雷达", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 编辑菜单：文本编辑快捷键必须有菜单项挂载，否则 LSUIElement 应用里
        // ⌘C / ⌘V / ⌘A 在搜索框里全部失效。target 留空，走响应链找第一响应者。
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: NSSelectorFromString("delete:"), keyEquivalent: "")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: "搜索", action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self
        editMenu.addItem(find)
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let rescanItem = NSMenuItem(title: "重新扫描", action: #selector(rescanFromMenu), keyEquivalent: "r")
        rescanItem.target = self
        viewMenu.addItem(rescanItem)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    /// ⌘F：面板没开就先弹出来，再把焦点交给搜索框
    @objc private func focusSearch() {
        if popover?.isShown != true { showPanel() }
        // 面板刚弹出时 SwiftUI 还没把搜索框建出来，等一拍再发
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .updateRadarFocusSearch, object: nil)
        }
    }

    @objc private func rescanFromMenu() { service.rescan() }

    private func showPanel() {
        guard let popover, !popover.isShown, let button = statusItem.button else { return }
        button.toolTip = nil
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPanelKeyMonitor()
    }

    private func hidePanel() {
        popover?.performClose(nil)
    }

    // MARK: - 面板键盘

    /// 只挂本地监视器：面板是 key window 时接管 ↑↓ / Return，其它情况原样放行。
    /// 用 Esc 关面板交给 NSPopover 自己（transient 弹层默认就支持）。
    private func installPanelKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 只把 keyCode 带进主线程，NSEvent 本身不是 Sendable
            let code = event.keyCode
            let handled = MainActor.assumeIsolated { self.handlePanelKey(code: code) }
            return handled ? nil : event
        }
    }

    private func removePanelKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 返回 true 表示这枚按键已经吃掉，false 表示原样放行
    private func handlePanelKey(code: UInt16) -> Bool {
        guard let popover, popover.isShown,
              let window = popover.contentViewController?.view.window,
              window.isKeyWindow else { return false }
        // 正在搜索框里打字：方向键要移光标、Return 什么也别做
        if window.firstResponder is NSTextView { return false }
        switch code {
        case 126: moveKeyRow(-1); return true      // ↑
        case 125: moveKeyRow(1); return true       // ↓
        case 36, 76: activateKeyRow(); return true // Return / 小键盘 Enter
        default: return false
        }
    }

    /// 行的顺序直接从布局里读：rowFrames 是按纵坐标记的，折叠、分组、换页签都不用另外算
    private func moveKeyRow(_ delta: Int) {
        let ids = ui.rowFrames.sorted { $0.value.minY < $1.value.minY }.map(\.key)
        guard !ids.isEmpty else { return }
        let current = ui.keyRow.flatMap { ids.firstIndex(of: $0) }
        let start = current ?? (delta > 0 ? -1 : ids.count)
        let next = min(max(start + delta, 0), ids.count - 1)
        ui.keyRow = ids[next]
    }

    /// Return：有新版本就去下载页；其它行在 Finder 中显示
    private func activateKeyRow() {
        guard let id = ui.keyRow, let row = service.rows.first(where: { $0.id == id }) else { return }
        if row.isUpdate {
            service.openUpdate(for: row)
        } else {
            service.reveal(row.app)
        }
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
        if !rippling { button.image = makeStatusIcon() }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.title = (n > 0 && service.settings.countVisible) ? " \(n)" : ""
        button.toolTip = n > 0 ? "\(n) 个 App 有新版本" : "更新雷达 · 全部都是最新的"
    }

    // MARK: - 扫描时"雷达波"

    /// 模板图是「黑剪影 + alpha」，塞进 CALayer 不会跟菜单栏明暗走，
    /// 所以按当前外观染一份再交给图层。
    private func tintedCGImage(_ image: NSImage, color: NSColor, scale: CGFloat) -> CGImage? {
        let pxW = Int(image.size.width * scale), pxH = Int(image.size.height * scale)
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // bitmapImageRep 的 context 用户空间是像素，不缩放图标只画到一角、只有 1/4 大
        ctx.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// 全透明但真有位图的同尺寸图，用来占住菜单栏里图标那一格
    private func blankIcon(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            img.addRepresentation(rep)
        }
        return img
    }

    private func circlePath(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2), transform: nil)
    }

    /// 扫描时图标本身不动，从环里往外荡两圈"雷达波"（一圈接一圈，很快但很淡）。
    /// 菜单栏只有 17pt，动整个图标或者让箭头滚过去都会糊成一团；涟漪只加淡环，最干净。
    private func startRippling() {
        guard !rippling, let button = statusItem.button else { return }
        rippling = true

        let size = makeStatusIcon().size
        button.image = blankIcon(size: size)
        button.wantsLayer = true

        let scale = button.window?.backingScaleFactor ?? 2
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color: NSColor = dark ? .white : .black
        var rect = NSRect(origin: .zero, size: size)
        if let cell = button.cell as? NSButtonCell {
            rect = cell.imageRect(forBounds: button.bounds)
        }

        // 图标本体：一直不动
        let icon = CALayer()
        icon.frame = rect
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = scale
        icon.contents = tintedCGImage(makeStatusIcon(), color: color, scale: scale)
        button.layer?.addSublayer(icon)
        iconLayer = icon

        // 涟漪：两条弧线同时往外扩、边扩边淡，错开半个周期，看着是连续往外推
        let center = CGPoint(x: rect.width / 2, y: rect.height / 2)
        for i in 0..<2 {
            let wave = CAShapeLayer()
            wave.frame = rect
            wave.fillColor = nil
            wave.strokeColor = color.withAlphaComponent(0.7).cgColor
            wave.lineWidth = 1.3
            wave.path = circlePath(center: center, radius: Self.rippleStart)
            wave.opacity = 0
            button.layer?.addSublayer(wave)
            rippleLayers.append(wave)

            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = circlePath(center: center, radius: Self.rippleStart)
            grow.toValue = circlePath(center: center, radius: Self.rippleEnd)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.12, 0.55, 1]

            for anim in [grow, fade] {
                anim.duration = Self.ripplePeriod
                anim.repeatCount = .infinity
                anim.isRemovedOnCompletion = false
                anim.timeOffset = CFTimeInterval(i) * Self.ripplePeriod / 2
            }
            wave.add(grow, forKey: "grow")
            wave.add(fade, forKey: "fade")
        }
    }

    private func stopRippling() {
        guard rippling else { return }
        rippling = false
        for layer in rippleLayers + [iconLayer].compactMap({ $0 }) {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        rippleLayers = []
        iconLayer = nil
        statusItem.button?.image = makeStatusIcon()
    }

    /// 菜单栏图标：18pt 的自绘模板图（圆圈 + 圆润箭头），跟最初那版一模一样。
    /// 走模板图，黑色由系统按菜单栏明暗自动换成白 —— 不做彩色、不缩放。
    private func makeStatusIcon() -> NSImage {
        // 优先用 asset catalog 里的模板图（Resources/Assets.xcassets/UpdateRadarMenuBar.svg）：
        // 矢量、任意缩放都清晰，设计师能直接改。template 渲染，系统按菜单栏明暗自动反色。
        //
        // 尺寸：SVG 的外框是 22，圆环只占 17.2/22。按 20.5pt 画出来圆环是 16pt，
        // 跟 Wi‑Fi、电池这类系统图标并排时高度一致；按 22pt 画会高出一头。
        let assetSide: CGFloat = 20.5
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

    /// 右键菜单（用户定稿 2026-10-26）：关于 / 设置 / 检测更新 / 退出。
    /// 检测频率、菜单栏显示数量、通知开关都搬进设置窗口了，菜单里不再重复。
    private func showStatusMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let about = NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let check = NSMenuItem(title: "检测更新", action: #selector(checkNow), keyEquivalent: "r")
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

    @objc private func checkNow() {
        service.rescan(thenCheck: true, force: true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 系统会调用它来确认「关掉窗口后能不能安全恢复状态」。我们只有菜单栏面板和两个窗口，
    /// 全部由 AppKit 恢复，直接返回 true；否则日志里一直有一条告警。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
