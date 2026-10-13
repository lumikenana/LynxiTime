import AppKit
import CoreGraphics

/// 判断每块屏幕上「系统菜单栏时钟」当前是否可见。
///
/// 双信号（均无需辅助功能/录屏权限，数据源同为 CGWindowList）：
/// 1. Menubar 窗口：Window Server 拥有、layer == 24、宽度≈屏宽、贴该屏顶边。
///    macOS 26 之前的系统里，进入全屏空间时它直接从 onScreen 列表消失。
/// 2. 前台 App 是否有窗口「铺满」该屏（顶到菜单栏条带、宽≈屏宽、底到屏幕底）。
///    macOS 26+ 起全屏空间里 Menubar 窗口仍在 onScreen 列表（只是视觉滑走），
///    但全屏窗口必然覆盖菜单栏条带；普通桌面的最大化窗口底部会给 Dock 留位，不满足。
///
/// 结论：菜单栏可见 ⇔ Menubar 窗口在屏上 且 前台无铺满窗口。查询失败 fail-open 返回空集。
private struct ScreenBox {
    let id: Int
    let cg: CGRect
    /// 菜单栏预留高度（顶边到可见区上沿）
    let menuBandHeight: CGFloat
}

/// 前台 App 在各屏幕上的窗口分布（按应用记忆位置用）
struct FrontAppLayout {
    let bundleID: String
    let name: String
    /// 前台 App 的 layer-0 窗口铺满（全屏空间）的屏幕
    let coveredDisplays: Set<Int>
    /// 前台 App 有在屏 layer-0 窗口（窗口中心命中）的屏幕
    let windowDisplays: Set<Int>
}

enum SystemClockVisibility {

    /// 系统菜单栏时钟当前可见的屏幕 displayID 集合
    static func visibleDisplayIDs() -> Set<Int> {
        let snapshot = makeSnapshot()
        guard let (windows, boxes, primaryMaxY) = snapshot else { return [] }

        // 信号 1：各屏的 Menubar 窗口是否在屏
        var menubarPresent = Set<Int>()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == Self.menuBarLayer,
                  (window[kCGWindowOwnerName as String] as? String) == Self.windowServer,
                  (window[kCGWindowName as String] as? String) == Self.menuBarName,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            for box in boxes where belongsToDisplay(rect, topOf: box.cg) {
                menubarPresent.insert(box.id)
            }
        }

        // 信号 2：前台 App 铺满各屏（含鼠标贴顶唤出菜单栏的修正）
        let covered = coveredDisplayIDs(windows: windows, boxes: boxes,
                                        primaryMaxY: primaryMaxY, applyReveal: true)

