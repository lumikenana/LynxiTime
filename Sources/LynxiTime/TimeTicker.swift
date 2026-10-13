import Foundation

/// 单一秒级时钟源，对齐整秒触发，所有屏幕共享
@MainActor
final class TimeTicker: ObservableObject {
    static let shared = TimeTicker()

    @Published private(set) var now = Date()

    private init() {
        let calendar = Calendar.current
        let nextSecond = calendar.nextDate(
            after: Date(),
            matching: DateComponents(nanosecond: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(1)

        let timer = Timer(
            fireAt: nextSecond,
            interval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        // common mode：菜单追踪时也照常走秒
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func tick() {
        now = Date()
    }
}
