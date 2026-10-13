import AppKit
import SwiftUI

/// 无边框、非激活、可覆盖全屏 App 的透明时钟面板
final class ClockPanel: NSPanel {

    /// convenience init 同步传给 4 参数 designated init 的真实主题。
    /// NSWindow 的 5 参数 init 会动态调用 4 参数 designated init，而 hosting（contentView）
    /// 必须在 super.init 之前创建挂载；若先用占位主题建 view，占位内容会在 init 期间
    /// 把窗口缩成占位尺寸，上屏前换 rootView 后窗口再围绕错误锚点自 resize 回真实尺寸
    /// （副屏独立外观字号不同时，时钟会偏出屏幕边缘）。init 全程在主线程同步完成。
    @MainActor private static var pendingTheme: DisplayTheme?

    /// SwiftUI 宿主：mouseDown 追踪循环实现按住时钟任意位置拖动
    let hosting: ClockHostingView<ClockView>

    /// 代码主动 setFrame 时置位，避免被误判为用户拖拽
    private(set) var isApplyingFrame = false

    /// NSWindow 的 5 参数 init 最终会动态调用这个 4 参数 designated init，必须在子类实现。
    /// 关键时序：hosting view 必须在 super.init 之前创建、init 内挂为 contentView，
    /// 且调用方需以目标屏幕的最终 frame + defer:true 创建本面板——
    /// NSHostingView 在窗口首次上屏时按目标屏 backingScaleFactor 解析缩放；
    /// 若先 orderFront 再跨屏 setFrame、或上屏后才挂 contentView，会出现内容空白/缩放错误。
    /// contentView 必须在 super.init 之前挂载，且从一开始就用该屏真正的主题
    /// （经 pendingTheme 传入）：占位主题会在 init 期间按占位内容尺寸缩窗，
    /// 之后再换 rootView 会触发窗口围绕错误锚点自 resize（独立外观尺寸不同即偏位）。
    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        let realTheme = ClockPanel.pendingTheme ?? DisplayTheme(displayID: 0)
        hosting = ClockHostingView(rootView: ClockView(theme: realTheme))
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // 拖拽由 ClockHostingView.mouseDown 追踪循环处理，不用内置背景拖动
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// 在目标屏幕的最终坐标处以 defer:true 创建；创建后直接 orderFrontRegardless 即可。
    /// 主题经 pendingTheme 传入，contentView 第一次上屏就是真实内容（见上）。
    convenience init(finalFrame frame: NSRect, level: NSWindow.Level, theme: DisplayTheme) {
        ClockPanel.pendingTheme = theme
        self.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        ClockPanel.pendingTheme = nil
        self.level = level
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        isApplyingFrame = true
        super.setFrame(frameRect, display: flag, animate: animateFlag)
        isApplyingFrame = false
    }
}
