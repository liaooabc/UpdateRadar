import Foundation

// 构建号判定的回归测试（不依赖 XCTest：这台机器只有 CLT，跑 SPM 测试反而更折腾）。
//
//   DEVELOPER_DIR=/Library/Developer/CommandLineTools \
//     swiftc -O src/Version.swift tools/test_version.swift -o /tmp/ur_ver_test && /tmp/ur_ver_test
//
// 加 --state：用本机真实 state.json + 已装 App 复算，看有多少条「更新」其实是构建号。

@main
struct VersionTests {
    static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "  ✓ " : "  ✗ ") + name)
        if !ok { failures += 1 }
    }

    static func expect(_ latest: String, _ current: String, build: String?,
                       _ want: Bool, _ name: String) {
        let got = latestIsInstalledBuild(latest, current: current, build: build)
        check(got == want,
              "\(name)：本机 \(current)（build \(build ?? "无")） vs 源里 \(latest) → \(want ? "已最新" : "真更新")，实得 \(got)")
    }

    static func expectCompare(_ a: String, _ b: String, _ want: ComparisonResult, _ name: String) {
        let got = Ver.compare(a, b)
        let sym: (ComparisonResult) -> String = { r in
            r == .orderedAscending ? "<" : r == .orderedDescending ? ">" : "="
        }
        check(got == want, "\(name)：\(a) \(sym(want)) \(b)，实得 \(got)")
    }

    /// bundleId → 本机装的 (营销版本号, 构建号, 名字)
    static func installedMap() -> [String: (version: String, build: String, name: String)] {
        var out: [String: (String, String, String)] = [:]
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                // 和 Scanner 一样只下钻两层：/Applications/X.app、/Applications/Adobe X/Y.app
                let rel = url.path.replacingOccurrences(of: root + "/", with: "")
                if rel.components(separatedBy: "/").count > 2 {
                    e.skipDescendants()
                    continue
                }
                guard url.pathExtension == "app" else { continue }
                e.skipDescendants()
                guard let d = NSDictionary(contentsOfFile: url.path + "/Contents/Info.plist") as? [String: Any],
                      let bid = d["CFBundleIdentifier"] as? String, out[bid] == nil else { continue }
                let v = (d["CFBundleShortVersionString"] as? String) ?? (d["CFBundleVersion"] as? String) ?? "0"
                let b = (d["CFBundleVersion"] as? String) ?? ""
                let n = (d["CFBundleDisplayName"] as? String)
                    ?? (d["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                out[bid] = (v, b, n)
            }
        }
        return out
    }

    static func stateReport() {
        let path = NSHomeDirectory() + "/Library/Application Support/UpdateRadar/state.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [String: [String: Any]] else {
            print("\n读不到 state.json，跳过真实数据复算")
            return
        }
        let apps = installedMap()
        var updates = 0
        var fixed: [(name: String, current: String, build: String, latest: String)] = []
        for (bid, r) in results where (r["status"] as? String) == "updateAvailable" {
            updates += 1
            guard let latest = r["latest"] as? String, let a = apps[bid] else { continue }
            if latestIsInstalledBuild(latest, current: a.version, build: a.build) {
                fixed.append((a.name, a.version, a.build, latest))
            }
        }
        print("\n真实数据复算：\(results.count) 个 App 有结果，\(updates) 条「有更新」，其中 \(fixed.count) 条其实是构建号")
        for f in fixed.sorted(by: { $0.name < $1.name }) {
            print("  · \(f.name)：\(f.current)（build \(f.build)） ← 源里 \(f.latest)")
        }
    }

    static func main() {
        print("构建号判定")
        // 这台机器上 Office 的真实数据
        expect("16.114.26102031", "16.114.1", build: "16.114.26102031", true,  "Office：cask 记的就是本机构建号")
        expect("16.114.26101123", "16.114.1", build: "16.114.26102031", true,  "Office：cask 比本机还旧（Outlook）")
        expect("16.115.26110101", "16.114.1", build: "16.114.26102031", false, "Office：真的出了 16.115")
        expect("16.114",          "16.114.1", build: "16.114.26102031", true,  "源里只写到营销版本号 16.114")
        // 常见 App：版本号和构建号是同一套数字，不能把正常补丁版吃掉
        expect("1.14.4", "1.14.4", build: "1.14.4", true,  "Obsidian：同版本")
        expect("1.14.5", "1.14.4", build: "1.14.4", false, "Obsidian：1.14.4 → 1.14.5 必须提示")
        expect("4.1.16", "4.1.15", build: "270115", false, "微信：构建号与营销版本号无关，照常提示")
        // 没有构建号 / 空构建号时行为不变
        expect("1.0.1", "1.0.0", build: nil, false, "没有构建号")
        expect("1.0.1", "1.0.0", build: "",  false, "构建号为空")
        // 构建号是日期、但版本号是另一套编号
        expect("5.2.1", "5.2.0", build: "26010101", false, "构建号是日期编号，与 5.2.x 无关")
        // 长构建后缀但确实更新
        expect("1.0.0.26020101", "1.0.0", build: "1.0.0.25010101", false, "构建号后缀确实是新的")

        print("\n版本比较（回归）")
        expectCompare("1.10", "1.9", .orderedDescending, "1.10 > 1.9")
        expectCompare("1.5.0", "1.5.1", .orderedAscending, "1.5.0 < 1.5.1")
        expectCompare("4.1.15", "4.1.15", .orderedSame, "4.1.15 = 4.1.15")
        expectCompare("v1.2.0", "1.2", .orderedSame, "v1.2.0 = 1.2")
        expectCompare("2026.39", "2026.9", .orderedDescending, "2026.39 > 2026.9")

        if CommandLine.arguments.contains("--state") { stateReport() }

        print("")
        print(failures == 0 ? "全部通过" : "\(failures) 条失败")
        exit(failures == 0 ? 0 : 1)
    }
}
