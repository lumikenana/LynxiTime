import AppKit
import Combine
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(L10n.t("tab.general"), systemImage: "gearshape") }
                .tag(0)
            AppearanceSettingsView()
                .tabItem { Label(L10n.t("tab.appearance"), systemImage: "textformat") }
                .tag(1)
            PositionSettingsView()
                .tabItem { Label(L10n.t("tab.position"), systemImage: "rectangle.3.group") }
                .tag(2)
        }
        .padding(20)
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launch = LaunchAtLoginState.shared

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("window-level"), selection: $settings.windowLevel) {
                    Text(L10n.t("level.normal")).tag(WindowLevelKind.normal)
                    Text(L10n.t("level.floating")).tag(WindowLevelKind.floating)
                    Text(L10n.t("level.overFullScreen")).tag(WindowLevelKind.overFullScreen)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.t("auto-hide"), isOn: $settings.autoHideWithClock)
                    Text(L10n.t("auto-hide.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(L10n.t("dock-icon"), isOn: $settings.showDockIcon)
                Toggle(isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { launch.apply($0) }
                )) {
                    Text(L10n.t("launch"))
                }
            }
        }
        .formStyle(.grouped)
        .alert(L10n.t("launch-failed"), isPresented: $launch.errorVisible) {
            Button(L10n.t("ok"), role: .cancel) {}
        }
    }
}

/// 开机启动开关状态（避免使用需要 Xcode 宏插件的 @State）
@MainActor
final class LaunchAtLoginState: ObservableObject {
    static let shared = LaunchAtLoginState()
    @Published var errorVisible = false

    func apply(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
        } catch {
            errorVisible = true
        }
    }
}

// MARK: - 外观编辑目标（全局 / 某块屏独立）

/// 外观页的编辑目标：所有显示器共用全局外观，或选中某块屏编辑它的独立外观。
/// 一份字段在「全局 AppSettings」与「单屏 ClockAppearance」之间转发写入。
@MainActor
final class AppearanceEditor: ObservableObject {
    static let shared = AppearanceEditor()

    enum Target: Hashable {
        case global
        case display(Int)

        var displayID: Int? {
            if case .display(let id) = self { return id }
            return nil
        }
    }

    @Published var target: Target = .global {
        didSet { reload() }
    }

    @Published var independent = false
    @Published var showSeconds = true
    @Published var use24Hour = true
    @Published var showDate = false
    @Published var showWeekday = false
    @Published var customFormatEnabled = false
    @Published var customFormat = "EEEE HH:mm"
    @Published var fontChoice: FontChoice = .sfPro
    @Published var customFontName = ""
    @Published var fontSize = 28.0
    @Published var textOpacity = 1.0
    @Published var textColor: SkinColor = .auto
    @Published var backgroundEnabled = false
    @Published var backgroundColor: SkinColor = .black
    @Published var backgroundOpacity = 0.35
    @Published var backgroundRadius = 6.0

    private let settings = AppSettings.shared
    /// reload / 联动改写本地字段期间，禁止 didSet 再回写
    private var applying = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        reload()

        // 外部（菜单栏快捷开关等）改了外观来源时刷新表单
        let s = settings
        func trig<V>(_ p: Published<V>.Publisher) -> AnyPublisher<Void, Never> {
            p.receive(on: RunLoop.main).map { _ in () }.eraseToAnyPublisher()
        }
        let triggers: [AnyPublisher<Void, Never>] = [
            trig(s.$showSeconds), trig(s.$use24Hour), trig(s.$showDate), trig(s.$showWeekday),
            trig(s.$customFormatEnabled), trig(s.$customFormat), trig(s.$fontChoice), trig(s.$customFontName),
            trig(s.$fontSize), trig(s.$textOpacity), trig(s.$textColor), trig(s.$backgroundEnabled),
            trig(s.$backgroundColor), trig(s.$backgroundOpacity), trig(s.$backgroundRadius),
            trig(s.$independentDisplays), trig(s.$appearancesByDisplay),
        ]

