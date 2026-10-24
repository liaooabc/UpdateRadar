import Foundation

/// 1.5.0 / v4.13.3 / 2026.39 / "Version 4.13.3" 这种才算版本号，"Download" 这类标题不算
private func looksLikeVersion(_ s: String) -> Bool {
    var t = s.trimmingCharacters(in: .whitespaces)
    for prefix in ["Version ", "version ", "v"] where t.hasPrefix(prefix) {
        t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        break
    }
    guard t.count >= 1, t.count <= 24 else { return false }
    if t.contains(" ") { return false }
    guard let first = t.first, first.isNumber else { return false }
    return t.contains(where: { $0.isNumber })
}

/// 这个版本号是不是测试版：Beta / Alpha / RC / Preview / nightly …
/// 用途只有一个 —— 别拿测试版去提示更新（用户只要正式版，见 1.0.6 的需求）。
func isPrereleaseVersion(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    // 按「非字母数字」切词，避免 Marc / snapshot 这类词里凑出来的字母组合误判
    let words: Set<String> = ["beta", "alpha", "rc", "pre", "preview", "prerelease",
                              "nightly", "snapshot", "canary", "unstable", "test", "dev"]
    let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    if tokens.contains(where: { words.contains($0) }) { return true }
    // 连写的：2.0.0-beta2 / 1.2.3rc1 / 3.0alpha
    let pattern = "(^|[^a-z])(alpha|beta|rc|dev|pre|preview|prerelease|nightly|snapshot|canary)[0-9]*([^a-z]|$)"
    if lower.range(of: pattern, options: .regularExpression) != nil { return true }
    return false
}

// MARK: - Sparkle appcast

final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var title: String?
        var shortVersion: String?
        var buildVersion: String?
        var minSystem: String?
        var link: String?
        var enclosure: String?
        var pubDate: String?
        var notes: String?
        var notesLink: String?
        /// <sparkle:channel>beta</sparkle:channel>：只有订阅了该通道的客户端才该收这条
        var channel: String?

        /// 对外展示、用来比较的版本号。营销版本号优先，其次 title（老式 appcast 把版本写在 title 里），
        /// 最后才是构建号——构建号跟 CFBundleShortVersionString 不是一套编号，不能混比。
        var marketingVersion: String? {
            if let v = shortVersion, !v.isEmpty { return v }
            if let t = title, looksLikeVersion(t) {
                // 去掉 "Version " 前缀再拿去比较
                var s = t.trimmingCharacters(in: .whitespaces)
                for p in ["Version ", "version "] where s.hasPrefix(p) {
                    s = String(s.dropFirst(p.count))
                    break
                }
                return s
            }
            return nil
        }
    }

    /// 1.5.0 / v4.13.3 / 2026.39 这种才算版本号，"Download" 这类标题不算
    private(set) var items: [Item] = []
    private var current: Item?
    private var buffer = ""
    private var inItem = false

    func parse(_ data: Data) -> [Item] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let el = elementName.lowercased()
        if el == "item" {
            inItem = true
            current = Item()
        }
        if el == "enclosure", inItem {
            current?.enclosure = attributeDict["url"]
            if current?.buildVersion == nil {
                current?.buildVersion = attributeDict["sparkle:version"] ?? attributeDict["version"]
            }
        }
        if inItem { buffer = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let el = elementName.lowercased()
        guard inItem else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "sparkle:shortversionstring":
            if !text.isEmpty { current?.shortVersion = text }
        case "title":
            if !text.isEmpty { current?.title = text }
        case "sparkle:version":
            if !text.isEmpty { current?.buildVersion = text }
        case "sparkle:minimumsystemversion":
            if !text.isEmpty { current?.minSystem = text }
        case "link":
            if !text.isEmpty { current?.link = text }
        case "pubdate":
            if !text.isEmpty { current?.pubDate = text }
        case "description":
            if current?.notes == nil, !text.isEmpty { current?.notes = text }
        case "sparkle:releasenoteslink":
            if !text.isEmpty { current?.notesLink = text }
        case "sparkle:channel":
            if !text.isEmpty { current?.channel = text }
        case "item":
            if let c = current { items.append(c) }
            current = nil
            inItem = false
        default:
            break
        }
        buffer = ""
    }
}

