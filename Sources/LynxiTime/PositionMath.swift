import AppKit
import Foundation

/// 9 宫格预设 / 归一化自由位置与窗口坐标的换算
enum PositionMath {
    /// 与屏幕边缘的最小间距
    static let margin: CGFloat = 8

    static func origin(for size: NSSize, in visibleFrame: NSRect, position: PanelPosition) -> NSPoint {
        switch position {
        case .preset(let preset):
            return presetOrigin(preset, size: size, in: visibleFrame)
        case .free(let u, let v):
            var x = visibleFrame.minX + CGFloat(u) * visibleFrame.width - size.width / 2
            var y = visibleFrame.minY + CGFloat(v) * visibleFrame.height - size.height / 2
            clamp(&x, min: visibleFrame.minX + margin, max: visibleFrame.maxX - margin - size.width)
            clamp(&y, min: visibleFrame.minY + margin, max: visibleFrame.maxY - margin - size.height)
            return NSPoint(x: x, y: y)
        }
    }

    /// 取时钟中心点在容器（屏幕 frame 或 visibleFrame）中的归一化坐标。
    /// 中心点先夹到 origin() 实际能放置的范围内，保证「拖动落点 → 恢复位置」像素一致，
    /// 不会因恢复时的 margin 夹取产生偏移。
    static func normalizedCenter(frame: NSRect, in container: NSRect) -> (x: Double, y: Double) {
        guard container.width > frame.width, container.height > frame.height else { return (0.5, 0.5) }
        func clamp(_ v: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            Swift.min(Swift.max(v, lower), upper < lower ? lower : upper)
        }
        let cx = clamp(frame.midX,
                       container.minX + margin + frame.width / 2,
                       container.maxX - margin - frame.width / 2)
        let cy = clamp(frame.midY,
                       container.minY + margin + frame.height / 2,
                       container.maxY - margin - frame.height / 2)
        return (
            Double((cx - container.minX) / container.width),
            Double((cy - container.minY) / container.height)
        )
    }

    private static func presetOrigin(_ preset: PositionPreset, size: NSSize, in vf: NSRect) -> NSPoint {
        let left = vf.minX + margin
        let right = vf.maxX - margin - size.width
        let centerX = vf.midX - size.width / 2
        let top = vf.maxY - margin - size.height
        let bottom = vf.minY + margin
        let centerY = vf.midY - size.height / 2

        switch preset {
        case .topLeading:     return NSPoint(x: left, y: top)
        case .topCenter:      return NSPoint(x: centerX, y: top)
        case .topTrailing:    return NSPoint(x: right, y: top)
        case .leadingCenter:  return NSPoint(x: left, y: centerY)
        case .center:         return NSPoint(x: centerX, y: centerY)
        case .trailingCenter: return NSPoint(x: right, y: centerY)
        case .bottomLeading:  return NSPoint(x: left, y: bottom)
        case .bottomCenter:   return NSPoint(x: centerX, y: bottom)
        case .bottomTrailing: return NSPoint(x: right, y: bottom)
        }
    }

    private static func clamp(_ value: inout CGFloat, min lower: CGFloat, max upper: CGFloat) {
        if upper < lower {
            value = lower
        } else {
            value = Swift.min(Swift.max(value, lower), upper)
        }
    }
}

extension NSScreen {
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}
