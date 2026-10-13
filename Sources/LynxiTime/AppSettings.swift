import AppKit
import Combine
import Foundation

/// 窗口层级三档
enum WindowLevelKind: String, CaseIterable, Identifiable {
    case normal
    case floating
    case overFullScreen
    var id: String { rawValue }

    var nsLevel: NSWindow.Level {
        switch self {
        case .normal:
            return .normal
        case .floating:
            return .floating
        case .overFullScreen:
            // 与原版 "Over Apps" 一致：压在状态栏附近，配合 fullScreenAuxiliary 覆盖全屏 App
            return NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        }
    }
}

/// 内置字体风格 + 本地自定义字体
enum FontChoice: String, CaseIterable, Identifiable, Codable {
    case sfPro
    case sfMono
    case sfRounded
    case custom
    var id: String { rawValue }
}

/// 内置皮肤颜色（文字 / 背景共用）
enum SkinColor: String, CaseIterable, Identifiable, Codable {
    case auto   // 仅文字色可用：跟随系统明暗的 .primary
    case white
    case black
    case gray
    case red
    case orange
    case amber
    case yellow
    case green
    case teal
    case cyan
    case blue
    case indigo
    case purple
    case pink
    case brown
    var id: String { rawValue }

    /// RGB（sRGB 0...255）；auto 为 nil
    var rgb: (Int, Int, Int)? {
        switch self {
        case .auto:   return nil
        case .white:  return (255, 255, 255)
        case .black:  return (0, 0, 0)
        case .gray:   return (158, 158, 158)
        case .red:    return (244, 67, 54)
        case .orange: return (255, 149, 0)
        case .amber:  return (255, 179, 0)
        case .yellow: return (255, 211, 0)
        case .green:  return (76, 175, 80)
        case .teal:   return (0, 150, 136)
        case .cyan:   return (0, 188, 212)
        case .blue:   return (33, 150, 243)
        case .indigo: return (63, 81, 181)
        case .purple: return (156, 39, 176)
        case .pink:   return (233, 30, 99)
        case .brown:  return (141, 110, 99)
        }
    }

    var nsColor: NSColor? {
        guard let (r, g, b) = rgb else { return nil }
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// 色板上勾选标记用什么颜色才看得清
    var isLight: Bool {
        guard let (r, g, b) = rgb else { return false }
        return (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) > 150
    }

    /// 背景色可选集合（auto 无意义）
    static let backgroundCases: [SkinColor] = [
        .black, .white, .gray, .brown,
        .red, .orange, .amber, .yellow,
        .green, .teal, .cyan, .blue, .indigo, .purple, .pink,
    ]
}

/// 同一个应用在同一块屏幕上的两套专属位置：全屏空间一套、普通窗口一套
struct AppPositionSlots: Codable, Equatable {
    var fullscreen: PanelPosition?
    var windowed: PanelPosition?
}

/// 一整套时钟外观/格式的值类型（全局默认值与单屏独立外观共用）
struct ClockAppearance: Codable, Equatable {
    var showSeconds: Bool
    var use24Hour: Bool
    var showDate: Bool
    var showWeekday: Bool
    var customFormatEnabled: Bool
    var customFormat: String
    var fontChoice: FontChoice
    var customFontName: String
    var fontSize: Double
    var textOpacity: Double
    var textColor: SkinColor
    var backgroundEnabled: Bool
    var backgroundColor: SkinColor
    var backgroundOpacity: Double
    var backgroundRadius: Double

