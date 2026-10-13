import AppKit
import Combine
import Foundation
import SwiftUI

struct DisplayInfo: Identifiable, Equatable {
    let id: Int
    let name: String
}

/// 为每块启用的屏幕维护一个 ClockPanel，处理屏幕热插拔、位置与尺寸同步
@MainActor
final class ClockManager: ObservableObject {
    static let shared = ClockManager()

    @Published private(set) var displays: [DisplayInfo] = []

    /// 当前前台应用名（菜单提示用；本 App 自己前台时保留上一个应用）
    @Published private(set) var activeAppName: String?
    /// 最近一次前台应用的逐屏窗口分布；打开我们的菜单/设置时据此保留上下文，时钟不跳动
    private var retainedLayout: FrontAppLayout?

    private let settings = AppSettings.shared
    private var panels: [Int: ClockPanel] = [:]
    private var lastSizes: [Int: NSSize] = [:]
    /// 每块屏时钟的锚点中心：尺寸变化（格式/字号）时围绕它伸缩，保证“改格式不挪位置”。
    /// 不能直接用 panel.frame 的中心——NSHostingView 在某些时机会先按左缘自动调整窗口尺寸。
    private var anchoredCenters: [Int: NSPoint] = [:]
    /// 由代码设置的窗口 frame；与之一致的 didMove 不是用户拖拽，忽略
    private var expectedFrames: [Int: NSRect] = [:]
    private var moveObservers: [Int: NSObjectProtocol] = [:]
    /// 正在拖拽（等待静止落位）的屏幕
    private var pendingDrags = Set<Int>()
    /// 跨屏迁移中「被送回」的原占面板：它的移动全是程序化的（send-back setFrame +
    /// 主题切换后 SwiftUI intrinsic 自 resize），短时间内忽略其 didMove，
    /// 否则会被误判成用户拖拽，给原屏幕写入错误的 .free 位置。
    private var migrationGuard = Set<Int>()
    private var dragPersistWork: [Int: DispatchWorkItem] = [:]
    private var relayoutWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

    /// 每屏当前已生效的位置槽位标识 "bundleID#fs/win"（nil=默认位置），用于切换时去重
    private var appliedSlotPerDisplay: [Int: String?] = [:]
    /// 因系统菜单栏时钟可见而被我们 orderOut 的屏幕（面板对象仍保留在 panels 里）
    private var autoHidden = Set<Int>()
    /// 隐藏防抖任务：菜单栏短暂滑入（鼠标划过顶边）不立即隐藏
    private var hideWorkItems: [Int: DispatchWorkItem] = [:]
    private var visibilityTimer: Timer?

    /// 每块屏的生效外观（独立外观或全局快照）
    private var themes: [Int: DisplayTheme] = [:]
    /// 每块屏的离屏测量器：ClockView 的理想尺寸
    private var measurers: [Int: NSHostingController<ClockView>] = [:]