/// 更新说明常是 HTML，去掉标签、实体和多余空白，只留能读的字。
/// 上限放宽到 1600：列表里只显示一行，但左键点开要看全文。
func plainNotes(_ raw: String?, limit: Int = 1600) -> String? {
    guard var s = raw else { return nil }
    s = s.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?s)<br\\s*/?>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                    "&quot;": "\"", "&#39;": "'", "&mdash;": "—", "&hellip;": "…"]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // 很多更新说明以·、•、- 开头，显示在行首很怪，去掉
    while let f = s.first, "·•-–—*>\u{2022}\u{00B7}\u{25CF}\u{3000} ".contains(f) {
        s.removeFirst()
    }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if s.count > limit { s = String(s.prefix(limit)) + "…" }
    return s
}

/// appcast 的 pubDate 是 RFC822 格式
func parseRFC822(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    if let d = f.date(from: s) { return d }
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f.date(from: s)
}

func parseISO8601(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    return f.date(from: s)
}

// MARK: - 网络

/// 从更新源地址推「官网」：
/// - GitHub 托管的（raw.githubusercontent.com / github.com/owner/repo/...）→ 仓库页
/// - downloads./download./cdn. 开头的下载主机场 → 去掉那一段（downloads.skylum.com → skylum.com）
/// - 其余取站点根（mole.fit/appcast.xml → mole.fit）
func siteFromFeed(_ urlString: String?) -> String? {
    guard let s = urlString, let u = URL(string: s), let host = u.host?.lowercased() else { return nil }
    let parts = u.path.split(separator: "/").map(String.init)
    if host == "github.com" || host == "raw.githubusercontent.com" {
        if parts.count >= 2 { return "https://github.com/\(parts[0])/\(parts[1])" }
        return "https://github.com"
    }
    var bare = host
    for p in ["downloads.", "download.", "cdn.", "dl."] where bare.hasPrefix(p) {
        bare = String(bare.dropFirst(p.count))
        break
    }
    // 产品子域也收成主域：luminarneomac.skylum.com → skylum.com。
    // 但 github.io / netlify.app 这类托管后缀的主域没意义，别动。
    let labels = bare.split(separator: ".").map(String.init)
    let hosting = ["github.io", "netlify.app", "vercel.app", "pages.dev",
                   "gitlab.io", "fly.dev", "web.app", "firebaseapp.com"]
    if labels.count >= 3, !bare.hasPrefix("www.") {
        let base = labels.suffix(2).joined(separator: ".")
        if !hosting.contains(base) { bare = base }
    }
    // GitHub Pages 这类托管站，真正的站名在路径第一段：farzaa.github.io/clicky-releases
    if labels.count >= 3, hosting.contains(labels.suffix(2).joined(separator: ".")),
       let first = parts.first, !first.isEmpty {
        return "https://\(bare)/\(first)"
    }
    return "https://\(bare)"
}

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // 死掉的源（停更的 appcast、国内连不上的接口）会一直占着并发槽位，
        // 所以超时不能给太宽裕：10 秒还没回话就当它没有。
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        // 默认每主机只 6 条连接，iTunes 查询动辄 30 个包，会被自己卡住
        c.httpMaximumConnectionsPerHost = 12
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: c)
    }()

    /// raw.githubusercontent.com 在国内时通时不通，用 jsDelivr 做镜像兜底
    private static func jsdelivrMirror(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), url.host == "raw.githubusercontent.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        let owner = parts[0], repo = parts[1], branch = parts[2]
        let rest = parts.dropFirst(3).joined(separator: "/")
        guard !rest.isEmpty else { return nil }
        return "https://cdn.jsdelivr.net/gh/\(owner)/\(repo)@\(branch)/\(rest)"
    }

    private static func fetchText(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// 注意：这里**故意不做失败重试**。以前失败会 sleep 0.5 秒再试一次，
    /// 等于把一个死掉的更新源（停更的 appcast、国内连不上的接口）的成本从 8 秒翻到 16 秒，
    /// 而并发槽位被它占着，整轮检查就被一两个死源拖到十几秒。
    /// 现在只保留 raw.githubusercontent.com → jsDelivr 的镜像兜底（那是「换条路能通」，
    /// 不是「同一条路再撞一次」）。
    static func text(_ urlString: String) async -> String? {
        if let s = await fetchText(urlString) { return s }
        if let alt = jsdelivrMirror(urlString), let s = await fetchText(alt) { return s }
        return nil
    }

    /// HTTP 状态码。GitHub 未认证时限流会返回 403 + X-RateLimit-Remaining: 0，
    /// 和「仓库不存在 / 网络不通」返回的 404 是完全不同的两回事，
    /// 混成一个 nil 的话上层只能笼统报「检测失败」，用户无从下手。
    struct HTTPError: Error {
        let status: Int
        /// 剩余配额（GitHub 的 X-RateLimit-Remaining），nil 表示该响应没带这个头
        let rateLimitRemaining: Int?
        var isRateLimited: Bool {
            if status == 429 { return true }
            if status == 403, let r = rateLimitRemaining, r <= 0 { return true }
            return false
        }
    }

    /// GitHub 专用：区分「限流」和「仓库没了」。
    /// 未认证配额只有 60 次/小时/IP（同一个 Wi-Fi 下几台 Mac 共用），撞墙时要说清原因。
    static func githubLatestRelease(_ repo: String) async -> Result<[String: Any]?, HTTPError> {
        let url = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let u = URL(string: url) else { return .success(nil) }
        do {
            let (data, resp) = try await session.data(from: u)
            guard let http = resp as? HTTPURLResponse else { return .success(nil) }
            guard (200..<300).contains(http.statusCode) else {
                let remain = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
                return .failure(HTTPError(status: http.statusCode, rateLimitRemaining: remain))
            }
            return .success(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        } catch {
            return .success(nil)
        }
    }

    static func json(_ urlString: String) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Homebrew Cask

/// Homebrew Cask 是社区维护的 Mac 软件版本库（7000+ 个 App，含大量没有 appcast 的商业软件）。
/// 设计取舍：18MB 的完整索引不下载 —— 随 App 带一张 120KB 的「App 名 → cask 名」表，
/// 运行时只按需拉单个 cask 的 1KB JSON，结果缓存 12 小时。这样内存和流量都可控。
enum Cask {
    struct Entry {
        let token: String
        let version: String
        let homepage: String?
    }

    private static let lock = NSLock()
    private static var store: [String: Cached]?
    private static var mapLoaded = false
    private static var nameMap: [String: String] = [:]
    private static var bundleMap: [String: String] = [:]

    private struct Cached: Codable {
        var version: String
        var homepage: String?
        var fetchedAt: Date
        var bundles: [String]?     // cask 里登记的 bundle id，用来复核同名不同版
    }

    private static var cacheURL: URL { URSupportDir.appendingPathComponent("cask-cache.json") }

    /// 名称表随包发布：{"apps": {"sketch.app": "sketch"}, "bundles": {"com.microsoft.Word": "microsoft-word"}}
    private static func loadMap() {
        // 12 路并发 Task 会同时进来：没这把锁就是两个线程同时写 Dictionary（会真崩）
        lock.lock(); defer { lock.unlock() }
        guard !mapLoaded else { return }
        mapLoaded = true
        guard let url = Bundle.main.url(forResource: "cask-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        nameMap = obj["apps"] as? [String: String] ?? [:]
        bundleMap = obj["bundles"] as? [String: String] ?? [:]
    }

    /// 一个 App 对应哪个 cask：先按 .app 文件名，再按 bundle id
    static func token(for app: InstalledApp) -> (token: String, exact: Bool)? {
        loadMap()
        // bundle id 最可靠（能排除同名不同 App），其次才按 .app 文件名
        if let bid = app.bundleId, let t = bundleMap[bid] { return (t, true) }
        let file = (app.path as NSString).lastPathComponent.lowercased()
        if let t = nameMap[file] { return (t, false) }
        return nil
    }

    /// cask 的 uninstall 段里写着「卸载时要退出的 bundle id」（如 notion.id），
    /// 拿它反查这到底是哪个 App。只看 uninstall：zap/trash 里混着路径，会误判。
    private static func bundleIds(in obj: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ o: Any) {
            if let d = o as? [String: Any] { d.values.forEach(walk) }
            else if let a = o as? [Any] { a.forEach(walk) }
            else if let str = o as? String {
                for part in str.split(whereSeparator: { " ,;".contains($0) }) {
                    let t = String(part)
                    let dots = t.filter { $0 == "." }.count
                    let clean = t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                    if dots >= 2, clean, !t.hasSuffix(".plist"), !t.hasSuffix(".app") {
                        ids.insert(t)
                    }
                }
            }
        }
        for a in obj["artifacts"] as? [Any] ?? [] {
            if let d = a as? [String: Any], let u = d["uninstall"] { walk(u) }
        }
        return ids
    }

    private static func loadCache() -> [String: Cached] {
        lock.lock(); defer { lock.unlock() }
        if let store { return store }
        var loaded: [String: Cached] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: Cached].self, from: data) {
            loaded = decoded
        }
        store = loaded
        return loaded
    }

    private static func saveCache(_ entry: Cached, token: String) {
        lock.lock(); defer { lock.unlock() }
        var current = store ?? [:]
        current[token] = entry
        // 只留最近 300 条，别让缓存文件无限长
        if current.count > 300 {
            let newest = current.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(300)
            current = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        store = current
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: cacheURL)
        }
    }

    /// 1.2.3,456 → 1.2.3；3.6.7-dbc92f97 → 3.6.7；2026.3.1 原样
    private static func cleanVersion(_ raw: String) -> String? {
        var v = raw.split(separator: ",").first.map(String.init) ?? raw
        v = v.trimmingCharacters(in: .whitespaces)
        if let dash = v.firstIndex(of: "-"), v[..<dash].contains(where: { $0.isNumber }) {
            v = String(v[..<dash])
        }
        guard let first = v.first, first.isNumber else { return nil }
        return v
    }

    private static func fetch(_ token: String) async -> Cached? {
        if let hit = loadCache()[token], Date().timeIntervalSince(hit.fetchedAt) < 12 * 3600 {
            return hit
        }
        guard let obj = await Net.json("https://formulae.brew.sh/api/cask/\(token).json") as? [String: Any],
              let raw = obj["version"] as? String,
              let version = cleanVersion(raw) else { return nil }
        let entry = Cached(version: version,
                           homepage: obj["homepage"] as? String,
                           fetchedAt: Date(),
                           bundles: Array(bundleIds(in: obj)))
        saveCache(entry, token: token)
        return entry
    }

    static func lookup(_ app: InstalledApp) async -> Entry? {
        guard let hit = token(for: app), let c = await fetch(hit.token) else { return nil }
        // 只按文件名对上的，再用 cask 登记的 bundle id 复核一次：
        // 本机装的是 Telegram Desktop（com.tdesktop.Telegram），cask 里是原生版（ru.keepcoder.Telegram），名字一样但不是同一个 App
        if !hit.exact, let ids = c.bundles, !ids.isEmpty, let bid = app.bundleId, !ids.contains(bid) {
            return nil
        }
        return Entry(token: hit.token, version: c.version, homepage: c.homepage)
    }

    /// 变成检测结果；本机比库里还新时给一句解释（内测版/官网还没同步）
    /// 16.114 对 16.114.26101123：多出来的那段是构建号，不是新版本
    static func isBuildOnlyBump(_ latest: String, over current: String) -> Bool {
        let l = latest.split(separator: ".").map(String.init)
        let c = current.split(separator: ".").map(String.init)
        guard l.count > c.count, Array(l.prefix(c.count)) == c else { return false }
        return l.dropFirst(c.count).allSatisfy { $0.count >= 6 && $0.allSatisfy(\.isNumber) }
    }

    static func verdict(_ app: InstalledApp, entry: Entry, allowBeta: Bool) -> Checker.Outcome {
        // 版本库里记的是测试版时不提示（有些 cask 会跟到 beta 上）
        if !allowBeta, isPrereleaseVersion(entry.version) {
            return Checker.Outcome(status: .upToDate, latest: app.version,
                                   url: entry.homepage ?? "https://formulae.brew.sh/cask/\(entry.token)",
                                   homepage: entry.homepage,
                                   note: "只跟正式版比：版本库里现在记的是测试版（\(entry.version)）")
        }
        // 版本库里记的是构建号（Office 的 cask version 就是 16.114.26102031）：
        // 本机装的就是这个包，别报更新。
        if latestIsInstalledBuild(entry.version, current: app.version, build: app.build) {
            return Checker.Outcome(status: .upToDate, latest: entry.version,
                                   url: entry.homepage ?? "https://formulae.brew.sh/cask/\(entry.token)",
                                   homepage: entry.homepage, note: nil)
        }
        if isBuildOnlyBump(entry.version, over: app.version) {
            return Checker.Outcome(status: .upToDate, latest: entry.version, url: entry.homepage, note: nil)
        }
        let newer = Ver.isNewer(entry.version, than: app.version)
        let note: String? = (!newer && Ver.isNewer(app.version, than: entry.version))
            ? "社区版本库记录的是 \(entry.version)，你装的更新（可能是内测版）"
            : nil
        return Checker.Outcome(status: newer ? .updateAvailable : .upToDate,
                               latest: entry.version,
                               url: entry.homepage ?? "https://formulae.brew.sh/cask/\(entry.token)",
                               homepage: entry.homepage,
                               note: note)
    }
}

