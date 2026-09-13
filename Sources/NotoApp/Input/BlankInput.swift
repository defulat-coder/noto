import SwiftUI
import AppKit

struct OccupiedAreas: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
extension View {
    /// 命中区域按 4pt 网格量化：滚动时 sub-pt 抖动不再每帧触发 preference 变化与整面板重算。
    func excludeFromBlankInput(in space: String = "reading") -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: OccupiedAreas.self, value: [Self.quantized(geometry.frame(in: .named(space)))])
        })
    }
    static func quantized(_ frame: CGRect) -> CGRect {
        func grid(_ value: CGFloat) -> CGFloat { (value / 4).rounded(.down) * 4 }
        let minX = grid(frame.minX), minY = grid(frame.minY)
        return CGRect(x: minX, y: minY,
                      width: max(4, grid(frame.maxX) - minX), height: max(4, grid(frame.maxY) - minY))
    }
}

// Observe without consuming clicks: text selection, native buttons and scrolling keep their own events.
private struct BlankInputEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var blankInputEnabled: Bool {
        get { self[BlankInputEnabledKey.self] }
        set { self[BlankInputEnabledKey.self] = newValue }
    }
}
struct BlankClickObserver: NSViewRepresentable {
    @Environment(\.blankInputEnabled) private var enabled
    let excluded: [CGRect]
    let floatingRect: CGRect?
    let onDoubleClick: (CGPoint) -> Void
    let onOutsideClick: () -> Void
    func makeNSView(context: Context) -> Surface {
        let view = Surface(); view.parent = self
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
            guard let view, let window = view.window, event.window === window, let parent = view.parent, parent.enabled else { return event }
            guard event.locationInWindow.y < window.contentLayoutRect.maxY else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            if let rect = parent.floatingRect, !rect.contains(point), event.clickCount == 1 { parent.onOutsideClick() }
            guard event.clickCount == 2, view.visibleRect.contains(point),
                  !(parent.floatingRect?.contains(point) ?? false), !parent.excluded.contains(where: { $0.contains(point) }) else { return event }
            var hit = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil))
            while let candidate = hit {
                if candidate is NSScroller || candidate is NSControl || candidate is NSTextView { return event }
                hit = candidate.superview
            }
            parent.onDoubleClick(point)
            return event
        }
        return view
    }
    func updateNSView(_ view: Surface, context: Context) { view.parent = self }
    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor); view.monitor = nil }
    }
    final class Surface: NSView {
        var parent: BlankClickObserver?
        var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
