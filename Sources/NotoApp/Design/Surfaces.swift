import SwiftUI
import AppKit

// One continuous desktop-sampling surface, shared by the desktop windows.
private struct DesktopBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

struct NotoGlassSurface: View {
    var radius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                ZStack {
                    DesktopBackdrop()
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: radius))
                    }
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A quieter, denser material separates navigation from the clear reading surface.
struct NotoSidebarSurface: View {
    var radius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(shape.fill(Color.primary.opacity(0.04)))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(Color.primary.opacity(0.04)), in: shape)
            } else {
                shape.fill(.regularMaterial)
                    .overlay(shape.fill(Color.primary.opacity(0.025)))
            }
        }.allowsHitTesting(false)
    }
}

struct SidebarBadge: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary).frame(width: 20, height: 20)
    }
}
