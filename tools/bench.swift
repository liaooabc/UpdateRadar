import Foundation

// 只看「查」这一段：扫描出的 App 全部跑一遍 Checker.check，
// 分别用旧的「6 个一批、整批等完」和新的「12 路滑动窗口」，量耗时。

func runBatch(_ apps: [InstalledApp], size: Int = 6) async -> Int {
    let start = Date()
    var i = 0
    while i < apps.count {
        let end = min(i + size, apps.count)
        let slice = Array(apps[i..<end])
        await withTaskGroup(of: CheckResult.self) { group in
            for a in slice { group.addTask { await Checker.check(a) } }
            for await _ in group {}
        }
        i = end
    }
    return Int(Date().timeIntervalSince(start) * 1000)
}

func runSliding(_ apps: [InstalledApp], limit: Int = 12) async -> Int {
    let start = Date()
    await withTaskGroup(of: CheckResult.self) { group in
        var next = apps.makeIterator()
        var inFlight = 0
        while inFlight < limit, let a = next.next() {
            group.addTask { await Checker.check(a) }
            inFlight += 1
        }
        while let _ = await group.next() {
            inFlight -= 1
            if let a = next.next() {
                group.addTask { await Checker.check(a) }
                inFlight += 1
            }
        }
    }
    return Int(Date().timeIntervalSince(start) * 1000)
}

@main
struct Bench {
    static func main() async {
        let apps = Scanner.scan().filter { !$0.isBeta }
        print("本机 App：\(apps.count) 个")
        let rounds = 2
        for r in 1...rounds {
            let a = await runBatch(apps)
            print("第 \(r) 轮  旧（6 个一批）: \(a) ms")
            let b = await runSliding(apps)
            print("第 \(r) 轮  新（12 路滑动）: \(b) ms")
        }
    }
}
