import Combine
import Foundation
import SwiftUI

/// 单块屏幕时钟的生效外观：解析「全局默认 vs 该屏独立外观」，并随设置变化自动刷新。
/// ClockView 只观察本对象，不直接读 AppSettings。
@MainActor
final class DisplayTheme: ObservableObject {
    private(set) var displayID: Int
    @Published private(set) var style: ClockAppearance

    private var cancellables = Set<AnyCancellable>()

    /// 生效外观发生变化（已防抖）：ClockManager 据此重新测量/布局。
    /// 必须从解析后的 style 驱动，而不能让管理器直接订阅 AppSettings——
    /// style 经 receive(on:) 在下一个 RunLoop 才更新，管理器若提前测量会读到旧尺寸，
    /// 且这次触发机会被消耗掉，窗口尺寸变化后不再围绕锚点重排（会溢出屏幕边缘）。
    var onStyleChange: (() -> Void)?

    init(displayID: Int) {
        self.displayID = displayID
        let settings = AppSettings.shared
        style = settings.appearance(for: displayID)

        let s = settings
        // 任意外观来源变化都重新解析；receive(on:) 避开 @Published willSet 读到旧值
        let triggers: [AnyPublisher<Void, Never>] = [
            s.$showSeconds.map { _ in () }.eraseToAnyPublisher(),
            s.$use24Hour.map { _ in () }.eraseToAnyPublisher(),
            s.$showDate.map { _ in () }.eraseToAnyPublisher(),
            s.$showWeekday.map { _ in () }.eraseToAnyPublisher(),
            s.$customFormatEnabled.map { _ in () }.eraseToAnyPublisher(),
            s.$customFormat.map { _ in () }.eraseToAnyPublisher(),
            s.$fontChoice.map { _ in () }.eraseToAnyPublisher(),
            s.$customFontName.map { _ in () }.eraseToAnyPublisher(),
            s.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            s.$textOpacity.map { _ in () }.eraseToAnyPublisher(),
            s.$textColor.map { _ in () }.eraseToAnyPublisher(),
            s.$backgroundEnabled.map { _ in () }.eraseToAnyPublisher(),
            s.$backgroundColor.map { _ in () }.eraseToAnyPublisher(),
            s.$backgroundOpacity.map { _ in () }.eraseToAnyPublisher(),
            s.$backgroundRadius.map { _ in () }.eraseToAnyPublisher(),
            s.$independentDisplays.map { _ in () }.eraseToAnyPublisher(),
            s.$appearancesByDisplay.map { _ in () }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .map { [weak self] _ in
                guard let self else { return ClockAppearance.global(from: settings) }
                return settings.appearance(for: self.displayID)
            }
            .removeDuplicates()
            .assign(to: &$style)

        // 解析后的外观真正变化后再通知布局；120ms 防抖合并滑块连发/逐字输入
        $style
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.onStyleChange?()
            }
            .store(in: &cancellables)
    }

    /// 跨屏拖拽迁移后改挂到新屏幕 id，并立即按新屏幕解析
    func reassign(displayID newID: Int) {
        displayID = newID
        style = AppSettings.shared.appearance(for: newID)
    }
}
