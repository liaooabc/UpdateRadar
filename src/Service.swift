import AppKit
import Combine
import Foundation

@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var rows: [AppRow] = []
    @Published private(set) var updateCount: Int = 0
    @Published private(set) var checking: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastCheck: Date?
    @Published var settings = AppSettings()
    @Published private(set) var appCount: Int = 0

    private var apps: [InstalledApp] = []
    private var results: [String: CheckResult] = [:]
    private var scheduler: NSBackgroundActivityScheduler?
    private var didBootstrap = false
    /// 扫描正在进行（防止连点「扫描」叠起来跑）
    private var scanning = false
    /// 监听 Applications 目录，装/卸 App 后自动重扫
    private var watcher: AppDirWatcher?
    /// 重扫防抖：一次安装会连着吐好几个 FSEvents
    private var pendingRescan: DispatchWorkItem?
    /// 结果重绘节流
    private var pendingRebuild: DispatchWorkItem?

    // 真正的实现在 Models.swift 的 URSupportDir：Cask 枚举在并发 Task 里也要用它
    static let supportDir: URL = URSupportDir

    private var storeURL: URL { Self.supportDir.appendingPathComponent("state.json") }

    init() {
        load()
    }

    // MARK: - 启动

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        startWatchingApplications()
        rescan(thenCheck: true)
        scheduleAutoCheck()
    }

    /// 扫描放到后台队列：遍历 /Applications、逐个读 Info.plist 是磁盘密集操作，
    /// 挂在主线程上会让面板在扫大目录时明显卡一下。
    /// - Parameters:
    ///   - thenCheck: 扫完是否接着检测一轮
    ///   - force: 检测时是否忽略新鲜度（用户手动点「扫描」时用 true）
    func rescan(thenCheck: Bool = false, force: Bool = false) {
        guard !scanning else { return }
        scanning = true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { Scanner.scan() }.value
            guard let self else { return }
            self.scanning = false
            self.apps = found
            // 只清「已卸载 App 的检测结果」，别动 ignored / dismissed：
            // 外接盘拔掉、或某次扫描抖动时 App 会临时扫不到，一清就把用户
            // 手动「忽略它 / 这个已经是最新」的记录抹了，下次又全冒出来。
            let live = Set(self.apps.map(\.id))
            let stale = self.results.keys.filter { !live.contains($0) }
            if !stale.isEmpty {
                for k in stale { self.results.removeValue(forKey: k) }
                self.save()
            }
            self.appCount = self.apps.count
            self.rebuild()
            if thenCheck { self.checkAll(force: force) }
        }
    }

    // MARK: - 检测

    /// 同时最多跑几个网络请求。之前是「6 个一批、等一批全完再下一批」，
    /// 一批里最慢的那个（国内常有 10 秒级的响应）会拖住整批；改成滑动窗口，
    /// 谁先回来就立刻补一个进去，总耗时接近「总请求数 / 并发数」。
    private static let maxConcurrentChecks = 12

    /// force = false（定时、启动）：结果还新鲜的 App 直接跳过，只补查过期的
    /// force = true（用户点「检查更新」或刷新按钮）：全部重查
    /// - Parameter only: 只查这几个 bundle id（切换「接收测试版」时只重查会受影响的那几个，
    ///   不用把 136 个 App 全跑一遍）
    func checkAll(force: Bool = false, only: Set<String>? = nil) {
        guard !checking else { return }
        // 还没扫到 App：先扫，扫完自动接着查这一轮，别在这里空转
        guard !apps.isEmpty else {
            rescan(thenCheck: true, force: force)
            return
        }

        // 这里用的是 settings.intervalHours：每 6 小时检查一次，就不会每 6 小时里反复查
        let ttl = max(0.25, settings.intervalHours) * 3600
        let cutoff = Date().addingTimeInterval(-ttl)

        let allowBeta = settings.receiveBetaEnabled
        let targets = apps
            .filter { !settings.ignored.contains($0.id) }
            .filter { app in
                if let only { return only.contains(app.id) }
                guard !force else { return true }
                guard let r = results[app.id] else { return true }
                return r.checkedAt < cutoff
            }
            .sorted { priority($0) > priority($1) }
        guard !targets.isEmpty else { return }

        checking = true
        progress = 0
        let total = Double(targets.count)
        let started = Date()

        Task { [weak self] in
            guard let self else { return }
            var done = 0
            await withTaskGroup(of: CheckResult.self) { group in
                var next = targets.makeIterator()
                var inFlight = 0

                // 先塞满并发槽位
                while inFlight < Self.maxConcurrentChecks, let app = next.next() {
                    let prev = self.results[app.id]     // 官网安装包指纹要比上一轮的结果
                    group.addTask { await Checker.check(app, previous: prev, allowBeta: allowBeta) }
                    inFlight += 1
                }

                while let result = await group.next() {
                    self.results[result.bundleId] = result
                    done += 1
                    inFlight -= 1
                    // 回来一个就补一个，别等整批
                    if let app = next.next() {
                        let prev = self.results[app.id]
                        group.addTask { await Checker.check(app, previous: prev, allowBeta: allowBeta) }
                        inFlight += 1
                    }
                    self.progress = Double(done) / total
                    self.scheduleRebuild()
                }
            }
            self.flushRebuild()
            self.settings.lastCheck = Date()
            self.lastCheck = self.settings.lastCheck
            self.checking = false
            self.progress = 1
            self.save()
            self.notifyIfNeeded()
            if ProcessInfo.processInfo.environment["UR_DEBUG"] != nil {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                FileHandle.standardError.write("[UR] 本轮查了 \(targets.count) 个 App，用时 \(ms) ms\n".data(using: .utf8)!)
            }
        }
    }

    /// 先查有检测源的，用户能更快看到有用结果。
    /// 商店里的排最前：就一两个请求、回得最快，而且它们只认商店的版本号
    private func priority(_ app: InstalledApp) -> Int {
        if app.isAppStore { return 3 }
        if Rules.match(app) != nil { return 2 }
        if app.sparkleFeed != nil { return 1 }
        return 0
    }

    // MARK: - 目录监听

    private func startWatchingApplications() {
        guard watcher == nil else { return }
        let home = NSHomeDirectory()
        let paths = ["/Applications", home + "/Applications"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        watcher = AppDirWatcher(paths: paths) { [weak self] in
            // FSEvents 回调在它自己的队列上，跳回主线程再动状态
            Task { @MainActor in self?.scheduleRescanFromDisk() }
        }
    }

    private func scheduleRescanFromDisk() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRescan = nil
            self?.rescan()
        }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: - 数据整合

    /// 结果一条条回来时合并重绘：以前每 4 个结果就整表重建 + 排序 + 切组，
    /// 136 个 App 会重建三十多次，扫描期间列表一直在重排。
    private func scheduleRebuild() {
        guard pendingRebuild == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRebuild = nil
            self?.rebuild()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 一轮查完：立刻用最终结果重建一次，不等节流
    private func flushRebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        rebuild()
    }

    private func rebuild() {
        rows = apps.map { app in
            var result = results[app.id]
            if let r = result, let confirmed = settings.dismissed?[app.id],
               confirmed == (r.latest ?? r.marker ?? "") {
                result?.status = .upToDate
                result?.note = r.latest == nil
                    ? "手动确认：官网这个安装包已经是最新的，下次换包再提醒"
                    : "手动确认：商店版本 \(r.latest ?? "-")，本机包标注 \(app.version)，App Store 也认为已最新"
            }
            return AppRow(app: app, result: result)
        }
        updateCount = rows.filter { $0.isUpdate && !settings.ignored.contains($0.id) }.count
    }

    // MARK: - 设置

    func ignore(_ app: InstalledApp) {
        if !settings.ignored.contains(app.id) {
            settings.ignored.append(app.id)
        }
        rebuild()
        save()
    }

    func unignore(_ id: String) {
        settings.ignored.removeAll { $0 == id }
        rebuild()
        save()
    }

    /// 设置面板里的「全部恢复提醒」：一次性清掉忽略名单
    func unignoreAll() {
        guard !settings.ignored.isEmpty else { return }
        settings.ignored.removeAll()
        rebuild()
        save()
    }

    func setInterval(_ hours: Double) {
        settings.intervalHours = hours
        scheduleAutoCheck()
        save()
    }

    func setHideUnknown(_ hide: Bool) {
        settings.hideUnknown = hide
        save()
    }

    /// 用户说「这个已经是最新」：记下当时的商店版本号，商店再涨版本会自动恢复提醒
    func dismiss(_ row: AppRow) {
        var map = settings.dismissed ?? [:]
        // 没有版本号的（官网只给安装包）：拿安装包指纹当钥匙，官网换包了还会提醒
        map[row.id] = row.latest ?? row.result?.marker ?? ""
        settings.dismissed = map
        rebuild()
        save()
    }

    func undismiss(_ id: String) {
        settings.dismissed?[id] = nil
        rebuild()
        save()
    }

    func isDismissed(_ id: String) -> Bool {
        settings.dismissed?[id] != nil
    }

    func setShowCount(_ on: Bool) {
        settings.showCount = on
        save()
    }

    func setNotify(_ on: Bool) {
        settings.notifyOnUpdates = on
        save()
    }

    /// 接收测试版：默认关。切换后只重查「结果会被这个开关影响」的 App，不跑全量。
    func setReceiveBeta(_ on: Bool) {
        settings.receiveBeta = on
        save()

        let affected = Set(rows.compactMap { row -> String? in
            guard let r = row.result else { return nil }
            if on {
                // 打开：appcast 源的 App 都可能藏着 beta，全都重看一眼
                if r.source == "sparkle" { return row.id }
            } else {
                // 关掉：现在正在提示测试版的那几条要立刻改判
                if let l = r.latest, isPrereleaseVersion(l) { return row.id }
            }
            // 之前被过滤成「只有测试版」的，两种方向都要重查
            if r.note?.hasPrefix("只跟正式版比") == true { return row.id }
            return nil
        })
        if ProcessInfo.processInfo.environment["UR_DEBUG"] != nil {
            let line = "[UR] 接收测试版 → \(on ? "开" : "关")，受影响 \(affected.count) 个：\(affected.sorted().joined(separator: ", "))\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        guard !affected.isEmpty else { return }
        checkAll(force: true, only: affected)
    }

    // MARK: - 通知

    /// 只在「可更新清单发生变化」时提醒，避免每轮都弹
    private func notifyIfNeeded() {
        guard settings.notifyEnabled else { return }
        let updates = rows.filter { $0.isUpdate && !settings.ignored.contains($0.id) }
            .sorted { $0.app.name < $1.app.name }
        let key = updates.map { "\($0.id)@\($0.latest ?? "")" }.joined(separator: "|")

        guard key != (settings.lastNotifiedKey ?? "") else { return }
        settings.lastNotifiedKey = key
        save()

        guard !updates.isEmpty else { return }
        let shown = updates.prefix(3)
            .map { "\($0.app.name) \($0.app.version)→\($0.latest ?? "?")" }
            .joined(separator: "、")
        let body = updates.count > 3 ? "\(shown) 等 \(updates.count) 个" : shown
        Notifier.shared.post(title: "\(updates.count) 个 App 有新版本", body: body, id: "updates")
    }

    /// 后台定时检测。用 NSBackgroundActivityScheduler 而不是 Timer：
    /// 它能感知睡眠、低电量、系统忙闲，唤醒时间由系统合并；
    /// 合盖一夜之后 Timer 攒下的到期事件会一次性全炸出来，它不会。
    private func scheduleAutoCheck() {
        scheduler?.invalidate()
        let s = NSBackgroundActivityScheduler(identifier: "com.hushixiong.updateradar.autocheck")
        s.repeats = true
        s.interval = max(0.25, settings.intervalHours) * 3600
        // 10 分钟内浮动，让系统挑它觉得合适的时间，别整点扎堆
        s.tolerance = s.interval * 0.1
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            Task { @MainActor in self?.checkAll() }
            completion(.finished)
        }
        scheduler = s
    }

    // MARK: - 持久化

    private struct Disk: Codable {
        var settings: AppSettings
        var results: [String: CheckResult]
    }

    private func save() {
        let disk = Disk(settings: settings, results: results)
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let disk = try? JSONDecoder().decode(Disk.self, from: data) else { return }
        settings = disk.settings
        results = disk.results
        lastCheck = disk.settings.lastCheck
    }

    // MARK: - 动作

    /// 「打开下载页」：直达更新源的下载地址（商店页 / dmg / GitHub Release）
    func openUpdate(for row: AppRow) {
        if let s = row.result?.downloadURL, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        } else {
            reveal(row.app)
        }
    }

    /// 左键点一行：去软件自己的官网（不下载、不跳商店产品页）
    func openSite(for row: AppRow) {
        let site = row.result?.homepage ?? row.result?.downloadURL
        if ProcessInfo.processInfo.environment["UR_DEBUG"] != nil {
            let line = "[UR] 左键打开：\(row.app.name) → \(site ?? "（无，改为在 Finder 中显示）")\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if let s = site, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        } else {
            reveal(row.app)
        }
    }

    func reveal(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }

    func launch(_ app: InstalledApp) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
    }
}

/// 监听 Applications 目录：装、卸、改名之后自动重扫，不用用户手动点「扫描」。
/// 用 FSEvents 而不是轮询：系统本来就在为 Finder/Spotlight 收集这些事件，
/// 对常驻的菜单栏 App 几乎没有额外开销；只监听顶层目录变化，不追 .app 内部文件。
private final class AppDirWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard !paths.isEmpty else { return }

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppDirWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(kFSEventStreamCreateFlagWatchRoot)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.hushixiong.updateradar.appwatch"))
        if !FSEventStreamStart(stream) {
            // 起不来就当作没监听：扫描按钮照常可用，不影响主要功能
            FSEventStreamInvalidate(stream)
            self.stream = nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // FSEventStreamCreate 的返回值由 ARC 持有，这里不再手动 Release
    }
}