    @MainActor
    static func global(from s: AppSettings) -> ClockAppearance {
        ClockAppearance(
            showSeconds: s.showSeconds,
            use24Hour: s.use24Hour,
            showDate: s.showDate,
            showWeekday: s.showWeekday,
            customFormatEnabled: s.customFormatEnabled,
            customFormat: s.customFormat,
            fontChoice: s.fontChoice,
            customFontName: s.customFontName,
            fontSize: s.fontSize,
            textOpacity: s.textOpacity,
            textColor: s.textColor,
            backgroundEnabled: s.backgroundEnabled,
            backgroundColor: s.backgroundColor,
            backgroundOpacity: s.backgroundOpacity,
            backgroundRadius: s.backgroundRadius
        )
    }
}

extension AppSettings: ClockFormatProviding {}

/// 时钟在单块屏幕上的位置：9 宫格预设或自由拖拽
enum PanelPosition: Codable, Equatable {
    case preset(PositionPreset)
    /// 以时钟中心在屏幕 visibleFrame 内的归一化坐标 (0...1)
    case free(x: Double, y: Double)
}

enum PositionPreset: String, CaseIterable, Identifiable, Codable {
    case topLeading
    case topCenter
    case topTrailing
    case leadingCenter
    case center
    case trailingCenter
    case bottomLeading
    case bottomCenter
    case bottomTrailing
    var id: String { rawValue }

    /// SF Symbols 3x3 定位图标
    var symbolName: String {
        switch self {
        case .topLeading: return "square.grid.3x3.topleft.filled"
        case .topCenter: return "square.grid.3x3.topmiddle.filled"
        case .topTrailing: return "square.grid.3x3.topright.filled"
        case .leadingCenter: return "square.grid.3x3.middleleft.filled"
        case .center: return "square.grid.3x3.center.filled"
        case .trailingCenter: return "square.grid.3x3.middleright.filled"
        case .bottomLeading: return "square.grid.3x3.bottomleft.filled"
        case .bottomCenter: return "square.grid.3x3.bottommiddle.filled"
        case .bottomTrailing: return "square.grid.3x3.bottomright.filled"
        }
    }
}

/// 全部偏好设置，UserDefaults 持久化，SwiftUI 直接绑定
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - 时间格式
    @Published var showSeconds: Bool {
        didSet {
            defaults.set(showSeconds, forKey: Keys.showSeconds)
            fallBackToAutoFormat()
        }
    }

    @Published var use24Hour: Bool {
        didSet {
            defaults.set(use24Hour, forKey: Keys.use24Hour)
            fallBackToAutoFormat()
        }
    }

    @Published var showDate: Bool {
        didSet {
            defaults.set(showDate, forKey: Keys.showDate)
            fallBackToAutoFormat()
        }
    }

    @Published var showWeekday: Bool {
        didSet {
            defaults.set(showWeekday, forKey: Keys.showWeekday)
            fallBackToAutoFormat()
        }
    }

    /// 拨动基础开关即视为退出“内置/自定义格式串”模式，回到开关拼装
    private func fallBackToAutoFormat() {
        guard loaded, customFormatEnabled else { return }
        customFormatEnabled = false
    }

    @Published var customFormatEnabled: Bool {
        didSet { defaults.set(customFormatEnabled, forKey: Keys.customFormatEnabled) }
    }

    @Published var customFormat: String {
        didSet { defaults.set(customFormat, forKey: Keys.customFormat) }
    }

    // MARK: - 外观
    @Published var fontChoice: FontChoice {
        didSet { defaults.set(fontChoice.rawValue, forKey: Keys.fontChoice) }
    }

    @Published var customFontName: String {
        didSet { defaults.set(customFontName, forKey: Keys.customFontName) }
    }

    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    @Published var textOpacity: Double {
        didSet { defaults.set(textOpacity, forKey: Keys.textOpacity) }
    }

    @Published var backgroundEnabled: Bool {
        didSet { defaults.set(backgroundEnabled, forKey: Keys.backgroundEnabled) }
    }

    @Published var backgroundColor: SkinColor {
        didSet { defaults.set(backgroundColor.rawValue, forKey: Keys.backgroundColor) }
    }

    @Published var textColor: SkinColor {
        didSet { defaults.set(textColor.rawValue, forKey: Keys.textColor) }
    }