        Publishers.MergeMany(triggers)
            .sink { [weak self] _ in self?.syncIfChanged() }
            .store(in: &cancellables)

        // 选中的屏幕被拔出/停用消失时，回到全局编辑
        ClockManager.shared.$displays
            .receive(on: RunLoop.main)
            .sink { [weak self] displays in
                guard let self, let id = self.target.displayID,
                      !displays.contains(where: { $0.id == id }) else { return }
                self.target = .global
            }
            .store(in: &cancellables)
    }

    var isInherited: Bool {
        if let id = target.displayID { return !settings.isIndependent(id) }
        return false
    }

    /// 由当前字段拼出的外观（设置页预览用）
    func currentAppearance() -> ClockAppearance {
        ClockAppearance(
            showSeconds: showSeconds,
            use24Hour: use24Hour,
            showDate: showDate,
            showWeekday: showWeekday,
            customFormatEnabled: customFormatEnabled,
            customFormat: customFormat,
            fontChoice: fontChoice,
            customFontName: customFontName,
            fontSize: fontSize,
            textOpacity: textOpacity,
            textColor: textColor,
            backgroundEnabled: backgroundEnabled,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            backgroundRadius: backgroundRadius
        )
    }

    func setIndependent(_ on: Bool) {
        guard let id = target.displayID else { return }
        settings.setIndependent(on, for: id)
        reload()
    }

    func applyFormatPattern(_ pattern: String) {
        applying = true
        customFormat = pattern
        customFormatEnabled = true
        applying = false
        switch target {
        case .global:
            settings.applyFormatPattern(pattern)
        case .display(let id):
            var a = settings.appearance(for: id)
            a.customFormat = pattern
            a.customFormatEnabled = true
            settings.setAppearance(a, for: id)
        }
    }

    func applyCustomFont(name: String) {
        applying = true
        customFontName = name
        fontChoice = .custom
        applying = false
        switch target {
        case .global:
            settings.customFontName = name
            settings.fontChoice = .custom
        case .display(let id):
            var a = settings.appearance(for: id)
            a.customFontName = name
            a.fontChoice = .custom
            settings.setAppearance(a, for: id)
        }
    }

    /// 通用字段回写（滑块/色板/开关）
    func commit<V: Equatable>(
        _ appearanceKey: WritableKeyPath<ClockAppearance, V>,
        _ value: V,
        global globalKey: ReferenceWritableKeyPath<AppSettings, V>
    ) {
        guard !applying else { return }
        switch target {
        case .global:
            settings[keyPath: globalKey] = value
        case .display(let id):
            var a = settings.appearance(for: id)
            a[keyPath: appearanceKey] = value
            settings.setAppearance(a, for: id)
        }
    }

    /// 拨动基础格式开关：退出自定义格式串模式（全局侧由 AppSettings.didSet 处理）
    func commitFormatFlag(
        _ appearanceKey: WritableKeyPath<ClockAppearance, Bool>,
        _ value: Bool,
        global globalKey: ReferenceWritableKeyPath<AppSettings, Bool>
    ) {
        commit(appearanceKey, value, global: globalKey)
        guard customFormatEnabled else { return }
        applying = true
        customFormatEnabled = false
        applying = false
        if case .display(let id) = target {
            var a = settings.appearance(for: id)
            a.customFormatEnabled = false
            settings.setAppearance(a, for: id)
        }
    }

    private func syncIfChanged() {
        guard !applying, currentAppearance() != resolvedAppearance() else { return }
        reload()
    }

    private func resolvedAppearance() -> ClockAppearance {
        switch target {
        case .global:
            return ClockAppearance.global(from: settings)
        case .display(let id):
            return settings.appearance(for: id)
        }
    }

    private func reload() {
        if let id = target.displayID {
            independent = settings.isIndependent(id)
        } else {
            independent = false
        }
        let a = resolvedAppearance()
        applying = true
        showSeconds = a.showSeconds
        use24Hour = a.use24Hour
        showDate = a.showDate
        showWeekday = a.showWeekday
        customFormatEnabled = a.customFormatEnabled
        customFormat = a.customFormat
        fontChoice = a.fontChoice
        customFontName = a.customFontName
        fontSize = a.fontSize
        textOpacity = a.textOpacity
        textColor = a.textColor
        backgroundEnabled = a.backgroundEnabled
        backgroundColor = a.backgroundColor
        backgroundOpacity = a.backgroundOpacity
        backgroundRadius = a.backgroundRadius
        applying = false
    }
}

