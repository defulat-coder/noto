// 屏幕边缘的屏幕边缘：液态玻璃 / 纯黑表面，悬停展开「今日任务」「写一笔」，
// 两端弧线负责移动与设置，悬停待办 / 录入时出现玻璃描述卡；不抢焦点。
//
// 稳定性的关键：窗口尺寸固定为最大展开态、位置只在启动/换边/拖动/换屏时变化，
// 悬停只驱动窗口内部剪影的 SwiftUI 形变——窗口级的 frame 动画是发抖的根源。
// 非激活面板、⌥ 拖动贴边、光标监视与全屏检测的窗口机制改编自 codenotch（MIT License，© vinzdg）
// https://github.com/vinzdg/codenotch

import AppKit
import SwiftUI
import NotoCore

/// 药丸吸附在哪条屏幕边。默认右侧，⌥ 拖动只沿这条边移动。
enum PillEdge: String, CaseIterable, Identifiable {
    case left, right, top, bottom

    var id: String { rawValue }
    var label: String {
        switch self { case .left: "左侧"; case .right: "右侧"; case .top: "顶部"; case .bottom: "底部" }
    }
    var isVertical: Bool { self == .left || self == .right }
}

/// 无边框、非激活的面板。nonactivatingPanel 加 canBecomeKey = false，
/// 让瞥一眼待办永远不会抢走当前应用的焦点；statusBar 层级让它盖住普通窗口。
final class PillPanel: NSPanel {
    var contextMenuProvider: (() -> NSMenu?)?
    /// 展开状态下落在元素上的单击。SwiftUI 的视图会自己消费部分事件，这里只接住空白处的点击。
    var onClick: ((CGPoint) -> Void)?
    /// ⌥ 拖动时上报的原始位移增量；松手后由 onDragEnd 持久化。
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var canCarry: ((CGPoint) -> Bool)?
    var onDragStart: ((Bool) -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        title = "Noto 屏幕边缘"
        identifier = NSUserInterfaceItemIdentifier("noto-edge")
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isInteracting = false

    // Route chrome gestures before SwiftUI's subviews consume them.
    override func sendEvent(_ event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.sendEvent(event)
        }
        if event.type == .rightMouseDown, let menu = contextMenuProvider?() {
            isInteracting = true
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            isInteracting = false
        } else if event.type == .leftMouseDown {
            let carry = canCarry?(localPoint(fromWindow: event.locationInWindow)) == true && !event.modifierFlags.contains(.option)
            if event.modifierFlags.contains(.option) || carry {
                isInteracting = true
                onDragStart?(carry)
                trackOptionDrag()
                isInteracting = false
            } else { onClick?(localPoint(fromWindow: event.locationInWindow)) }
        } else { super.sendEvent(event) }
    }

    /// 窗口底边原点换成面板左上原点，与 SwiftUI 的翻转坐标一致。
    private func localPoint(fromWindow point: NSPoint) -> CGPoint {
        guard let size = contentView?.bounds.size else { return .zero }
        return CGPoint(x: point.x, y: size.height - point.y)
    }

    /// 阻塞读取本窗口的事件流直到松手，是 AppKit 自定义拖动的标准做法。
    private func trackOptionDrag() {
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch event.type {
            case .leftMouseDragged: onDrag?(event.deltaX, -event.deltaY)
            case .leftMouseUp: onDragEnd?(); return
            default: return
            }
        }
    }
}

// A plain content container prevents NSHostingView's ideal size from resizing
// the NSPanel. Adapted from Codenotch's NotchContainerView (MIT).
final class PillContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return subviews.reversed().compactMap { $0.hitTest(local) }.first
    }
}

final class PillHostingView: NSHostingView<PillRootView> {
    var interactiveRects: [CGRect] = []
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
}

