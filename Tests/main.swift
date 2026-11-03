import Foundation

// 轻量断言：失败退出码非零，方便接进 build.sh 或 CI。
var failures = 0

func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS  \(name)") } else { print("FAIL  \(name)"); failures += 1 }
}

func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ name: String) {
    let ok = actual.map { $0 == expected } ?? false
    if ok {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)（期望 \(expected)，实际 \(actual.map { "\($0)" } ?? "nil")）")
        failures += 1
    }
}

// MARK: - cleanVersion：cask 版本号清洗
// 回归点：4.0.0-beta.1 不能被截成 4.0.0（否则 beta 被当成正式更新推出去）。

expectEqual(Cask.cleanVersion("1.2.3,456"), "1.2.3", "cleanVersion 逗号后缀截断")
expectEqual(Cask.cleanVersion("3.6.7-dbc92f97"), "3.6.7", "cleanVersion commit 后缀截断")
expectEqual(Cask.cleanVersion("4.0.0-beta.1"), "4.0.0-beta.1", "cleanVersion 保留 beta 后缀")
expectEqual(Cask.cleanVersion("2026.3.1"), "2026.3.1", "cleanVersion 普通版本原样")
expectEqual(Cask.cleanVersion(" 2.1.0 "), "2.1.0", "cleanVersion 去首尾空格")
expect(Cask.cleanVersion("v1.2") == nil, "cleanVersion 非数字开头拒绝")

// MARK: - isPrereleaseVersion

expect(isPrereleaseVersion("4.0.0-beta.1"), "beta.1 判为测试版")
expect(isPrereleaseVersion("1.2.3rc1"), "rc1 连写判为测试版")
expect(!isPrereleaseVersion("4.0.0"), "正式版不误判")
expect(!isPrereleaseVersion("2026.3.1"), "日期版本不误判")

// MARK: - Scanner.hasAppStoreReceipt：假收据识别
// 回归点：第三方直装版塞的 20 字节「收据」只有一行安装站网址，
// 不能当成商店包（否则被钉死在 iTunes 查询上，无检测源）。

private func makeApp(withReceipt data: Data?) -> String {
    let root = NSTemporaryDirectory()
        + "ur-receipt-\(UUID().uuidString)/Fake.app/Contents/_MASReceipt"
    try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    if let data {
        try! data.write(to: URL(fileURLWithPath: root + "/receipt"))
    }
    let contents = (root as NSString).deletingLastPathComponent
    return (contents as NSString).deletingLastPathComponent
}

let noReceipt = makeApp(withReceipt: nil)
expect(!Scanner.hasAppStoreReceipt(at: noReceipt), "没有收据：不算商店包")

let emptyReceipt = makeApp(withReceipt: Data())
expect(Scanner.hasAppStoreReceipt(at: emptyReceipt), "0 字节收据：仍按商店包算")

let fakeReceipt = makeApp(withReceipt: "https://macked.app/".data(using: .utf8))
expect(!Scanner.hasAppStoreReceipt(at: fakeReceipt), "20 字节网址收据：伪造，不算商店包")

let bigReceipt = makeApp(withReceipt: Data(count: 2048))
expect(Scanner.hasAppStoreReceipt(at: bigReceipt), "2KB 收据：算商店包")

let smallAppleReceipt = makeApp(withReceipt: Data(repeating: 0x20, count: 300)
    + "Apple Inc.".data(using: .utf8)!)
expect(Scanner.hasAppStoreReceipt(at: smallAppleReceipt), "小但带 Apple 签发串：算商店包")

// MARK: - Cask.bundleIds：从 uninstall 段提取 bundle id
// 回归点：.plist / .app 结尾的字符串不能混进来（trae-cn 的映射就是这么缺的）。

let traeObj: [String: Any] = [
    "artifacts": [
        ["uninstall": ["quit": ["cn.trae.app", "cn.trae.ShipIt"],
                       "delete": ["/Applications/Trae CN.app", "~/Library/Preferences/cn.trae.app.plist"]]]
    ]
]
let traeIds = Cask.bundleIds(in: traeObj)
expect(traeIds.contains("cn.trae.app"), "bundleIds 提取裸 id")
expect(traeIds.contains("cn.trae.shipit") || traeIds.contains("cn.trae.ShipIt"), "bundleIds 提取 ShipIt")
expect(!traeIds.contains("cn.trae.app.plist"), "bundleIds 过滤 .plist")
expect(!traeIds.contains("/applications/trae"), "bundleIds 不收路径")

let zapOnly: [String: Any] = ["artifacts": [["zap": ["trash": ["~/Library/x.y.z"]]]]]
expect(Cask.bundleIds(in: zapOnly).isEmpty, "zap/trash 段不参与提取")

// MARK: -

if failures > 0 {
    print("\n\(failures) 个用例失败")
    exit(1)
}
print("\n全部通过")