// MARK: - 检测器

enum Checker {
    /// - Parameter allowBeta: 用户打开了「接收测试版」时才为 true；默认只跟正式版比
    static func check(_ app: InstalledApp, allowBeta: Bool = false) async -> CheckResult {
        let bid = app.id
        let now = Date()

        func failed(_ note: String) -> CheckResult {
            CheckResult(bundleId: bid, status: .failed, latest: nil,
                        downloadURL: nil, note: note, source: "failed", checkedAt: now)
        }

        // 1. 厂商专用规则优先（微信这类没有 appcast 的常用软件）
        if let rule = Rules.match(app) {
            if let r = await rule.run(app, allowBeta) {
                return CheckResult(bundleId: bid, status: r.status, latest: r.latest,
                                   downloadURL: r.url, homepage: r.homepage ?? r.url, note: r.note,
                                   source: "vendor",
                                   checkedAt: now, releaseDate: r.releaseDate, notes: r.notes)
            }
            // 规则命中但这次没抓到：说明是网络/页面变动问题，不是“没有检测源”
            return failed("官网页面没抓到版本号")
        }

        // 2. Sparkle appcast：34 个 App 走这条路
        if let feed = app.sparkleFeed {
            if let r = await sparkle(feed: feed, current: app.version, build: app.build,
                                     allowBeta: allowBeta) {
                return CheckResult(bundleId: bid, status: r.status, latest: r.latest,
                                   downloadURL: r.url,
                                   homepage: r.homepage ?? siteFromFeed(feed),
                                   note: nil, source: "sparkle",
                                   checkedAt: now, releaseDate: r.releaseDate, notes: r.notes)
            }
            // appcast 这次没抓到：先用社区版本库兜一层，别急着报「检测失败」
            if let entry = await Cask.lookup(app) {
                return result(app, Cask.verdict(app, entry: entry, allowBeta: allowBeta), source: "cask", now: now)
            }
            return failed("更新源没有响应")
        }

        // 3. Mac App Store 上架的应用（不在商店里属于正常情况，算无检测源）
        // iTunes lookup 是分区的：国区没上架的 App 在 cn 上返回 resultCount=0，
        // 会被误判成「不在商店」。所以国区查不到时再试一次美区，只在没命中时才多发请求。
        if let bidReal = app.bundleId, app.isAppStore {
            for country in ["cn", "us"] {
                if let r = await appStore(bundleId: bidReal, current: app.version, build: app.build,
                                          installedAt: app.installedAt, country: country,
                                          allowBeta: allowBeta) {
                    return CheckResult(bundleId: bidReal, status: r.status, latest: r.latest,
                                       downloadURL: r.url, homepage: r.homepage, note: nil, source: "appstore",
                                       checkedAt: now, releaseDate: r.releaseDate, notes: r.notes)
                }
            }
        }

        // 4. Homebrew Cask：没有 appcast、不在商店、也没有厂商规则的，最后一层
        if let entry = await Cask.lookup(app) {
            return result(app, Cask.verdict(app, entry: entry, allowBeta: allowBeta), source: "cask", now: now)
        }

        return CheckResult(bundleId: bid, status: .unknown, latest: nil,
                           downloadURL: nil, note: nil, source: "manual", checkedAt: now)
    }

