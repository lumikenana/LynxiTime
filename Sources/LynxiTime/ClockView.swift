import SwiftUI

/// 按外观配置解析字体（ClockView 与潜在的预览共用）
enum ClockFont {
    static func resolved(for appearance: ClockAppearance) -> NSFont {
        let size = CGFloat(appearance.fontSize)
        switch appearance.fontChoice {
        case .sfPro:
            return .systemFont(ofSize: size)
        case .sfMono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sfRounded:
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case .custom:
            let name = appearance.customFontName
            if !name.isEmpty, let font = NSFont(name: name, size: size) {
                return font
            }
            return .systemFont(ofSize: size)
        }
    }
}

/// 屏幕上渲染的时钟本体（在每个面板的 NSHostingView 中）
struct ClockView: View {
    @ObservedObject var theme: DisplayTheme
    @ObservedObject var ticker = TimeTicker.shared

    private var s: ClockAppearance { theme.style }

    var body: some View {
        Text(ClockFormat.string(from: ticker.now, settings: s))
            .font(Font(ClockFont.resolved(for: s)))
            .monospacedDigit()
            .foregroundStyle(resolvedTextColor)
            .opacity(s.textOpacity)
            .multilineTextAlignment(.center)
            .fixedSize()
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background {
                if s.backgroundEnabled, let bg = s.backgroundColor.nsColor {
                    RoundedRectangle(cornerRadius: s.backgroundRadius, style: .continuous)
                        .fill(
                            Color(nsColor: bg)
                                .opacity(s.backgroundOpacity)
                        )
                }
            }
            // 透明的外边距：扩大拖拽热区，又不改变可见内边距
            .padding(6)
            .contentShape(Rectangle())
    }

    /// auto 跟随系统明暗（.primary），否则用内置皮肤色
    var resolvedTextColor: Color {
        if let c = s.textColor.nsColor {
            return Color(nsColor: c)
        }
        return Color.primary
    }
}
