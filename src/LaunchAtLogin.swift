import Combine
import Foundation
import ServiceManagement

/// 登录时打开：用系统的 SMAppService，状态以系统为准，不另存一份到 state.json。
/// 要求 App 已经在「应用程序」里；从 DMG 直接跑（AppTranslocation）时注册会失败。
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// 开关的位置：已启用，或者「已注册、但系统还要用户去登录项里允许一次」都算打开——
    /// 后者如果显示成关，用户看到开关自己弹回去，会以为坏了。
    @Published private(set) var isEnabled = false
    /// 已注册但系统要求用户去「系统设置 → 通用 → 登录项」里允许一次，此时还没真正生效
    @Published private(set) var requiresApproval = false
    /// 最近一次开关失败的原因；成功后清掉
    @Published private(set) var lastError: String?

    private init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled || status == .requiresApproval)
        requiresApproval = (status == .requiresApproval)
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled {
                    lastError = nil
                    refresh()
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                // notFound：系统里本来就没有这一项，别再调 unregister 换一个错出来
                let status = SMAppService.mainApp.status
                if status == .notRegistered || status == .notFound {
                    lastError = nil
                    refresh()
                    return
                }
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = friendlyMessage(for: error, turningOn: on)
        }
        refresh()
    }

    private func friendlyMessage(for error: Error, turningOn: Bool) -> String {
        let raw = error.localizedDescription
        let path = Bundle.main.bundlePath
        if path.contains("AppTranslocation") {
            return "请先把「更新雷达」拖进「应用程序」文件夹，再打开这个开关。"
        }
        if turningOn, !path.hasPrefix("/Applications/") {
            return "请先把「更新雷达」放到「应用程序」文件夹（现在在 \(path)）。"
        }
        return raw.isEmpty ? "无法更改登录项，请到「系统设置 → 通用 → 登录项」里手动处理。" : raw
    }
}