    /// Outcome → CheckResult（cask 这条路用，带来源标记）
    static func result(_ app: InstalledApp, _ o: Outcome, source: String, now: Date) -> CheckResult {
        CheckResult(bundleId: app.id, status: o.status, latest: o.latest,
                    downloadURL: o.url, homepage: o.homepage ?? o.url, note: o.note, source: source,
                    checkedAt: now, releaseDate: o.releaseDate, notes: o.notes)
    }


    struct Outcome {
        var status: CheckStatus
        var latest: String?
        var url: String?
        var homepage: String? = nil
        var note: String?
        var releaseDate: Date?
        var notes: String?
    }

    static func sparkle(feed: String, current: String, build: String?, allowBeta: Bool) async -> Outcome? {
        guard let body = await Net.text(feed), !body.isEmpty else { return nil }
        let items = AppcastParser().parse(Data(body.utf8))
        guard !items.isEmpty else { return nil }

        // appcast 里条目按新到旧排列，取第一条「正式版 + 本机系统能装」的。
        // 带 <sparkle:channel> 的（beta 通道）和版本号里带 Beta/RC 的一律跳过：
        // 用户只要稳定版，别拿 beta 去提示「有新版本」。
        var sawAnyVersioned = false
        var sawOnlyPrerelease = true
        for it in items {
            guard let v = it.marketingVersion else { continue }
            sawAnyVersioned = true
            let isBeta = (it.channel?.isEmpty == false) || isPrereleaseVersion(v)
            if !isBeta { sawOnlyPrerelease = false }
            // 没勾「接收测试版」时才跳过 beta 条目；勾了就按原来的行为，beta 也算新版
            if !allowBeta, isBeta { continue }
            guard systemSatisfies(it.minSystem) else { continue }
            let latest = v
            // 有的 Sparkle 源把构建号写进 title，本机装的已经是这个包 → 已是最新
            if latestIsInstalledBuild(latest, current: current, build: build) {
                return Outcome(status: .upToDate, latest: latest,
                               url: it.enclosure ?? it.link ?? feed,
                               homepage: siteFromFeed(it.link) ?? siteFromFeed(feed),
                               note: nil,
                               releaseDate: parseRFC822(it.pubDate),
                               notes: plainNotes(it.notes))
            }
            let newer = Ver.isNewer(latest, than: current)
            var notes = plainNotes(it.notes)
            if notes == nil, newer, let link = it.notesLink, let html = await Net.text(link) {
                notes = plainNotes(html)
            }
            // notes 不管是不是新版本都存下来：点开「其他」页里已是最新的 App，
            // 也该能看到它这一版更新了什么
            return Outcome(status: newer ? .updateAvailable : .upToDate,
                           latest: latest,
                           url: it.enclosure ?? it.link ?? feed,
                           homepage: siteFromFeed(it.link) ?? siteFromFeed(feed),
                           note: nil,
                           releaseDate: parseRFC822(it.pubDate),
                           notes: notes)
        }
        // 更新源里只有测试版（比如作者开了 beta 通道、正式版还没跟上）：
        // 本机装的就是最新正式版，安静地算「已是最新」，别报更新也别报失败。
        if !allowBeta, sawAnyVersioned, sawOnlyPrerelease {
            return Outcome(status: .upToDate, latest: current, url: feed, homepage: siteFromFeed(feed),
                           note: "只跟正式版比：更新源里最新的是测试版（\(items.compactMap { $0.marketingVersion }.first ?? "beta")）")
        }
        return nil
    }