    @Published var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }

    @Published var backgroundRadius: Double {
        didSet { defaults.set(backgroundRadius, forKey: Keys.backgroundRadius) }
    }

    // MARK: - 行为
    @Published var windowLevel: WindowLevelKind {
        didSet { defaults.set(windowLevel.rawValue, forKey: Keys.windowLevel) }
    }

    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }

    /// 系统菜单栏时钟可见（普通桌面）时自动隐藏该屏时钟；逐屏独立判定
    @Published var autoHideWithClock: Bool {
        didSet { defaults.set(autoHideWithClock, forKey: Keys.autoHideWithClock) }
    }

    /// 空数组表示“所有显示器都启用”
    @Published var enabledDisplays: [Int] {
        didSet { defaults.set(enabledDisplays, forKey: Keys.enabledDisplays) }
    }

    @Published var positionsByDisplay: [String: PanelPosition] {
        didSet { persistPositions() }
    }

    /// 按应用记忆位置总开关。开启后拖动时钟落位即按「前台应用 + 全屏/窗口」自动存档
    @Published var perAppPositionEnabled: Bool {
        didSet { defaults.set(perAppPositionEnabled, forKey: Keys.perAppPositionEnabled) }
    }

    /// 应用专属位置：[displayID 字符串: [bundleID: 全屏/窗口两套位置]]
    /// 仅当该应用在该屏前台时取对应槽位，缺槽位时用 positionsByDisplay 的默认位置
    @Published var appPositions: [String: [String: AppPositionSlots]] {
        didSet { persistAppPositions() }
    }

    /// 使用独立外观（而非全局默认）的显示器 id；空=全部继承全局
    @Published var independentDisplays: [Int] {
        didSet { defaults.set(independentDisplays, forKey: Keys.independentDisplays) }
    }

    /// 每屏独立外观快照（即使后来关掉独立开关也保留，重新开启时恢复）
    @Published var appearancesByDisplay: [String: ClockAppearance] {
        didSet { persistAppearances() }
    }

    private let defaults = UserDefaults.standard
    /// init 期间 didSet 只做持久化，不做“联动副作用”
    private var loaded = false

    private init() {
        // 注册出厂默认值
        defaults.register(defaults: [
            Keys.showSeconds: true,
            Keys.use24Hour: true,
            Keys.showDate: false,
            Keys.showWeekday: false,
            Keys.customFormatEnabled: false,
            Keys.customFormat: "EEEE HH:mm",
            Keys.fontChoice: FontChoice.sfPro.rawValue,
            Keys.customFontName: "",
            Keys.fontSize: 28.0,
            Keys.textOpacity: 1.0,
            Keys.backgroundEnabled: false,
            Keys.backgroundColor: SkinColor.black.rawValue,
            Keys.textColor: SkinColor.auto.rawValue,
            Keys.backgroundOpacity: 0.35,
            Keys.backgroundRadius: 6.0,
            Keys.windowLevel: WindowLevelKind.overFullScreen.rawValue,
            Keys.showDockIcon: false,
            Keys.autoHideWithClock: true,
            Keys.enabledDisplays: [Int](),
            Keys.perAppPositionEnabled: true,
        ])

        showSeconds = defaults.bool(forKey: Keys.showSeconds)
        use24Hour = defaults.bool(forKey: Keys.use24Hour)
        showDate = defaults.bool(forKey: Keys.showDate)
        showWeekday = defaults.bool(forKey: Keys.showWeekday)
        customFormatEnabled = defaults.bool(forKey: Keys.customFormatEnabled)
        customFormat = defaults.string(forKey: Keys.customFormat) ?? "EEEE HH:mm"
        fontChoice = FontChoice(rawValue: defaults.string(forKey: Keys.fontChoice) ?? "") ?? .sfPro
        customFontName = defaults.string(forKey: Keys.customFontName) ?? ""
        fontSize = defaults.double(forKey: Keys.fontSize)
        textOpacity = defaults.double(forKey: Keys.textOpacity)
        backgroundEnabled = defaults.bool(forKey: Keys.backgroundEnabled)
        backgroundColor = SkinColor(rawValue: defaults.string(forKey: Keys.backgroundColor) ?? "") ?? .black
        textColor = SkinColor(rawValue: defaults.string(forKey: Keys.textColor) ?? "") ?? .auto
        loaded = true
        backgroundOpacity = defaults.double(forKey: Keys.backgroundOpacity)
        backgroundRadius = defaults.double(forKey: Keys.backgroundRadius)
        windowLevel = WindowLevelKind(rawValue: defaults.string(forKey: Keys.windowLevel) ?? "") ?? .overFullScreen
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        autoHideWithClock = defaults.bool(forKey: Keys.autoHideWithClock)
        enabledDisplays = defaults.array(forKey: Keys.enabledDisplays) as? [Int] ?? []
        positionsByDisplay = AppSettings.decodePositions(defaults.data(forKey: Keys.positionsByDisplay))
        appPositions = AppSettings.decodeAppPositions(defaults.data(forKey: Keys.appPositions))
        perAppPositionEnabled = defaults.bool(forKey: Keys.perAppPositionEnabled)
        independentDisplays = defaults.array(forKey: Keys.independentDisplays) as? [Int] ?? []
        appearancesByDisplay = AppSettings.decodeAppearances(defaults.data(forKey: Keys.appearancesByDisplay))
    }

    // MARK: - 显示器 / 位置便捷方法

    func isEnabled(_ displayID: Int) -> Bool {
        enabledDisplays.isEmpty || enabledDisplays.contains(displayID)
    }

    /// 白名单语义：空名单代表全开；关闭一块时先填满其余屏幕，
    /// 重新启用使名单回到“全部启用”时恢复为空名单。
    func setDisplay(_ displayID: Int, enabled: Bool, allIDs: [Int]) {
        if enabled {
            guard !enabledDisplays.isEmpty, !enabledDisplays.contains(displayID) else { return }
            let ids = enabledDisplays + [displayID]
            enabledDisplays = Set(ids) == Set(allIDs) ? [] : ids
        } else {
            guard isEnabled(displayID) else { return }
            enabledDisplays = (enabledDisplays.isEmpty ? allIDs : enabledDisplays)
                .filter { $0 != displayID }
        }
    }

    func position(for displayID: Int) -> PanelPosition {
        positionsByDisplay[String(displayID)] ?? .preset(.topTrailing)
    }

    func setPosition(_ position: PanelPosition, for displayID: Int) {
        positionsByDisplay[String(displayID)] = position
    }

    // MARK: - 按应用的位置覆盖

    /// 该应用在该屏、指定全屏/窗口状态下的专属位置；未配置返回 nil（用默认位置）
    func appPosition(for displayID: Int, bundleID: String, fullscreen: Bool) -> PanelPosition? {
        let slots = appPositions[String(displayID)]?[bundleID]
        return fullscreen ? slots?.fullscreen : slots?.windowed
    }

    /// 该应用在该屏的两套槽位（设置页展示用）
    func appSlots(for displayID: Int, bundleID: String) -> AppPositionSlots? {
        appPositions[String(displayID)]?[bundleID]
    }

    /// 写入某应用在某屏某状态的专属位置；传 nil 清该槽位，两套皆空时整条移除
    func setAppPosition(_ position: PanelPosition?,
                        for displayID: Int, bundleID: String, fullscreen: Bool) {
        let key = String(displayID)
        var slots = appPositions[key]?[bundleID] ?? AppPositionSlots(fullscreen: nil, windowed: nil)
        if fullscreen {
            slots.fullscreen = position
        } else {
            slots.windowed = position
        }
        var inner = appPositions[key] ?? [:]
        if slots.fullscreen == nil && slots.windowed == nil {
            inner.removeValue(forKey: bundleID)
        } else {
            inner[bundleID] = slots
        }
        if inner.isEmpty {
            appPositions.removeValue(forKey: key)
        } else {
            appPositions[key] = inner
        }
    }

    /// 清除某应用在某屏的全部专属位置
    func clearAppPosition(for displayID: Int, bundleID: String) {
        setAppPosition(nil, for: displayID, bundleID: bundleID, fullscreen: true)
        setAppPosition(nil, for: displayID, bundleID: bundleID, fullscreen: false)
    }

    /// 某屏已配置专属位置的应用 bundleID 列表
    func appBundleIDs(for displayID: Int) -> [String] {
        (appPositions[String(displayID)]?.keys).map { Array($0) } ?? []
    }

    /// 选择内置格式预设：写入格式串并启用自定义串模式
    func applyFormatPattern(_ pattern: String) {
        customFormat = pattern
        customFormatEnabled = true
    }

    // MARK: - 每屏独立外观

    func isIndependent(_ displayID: Int) -> Bool {
        independentDisplays.contains(displayID)
    }

    /// 该屏当前生效的外观：独立用快照，否则用全局
    func appearance(for displayID: Int) -> ClockAppearance {
        if isIndependent(displayID),
           let saved = appearancesByDisplay[String(displayID)] {
            return saved
        }
        return ClockAppearance.global(from: self)
    }

    /// 开启时：若无历史快照则以当前全局外观播种；关闭时仅移出名单（快照保留）
    func setIndependent(_ on: Bool, for displayID: Int) {
        if on {
            guard !independentDisplays.contains(displayID) else { return }
            independentDisplays.append(displayID)
            if appearancesByDisplay[String(displayID)] == nil {
                appearancesByDisplay[String(displayID)] = ClockAppearance.global(from: self)
            }
        } else {
            independentDisplays.removeAll { $0 == displayID }
        }
    }

    func setAppearance(_ appearance: ClockAppearance, for displayID: Int) {
        appearancesByDisplay[String(displayID)] = appearance
    }

    private func persistAppearances() {
        if let data = try? JSONEncoder().encode(appearancesByDisplay) {
            defaults.set(data, forKey: Keys.appearancesByDisplay)
        }
    }

    private static func decodeAppearances(_ data: Data?) -> [String: ClockAppearance] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: ClockAppearance].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistPositions() {
        if let data = try? JSONEncoder().encode(positionsByDisplay) {
            defaults.set(data, forKey: Keys.positionsByDisplay)
        }
    }

    private static func decodePositions(_ data: Data?) -> [String: PanelPosition] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: PanelPosition].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistAppPositions() {
        if let data = try? JSONEncoder().encode(appPositions) {
            defaults.set(data, forKey: Keys.appPositions)
        }
    }

    private static func decodeAppPositions(_ data: Data?) -> [String: [String: AppPositionSlots]] {
        guard let data else { return [:] }
        // 新格式：每应用全屏 / 窗口两套槽位（顺带剔除两槽皆空 / 空字典的脏数据）
        if let decoded = try? JSONDecoder().decode(
            [String: [String: AppPositionSlots]].self, from: data) {
            return sanitized(decoded)
        }
        // 旧格式（单槽位）：迁移到全屏槽位
        if let legacy = try? JSONDecoder().decode(
            [String: [String: PanelPosition]].self, from: data) {
            return sanitized(legacy.mapValues { perApp in
                perApp.mapValues { AppPositionSlots(fullscreen: $0, windowed: nil) }
            })
        }
        return [:]
    }

    /// 剔除两槽皆空的应用条目与空的显示器字典
    private static func sanitized(_ map: [String: [String: AppPositionSlots]])
        -> [String: [String: AppPositionSlots]] {
        map.compactMapValues { perApp in
            let kept = perApp.filter { $0.value.fullscreen != nil || $0.value.windowed != nil }
            return kept.isEmpty ? nil : kept
        }
    }
}

private enum Keys {
    static let showSeconds = "showSeconds"
    static let use24Hour = "use24Hour"
    static let showDate = "showDate"
    static let showWeekday = "showWeekday"
    static let customFormatEnabled = "customFormatEnabled"
    static let customFormat = "customFormat"
    static let fontChoice = "fontChoice"
    static let customFontName = "customFontName"
    static let fontSize = "fontSize"
    static let textOpacity = "textOpacity"
    static let backgroundEnabled = "backgroundEnabled"
    static let backgroundColor = "backgroundColor"
    static let textColor = "textColor"
    static let backgroundOpacity = "backgroundOpacity"
    static let backgroundRadius = "backgroundRadius"
    static let windowLevel = "windowLevel"
    static let showDockIcon = "showDockIcon"
    static let autoHideWithClock = "autoHideWithClock"
    static let perAppPositionEnabled = "perAppPositionEnabled"
    static let enabledDisplays = "enabledDisplays"
    static let positionsByDisplay = "positionsByDisplay"
    static let appPositions = "appPositions"
    static let independentDisplays = "independentDisplays"
    static let appearancesByDisplay = "appearancesByDisplay"
}
