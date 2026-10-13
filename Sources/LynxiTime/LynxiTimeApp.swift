import AppKit
import Combine
import SwiftUI

@main
struct LynxiTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("LynxiTime", systemImage: "clock.fill") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .frame(width: 520, height: 460)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)

        // receive(on:)：@Published 在 willSet 阶段发送，否则应用的会是上一次的旧值
        settings.$showDockIcon
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { show in
                NSApp.setActivationPolicy(show ? .regular : .accessory)
            }
            .store(in: &cancellables)

        // 初始化面板管理器并立刻对账建表
        _ = ClockManager.shared
    }

    private var cancellables = Set<AnyCancellable>()
}