    static func appStore(bundleId: String, current: String, build: String?, installedAt: Date?,
                         country: String, allowBeta: Bool) async -> Outcome? {
        let url = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(country)"
        guard let obj = await Net.json(url) as? [String: Any],
              let count = obj["resultCount"] as? Int, count > 0,
              let results = obj["results"] as? [[String: Any]],
              let first = results.first,
              let latest = first["version"] as? String else { return nil }
        let page = first["trackViewUrl"] as? String
        // sellerUrl 是开发者自己的官网（Compressor → apple.com/mac/compressor …），
        // 比商店产品页更像「软件网站」
        let seller = (first["sellerUrl"] as? String).flatMap { URL(string: $0)?.absoluteString }
        let release = parseISO8601(first["currentVersionReleaseDate"] as? String)

        // 商店接口偶尔也会给构建号（开发者把 build 填进 version 字段）
        if latestIsInstalledBuild(latest, current: current, build: build) {
            return Outcome(status: .upToDate, latest: latest, url: page, homepage: seller,
                           releaseDate: release)
        }

        // 有些开发者发版时没同步 Mac 包里的 CFBundleShortVersionString，
        // 导致「商店 1.13、包内写着 1.4」。Apple 比的是构建号，认为已最新；
        // 这里用安装时间兜底：包比商店那次发布还新，就说明拿到的就是最新包。
        if Ver.isNewer(latest, than: current), let installedAt, let release,
           installedAt > release.addingTimeInterval(60 * 60) {
            return Outcome(status: .upToDate, latest: latest, url: page, homepage: seller,
                           note: "商店版本是 \(latest)，但本机包内标注 \(current)：开发者没同步 Mac 包的版本号，App Store 也认为已是最新",
                           releaseDate: release)
        }

        if !allowBeta, isPrereleaseVersion(latest) {
            return Outcome(status: .upToDate, latest: current, url: page, homepage: seller,
                           note: "只跟正式版比：商店里最新的是测试版（\(latest)）", releaseDate: release)
        }
        let isNewer = Ver.isNewer(latest, than: current)
        // 同上：不是新版本也留着更新说明，点开能看
        return Outcome(status: isNewer ? .updateAvailable : .upToDate,
                       latest: latest, url: page, homepage: seller, note: nil,
                       releaseDate: release,
                       notes: plainNotes(first["releaseNotes"] as? String))
    }
}