    private init() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconcile()
            }
            .store(in: &cancellables)

        // 必须 receive(on:)：@Published 在 willSet 阶段发送，同步闭包里读到的还是旧值。
        settings.$windowLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.panels.values.forEach { $0.level = level.nsLevel }
            }
            .store(in: &cancellables)

        settings.$enabledDisplays
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)

        // 自动隐藏开关变化：开启则立即重判，关闭则 updateAutoHide 会恢复全部面板
        settings.$autoHideWithClock
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateAutoHide() }
            .store(in: &cancellables)

        // 按应用记忆位置总开关：清掉槽位缓存并立即按当前前台应用重摆
        settings.$perAppPositionEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reattachAppPositions() }
            .store(in: &cancellables)

        // 前台 App / 空间切换时菜单栏可见性可能立即变化：立刻查一次 + 0.6s 后复查（等切换动画）
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            let observer = workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleFrontmostAppChange()
                    self?.updateAutoHide()
                    // 全屏空间切换动画中窗口 frame 尚未稳定：0.6s 后重查前台 App 并复查显隐
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.handleFrontmostAppChange()
                        self?.updateAutoHide()
                    }
                }
            }
            workspaceObservers.append(observer)
        }

        // 注意：不能订阅 $positionsByDisplay 来重排窗口——拖拽落位本身也会写入位置，
        // 且 @Published 在 willSet 阶段发送，闭包里读到的是旧值，会把刚拖放的时钟弹回预设位。
        // UI 侧的位置改走 applyPosition(_:for:) 显式移动单块面板。

        // 尺寸相关的重排统一由各屏 DisplayTheme 的「解析后外观」变化驱动
        // （全局设置、独立快照、独立开关切换都会体现为 style 变化；回调在 createPanel 里挂接）。
        // 不能直接订阅 AppSettings：style 经 receive(on:) 晚一个 RunLoop 才更新，
        // 提前测量会读到旧尺寸并白白消耗掉这次触发。格式串防抖也已在 theme 内完成。

        // 此时 App 可能尚在 willFinishLaunching，不能创建 NSWindow，延迟到本轮 RunLoop 结束后
        DispatchQueue.main.async { [weak self] in
            self?.startVisibilityTimer()
            self?.reconcile()
            // 开机自启直接进入某应用全屏空间时，出生即按其专属位置摆放
            self?.handleFrontmostAppChange()
        }
    }

    // MARK: - 按应用记忆位置

    /// 前台应用的逐屏窗口分布；本 App 自己前台时保留上一份
    private func currentLayout() -> FrontAppLayout? {
        SystemClockVisibility.frontAppLayout() ?? retainedLayout
    }

    /// 前台 App / 全屏状态 / 窗口所在屏变化时把时钟切到对应槽位。
    /// 通知可能漏发（全屏切换无可靠通知），0.5s 轮询也调本方法；各屏按槽位 id 去重。
    private func handleFrontmostAppChange() {
        if let layout = SystemClockVisibility.frontAppLayout() {
            retainedLayout = layout
            activeAppName = layout.name
        }
        refreshAppPositions()
    }

    /// 菜单打开时强制刷新一次（应用名/状态不及时的兜底入口）
    func refreshActiveAppForMenu() {
        handleFrontmostAppChange()
    }

    /// 开关总闸：各屏强制移动到当前应生效的位置（关时回默认，开时恢复存档槽位）。
    /// 不能只清缓存走 refreshAppPositions——缓存与目标都为 nil 时去重会跳过本需移动的面板。
    private func reattachAppPositions() {
        for screen in NSScreen.screens {
            let id = screen.displayID
            guard let panel = panels[id], !pendingDrags.contains(id) else { continue }
            let placement = effectivePlacement(for: screen)
            appliedSlotPerDisplay[id] = placement.identity
            let origin = PositionMath.origin(
                for: panel.frame.size,
                in: placement.container,
                position: placement.position
            )
            setOrigin(origin, id: id, on: panel)
        }
    }

    /// 该屏当前应生效的位置 + 归一化容器 + 槽位 id。
    /// 全屏槽以屏幕完整 frame 为容器（全屏空间可放到真正的顶角），
    /// 窗口槽与默认位置以 visibleFrame 为容器（避开菜单栏 / Dock）。
    private func effectivePlacement(for screen: NSScreen)
        -> (position: PanelPosition, container: NSRect, identity: String?) {
        let id = screen.displayID
        if settings.perAppPositionEnabled,
           let layout = currentLayout(),
           layout.windowDisplays.contains(id),
           let slot = settings.appPosition(
               for: id, bundleID: layout.bundleID,
               fullscreen: layout.coveredDisplays.contains(id)) {
            let fullscreen = layout.coveredDisplays.contains(id)
            return (slot,
                    fullscreen ? screen.frame : screen.visibleFrame,
                    slotIdentity(layout.bundleID, fullscreen))
        }
        return (settings.position(for: id), screen.visibleFrame, nil)
    }

    private func slotIdentity(_ bundleID: String, _ fullscreen: Bool) -> String {
        "\(bundleID)#\(fullscreen ? "fs" : "win")"
    }

    /// 按当前前台应用的逐屏分布把各屏时钟移到应生效的位置；槽位相同则跳过
    private func refreshAppPositions() {
        for screen in NSScreen.screens {
            let id = screen.displayID
            guard let panel = panels[id], !pendingDrags.contains(id) else { continue }
            let placement = effectivePlacement(for: screen)
            // 缺省的缓存按 nil（默认位置）看待，避免首刷无谓地重摆一次
            let cached = appliedSlotPerDisplay[id] ?? nil
            guard cached != placement.identity else { continue }
            appliedSlotPerDisplay[id] = placement.identity
            let origin = PositionMath.origin(
                for: panel.frame.size,
                in: placement.container,
                position: placement.position
            )
            setOrigin(origin, id: id, on: panel)
        }
    }

    /// 设置页清除某应用的全部专属位置；若它是某屏当前生效项，该屏立即回默认位置
    func clearOverride(displayID: Int, bundleID: String) {
        settings.clearAppPosition(for: displayID, bundleID: bundleID)
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }),
              let panel = panels[displayID],
              currentLayout()?.bundleID == bundleID else { return }
        let placement = effectivePlacement(for: screen)
        appliedSlotPerDisplay[displayID] = placement.identity
        let origin = PositionMath.origin(
            for: panel.frame.size,
            in: placement.container,
            position: placement.position
        )
        setOrigin(origin, id: displayID, on: panel)
    }

    // MARK: - 随系统菜单栏自动隐藏

    private func startVisibilityTimer() {
        guard visibilityTimer == nil else { return }
        // 轮询负责捕获鼠标顶边唤出/收起菜单栏、全屏切换这类无（或漏掉的）通知变化；
        // App / 空间切换另由通知即时触发
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleFrontmostAppChange()
                self?.updateAutoHide()
            }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    /// - Parameter immediateHide: 仅面板创建/对账路径用：出生即藏不等待防抖，
    ///   避免桌面启动时时钟闪一下；事件/轮询路径走 0.25s 防抖，鼠标短暂划过顶边不隐藏
    private func updateAutoHide(immediateHide: Bool = false) {
        let shouldHide = settings.autoHideWithClock ? SystemClockVisibility.visibleDisplayIDs() : []

        for (id, panel) in panels {
            if shouldHide.contains(id) {
                // 正在拖拽中的面板不能藏（用户正抓着）；拖拽落位后下一轮轮询会处理
                guard !autoHidden.contains(id),
                      hideWorkItems[id] == nil,
                      !pendingDrags.contains(id) else { continue }
                if immediateHide {
                    // reconcile 路径：面板刚 orderFront，同一调用栈立刻撤下，一帧都不闪
                    panel.orderOut(nil)
                    autoHidden.insert(id)
                    continue
                }
                let work = DispatchWorkItem { [weak self, weak panel] in
                    guard let self, let panel else { return }
                    self.hideWorkItems.removeValue(forKey: id)
                    // 防抖延迟后复查：菜单栏只是短暂滑入（鼠标划过顶边）就不隐藏
                    guard self.settings.autoHideWithClock,
                          !self.pendingDrags.contains(id),
                          SystemClockVisibility.visibleDisplayIDs().contains(id) else { return }
                    panel.orderOut(nil)
                    self.autoHidden.insert(id)
                }
                hideWorkItems[id] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            } else {
                hideWorkItems.removeValue(forKey: id)?.cancel()
                guard autoHidden.contains(id) else { continue }
                autoHidden.remove(id)
                panel.orderFrontRegardless()
                scheduleRelayout()
            }
        }
    }

    // MARK: - 对外操作

    /// 用户在菜单/设置里为某块屏幕选定位置：持久化并立即移动该面板。
    /// 总开关开启、该屏当前有前台应用上下文时（含打开设置前保留的上下文），
    /// 写入该应用的全屏/窗口槽位而非默认位置。
    func applyPosition(_ position: PanelPosition, for displayID: Int) {
        dragPersistWork.removeValue(forKey: displayID)?.cancel()
        pendingDrags.remove(displayID)
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }),
              let panel = panels[displayID] else { return }

        // 该屏上当前有前台应用的窗口时，九宫格写入该应用对应槽位；否则写默认位置
        let layout = currentLayout()
        let fullscreen = layout?.coveredDisplays.contains(displayID) ?? false
        if settings.perAppPositionEnabled,
           let layout, layout.windowDisplays.contains(displayID) {
            settings.setAppPosition(position, for: displayID,
                                    bundleID: layout.bundleID, fullscreen: fullscreen)
            appliedSlotPerDisplay[displayID] = slotIdentity(layout.bundleID, fullscreen)
        } else {
            settings.setPosition(position, for: displayID)
            appliedSlotPerDisplay[displayID] = nil
        }

        let container: NSRect = fullscreen && settings.perAppPositionEnabled
            && layout?.windowDisplays.contains(displayID) == true
            ? screen.frame : screen.visibleFrame
        let origin = PositionMath.origin(
            for: panel.frame.size,
            in: container,
            position: position
        )
        setOrigin(origin, id: displayID, on: panel)
    }

    // MARK: - 屏幕对账

    private func reconcile() {
        refreshDisplayList()

        let screens = NSScreen.screens
        let activeIDs = Set(screens.map(\.displayID))

        for (id, panel) in panels where !activeIDs.contains(id) || !settings.isEnabled(id) {
            if let observer = moveObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(observer)
            }
            panel.close()
            panels.removeValue(forKey: id)
            themes.removeValue(forKey: id)
            measurers.removeValue(forKey: id)
            lastSizes.removeValue(forKey: id)
            anchoredCenters.removeValue(forKey: id)
            expectedFrames.removeValue(forKey: id)
            pendingDrags.remove(id)
            migrationGuard.remove(id)
            autoHidden.remove(id)
            appliedSlotPerDisplay.removeValue(forKey: id)
            hideWorkItems.removeValue(forKey: id)?.cancel()
            dragPersistWork.removeValue(forKey: id)?.cancel()
        }

        for screen in screens where settings.isEnabled(screen.displayID) && panels[screen.displayID] == nil {
            createPanel(on: screen)
        }

        // 显示器 geometry 可能整体变化（分辨率/菜单栏），重新对齐（拖拽中的屏跳过）
        applyStoredPositions()
        // 热插拔后按当前前台应用重新决定各屏专属位置（新屏缓存为空，首次不会空摆）
        refreshAppPositions()
        scheduleRelayout()
        // 新创建的面板若出生在菜单栏可见的桌面（主屏默认态），同一 RunLoop 立即藏掉，避免闪现
        updateAutoHide(immediateHide: true)
    }

    private func refreshDisplayList() {
        displays = NSScreen.screens.map { screen in
            DisplayInfo(id: screen.displayID, name: screen.localizedName)
        }
    }

    private func createPanel(on screen: NSScreen) {
        let id = screen.displayID
        let theme = themes[id] ?? DisplayTheme(displayID: id)
        themes[id] = theme
        theme.onStyleChange = { [weak self] in
            self?.scheduleRelayout()
        }
        let measurer = measurers[id] ?? NSHostingController(rootView: ClockView(theme: theme))
        measurers[id] = measurer

        // 离屏初测只用于 orderFront 前的首帧位置；上屏后 layout() 会用面板宿主复测纠正。
        // 出生即按当前前台应用的专属位置摆（开机自启进全屏应用时首帧就不闪错位置）。
        let fitting = measuredFittingSize(measurer.view as! NSHostingView<ClockView>)
        let birth = effectivePlacement(for: screen)
        let origin = PositionMath.origin(
            for: fitting,
            in: birth.container,
            position: birth.position
        )
        appliedSlotPerDisplay[id] = birth.identity

        // 必须用目标屏最终坐标 + defer:true 一次性创建并上屏（见 ClockPanel.init 注释），
        // 不能先建占位窗口再跨屏 setFrame，也不能上屏后再挂 SwiftUI 内容。
        let panel = ClockPanel(
            finalFrame: NSRect(origin: origin, size: fitting),
            level: settings.windowLevel.nsLevel,
            theme: theme
        )

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            Task { @MainActor in
                // id 可能因跨屏拖拽迁移而改变，按面板实例反查当前归属
                guard let currentID = self.panels.first(where: { $0.value === panel })?.key else { return }
                self.panelDidMove(id: currentID, panel: panel)
            }
        }
        moveObservers[id] = observer

        panels[id] = panel
        lastSizes[id] = fitting
        anchoredCenters[id] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        expectedFrames[id] = panel.frame

        panel.orderFrontRegardless()
        // reconcile 末尾的 scheduleRelayout() 会在下一个 RunLoop 用面板宿主复测纠正首帧
    }

    private func measuredFittingSize<V: View>(_ hosting: NSHostingView<V>) -> NSSize {
        // 上屏后的 hosting view 已按目标屏渲染，intrinsicContentSize 即理想尺寸；
        // 不能用离屏 NSHostingController.sizeThatFits——副屏会得到主屏上下文的尺寸。
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if size.width > 1, size.height > 1 { return size }
        return hosting.intrinsicContentSize
    }

    // MARK: - 布局

    private func scheduleRelayout() {
        relayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.relayoutAll()
        }
        relayoutWork = work
        // 等 SwiftUI 完成本轮刷新再测量
        DispatchQueue.main.async(execute: work)
    }

    private func relayoutAll() {
        for screen in NSScreen.screens {
            guard let panel = panels[screen.displayID],
                  !pendingDrags.contains(screen.displayID) else { continue }
            layout(panel: panel, on: screen, forced: false)
        }
    }

    private func applyStoredPositions() {
        for screen in NSScreen.screens {
            guard let panel = panels[screen.displayID],
                  !pendingDrags.contains(screen.displayID) else { continue }
            let placement = effectivePlacement(for: screen)
            let origin = PositionMath.origin(
                for: panel.frame.size,
                in: placement.container,
                position: placement.position
            )
            setOrigin(origin, id: screen.displayID, on: panel)
        }
    }

    /// forced=false 时仅在尺寸变化后重排（避免透明度等无关设置触发跳动）
    private func layout(panel: ClockPanel, on screen: NSScreen, forced: Bool) {
        let id = screen.displayID
        // 以上屏后的面板自身宿主测量为准：离屏 NSHostingController 在副屏上会按主屏上下文
        // 量出主屏外观的尺寸（独立外观的字号/格式不同），导致初摆位按错误宽度贴边。
        // 上屏后的 hosting 带着该屏的主题与 backingScale，结果可靠。
        panel.hosting.layoutSubtreeIfNeeded()
        var fitting = measuredFittingSize(panel.hosting)
        guard fitting.width > 0, fitting.height > 0 else { return }

        if !forced, let last = lastSizes[screen.displayID] {
            let measuredUnchanged = abs(last.width - fitting.width) < 0.5
                && abs(last.height - fitting.height) < 0.5
            if measuredUnchanged {
                // 测量值与上次相同，但窗口实际 frame 已不同：orderFront 后的首个 SwiftUI
                // transaction 刚按目标屏 intrinsic 自 resize，fittingSize 还短暂报旧值。
                // 以窗口实际尺寸为准补一次定位；普通“测量值变小”的场景不会走到这里。
                if abs(panel.frame.width - last.width) > 0.5
                    || abs(panel.frame.height - last.height) > 0.5 {
                    fitting = panel.frame.size
                } else {
                    return
                }
            }
        }

        lastSizes[id] = fitting

        let placement = effectivePlacement(for: screen)
        let position = placement.position
        let origin = PositionMath.origin(
            for: fitting,
            in: placement.container,
            position: position
        )
        var resolvedOrigin = origin
        if !forced {
            let vf = placement.container
            // 自由拖拽位：围绕落位时记录的锚点中心伸缩；不能用启动时夹取过的 frame 中心，
            // 否则大字号启动会把锚点永久推离屏幕边缘，缩回去也回不到原位。
            if case .free = position {
                let center = anchoredCenters[id]
                    ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY)
                resolvedOrigin = NSPoint(x: center.x - fitting.width / 2,
                                         y: center.y - fitting.height / 2)
            }
            // 预设位天然贴边锚定（PositionMath 已按新尺寸重算）；此处只做越界夹取，
            // 大字号超出屏幕时至少保持左/上缘可见。
            let minX = vf.minX + PositionMath.margin
            let maxX = vf.maxX - PositionMath.margin - fitting.width
            let minY = vf.minY + PositionMath.margin
            let maxY = vf.maxY - PositionMath.margin - fitting.height
            resolvedOrigin.x = Swift.min(Swift.max(resolvedOrigin.x, minX), Swift.max(minX, maxX))
            resolvedOrigin.y = Swift.min(Swift.max(resolvedOrigin.y, minY), Swift.max(minY, maxY))
        }
        // 同屏内调整尺寸/位置是安全的（已挂载内容的窗口跨屏 setFrame 同样安全，勿在挂载前跨屏）
        let target = NSRect(origin: resolvedOrigin, size: fitting)
        expectedFrames[id] = target
        panel.setFrame(target, display: true, animate: false)
        expectedFrames[id] = panel.frame
        // 锚点保持为期望中心（不按夹取后的实际位置改），切回窄格式才能回到原位
    }

    private func setOrigin(_ origin: NSPoint, id: Int, on panel: ClockPanel) {
        var frame = panel.frame
        guard abs(frame.origin.x - origin.x) > 0.5 || abs(frame.origin.y - origin.y) > 0.5 else { return }
        frame.origin = origin
        expectedFrames[id] = frame
        panel.setFrame(frame, display: true, animate: false)
        expectedFrames[id] = panel.frame
        anchoredCenters[id] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    // MARK: - 拖拽落位

    private func panelDidMove(id: Int, panel: ClockPanel) {
        // 跨屏迁移后被送回的原占面板：一切移动皆程序化，禁止误判为拖拽
        // （此刻用户可能正按着鼠标拖另一块面板，所以此判断必须在鼠标判断之前）
        guard !migrationGuard.contains(id) else { return }
        // 只有鼠标按住期间的移动才可能是用户拖拽：orderFront / intrinsic 自 resize 等
        // 程序化 didMove 即使漏过下面的 frame 过滤，也绝不能写成用户落位
        guard NSEvent.pressedMouseButtons != 0 else { return }
        // setFrame override 进行中的同步通知、以及与目标 frame 一致的通知，都是程序化移动
        guard !panel.isApplyingFrame else { return }
        if let expected = expectedFrames[id], framesEqual(expected, panel.frame) {
            return
        }
        // 用户开始拖动：取消隐藏倒计时（面板正在被使用）；落位后由轮询重新判定
        hideWorkItems.removeValue(forKey: id)?.cancel()

        // 允许把时钟拖到另一块屏幕上：归属迁移到窗口当前所在屏幕
        let targetScreen = panel.screen ?? NSScreen.screens.first(where: { $0.displayID == id })
        guard let screen = targetScreen else { return }
        let targetID = screen.displayID

        if targetID != id {
            migratePanel(panel, from: id, to: targetID)
        }

        pendingDrags.insert(targetID)
        dragPersistWork[targetID]?.cancel()

        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            // 拖拽期间可能发生跨屏迁移，落位时按面板当前归属动态解析，不能用闭包捕获的旧 id/screen
            let currentID = self.panels.first(where: { $0.value === panel })?.key ?? targetID
            guard let currentScreen = NSScreen.screens.first(where: { $0.displayID == currentID }) else { return }
            // 落位屏上有前台应用的窗口时记该应用的槽位（全屏槽按整屏 frame 归一化，
            // 窗口槽按 visibleFrame）；该屏没有前台应用窗口时只改默认位置。
            // 拖拽非激活面板不会让我们自己变前台；本 App 在前台时退回保留的上下文。
            let layout = self.currentLayout()
            let fullscreen = layout?.coveredDisplays.contains(currentID) ?? false
            let toAppSlot = self.settings.perAppPositionEnabled
                && layout?.windowDisplays.contains(currentID) == true
            let container: NSRect = toAppSlot && fullscreen
                ? currentScreen.frame : currentScreen.visibleFrame
            let point = PositionMath.normalizedCenter(frame: panel.frame, in: container)
            // 先写位置再解除 pending；位置写入不会触发窗口重排（无订阅），避免弹回。
            if toAppSlot, let layout {
                self.settings.setAppPosition(.free(x: point.x, y: point.y),
                                             for: currentID, bundleID: layout.bundleID,
                                             fullscreen: fullscreen)
                self.appliedSlotPerDisplay[currentID] =
                    self.slotIdentity(layout.bundleID, fullscreen)
            } else {
                self.settings.setPosition(.free(x: point.x, y: point.y), for: currentID)
                self.appliedSlotPerDisplay[currentID] = nil
            }
            self.anchoredCenters[currentID] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            self.pendingDrags.remove(currentID)
        }
        dragPersistWork[targetID] = work
        // 停止移动 0.25 秒后落位为自定义位置
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 面板被拖到另一块屏幕：把它连同观察器/状态改挂到新屏幕 id。
    /// 若目标屏已有面板，则两块面板交换屏幕归属（原占面板送回拖出屏）。
    private func migratePanel(_ panel: ClockPanel, from oldID: Int, to newID: Int) {
        // 旧屏幕 key 下还挂着跨屏前调度的落位任务，闭包捕获的旧坐标会写出脏位置
        dragPersistWork[oldID]?.cancel()
        dragPersistWork.removeValue(forKey: oldID)
        pendingDrags.remove(oldID)
        hideWorkItems.removeValue(forKey: oldID)?.cancel()
        hideWorkItems.removeValue(forKey: newID)?.cancel()
        let occupantWasHidden = autoHidden.contains(newID)
        autoHidden.remove(oldID)
        autoHidden.remove(newID)
        // 被拖面板全程处于拖拽态：紧随其后的 refreshAppPositions 不得移动它
        pendingDrags.insert(newID)

        if let occupant = panels[newID], occupant !== panel {
            // 原占面板接下来会被程序化送回 + 因主题切换自 resize，短暂屏蔽其拖拽判定
            migrationGuard.insert(oldID)
            panels[oldID] = occupant
            panels[newID] = panel
            let observer = moveObservers[oldID]
            moveObservers[oldID] = moveObservers[newID]
            moveObservers[newID] = observer
            let size = lastSizes[oldID]
            lastSizes[oldID] = lastSizes[newID]
            lastSizes[newID] = size
            // 主题与测量器跟随各自面板交换屏幕归属，再按新 id 重新解析独立外观
            let movedTheme = themes[oldID]
            let occupantTheme = themes[newID]
            themes[newID] = movedTheme
            themes[oldID] = occupantTheme
            movedTheme?.reassign(displayID: newID)
            occupantTheme?.reassign(displayID: oldID)
            let movedMeasurer = measurers[oldID]
            let occupantMeasurer = measurers[newID]
            measurers[newID] = movedMeasurer
            measurers[oldID] = occupantMeasurer
            // 被拖面板沿用它当前落点作为锚点；原占面板的锚点随归属换到 oldID，稍后按送回位置重算
            anchoredCenters[newID] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            expectedFrames[oldID] = nil
            expectedFrames[newID] = nil

            // 原占面板若因菜单栏可见被 orderOut 过，必须先恢复显示，setFrame 不会让窗口上屏
            if occupantWasHidden {
                occupant.orderFrontRegardless()
            }

            // 原占面板送回拖出屏（已挂载内容的窗口跨屏 setFrame 是安全的）
            if let oldScreen = NSScreen.screens.first(where: { $0.displayID == oldID }) {
                let frame = occupant.frame
                let placement = effectivePlacement(for: oldScreen)
                let origin = PositionMath.origin(
                    for: frame.size,
                    in: placement.container,
                    position: placement.position
                )
                let target = NSRect(origin: origin, size: frame.size)
                // 先登记期望 frame，跨屏移动途中的 didMove 才不会被误判为又一次拖拽
                expectedFrames[oldID] = target
                occupant.setFrame(target, display: true, animate: false)
                expectedFrames[oldID] = occupant.frame
                anchoredCenters[oldID] = NSPoint(x: occupant.frame.midX, y: occupant.frame.midY)
            }
            // 归属交换后两屏生效的槽位缓存全部失效：被拖面板拖拽中会跳过，
            // 原占面板立即按 oldID 的生效位置（可能是专属位置）重摆
            appliedSlotPerDisplay.removeValue(forKey: oldID)
            appliedSlotPerDisplay.removeValue(forKey: newID)
            refreshAppPositions()
            updateAutoHide()
            // 主题切换的 intrinsic 自 resize（~120ms 防抖 + 一帧）完成后解除屏蔽并补一次定位
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.migrationGuard.remove(oldID)
                self?.scheduleRelayout()
                self?.refreshAppPositions()
                // 两块面板已交换屏幕：按新屏幕的菜单栏可见性重新决定显隐
                self?.updateAutoHide()
            }
            return
        }

        if let observer = moveObservers.removeValue(forKey: oldID) {
            moveObservers[newID] = observer
        }
        panels.removeValue(forKey: oldID)
        panels[newID] = panel
        if let size = lastSizes.removeValue(forKey: oldID) {
            lastSizes[newID] = size
        }
        if let theme = themes.removeValue(forKey: oldID) {
            themes[newID] = theme
            theme.reassign(displayID: newID)
        }
        if let measurer = measurers.removeValue(forKey: oldID) {
            measurers[newID] = measurer
        }
        anchoredCenters.removeValue(forKey: oldID)
        anchoredCenters[newID] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        expectedFrames.removeValue(forKey: oldID)
        // 被拖面板在 pendingDrags 中会跳过；落位后按当时的前台应用写入并更新缓存
        appliedSlotPerDisplay.removeValue(forKey: oldID)
        appliedSlotPerDisplay.removeValue(forKey: newID)
        refreshAppPositions()
        updateAutoHide()
    }

    private func framesEqual(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= 0.5
            && abs(a.origin.y - b.origin.y) <= 0.5
            && abs(a.size.width - b.size.width) <= 0.5
            && abs(a.size.height - b.size.height) <= 0.5
    }
}