// AppKit screen coordinates have a bottom-left origin; panel content is flipped.
// Keep positioning and persistence inverse operations on all four edges.
enum PillPlacement {
    static func nearestEdge(point: CGPoint, screen: CGRect) -> PillEdge {
        let distances: [(PillEdge, CGFloat)] = [(.left, abs(point.x - screen.minX)), (.right, abs(screen.maxX - point.x)), (.top, abs(screen.maxY - point.y)), (.bottom, abs(point.y - screen.minY))]
        return distances.min { $0.1 < $1.1 }!.0
    }
    static func frame(screen: CGRect, size: CGSize, edge: PillEdge, offset: Double, anchor: CGFloat) -> CGRect {
        let along = edge.isVertical ? screen.height : screen.width
        let extent = edge.isVertical ? size.height : size.width
        let position = min(max(CGFloat(offset) * along - anchor, 0), max(0, along - extent))
        switch edge {
        case .left: return CGRect(x: screen.minX, y: screen.minY + position, width: size.width, height: size.height).integral
        case .right: return CGRect(x: screen.maxX - size.width, y: screen.minY + position, width: size.width, height: size.height).integral
        case .top: return CGRect(x: screen.minX + position, y: screen.maxY - size.height, width: size.width, height: size.height).integral
        case .bottom: return CGRect(x: screen.minX + position, y: screen.minY, width: size.width, height: size.height).integral
        }
    }
    static func offset(frame: CGRect, screen: CGRect, edge: PillEdge, anchor: CGFloat) -> Double {
        let value = edge.isVertical ? (frame.minY + anchor - screen.minY) / max(1, screen.height) : (frame.minX + anchor - screen.minX) / max(1, screen.width)
        return min(max(value, 0), 1)
    }
}

/// 前台应用是否正在指定屏幕上全屏。
/// 只认「窗口完全覆盖整块屏幕」这一种信号：原生全屏的窗口边界就是整块屏幕。
/// codenotch 原实现还接受「从菜单栏下方开始、贴到屏幕底」的窗口，那会把
/// 最大化（但非全屏）的普通应用误判成全屏，让药丸在最常用的前台场景消失。
enum PillFullscreen {
    static func isFrontmostAppFullScreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }

        // AppKit 坐标（主屏左下为原点）换成 CoreGraphics 坐标（左上为原点）再比较窗口框。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let bounds = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict)
            else { continue }
            let coversScreen = abs(b.origin.x - bounds.origin.x) <= 4
                && abs(b.origin.y - bounds.origin.y) <= 4
                && abs(b.width - bounds.width) <= 4
                && abs(b.height - bounds.height) <= 4
            if coversScreen { return true }
        }
        return false
    }
}

@MainActor
final class PillController: NSObject {
    // 几何常量（面板点）。across = 离屏幕边框的进深，along = 沿边方向。
    // 窗口固定为最大展开尺寸，悬停只改变内部剪影，不再改变窗口框。
    static let collapsedAcross: CGFloat = 26 * PillMetrics.scale
    static let collapsedLength: CGFloat = 210 * PillMetrics.scale
    nonisolated static let barAcross: CGFloat = PillMetrics.depth
    static let barLength: CGFloat = PillMetrics.length + 64
    static let bodyLength: CGFloat = PillMetrics.length
    static let bodyStart: CGFloat = PillMetrics.start
    static let tabAlong: CGFloat = bodyStart + (bodyLength - collapsedLength) / 2
    static let cardGap: CGFloat = 10.5
    static let cardAcross: CGFloat = 254.2
    static let arcMargin: CGFloat = 0

    static func windowSize(for edge: PillEdge) -> CGSize {
        edge.isVertical
            ? CGSize(width: ceil(barAcross + cardGap + cardAcross), height: ceil(PillMetrics.length(for: edge) + 64))
            : CGSize(width: ceil(PillMetrics.length(for: edge) + 64), height: ceil(PillMetrics.depth(for: edge) + cardGap + 272))
    }

    /// 光标离开后收起的宽限。
    private let foldGrace: TimeInterval = 0.5

    let model = PillModel()
    private(set) weak var appModel: AppModel?
    private(set) var panel: PillPanel?
    private var hosting: PillHostingView?
    var showWindow: (() -> Void)?
    private var pollTimer: Timer?
    private var foldWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    private let defaults: UserDefaults
    private var started = false
    private var tick = 0

    init(appModel: AppModel, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appModel = appModel
        super.init()
        model.controller = self
        model.edge = savedEdge
    }