// MARK: - 厂商规则

struct VendorRule {
    let matches: (InstalledApp) -> Bool
    /// 第二个参数是 allowBeta（用户勾了「接收测试版」才为 true）
    let run: (InstalledApp, Bool) async -> Checker.Outcome?
}

enum Rules {
    /// 把一个「官方最新版本号」变成检测结果；本机反而更高时给个说明
    static func verdict(_ app: InstalledApp, latest: String, url: String, releaseDate: Date? = nil,
                        allowBeta: Bool = false) -> Checker.Outcome {
        // 抓到的要是测试版（2.0.0-beta.3、1.2rc1 这种），就不算更新：只跟正式版比
        if !allowBeta, isPrereleaseVersion(latest) {
            return Checker.Outcome(status: .upToDate, latest: app.version, url: url, homepage: url,
                                   note: "只跟正式版比：更新源里最新的是测试版（\(latest)）",
                                   releaseDate: releaseDate)
        }
        // 官网页面抓到的是构建号：本机装的已是这个包
        if latestIsInstalledBuild(latest, current: app.version, build: app.build) {
            return Checker.Outcome(status: .upToDate, latest: latest, url: url, homepage: url,
                                   releaseDate: releaseDate)
        }
        let newer = Ver.isNewer(latest, than: app.version)
        // 只有「本机反而更高」时才需要解释，版本相同或更新都保持沉默
        let note: String? = (!newer && Ver.isNewer(app.version, than: latest))
            ? "官方源当前是 \(latest)，你装的版本更高（可能是内测版）"
            : nil
        return Checker.Outcome(status: newer ? .updateAvailable : .upToDate,
                               latest: latest, url: url, homepage: url,
                               note: note, releaseDate: releaseDate)
    }

