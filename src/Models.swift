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
    let sparkleFeed: String?
    let isAppStore: Bool
    let isBeta: Bool
    let installedAt: Date?   // .app 的创建时间，用来判断 Apple 发的是不是最新包

    var icon: NSImage { IconCache.shared.icon(for: path) }
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

    var id: String { bundleId }
}

struct AppSettings: Codable, Equatable {
    var intervalHours: Double = 6
    var ignored: [String] = []
    var lastCheck: Date?
    /// 只显示有自动检测源的 App（默认关：全部列出，没源的排在后面）
    var hideUnknown: Bool = false
    /// 可选是为了兼容旧版 state.json 里没有这两个键的情况
    var notifyOnUpdates: Bool?
    var showCount: Bool?
    var lastNotifiedKey: String?
    /// bundleId -> 用户手动确认为最新的那个商店版本号；商店再出新版本时会自动重新提醒
    var dismissed: [String: String]?

    var notifyEnabled: Bool { notifyOnUpdates ?? true }
    var countVisible: Bool { showCount ?? true }
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
            let base = "\(app.version)  →  \(latest ?? "?" )"
            if let d = result?.releaseDate {
                let f = DateFormatter()
                f.dateFormat = "M月d日"
                return base + "　·　" + f.string(from: d)
            }
            return base
        case .upToDate:
            if let n = result?.note, n.hasPrefix("手动确认") {
                return "\(app.version)　已确认最新（商店 \(latest ?? "?"))"
            }
            // 更新源里只有测试版时不提示更新，但得让用户知道为什么（不然会以为漏了）
            if result?.note?.hasPrefix("只跟正式版比") == true {
                return "\(app.version)　·　只有测试版更新"
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


/// 图标很贵：每次调用都会问 LaunchServices。缓存起来，滚动才不会卡。
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func icon(for path: String) -> NSImage {
        lock.lock()
        if let hit = cache[path] { lock.unlock(); return hit }
        lock.unlock()

        // 列表里只画到 26pt，没必要留着 512px 的原始位图：
        // 直接光栅化到 64×64 像素（32pt @2x），一张 16KB 而不是几百 KB
        let src = NSWorkspace.shared.icon(forFile: path)
        let img = IconCache.rasterize(src, pixels: 64)

        lock.lock()
        cache[path] = img
        lock.unlock()
        return img
    }

    private static func rasterize(_ src: NSImage, pixels: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return src }

        rep.size = NSSize(width: pixels / 2, height: pixels / 2)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            src.draw(in: NSRect(x: 0, y: 0, width: pixels / 2, height: pixels / 2))
        }
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))
        out.addRepresentation(rep)
        return out
    }
}
