import AppKit
import Foundation

enum Scanner {
    static let selfBundleId = "com.hushixiong.updateradar"

    static func scan() -> [InstalledApp] {
        var roots = ["/Applications"]
        let home = NSHomeDirectory()
        roots.append(home + "/Applications")

        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in roots {
            guard let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var depthGuard = 0
            for case let url as URL in e {
                depthGuard += 1
                if depthGuard > 4000 { break }
                // 只下钻两层：/Applications/X.app 与 /Applications/Adobe X/Y.app
                let rel = url.path.replacingOccurrences(of: root + "/", with: "")
                if rel.components(separatedBy: "/").count > 2 {
                    e.skipDescendants()
                    continue
                }
                guard url.pathExtension == "app" else { continue }
                e.skipDescendants()

                guard let app = readApp(at: url.path) else { continue }
                if seen.contains(app.id) { continue }
                seen.insert(app.id)
                apps.append(app)
            }
        }

        return apps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func readApp(at path: String) -> InstalledApp? {
        let infoPath = path + "/Contents/Info.plist"
        guard FileManager.default.fileExists(atPath: infoPath),
              let dict = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else { return nil }

        let bundleId = dict["CFBundleIdentifier"] as? String
        if bundleId == selfBundleId { return nil }

        var name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
            ?? "0"
        // 构建号单独留着：Office 这类更新源记的是 build（16.114.26102031），
        // 营销版本号是 16.114.1，只比前者必然误报「有新版本」。
        let build = (dict["CFBundleVersion"] as? String) ?? ""

        var feed = dict["SUFeedURL"] as? String
        if let f = feed {
            let low = f.lowercased()
            if low.contains("0.0.0.0") || low.contains("localhost") || low.contains("127.0.0.1") {
                feed = nil
            }
        }

        let isMAS = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let installedAt = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)

        let isBeta = version.lowercased().contains("beta")
            || version.lowercased().contains("-rc")
            || name.lowercased().contains("beta")

        return InstalledApp(
            id: bundleId ?? path,
            name: name,
            path: path,
            bundleId: bundleId,
            version: version,
            build: build,
            sparkleFeed: feed,
            isAppStore: isMAS,
            isBeta: isBeta,
            installedAt: installedAt
        )
    }
}
