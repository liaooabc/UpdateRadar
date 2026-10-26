import AppKit
import Combine
import Foundation

/// 「更新雷达」自己的更新。别人的 App 更新靠检测源，它自己的更新靠 GitHub Release：
/// 仓库的 latest release 就是唯一可信来源，tag 是版本号，assets 里是 DMG。
///
/// 装新版的做法（Sparkle 那套的精简版）：下载 DMG → 挂载 → 校验包 → ditto 到暂存区 →
/// 交给一个小 shell 脚本，等本进程退出后「备份旧包 → 放新包 → 重新打开」，失败就回滚。
/// 不自己覆盖正在运行的包：那样最容易留下一个半新半旧、一开就崩的 App。
@MainActor
final class SelfUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(version: String, downloadURL: String, pageURL: String, hasDMG: Bool)
        case downloading(version: String, progress: Double)
        case installing(version: String)
        case failed(String)
    }

    static let repo = "liaooabc/UpdateRadar"

    @Published private(set) var phase: Phase = .idle
    private var lastChecked: Date?

    var currentVersion: String {
        // 调试用：UPDATERADAR_FAKE_VERSION=1.0.9 假装本机是旧版，看「有新版本」那一行长什么样
        if let fake = ProcessInfo.processInfo.environment["UPDATERADAR_FAKE_VERSION"] { return fake }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var isChecking: Bool { phase == .checking }
    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    /// 启动时、以及每 24 小时一次：距上次检查不到一天就不打扰
    func checkIfStale() {
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 3600 {
            // 调试用：UPDATERADAR_AUTO_INSTALL=1 查到新版本就自己走一遍下载+安装（验证整条链路）
            maybeAutoInstall()
            return
        }
        check()
    }

    func check() {
        guard !isChecking, !isBusy else { return }
        phase = .checking
        Task { [weak self] in
            let result = await Net.githubLatestRelease(Self.repo)
            guard let self else { return }
            self.lastChecked = Date()

            switch result {
            case .failure(let err):
                self.phase = .failed(err.isRateLimited ? "GitHub 接口被限流，稍后再试" : "检查失败（HTTP \(err.status)）")
            case .success(let object):
                guard let object, let tag = object["tag_name"] as? String else {
                    self.phase = .failed("检查失败（拿不到发布信息）")
                    return
                }
                let latest = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
                let page = object["html_url"] as? String ?? "https://github.com/\(Self.repo)/releases/latest"
                let assets = object["assets"] as? [[String: Any]] ?? []
                let dmg = assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg") }

                if Ver.isNewer(latest, than: self.currentVersion) {
                    self.phase = .available(version: latest,
                                            downloadURL: (dmg?["browser_download_url"] as? String) ?? page,
                                            pageURL: page,
                                            hasDMG: dmg != nil)
                    Debug.autoInstallIfRequested(self)
                } else {
                    self.phase = .upToDate(latest)
                }
            }
        }
    }

    private func maybeAutoInstall() {
        if case let .available(version, url, _, hasDMG) = phase, hasDMG {
            install(version: version, downloadURL: url)
        }
    }

    private enum Debug {
        static func autoInstallIfRequested(_ updater: SelfUpdater) {
            guard ProcessInfo.processInfo.environment["UPDATERADAR_AUTO_INSTALL"] != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak updater] in
                updater?.maybeAutoInstall()
            }
        }
    }

    // MARK: - 安装

    /// 用户点「更新并重启」：下载 → 挂载校验 → 暂存 → 交给脚本替换 → 退出
    func install(version: String, downloadURL: String) {
        guard !isBusy else { return }
        phase = .downloading(version: version, progress: 0)

        Task { [weak self] in
            guard let self else { return }
            do {
                let dmg = try await Self.download(downloadURL) { ratio in
                    Task { @MainActor in
                        if case let .downloading(v, _) = self.phase {
                            self.phase = .downloading(version: v, progress: ratio)
                        }
                    }
                }
                self.phase = .installing(version: version)
                try self.stageAndHandOff(dmg: dmg, expectedVersion: version)
                // 脚本在等本进程退出，给它一点时间接手再退
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                self.phase = .failed(message)
                Self.reportFailure(message)
            }
        }
    }

    /// 校验包 → 拷到暂存区 → 写替换脚本 → 起脚本（脚本会先等我们退出）
    private func stageAndHandOff(dmg: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        let runningApp = URL(fileURLWithPath: Bundle.main.bundlePath)

        // Gatekeeper 的「随机路径」运行（AppTranslocation）替换不了，直接说清楚
        if runningApp.path.contains("AppTranslocation") {
            throw UpdateError("这个 App 是从 DMG 里直接运行的，没法自动替换。请先把它拖进「应用程序」再试。")
        }
        // 目标目录不可写就别等到退出后才发现（那时候 App 已经没了）
        let targetDir = runningApp.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: targetDir.path) else {
            throw UpdateError("没有权限写入 \(targetDir.path)。请把 App 拖进「应用程序」文件夹，或手动下载安装。")
        }

        let mount = fm.temporaryDirectory.appendingPathComponent("urmount-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                          "-mountpoint", mount.path, dmg.path])
        let items = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("下载的 DMG 里没有找到 App，可能下载到了错误的文件。")
        }
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("下载的 App 不是更新雷达（bundle id 对不上），已中止。")
        }
        let gotVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard Ver.compare(gotVersion, expectedVersion) != .orderedAscending else {
            throw UpdateError("下载到的是 \(gotVersion)，不是 \(expectedVersion)，已中止。")
        }

        // 暂存（拷出来，DMG 就可以卸了）
        let stagingDir = URSupportDir.appendingPathComponent("Update", isDirectory: true)
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staging = stagingDir.appendingPathComponent("更新雷达.app")
        try Self.run("/usr/bin/ditto", [newApp.path, staging.path])
        try? fm.removeItem(at: dmg)

        // 替换脚本：等本进程退出 → 备份 → 放新包 → 重新打开；任何一步失败都回滚并重新打开旧的
        let backup = stagingDir.appendingPathComponent("旧版备份.app")
        let script = fm.temporaryDirectory.appendingPathComponent("ur-update-\(UUID().uuidString.prefix(8)).sh")
        let body = """
        #!/bin/bash
        # 更新雷达自动替换脚本（App 退出后执行）
        APP="$1"; NEW="$2"; BACKUP="$3"; PID="$4"
        n=0
        while /bin/kill -0 "$PID" 2>/dev/null; do
          /bin/sleep 0.2
          n=$((n+1)); [ "$n" -gt 150 ] && break
        done
        /bin/sleep 0.6
        /bin/rm -rf "$BACKUP"
        if ! /bin/mv "$APP" "$BACKUP"; then
          /usr/bin/open "$APP" 2>/dev/null
          exit 1
        fi
        if /usr/bin/ditto "$NEW" "$APP"; then
          /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
          /usr/bin/open "$APP"
          /bin/rm -rf "$BACKUP" "$NEW"
        else
          /bin/rm -rf "$APP"
          /bin/mv "$BACKUP" "$APP"
          /usr/bin/open "$APP"
          exit 2
        fi
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, runningApp.path, staging.path, backup.path, String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
    }

    // MARK: - 下载

    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Error>?
        private var target: URL?
        private var onProgress: ((Double) -> Void)?
        private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

        func fetch(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
            self.onProgress = onProgress
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // 这个方法返回后临时文件就没了，必须当场搬走
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("更新雷达-\(UUID().uuidString.prefix(8)).dmg")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                continuation?.resume(returning: dest)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, continuation != nil else { return }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private static func download(_ urlString: String, onProgress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = URL(string: urlString) else { throw UpdateError("下载地址不正确") }
        let downloader = Downloader()
        let file = try await downloader.fetch(url, onProgress: onProgress)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 1024 * 100 else { throw UpdateError("下载下来的文件太小，可能不是安装包") }
        return file
    }

    // MARK: - 小工具

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    fileprivate static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) 出错（\(process.terminationStatus)）：\(text)")
        }
    }

    /// 失败一律用系统警告框说清楚原因（这几步都可能被权限、磁盘、网络挡下）
    private static func reportFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "更新没有装成功"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