    /// 官网页面里抓版本号
    static func pageRegex(app: InstalledApp, page: String, pattern: String,
                          downloadPage: String, allowBeta: Bool) async -> Checker.Outcome? {
        guard let html = await Net.text(page) else { return nil }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        let found = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var versions: [String] = []
        for m in found where m.numberOfRanges > 1 {
            versions.append(ns.substring(with: m.range(at: 1)))
        }
        guard let latest = versions.max(by: { Ver.compare($0, $1) == .orderedAscending }) else { return nil }
        return verdict(app, latest: latest, url: downloadPage, allowBeta: allowBeta)
    }

    /// GitHub Releases 最新 tag
    static func githubRepo(app: InstalledApp, repo: String, downloadPage: String,
                           allowBeta: Bool) async -> Checker.Outcome? {
        switch await Net.githubLatestRelease(repo) {
        case .failure(let err):
            if err.isRateLimited {
                // 403/429 不是「这个 App 坏了」，是配额用完了：如实说，别让用户以为软件出问题
                return Checker.Outcome(
                    status: .failed, latest: nil, url: downloadPage, homepage: downloadPage,
                    note: "GitHub 接口限流（未登录时每小时 60 次，同一网络下多台 Mac 共用配额）；过一会儿再看，或把检测频率调低")
            }
            return nil   // 404（仓库没了）和其他状态码：沿用旧行为，当作抓不到
        case .success(let obj):
            guard let obj, let tag = obj["tag_name"] as? String else { return nil }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return verdict(app, latest: latest, url: downloadPage, allowBeta: allowBeta)
        }
    }