    deinit {
        pollTimer?.invalidate()
        foldWork?.cancel()
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private var edge: PillEdge { model.edge }
    private var savedEdge: PillEdge { PillEdge(rawValue: defaults.string(forKey: "pillEdge") ?? "") ?? .right }

    private var alwaysExpanded: Bool { defaults.string(forKey: "pillVisibility") == "always" }

    private var enabled: Bool { defaults.object(forKey: "pillEnabled") as? Bool ?? true }

    /// 凸舌中点在沿边方向上的落点（占屏长比例）。
    private var offset: CGFloat {
        get { defaults.object(forKey: "pillOffset." + edge.rawValue) as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "pillOffset." + edge.rawValue) }
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncWithSettings() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateForFullscreen() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateForFullscreen() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncWithSettings() }
        })
        // 光标不会为了停在原地而产生事件，所以慢速轮询兜底；全局监视器负责快速响应移动。
        pollTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.cursorMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
        syncWithSettings()
    }

    // MARK: - 面板生命周期

    private func syncWithSettings() {
        guard !model.isMoving else { return }
        let changedEdge = model.edge != savedEdge
        if changedEdge { setExpanded(false, animate: false) }
        model.edge = savedEdge
        if enabled {
            if panel == nil { createPanel() }
            let glassy = defaults.string(forKey: "pillSurface") != "black" && PillGlass.available && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            panel?.appearance = glassy ? nil : NSAppearance(named: .darkAqua)
            reposition()
            updateForFullscreen()
            model.refresh(force: true)
            if alwaysExpanded, panel?.isVisible == true { setExpanded(true, animate: false) }
            cursorMoved()
        } else {
            panel?.orderOut(nil)
            panel = nil
            hosting = nil
            setExpanded(false, animate: false)
        }
    }

    private func createPanel() {
        let size = Self.windowSize(for: edge)
        let panel = PillPanel(contentRect: CGRect(origin: .zero, size: size))
        let container = PillContainerView(frame: CGRect(origin: .zero, size: size))
        let hosting = PillHostingView(rootView: PillRootView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        container.addSubview(hosting)
        panel.contentView = container
        self.hosting = hosting
        panel.onClick = { [weak self] local in self?.handleClick(local: local) }
        panel.contextMenuProvider = { [weak self] in self?.makeMenu() }
        panel.onDrag = { [weak self] dx, dy in self?.drag(byDx: dx, dy: dy) }
        panel.canCarry = { [weak self] local in self?.model.expanded == true && self?.elementRect(.move).contains(local) == true }
        panel.onDragStart = { [weak self] carry in
            self?.foldWork?.cancel(); self?.foldWork = nil
            self?.model.isMoving = carry
        }
        panel.onDragEnd = { [weak self] in
            guard let self else { return }
            self.defaults.set(self.edge.rawValue, forKey: "pillEdge")
            self.persistOffset()
            self.model.isMoving = false
            self.syncWithSettings()
        }
        self.panel = panel
    }

    private func currentScreen() -> NSScreen? {
        if let panel, panel.isVisible,
           let hit = NSScreen.screens.first(where: { panel.frame.intersects($0.frame) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - 定位：across = 离屏幕边框的进深，along = 沿边方向；本地坐标左上为原点。

    private var anchor: CGFloat { edge.isVertical ? Self.windowSize(for: edge).height - Self.bodyStart - PillMetrics.length(for: edge) / 2 : Self.bodyStart + PillMetrics.length(for: edge) / 2 }

    private func reposition() {
        guard let panel, let screen = currentScreen() else { return }
        panel.setFrame(PillPlacement.frame(screen: screen.frame, size: Self.windowSize(for: edge), edge: edge, offset: offset, anchor: anchor), display: true)
    }

    func resetPosition() { offset = 0.5; reposition() }

    private var barDepth: CGFloat { PillMetrics.depth(for: edge) }

    private var tabRect: CGRect {
        rect(across: 0, along: Self.bodyStart + (PillMetrics.length(for: edge) - Self.collapsedLength) / 2, depth: Self.collapsedAcross, length: Self.collapsedLength)
    }

    private var barRect: CGRect {
        rect(across: 0, along: 0, depth: barDepth, length: PillMetrics.length(for: edge) + 64)
    }

    static func cardFrame(edge: PillEdge, element: PillElement, height: CGFloat, panelSize: CGSize) -> CGRect {
        let width: CGFloat = edge.isVertical ? cardAcross : 226
        let depth: CGFloat = edge.isVertical ? height : height + 28.2
        let alongLength = edge.isVertical ? height : width
        let alongLimit = edge.isVertical ? panelSize.height : panelSize.width
        let origin = min(max(element.centerAlong(for: edge) - alongLength / 2, 0), max(0, alongLimit - alongLength))
        let gap = PillMetrics.depth(for: edge) + cardGap
        switch edge {
        case .right: return CGRect(x: panelSize.width - gap - width, y: origin, width: width, height: height)
        case .left: return CGRect(x: gap, y: origin, width: width, height: height)
        case .top: return CGRect(x: origin, y: gap, width: width, height: depth)
        case .bottom: return CGRect(x: origin, y: panelSize.height - gap - depth, width: width, height: depth)
        }
    }
    private var cardRect: CGRect {
        Self.cardFrame(edge: edge, element: model.hovered ?? .today, height: model.cardHeight(for: model.hovered ?? .today), panelSize: Self.windowSize(for: edge))
    }

    private func rect(across: CGFloat, along: CGFloat, depth: CGFloat, length: CGFloat) -> CGRect {
        let size = Self.windowSize(for: edge)
        switch edge {
        case .right:
            return CGRect(x: size.width - across - depth, y: along, width: depth, height: length)
        case .left:
            return CGRect(x: across, y: along, width: depth, height: length)
        case .top:
            return CGRect(x: along, y: across, width: length, height: depth)
        case .bottom:
            return CGRect(x: along, y: size.height - across - depth, width: length, height: depth)
        }
    }

    private func elementRect(_ element: PillElement) -> CGRect {
        rect(across: 3, along: element.originAlong(for: edge),
             depth: barDepth - 6, length: element.extent(for: edge))
    }

    func hoverTarget(at local: CGPoint) -> PillElement? {
        let bridge = rect(across: barDepth, along: 0, depth: Self.cardGap, length: PillMetrics.length(for: edge) + 64)
        if model.hasCard && (cardRect.contains(local) || bridge.contains(local)) { return model.hovered }
        guard barRect.contains(local) else { return nil }
        return [PillElement.today, .compose, .settings, .move].first { elementRect($0).contains(local) }
    }

    // MARK: - 光标监视与悬停

    private func poll() {
        tick += 1
        cursorMoved()
        if tick.isMultiple(of: 20) { updateForFullscreen() }
        if tick.isMultiple(of: 40) { model.refresh() }
    }

    private func localCursor() -> CGPoint? {
        guard let panel else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
    }

    private func cursorMoved() {
        guard let panel, panel.isVisible, !panel.isInteracting else { return }
        let local = localCursor() ?? CGPoint(x: -1, y: -1)

        if !model.expanded {
            // 收起态：光标碰到凸舌即展开。
            let overTab = tabRect.insetBy(dx: -10, dy: -8).contains(local)
            hosting?.interactiveRects = [tabRect.insetBy(dx: -10, dy: -8)]
            panel.ignoresMouseEvents = !overTab
            if overTab { setExpanded(true, animate: true) }
            return
        }

        let overBar = barRect.contains(local)
        let overCard = model.hasCard && cardRect.contains(local)
        let overBridge = model.hasCard && rect(across: barDepth, along: 0, depth: Self.cardGap, length: PillMetrics.length(for: edge) + 64).contains(local)
        hosting?.interactiveRects = [barRect] + (!model.hasCard ? [] : [cardRect])
        panel.ignoresMouseEvents = !(overBar || overCard)

        let target = hoverTarget(at: local)
        if target != model.hovered {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)) { model.hovered = target }
        }

        if overBar || overCard || overBridge { foldWork?.cancel(); foldWork = nil }
        if !overBar, !overCard, !overBridge, !alwaysExpanded, foldWork == nil {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.foldWork = nil
                    guard self.panel?.isInteracting != true else { return }
                    self.setExpanded(false, animate: true)
                }
            }
            foldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace, execute: work)
        }
    }

    /// 接触即展开；收起由 cursorMoved 里的宽限计时负责。
    /// 只切换模型状态——剪影形变交给 SwiftUI，窗口框纹丝不动。
    private func setExpanded(_ wanted: Bool, animate: Bool) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            guard !model.expanded else { return }
            let change = { self.model.expanded = true }
            if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78), change)
            } else {
                change()
            }
            model.refresh(force: true)
            cursorMoved()
        } else {
            foldWork?.cancel()
            foldWork = nil
            guard model.expanded || model.hovered != nil else { return }
            let change = {
                self.model.expanded = false
                self.model.hovered = nil
            }
            if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78), change)
            } else {
                change()
            }
        }
    }

    // MARK: - 点击与动作

    private func handleClick(local: CGPoint) {
        guard model.expanded else { setExpanded(true, animate: true); return }
        let element = model.hasCard && cardRect.contains(local) ? model.hovered : [PillElement.today, .compose, .settings, .move].first { elementRect($0).contains(local) }
        activate(element)
    }

    func activate(_ element: PillElement?) {
        switch element {
        case .today:
            openMainWindow()
            appModel?.showDueTasks()
        case .compose:
            openComposer()
        case .settings:
            openMainWindow()
            appModel?.settings = true
        case .move:
            if let view = panel?.contentView { makeMenu().popUp(positioning: nil, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY), in: view) }
        case nil:
            break
        }
    }

    /// 借主窗口的录入框写一笔；药丸自身不做文本输入，保持永不抢焦点。
    func openComposer() {
        fold()
        showWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
        appModel?.switchMode(.notes)
        if appModel?.mode == .notes { appModel?.showComposer() }
    }

    func openMainWindow() {
        fold()
        showWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func fold() {
        foldWork?.cancel()
        foldWork = nil
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.22)) {
            model.expanded = alwaysExpanded
            model.hovered = nil
        }
    }

    // MARK: - ⌥ 拖动

    /// AppKit 坐标向上为正，deltaY 直接加在 minY 上。
    private func drag(byDx dx: CGFloat, dy: CGFloat) {
        guard let panel, let screen = currentScreen() else { return }
        if model.isMoving {
            let mouse = NSEvent.mouseLocation
            let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? screen
            model.edge = PillPlacement.nearestEdge(point: mouse, screen: target.frame)
            let f = target.frame
            let fraction = edge.isVertical ? (mouse.y - f.minY) / f.height : (mouse.x - f.minX) / f.width
            panel.setFrame(PillPlacement.frame(screen: f, size: Self.windowSize(for: edge), edge: edge, offset: fraction, anchor: anchor), display: true)
            return
        }
        let f = screen.frame
        var frame = panel.frame
        if edge.isVertical {
            frame.origin.y = min(max(frame.origin.y + dy, f.minY), f.maxY - frame.height)
        } else {
            frame.origin.x = min(max(frame.origin.x + dx, f.minX), f.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
    }

    private func persistOffset() {
        guard let panel, let screen = currentScreen(), panel.isVisible else { return }
        offset = PillPlacement.offset(frame: panel.frame, screen: screen.frame, edge: edge, anchor: anchor)
    }

    // MARK: - 全屏与右键菜单

    private func updateForFullscreen() {
        guard enabled, let panel else { return }
        let fullscreen = currentScreen().map { PillFullscreen.isFrontmostAppFullScreen(on: $0) } ?? false
        if fullscreen {
            if panel.isVisible {
                setExpanded(false, animate: false)
                panel.orderOut(nil)
            }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
            hosting?.interactiveRects = [tabRect.insetBy(dx: -10, dy: -8)]
            panel.ignoresMouseEvents = true
            if alwaysExpanded { setExpanded(true, animate: false) }
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("打开 Noto", #selector(openMain)))
        menu.addItem(item("新建记录", #selector(composeMenu)))
        let submenu = NSMenu()
        submenu.title = "位置"
        for candidate in PillEdge.allCases {
            let row = NSMenuItem(title: candidate.label, action: #selector(changeEdge(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = candidate.rawValue
            row.state = candidate == edge ? .on : .off
            row.isEnabled = true
            submenu.addItem(row)
        }
        let edgeItem = NSMenuItem()
        edgeItem.title = "位置"
        edgeItem.submenu = submenu
        menu.addItem(edgeItem)
        menu.addItem(.separator())
        menu.addItem(item("隐藏屏幕边缘", #selector(hideMenu)))
        return menu
    }

    @objc private func openMain() { openMainWindow() }
    @objc private func composeMenu() { openComposer() }
    @objc private func hideMenu() { defaults.set(false, forKey: "pillEnabled") }
    @objc private func changeEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: "pillEdge")
        syncWithSettings()
    }
}
