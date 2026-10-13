import AppKit
import SwiftUI

/// 菜单头部的时钟：独立 ObservableObject，仅头部 Text 订阅，只在整分钟发布。
/// 旧实现让整个菜单观察每秒刷新的 TimeTicker，菜单打开期间 SwiftUI 每秒重建整棵菜单树、
/// AppKit 重新生成菜单项，鼠标悬停的高亮会在相邻项之间来回跳（“上下飘”），
/// 甚至每秒的标题变化本身就会让打开的菜单关闭。头部因此不显示秒、整分钟原地改一次标题。
@MainActor
final class MenuHeaderClock: ObservableObject {
    static let shared = MenuHeaderClock()
    @Published private(set) var text = ""

    private init() {
        refresh()
        let calendar = Calendar.current
        let nextMinute = calendar.nextDate(
            after: Date(),
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(60)

        let timer = Timer(
            fireAt: nextMinute,
            interval: 60,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func tick() { refresh() }

    /// 菜单每次打开时刷新一次（格式设置可能刚被改过）
    func refresh() {
        let newText = ClockFormat.headerString(from: Date(), settings: AppSettings.shared)
        guard newText != text else { return }
        text = newText
    }
}

/// 菜单栏图标点开后的菜单
struct MenuBarContent: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var header = MenuHeaderClock.shared
    @ObservedObject private var manager = ClockManager.shared

    var body: some View {
        Button(action: {}) {
            Text(header.text)
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
        }
        .disabled(true)
        .onAppear {
            header.refresh()
            // 菜单每次打开强制重取前台应用，避免应用名/全屏状态刷新不及时
            manager.refreshActiveAppForMenu()
        }

        Divider()

        Toggle(L10n.t("show-seconds"), isOn: $settings.showSeconds)
        Toggle(L10n.t("24h"), isOn: $settings.use24Hour)
        Toggle(L10n.t("show-background"), isOn: $settings.backgroundEnabled)
        Toggle(L10n.t("auto-hide"), isOn: $settings.autoHideWithClock)

        Menu(L10n.t("position")) {
            ForEach(PositionPreset.allCases) { preset in
                        Button {
                            for display in manager.displays {
                                manager.applyPosition(.preset(preset), for: display.id)
                            }
                        } label: {
                            Label(title: { Text(L10n.t(preset.rawValue)) },
                                  icon: { Image(systemName: preset.symbolName) })
                        }
                    }
        }

        Menu(L10n.t("displays")) {
            if manager.displays.isEmpty {
                Text(L10n.t("displays"))
            }
            ForEach(manager.displays) { display in
                Toggle(display.name, isOn: Binding(
                    get: { settings.isEnabled(display.id) },
                    set: { on in
                        settings.setDisplay(display.id, enabled: on,
                                            allIDs: manager.displays.map(\.id))
                    }
                ))
            }
        }

        Menu(L10n.t("window-level")) {
            ForEach(WindowLevelKind.allCases) { level in
                Button {
                    settings.windowLevel = level
                } label: {
                    Label(L10n.t("level.\(level.rawValue)"),
                          systemImage: settings.windowLevel == level ? "checkmark" : "")
                }
            }
        }

        // 按应用记忆位置总开关；开启时菜单提示当前前台应用（在该应用窗口所在屏拖时钟即自动存档）。
        // 我们自己前台时 activeAppName 保留切换前的应用名。
        Divider()
        Toggle(L10n.t("per-app-memory"), isOn: $settings.perAppPositionEnabled)
        if settings.perAppPositionEnabled, let name = manager.activeAppName {
            Text(String(format: L10n.t("per-app-hint"), name))
        }

        Divider()

        Toggle(L10n.t("dock-icon"), isOn: $settings.showDockIcon)
        Toggle(L10n.t("launch"), isOn: Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { enabled in
                do {
                    try LaunchAtLogin.set(enabled)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = L10n.t("launch-failed")
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        ))

        Divider()

        Button(L10n.t("settings")) {
            SettingsOpener.open()
        }
        Button(L10n.t("quit")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
