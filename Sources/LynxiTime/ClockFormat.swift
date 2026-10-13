import Foundation

/// 时间格式所需的只读设置（全局 AppSettings 与单屏 ClockAppearance 都可提供）
@MainActor
protocol ClockFormatProviding {
    var showSeconds: Bool { get }
    var use24Hour: Bool { get }
    var showDate: Bool { get }
    var showWeekday: Bool { get }
    var customFormatEnabled: Bool { get }
    var customFormat: String { get }
}

extension ClockAppearance: ClockFormatProviding {}

/// 内置格式预设（pattern 直接交给 DateFormatter，输出仍随系统语言本地化 AM/PM、月份等）
struct FormatPreset: Identifiable, Equatable {
    let pattern: String
    var id: String { pattern }

    static let all: [FormatPreset] = [
        FormatPreset(pattern: "HH:mm:ss"),
        FormatPreset(pattern: "HH:mm"),
        FormatPreset(pattern: "h:mm:ss a"),
        FormatPreset(pattern: "h:mm a"),
        FormatPreset(pattern: "MMM d HH:mm"),
        FormatPreset(pattern: "MMM d h:mm a"),
        FormatPreset(pattern: "EEE HH:mm"),
        FormatPreset(pattern: "EEEE HH:mm:ss"),
        FormatPreset(pattern: "yyyy-MM-dd HH:mm:ss"),
    ]
}

/// 时间格式：开关拼装本地化模板，或直接透传用户的自定义格式串
enum ClockFormat {
    @MainActor
    static func string(from date: Date, settings: any ClockFormatProviding) -> String {
        formatter(for: settings).string(from: date)
    }

    /// 菜单栏菜单头部用：与时钟同一格式但不显示秒。
    /// 打开的菜单里每秒改标题会导致 AppKit 关闭/重建菜单，所以头部只按分钟刷新。
    @MainActor
    static func headerString(from date: Date, settings: any ClockFormatProviding) -> String {
        let base = formatter(for: settings)
        guard settings.showSeconds || base.dateFormat.contains("ss") else {
            return base.string(from: date)
        }
        var pattern = base.dateFormat
            .replacingOccurrences(of: ":ss", with: "")
            .replacingOccurrences(of: "ss", with: "")
        while let r = pattern.range(of: "  ") { pattern.replaceSubrange(r, with: " ") }
        pattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: " ::"))

        let formatter = DateFormatter()
        formatter.locale = base.locale
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    @MainActor
    static func formatter(for settings: any ClockFormatProviding) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current

        if settings.customFormatEnabled, !settings.customFormat.isEmpty {
            formatter.dateFormat = settings.customFormat
            return formatter
        }

        var skeletons: [String] = []
        if settings.showWeekday { skeletons.append("EEEE") }
        if settings.showDate { skeletons.append("yMMMd") }

        switch (settings.use24Hour, settings.showSeconds) {
        case (true, true):  skeletons.append("HHmmss")
        case (true, false): skeletons.append("HHmm")
        case (false, true): skeletons.append("jjmmss")
        case (false, false): skeletons.append("jjmm")
        }

        // setLocalizedDateFormatFromTemplate 会按当前语言调整顺序/分隔符/12小时制后缀
        formatter.setLocalizedDateFormatFromTemplate(skeletons.joined())
        return formatter
    }
}
