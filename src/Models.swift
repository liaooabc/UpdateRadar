import AppKit
import Foundation

/// 数据目录。不挂在 UpdateService 上：Cask 枚举在后台并发 Task 里要用它，
/// 而 UpdateService 是 @MainActor 隔离的（Swift 6 语言模式下会硬报错）。
let URSupportDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("UpdateRadar", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

struct InstalledApp: Identifiable, Hashable {
    let id: String          // bundleIdentifier，没有就用路径
    let name: String
    let path: String
    let bundleId: String?
    let version: String
    /// CFBundleVersion。更新源经常写构建号而不是营销版本号（Office: 16.114.26102031），
    /// 少了它就会把「本机已经装着的包」判成新版本。
    let build: String
    let sparkleFeed: String?
    let isAppStore: Bool
    let isBeta: Bool
    let installedAt: Date?   // .app 的创建时间，用来判断 Apple 发的是不是最新包

    /// 图标里带了浅色/深色两份，画的时候由 AppKit 按当前外观自己挑
    var icon: AppIconPair { IconCache.shared.icon(for: path) }
}

enum CheckStatus: String, Codable {
    case upToDate        // 已是最新
    case updateAvailable // 有新版本
    case unknown         // 没有可用的检测源
    case failed          // 检测出错（网络等）
}

struct CheckResult: Identifiable, Codable, Equatable {
    let bundleId: String
    var status: CheckStatus
    var latest: String?
    var downloadURL: String?
    /// 软件自己的官网（不是下载直链、也不是商店的产品页）。
    /// 左键点一行用它；「打开下载页」才用 downloadURL。
    var homepage: String?
    var note: String?
    var source: String?     // sparkle / appstore / vendor / manual
    var checkedAt: Date
    var releaseDate: Date?  // 新版本的发布/更新时间，用来证明"哪个更新"
    var notes: String?      // 更新详情（从更新源里抓的第一段）
    /// 官网安装包指纹（文件名的构建时间戳）。官网只放安装包、不写版本号的 App
    /// （扣子桌面端）用它判断「官网的包换了没」，因为压根没有版本号可比。
    var marker: String? = nil
    /// 这条结果是被「不接收测试版」开关压下去的（更新源里最新的其实是 beta）。
    /// 切开关时要重查这些 App —— 用结构化标记，别去 match 中文提示文案。
    /// 可选是为了兼容旧版 state.json（没有这个键就是 nil）。
    var suppressedBeta: Bool? = nil

    var id: String { bundleId }
}

struct AppSettings: Codable, Equatable {
    var intervalHours: Double = 6
    var ignored: [String] = []
    var lastCheck: Date?
    /// 只显示有自动检测源的 App（默认开：没源的藏起来，设置里能再打开）。
    /// 可选是为了兼容旧版 state.json 没有这个键。
    var hideUnknown: Bool?
    /// 隐藏检测失败的 App（默认开）。失败多是源暂时抽风，15 分钟后会补查，
    /// 平时不用占列表的位置。
    var hideFailed: Bool?
    /// 可选是为了兼容旧版 state.json 里没有这两个键的情况
    var notifyOnUpdates: Bool?
    var showCount: Bool?
    var lastNotifiedKey: String?
    /// bundleId -> 用户手动确认为最新的那个商店版本号；商店再出新版本时会自动重新提醒
    var dismissed: [String: String]?

    /// 接不接收测试版（beta / rc）更新。默认关：只跟正式版比，别拿 beta 打扰人。
    var receiveBeta: Bool?

    var notifyEnabled: Bool { notifyOnUpdates ?? true }
    var countVisible: Bool { showCount ?? true }
    var receiveBetaEnabled: Bool { receiveBeta ?? false }
    var hideUnknownEnabled: Bool { hideUnknown ?? true }
    var hideFailedEnabled: Bool { hideFailed ?? true }
}

struct Store: Codable {
    var settings: AppSettings = AppSettings()
    var results: [String: CheckResult] = [:]
}

/// 一个 App 在界面上的完整状态
struct AppRow: Identifiable {
    let app: InstalledApp
    let result: CheckResult?

    var id: String { app.id }
    var status: CheckStatus { result?.status ?? .unknown }
    var latest: String? { result?.latest }
    var isUpdate: Bool { status == .updateAvailable }
    var hasSource: Bool { (result?.source != nil && result?.source != "manual") || result?.status == .failed }

    /// 把「GitHub 接口限流（未登录时每小时 60 次…）」这类长 note 压成一句短的
    static func shortReason(_ note: String) -> String? {
        let head = note.split(whereSeparator: { "（(，,；;：:".contains($0) }).first.map(String.init) ?? note
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 12 ? trimmed : String(trimmed.prefix(12)) + "…"
    }

    var subtitle: String {
        switch status {
        case .updateAvailable:
            // 官网只放安装包、没有版本号的那种：只能告诉你「官网换包了」
            guard let latest else { return "\(app.version)　·　官网有新安装包" }
            // 副标题只留「本机版本 → 新版本」，不再追加发布日期
            return "\(app.version)  →  \(latest)"
        case .upToDate:
            if let n = result?.note, n.hasPrefix("手动确认") {
                return "\(app.version)　已确认最新（商店 \(latest ?? "?"))"
            }
            // 更新源里只有测试版时不提示更新，但得让用户知道为什么（不然会以为漏了）
            if result?.note?.hasPrefix("只跟正式版比") == true {
                return "\(app.version)　·　只有测试版更新"
            }
            // 官网页面比本机旧（酷家乐那种页面常年不更新）：把官网看到的写出来，
            // 免得用户以为「加了官网源怎么还是老样子」
            if result?.note?.hasPrefix("官方源当前是") == true, let latest {
                return "\(app.version)　·　官网页面还是 \(latest)"
            }
            return app.version
        case .failed:
            // 状态字在右边那列（⚠ 检测失败），副标题不重复状态字；
            // 有 note 就带一句「为什么失败」，太长的截断（完整原文在悬停提示里）
            if let n = result?.note, let short = AppRow.shortReason(n) {
                return "\(app.version)　·　\(short)"
            }
            return app.version
        case .unknown:
            return app.version
        }
    }
}


/// 一个 App 的浅色、深色两套图标。有些 App 只提供一套，两份就一样。
struct AppIconPair {
    let light: NSImage
    let dark: NSImage
}

/// 图标很贵：每次调用都会问 LaunchServices。缓存起来，滚动才不会卡。
final class IconCache {
    static let shared = IconCache()

    private struct Entry {
        let icons: AppIconPair
        /// App 包的修改时间：App 升级换了图标后这里会变，据此重新取图
        let stamp: Date?
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    func icon(for path: String) -> AppIconPair {
        let stamp = IconCache.stamp(of: path)
        lock.lock()
        if let hit = cache[path], hit.stamp == stamp { lock.unlock(); return hit.icons }
        lock.unlock()

        // 列表里只画到 40pt，没必要留着 512px 的原始位图：
        // 直接光栅化到 64×64 像素，一张 16KB 而不是几百 KB
        let src = NSWorkspace.shared.icon(forFile: path)
        let icons = AppIconPair(light: IconCache.rasterize(src, pixels: 64, dark: false),
                                dark: IconCache.rasterize(src, pixels: 64, dark: true))

        lock.lock()
        cache[path] = Entry(icons: icons, stamp: stamp)
        lock.unlock()
        return icons
    }

    /// App 被升级后图标可能换掉，所以缓存要跟着包的修改时间走，
    /// 不用重启面板
    private static func stamp(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    /// 扫描结束后在后台先把图标暖进缓存。
    /// 行里是现取图标的（`row.app.icon`），第一次切到「其他」页时近百个图标
    /// 会在主线程上依次问 LaunchServices + 光栅化，点一下就能卡半秒；
    /// 先在后台备好，切页签就只是换内容。
    func preload(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for path in paths {
                _ = self.icon(for: path)
            }
        }
    }

    /// 光栅化成 64px 的位图，按目标外观单独取一遍：
    /// 光栅化会把图标「拍平」，不按外观取图的话深浅色切了也不会变。
    private static func rasterize(_ src: NSImage, pixels: Int, dark: Bool) -> NSImage {
        let size = NSSize(width: pixels / 2, height: pixels / 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return src }

        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            let rect = NSRect(origin: .zero, size: size)
            if let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) {
                appearance.performAsCurrentDrawingAppearance {
                    src.draw(in: rect)
                }
            } else {
                src.draw(in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }
}
