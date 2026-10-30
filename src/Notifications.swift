import Combine
import Foundation
import UserNotifications

/// 系统通知：发现新版本时弹一条横幅，点它就把面板展开。
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var granted = false
    private var asked = false
    var onOpen: (() -> Void)?

    /// 系统里真实的授权状态。设置页要显示它，否则开关和实际行为会脱节
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    var isAuthorized: Bool { granted }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        refreshAuthorization()
        guard !asked else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in
                Notifier.shared.granted = ok
                Notifier.shared.refreshAuthorization()
            }
        }
    }

    /// 用户可能在系统设置里随时改权限，查一下当前真实状态
    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                Notifier.shared.authorization = settings.authorizationStatus
                Notifier.shared.granted = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
        }
    }

    func post(title: String, body: String, id: String) {
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// App 在前台时也把横幅显示出来（默认会被吞掉）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            Notifier.shared.onOpen?()
        }
        completionHandler()
    }
}
