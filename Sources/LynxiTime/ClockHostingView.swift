import AppKit
import SwiftUI

/// SwiftUI 时钟宿主：按住时钟任意位置（含透明热区）即可拖动窗口。
/// 交给系统的 performDrag 做窗口服务器级拖动（比逐帧 setFrameOrigin 更顺滑，
/// 跨不同 backing 缩放倍数的屏幕时也不会出现内容短暂消失）。
final class ClockHostingView<Content: View>: NSHostingView<Content> {

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
