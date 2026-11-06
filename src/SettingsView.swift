import AppKit
import SwiftUI

/// 面板里的设置页：点齿轮后整个面板翻到这一页，不再单独开一个设置窗口。
/// 排版照系统「设置」的观感：小号分组标题 + 一张玻璃卡片包住若干行，
/// 每行左边一枚小图标 + 标题，右边一个原生控件（开关 / 菜单 / 数值）。
/// 卡片用系统的 `glassEffect`，所以「降低透明度 / 增强对比度」照样作用到它身上。
struct PanelSettingsView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    /// 分组标题不在玻璃卡片里，纯靠 vibrancy 拿色会在弹层里偏淡；按明暗模式给个固定色
    @Environment(\.colorScheme) private var colorScheme

    private var headerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.55)
    }

    // MARK: - 绑定（直接落到 UpdateService 的 setter 上，改完立刻存盘）

    private var interval: Binding<Double> {
        Binding(get: { service.settings.intervalHours }, set: { service.setInterval($0) })
    }
    private var receiveBeta: Binding<Bool> {
        Binding(get: { service.settings.receiveBetaEnabled }, set: { service.setReceiveBeta($0) })
    }
    private var showCount: Binding<Bool> {
        Binding(get: { service.settings.countVisible }, set: { service.setShowCount($0) })
    }
    private var hideUnknown: Binding<Bool> {
        Binding(get: { service.settings.hideUnknownEnabled }, set: { service.setHideUnknown($0) })
    }
    private var hideFailed: Binding<Bool> {
        Binding(get: { service.settings.hideFailedEnabled }, set: { service.setHideFailed($0) })
    }
    private var notifyOnUpdates: Binding<Bool> {
        Binding(get: { service.settings.notifyEnabled }, set: { service.setNotify($0) })
    }
    /// 登录项：状态归系统（SMAppService）管，不落到 state.json，所以每次打开这一页都重读一次
    private var openAtLogin: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
    }

    // MARK: - 文案

    private var ignoredCount: Int { service.settings.ignored.count }

    private var notificationStatusText: String {
        switch notifier.authorization {
        case .authorized: return "已允许"
        case .provisional: return "已允许（安静提醒）"
        case .denied: return "已在系统设置中关闭"
        case .notDetermined: return "尚未询问"
        @unknown default: return "状态未知"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("检测") {
                SettingRow(symbol: "timer", title: "扫描间隔") {
                    Picker("", selection: interval) {
                        Text("每小时").tag(1.0)
                        Text("每 6 小时").tag(6.0)
                        Text("每 12 小时").tag(12.0)
                        Text("每天").tag(24.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 104)
                }
                SettingRow(symbol: "testtube.2", title: "接收测试版") {
                    Toggle("", isOn: receiveBeta).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            section("显示") {
                SettingRow(symbol: "power", title: "登录时打开") {
                    Toggle("", isOn: openAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                if launchAtLogin.requiresApproval || launchAtLogin.lastError != nil {
                    Text(launchAtLogin.lastError
                         ?? "已加入登录项，但还要去「系统设置 → 通用 → 登录项」里允许一次。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(launchAtLogin.lastError == nil ? Color.orange : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                SettingRow(symbol: "menubar.rectangle", title: "菜单栏显示数量") {
                    Toggle("", isOn: showCount).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                SettingRow(symbol: "questionmark.circle", title: "隐藏无检测源的 App") {
                    Toggle("", isOn: hideUnknown).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                SettingRow(symbol: "exclamationmark.triangle", title: "隐藏检测失败的 App") {
                    Toggle("", isOn: hideFailed).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            section("通知") {
                SettingRow(symbol: "bell", title: "有新版本时通知我") {
                    Toggle("", isOn: notifyOnUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(notifier.authorization == .denied)
                }
                SettingRow(symbol: "bell.badge", title: "系统通知") {
                    HStack(spacing: 8) {
                        Text(notificationStatusText)
                            .font(.system(size: 12, weight: .medium))
                        Button("打开设置…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            section("数据") {
                SettingRow(symbol: "eye.slash", title: "已忽略的 App") {
                    HStack(spacing: 8) {
                        Text("\(ignoredCount) 个")
                            .font(.system(size: 12, weight: .medium))
                        ConfirmingButton(
                            title: "恢复",
                            dialogTitle: "恢复 \(ignoredCount) 个 App 的更新提醒？",
                            confirmTitle: "恢复提醒",
                            message: "这些 App 一旦有新版本，会重新出现在「可更新」里。",
                            isEnabled: ignoredCount > 0
                        ) {
                            service.unignoreAll()
                        }
                        .controlSize(.small)
                    }
                }
            }

            // 「更新雷达」分组（当前版本 + 检查更新 / 安装）已搬到关于页，这里不再重复
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        // 用户可能刚在系统设置里改过通知权限 / 登录项，这一页一露脸就按系统真实状态重画
        .onAppear {
            notifier.refreshAuthorization()
            launchAtLogin.refresh()
        }
    }

    /// 一组设置：小号标题 + 一张系统玻璃卡片，行与行之间一条细分隔线
    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(headerColor)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .modifier(SettingsCard())
        }
    }
}

/// 一行设置：图标 + 标题（可带副标题） + 右侧控件。
/// 图标一律中性色、跟标题文字同色系，不再用「打开就染蓝」的强调色——否则一页里花花绿绿。
private struct SettingRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.colorScheme) private var colorScheme

    private var iconColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.7)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            trailing()
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, 29)
        }
    }
}

/// 设置卡片的底：一层很薄的系统玻璃 + 圆角。关于页也复用这一层，保证两页观感一致
struct SettingsCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// 带确认的按钮：批量、会打断手上的工作这类操作，先弹一句系统确认。
/// 「问过没」存在一个小 ObservableObject 里，而不是 @State：
/// 本机是 Command Line Tools，shim 里没有 SwiftUI 的宏插件，@State 编不过。
/// 关于页也复用它（安装更新），所以不设 private。
final class ConfirmState: ObservableObject {
    @Published var asking = false
}

struct ConfirmingButton: View {
    let title: String
    let dialogTitle: String
    let confirmTitle: String
    let message: String
    var isEnabled = true
    let action: () -> Void

    @ObservedObject private var state = ConfirmState()

    var body: some View {
        Button(title) { state.asking = true }
            .disabled(!isEnabled)
            .confirmationDialog(dialogTitle, isPresented: $state.asking, titleVisibility: .visible) {
                Button(confirmTitle) { action() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(message)
            }
    }
}