// MARK: - 外观

/// 承接系统字体选择器回调
@MainActor
final class FontPanelCoordinator: NSObject, NSFontChanging {
    static let shared = FontPanelCoordinator()

    func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let editor = AppearanceEditor.shared
        let converted = sender.convert(NSFont.systemFont(ofSize: CGFloat(editor.fontSize)))
        editor.applyCustomFont(name: converted.fontName)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var manager = ClockManager.shared
    @ObservedObject private var editor = AppearanceEditor.shared
    @ObservedObject private var ticker = TimeTicker.shared
    private let fontCoordinator = FontPanelCoordinator.shared

    private let presetColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        Form {
            Section(L10n.t("applies-to")) {
                Picker(L10n.t("applies-to"), selection: $editor.target) {
                    Text(L10n.t("all-displays")).tag(AppearanceEditor.Target.global)
                    ForEach(manager.displays) { display in
                        Text(display.name).tag(AppearanceEditor.Target.display(display.id))
                    }
                }
                .labelsHidden()

                if let id = editor.target.displayID {
                    Toggle(L10n.t("independent-appearance"), isOn: Binding(
                        get: { editor.independent },
                        set: { editor.setIndependent($0) }
                    ))
                    Text(L10n.t("independent-hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                Section(L10n.t("time-format")) {
                    Toggle(L10n.t("24h"), isOn: formatFlagBinding(\.use24Hour, global: \.use24Hour))
                    Toggle(L10n.t("show-seconds"), isOn: formatFlagBinding(\.showSeconds, global: \.showSeconds))
                    Toggle(L10n.t("show-date"), isOn: formatFlagBinding(\.showDate, global: \.showDate))
                    Toggle(L10n.t("show-weekday"), isOn: formatFlagBinding(\.showWeekday, global: \.showWeekday))

                    HStack {
                        Text(L10n.t("preview"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ClockFormat.string(from: ticker.now, settings: editor.currentAppearance()))
                            .font(.system(.body, design: .monospaced))
                            .monospacedDigit()
                    }
                }

                Section(L10n.t("format-presets")) {
                    LazyVGrid(columns: presetColumns, spacing: 8) {
                        ForEach(FormatPreset.all) { preset in
                            presetButton(preset)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section(L10n.t("custom-format")) {
                    Toggle(L10n.t("custom-format"), isOn: boolBinding(\.customFormatEnabled, global: \.customFormatEnabled))
                    TextField("EEEE HH:mm", text: bindString(\.customFormat, global: \.customFormat))
                        .disabled(!editor.customFormatEnabled)
                        .font(.system(.body, design: .monospaced))
                    Text(L10n.t("custom-format.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t("font")) {
                    Picker(L10n.t("font"), selection: bindFont()) {
                        Text("SF Pro").tag(FontChoice.sfPro)
                        Text("SF Mono").tag(FontChoice.sfMono)
                        Text("SF Rounded").tag(FontChoice.sfRounded)
                        Text(L10n.t("font.custom")).tag(FontChoice.custom)
                    }
                    .pickerStyle(.segmented)

                    if editor.fontChoice == .custom {
                        HStack {
                            Text(customFontDisplayName)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.t("choose-font")) {
                                NSApp.activate(ignoringOtherApps: true)
                                NSFontManager.shared.target = fontCoordinator
                                NSFontManager.shared.orderFrontFontPanel(nil)
                            }
                        }
                    }

                    SliderRow(title: L10n.t("font-size"), value: bindDouble(\.fontSize, global: \.fontSize), range: 12...96, step: 1)
                    SliderRow(title: L10n.t("text-opacity"), value: bindDouble(\.textOpacity, global: \.textOpacity), range: 0.1...1, step: 0.05)
                }

                Section(L10n.t("text-color")) {
                    SwatchPicker(selection: bindColor(\.textColor, global: \.textColor), colors: SkinColor.allCases)
                }

                Section(L10n.t("background")) {
                    Toggle(L10n.t("show-background"), isOn: boolBinding(\.backgroundEnabled, global: \.backgroundEnabled))
                    SwatchPicker(selection: bindColor(\.backgroundColor, global: \.backgroundColor), colors: SkinColor.backgroundCases)
                        .disabled(!editor.backgroundEnabled)
                        .opacity(editor.backgroundEnabled ? 1 : 0.4)

                    SliderRow(title: L10n.t("background-opacity"),
                              value: bindDouble(\.backgroundOpacity, global: \.backgroundOpacity), range: 0.1...1, step: 0.05)
                        .disabled(!editor.backgroundEnabled)
                    SliderRow(title: L10n.t("corner-radius"),
                              value: bindDouble(\.backgroundRadius, global: \.backgroundRadius), range: 0...40, step: 1)
                        .disabled(!editor.backgroundEnabled)
                }
            }
            // 选中某块屏但未开独立外观时：展示继承到的全局值但禁止编辑
            .disabled(editor.isInherited)
        }
        .formStyle(.grouped)
    }

    // MARK: 编辑器字段 -> 双向绑定（统一经 AppearanceEditor 转发）

    private func boolBinding(
        _ key: WritableKeyPath<ClockAppearance, Bool>,
        global gk: ReferenceWritableKeyPath<AppSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { editor.currentAppearance()[keyPath: key] },
            set: { editor.commit(key, $0, global: gk) }
        )
    }

    private func formatFlagBinding(
        _ key: WritableKeyPath<ClockAppearance, Bool>,
        global gk: ReferenceWritableKeyPath<AppSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { editor.currentAppearance()[keyPath: key] },
            set: { editor.commitFormatFlag(key, $0, global: gk) }
        )
    }

    private func bindString(
        _ key: WritableKeyPath<ClockAppearance, String>,
        global gk: ReferenceWritableKeyPath<AppSettings, String>
    ) -> Binding<String> {
        Binding(
            get: { editor.currentAppearance()[keyPath: key] },
            set: { editor.commit(key, $0, global: gk) }
        )
    }

    private func bindDouble(
        _ key: WritableKeyPath<ClockAppearance, Double>,
        global gk: ReferenceWritableKeyPath<AppSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { editor.currentAppearance()[keyPath: key] },
            set: { editor.commit(key, $0, global: gk) }
        )
    }

    private func bindColor(
        _ key: WritableKeyPath<ClockAppearance, SkinColor>,
        global gk: ReferenceWritableKeyPath<AppSettings, SkinColor>
    ) -> Binding<SkinColor> {
        Binding(
            get: { editor.currentAppearance()[keyPath: key] },
            set: { editor.commit(key, $0, global: gk) }
        )
    }

    private func bindFont() -> Binding<FontChoice> {
        Binding(
            get: { editor.fontChoice },
            set: { value in
                editor.commit(\.fontChoice, value, global: \.fontChoice)
            }
        )
    }

    private func presetButton(_ preset: FormatPreset) -> some View {
        let selected = editor.customFormatEnabled && editor.customFormat == preset.pattern
        return Button {
            editor.applyFormatPattern(preset.pattern)
        } label: {
            Text(preset.pattern)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .gray)
        .help(preset.pattern)
    }

    private var customFontDisplayName: String {
        let name = editor.customFontName
        guard !name.isEmpty,
              let font = NSFont(name: name, size: NSFont.systemFontSize) else {
            return L10n.t("choose-font")
        }
        return font.displayName ?? name
    }
}

/// 圆形色板选择器（皮肤颜色）
private struct SwatchPicker: View {
    @Binding var selection: SkinColor
    let colors: [SkinColor]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(colors) { color in
                Button {
                    selection = color
                } label: {
                    swatch(for: color)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(alignment: .center) {
                            Circle()
                                .strokeBorder(style: StrokeStyle(lineWidth: 2.5))
                                .foregroundStyle(selection == color ? Color.accentColor : .clear)
                                .padding(1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("color.\(color.rawValue)")))
                .help(L10n.t("color.\(color.rawValue)"))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func swatch(for color: SkinColor) -> some View {
        if color == .auto {
            // 黑白渐变表示“跟随系统”
            Circle()
                .fill(LinearGradient(colors: [.black, .white],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay {
                    if selection == color {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
        } else if let ns = color.nsColor {
            Circle()
                .fill(Color(nsColor: ns))
                .overlay {
                    if selection == color {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(color.isLight ? Color.black : Color.white)
                    }
                }
        } else {
            Circle().fill(Color.gray)
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, format: .number.precision(.fractionLength(0...2)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

// MARK: - 位置与显示器

private struct PositionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var manager = ClockManager.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        Form {
            Section {
                Text(L10n.t("drag-hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(manager.displays) { display in
                Section {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(PositionPreset.allCases) { preset in
                            presetButton(preset: preset, displayID: display.id)
                        }
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Label(L10n.t("custom-position"),
                              systemImage: isFree(display.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isFree(display.id) ? Color.accentColor : .secondary)
                        Spacer()
                        Button(L10n.t("reset-position")) {
                            manager.applyPosition(.preset(.topTrailing), for: display.id)
                        }
                    }

                    // 该屏已保存的应用专属位置
                    appOverrideSection(display.id)
                } header: {
                    HStack {
                        Text(display.name)
                        Spacer()
                        Toggle(L10n.t("enabled"), isOn: Binding(
                            get: { settings.isEnabled(display.id) },
                            set: { on in
                                settings.setDisplay(display.id, enabled: on,
                                                    allIDs: manager.displays.map(\.id))
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func presetButton(preset: PositionPreset, displayID: Int) -> some View {
        let selected: Bool = {
            if case .preset(let current) = settings.position(for: displayID), current == preset {
                return true
            }
            return false
        }()

        return Button {
            manager.applyPosition(.preset(preset), for: displayID)
        } label: {
            Image(systemName: preset.symbolName)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .gray)
    }

    private func isFree(_ displayID: Int) -> Bool {
        if case .free = settings.position(for: displayID) { return true }
        return false
    }

    @ViewBuilder
    private func appOverrideSection(_ displayID: Int) -> some View {
        if !appOverrides(displayID).isEmpty {
            Divider()
            Text(L10n.t("app-positions"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(appOverrides(displayID), id: \.self) { bundleID in
                appOverrideRow(bundleID: bundleID, displayID: displayID)
            }
        }
    }

    /// 该屏配置过专属位置的应用，按应用名排序
    private func appOverrides(_ displayID: Int) -> [String] {
        settings.appBundleIDs(for: displayID)
            .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    private func appOverrideRow(bundleID: String, displayID: Int) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 14))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(appName(bundleID)).font(.callout)
                Text(slotsDescription(settings.appSlots(for: displayID, bundleID: bundleID)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                manager.clearOverride(displayID: displayID, bundleID: bundleID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("app-position-clear"))
        }
        .padding(.leading, 4)
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
        else { return bundleID }
        return name
    }

    private func onePositionDescription(_ position: PanelPosition?) -> String {
        guard let position else { return "" }
        if case .preset(let preset) = position { return L10n.t(preset.rawValue) }
        return L10n.t("app-position-custom")
    }

    /// 形如「全屏：自定义位置 · 窗口：右上角」，只列已存档的槽位
    private func slotsDescription(_ slots: AppPositionSlots?) -> String {
        guard let slots else { return "" }
        var parts: [String] = []
        if let fs = slots.fullscreen {
            parts.append(String(format: L10n.t("slot-fullscreen"), onePositionDescription(fs)))
        }
        if let win = slots.windowed {
            parts.append(String(format: L10n.t("slot-windowed"), onePositionDescription(win)))
        }
        return parts.joined(separator: " · ")
    }
}