        var result = Set<Int>()
        for box in boxes {
            if menubarPresent.contains(box.id) && !covered.contains(box.id) {
                result.insert(box.id)
            }
        }
        return result
    }

    /// 前台 App 的 layer-0 窗口铺满了哪些屏（全屏空间 / 演示模式）。
    /// 不做鼠标贴顶修正——供「按应用记忆位置」区分全屏 / 窗口状态使用。
    static func displaysCoveredByFrontmostApp() -> Set<Int> {
        guard let (windows, boxes, primaryMaxY) = makeSnapshot() else { return [] }
        return coveredDisplayIDs(windows: windows, boxes: boxes,
                                 primaryMaxY: primaryMaxY, applyReveal: false)
    }

    /// 前台 App（排除本 App 自己）在哪些屏上有窗口、哪些屏被它铺满；无前台应用或它在各屏
    /// 都没有在屏窗口时返回 nil（调用方据此保留切换前的上下文）。一次窗口列表遍历同时得出。
    static func frontAppLayout() -> FrontAppLayout? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let (windows, boxes, _) = makeSnapshot()
        else { return nil }

        var covered = Set<Int>()
        var present = Set<Int>()
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for box in boxes {
                if covers(rect, screen: box) { covered.insert(box.id) }
                if box.cg.contains(center) { present.insert(box.id) }
            }
        }
        // 铺满判定只看窗口几何，窗口中心理论上必在屏内；双保险
        present.formUnion(covered)
        guard !present.isEmpty else { return nil }
        return FrontAppLayout(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            coveredDisplays: covered,
            windowDisplays: present
        )
    }

    private static func makeSnapshot() -> ([[String: Any]], [ScreenBox], CGFloat)? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        guard let primary = NSScreen.screens.first(where: { $0.frame.origin.y == 0 }) else { return nil }
        let primaryMaxY = primary.frame.maxY

        let boxes: [ScreenBox] = NSScreen.screens.map { screen in
            let cg = cgFrame(of: screen, primaryMaxY: primaryMaxY)
            let band = max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
            return ScreenBox(id: screen.displayID, cg: cg, menuBandHeight: band)
        }
        return (windows, boxes, primaryMaxY)
    }

    /// 前台 App 的窗口铺满了哪些屏；applyReveal 时全屏鼠标贴顶唤出菜单栏的屏按未铺满处理
    private static func coveredDisplayIDs(windows: [[String: Any]],
                                          boxes: [ScreenBox],
                                          primaryMaxY: CGFloat,
                                          applyReveal: Bool) -> Set<Int> {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return [] }
        var covered = Set<Int>()

        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int,
                  pid == frontPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }

            for box in boxes where covers(rect, screen: box) {
                covered.insert(box.id)
            }
        }

        guard applyReveal else { return covered }
        // 全屏下鼠标贴顶：菜单栏滑入，时钟暂时可见（移动离开后由 0.25s 防抖恢复隐藏）
        let mouseNS = NSEvent.mouseLocation
        let mouseCG = CGPoint(x: mouseNS.x, y: primaryMaxY - mouseNS.y)
        for box in boxes where covered.contains(box.id) {
            // 必须落在该屏自身的顶边条带内（上方/旁边的显示器坐标不算唤出）
            if mouseCG.y >= box.cg.minY && mouseCG.y <= box.cg.minY + Self.revealStrip
                && mouseCG.x >= box.cg.minX && mouseCG.x <= box.cg.maxX {
                covered.remove(box.id)
            }
        }
        return covered
    }

    /// 窗口是否铺满整屏（菜单栏被它盖住）：
    /// 宽≈屏宽、上沿进入菜单栏条带、底到屏幕底边
    private static func covers(_ rect: CGRect, screen box: ScreenBox) -> Bool {
        let band = max(box.menuBandHeight, Self.fallbackMenuHeight)
        return rect.width >= box.cg.width - 4
            && rect.minX <= box.cg.minX + 4
            && rect.maxX >= box.cg.maxX - 4
            && rect.minY <= box.cg.minY + band + Self.topSlack
            && rect.maxY >= box.cg.maxY - Self.bottomSlack
    }

    /// Menubar 窗口是否属于指定屏幕：宽度基本等于屏宽，且与该屏顶部条带相交
    private static func belongsToDisplay(_ rect: CGRect, topOf frame: CGRect) -> Bool {
        rect.width >= frame.width - 4
            && rect.minY < frame.minY + Self.topStripHeight
            && rect.maxY > frame.minY
    }

    /// NSScreen frame（Cocoa 左下原点）→ CG 全局坐标（主屏左上原点，Y 向下）
    private static func cgFrame(of screen: NSScreen, primaryMaxY: CGFloat) -> CGRect {
        let ns = screen.frame
        return CGRect(
            x: ns.origin.x,
            y: primaryMaxY - ns.origin.y - ns.height,
            width: ns.width,
            height: ns.height
        )
    }

    private static let menuBarLayer = 24 // NSMainMenuWindowLevel
    private static let windowServer = "Window Server"
    private static let menuBarName = "Menubar"
    /// 判定相交用的屏幕顶部条带高度（菜单栏高 24/30/39，留足余量）
    private static let topStripHeight: CGFloat = 60
    /// 副屏可见区不给菜单栏预留时的兜底条带高度
    private static let fallbackMenuHeight: CGFloat = 30
    /// 铺满判定的上/下容差
    private static let topSlack: CGFloat = 6
    private static let bottomSlack: CGFloat = 4
    /// 鼠标距屏幕顶边多少 pt 以内视为「唤出菜单栏」（系统热区约 5pt，warp 常被夹到 y≈3）
    private static let revealStrip: CGFloat = 5
}
