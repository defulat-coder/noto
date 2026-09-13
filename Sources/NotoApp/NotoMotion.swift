import AppKit
import SwiftUI

/// One motion policy for desktop stories. Keyboard commands and Reduce Motion
/// resolve immediately; asynchronous replies can still fade in independently.
@MainActor
enum NotoMotion {
    enum Story { case feedback, navigation, layout }
    private(set) static var keyboardInput = false
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { record(event.type) }
            return event
        }
    }
    static func record(_ type: NSEvent.EventType) {
        switch type {
        case .keyDown: keyboardInput = true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: keyboardInput = false
        default: break
        }
    }
    static func animation(_ story: Story, reduced: Bool? = nil) -> Animation? {
        guard !(reduced ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), !keyboardInput else { return nil }
        switch story {
        case .feedback: return .easeOut(duration: 0.12)
        case .navigation: return .easeOut(duration: 0.16)
        case .layout: return .spring(response: 0.26, dampingFraction: 0.92)
        }
    }
    static var hover: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.10)
    }
    static var arrival: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)
    }
    static func perform(_ story: Story = .layout, _ changes: () -> Void) {
        withAnimation(animation(story), changes)
    }
}

/// Keep the hit rectangle fixed while the label responds to a press.
struct NavigationButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 40
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(NotoMotion.animation(.feedback), value: configuration.isPressed)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(enabled ? Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.055 : 0) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(NotoMotion.hover, value: hovered)
            .opacity(enabled ? 1 : 0.4)
    }
}