    static let all: [VendorRule] = [
        // 微信
        VendorRule(matches: { $0.bundleId == "com.tencent.xinWeChat" }) { app, allowBeta in
            await pageRegex(app: app,
                            page: "https://mac.weixin.qq.com/",
                            pattern: #"WeChatMac_([0-9]+\.[0-9]+\.?[0-9]*)\.dmg"#,
                            downloadPage: "https://mac.weixin.qq.com/",
                            allowBeta: allowBeta)
        },
        // QQ
        VendorRule(matches: { $0.bundleId == "com.tencent.QQ" || $0.bundleId == "com.tencent.qq" }) { app, allowBeta in
            await pageRegex(app: app,
                            page: "https://im.qq.com/macqq/index.shtml",
                            pattern: #"QQ_v([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+\.dmg"#,
                            downloadPage: "https://im.qq.com/macqq/",
                            allowBeta: allowBeta)
        },
        // Obsidian
        VendorRule(matches: { $0.bundleId == "md.obsidian" }) { app, allowBeta in
            await githubRepo(app: app, repo: "obsidianmd/obsidian-releases",
                             downloadPage: "https://obsidian.md/download", allowBeta: allowBeta)
        },
        // Google Chrome：官方 versionhistory 接口在国内不通，改用 Chrome for Testing 的 stable 版本
        VendorRule(matches: { $0.bundleId == "com.google.Chrome" }) { app, allowBeta in
            guard let obj = await Net.json("https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json") as? [String: Any],
                  let channels = obj["channels"] as? [String: Any],
                  let stable = channels["Stable"] as? [String: Any],
                  let latest = stable["version"] as? String else { return nil }
            return verdict(app, latest: latest, url: "https://www.google.com/chrome/", allowBeta: allowBeta)
        },
        // WPS Office
        VendorRule(matches: { $0.bundleId == "com.kingsoft.wpsoffice.mac" }) { app, allowBeta in
            await pageRegex(app: app,
                            page: "https://www.wps.cn/product/wpsmac",
                            pattern: #"(1[0-9]\.[0-9]+\.[0-9]{4,6})"#,
                            downloadPage: "https://www.wps.cn/product/wpsmac",
                            allowBeta: allowBeta)
        },
        // Motrix
        VendorRule(matches: { $0.bundleId == "app.motrix.native" }) { app, allowBeta in
            await githubRepo(app: app, repo: "agalwood/Motrix",
                             downloadPage: "https://motrix.app/", allowBeta: allowBeta)
        },
        // Anki
        VendorRule(matches: { $0.bundleId == "net.ankiweb.anki" }) { app, allowBeta in
            await githubRepo(app: app, repo: "ankitects/anki",
                             downloadPage: "https://apps.ankiweb.net/", allowBeta: allowBeta)
        },
        // 洛雪音乐
        VendorRule(matches: { $0.bundleId == "cn.toside.music.desktop" }) { app, allowBeta in
            await githubRepo(app: app, repo: "lyswhut/lx-music-desktop",
                             downloadPage: "https://github.com/lyswhut/lx-music-desktop/releases",
                             allowBeta: allowBeta)
        },
        // UVR（Ultimate Vocal Remover）
        VendorRule(matches: { $0.id == "UVR" || $0.bundleId == "UVR" }) { app, allowBeta in
            await githubRepo(app: app, repo: "Anjok07/ultimatevocalremovergui",
                             downloadPage: "https://github.com/Anjok07/ultimatevocalremovergui/releases",
                             allowBeta: allowBeta)
        }
    ]

    static func match(_ app: InstalledApp) -> VendorRule? {
        all.first { $0.matches(app) }
    }
}
