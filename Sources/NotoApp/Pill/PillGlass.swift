import SwiftUI

// Silhouettes adapted from vinzdg/codenotch (MIT; THIRD-PARTY-NOTICES/codenotch.txt).
struct PillTooltipTail: Shape {
    /// Which way the card sits relative to the notch — the tip points back the
    /// other way, at the cell.
    let direction: PillCardTailDirection

    func path(in rect: CGRect) -> Path {
        // The tip and the two ends of the base opposite it. Each curve starts
        // or finishes parallel to the card edge, rounding both joins while the
        // point stays crisp and continues to land on the hovered ring.
        let (tip, a, b, aShoulder, aTip, bTip, bShoulder):
            (CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint)
        switch direction {
        case .right:   // card on the left, tip to the right
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.25)
        case .left:  // card on the right, tip to the left
            tip = CGPoint(x: rect.minX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25)
        case .up:      // card below, tip upward
            tip = CGPoint(x: rect.midX, y: rect.minY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY)
        case .down:        // card above, tip downward
            tip = CGPoint(x: rect.midX, y: rect.maxY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY)
        }

        var path = Path()
        path.move(to: a)
        path.addCurve(to: tip, control1: aShoulder, control2: aTip)
        path.addCurve(to: b, control1: bTip, control2: bShoulder)
        path.closeSubpath()
        return path
    }

    /// Long in the direction it points, wide across it.
    static func size(for direction: PillCardTailDirection) -> CGSize {
        switch direction {
        case .right, .left:
            return CGSize(width: 28.2, height: 32.7)
        case .down, .up:
            return CGSize(width: 32.7, height: 28.2)
        }
    }
}

/// The card and its tail as a single outline.
///
/// One glass shape, not two: separate ones each grow their own rim highlight
/// and the seam shows where the tail leaves the card. Internal so the tests can
/// measure the outline.
struct PillTooltipSilhouette: Shape {
    /// Which side of the notch the card is on, so the tail goes on the other one.
    let direction: PillCardTailDirection
    /// The same nudge `TooltipShell` applies to the tail view, along the card's
    /// own axis. The glass is masked by this outline, so a tail that has slid
    /// along the card to stay on its cell would otherwise be left unpainted.
    var tailOffset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // The two pieces are placed out of `rect` exactly the way
        // `TooltipShell.body` stacks them, so the outline keeps following the
        // card while its height animates.
        let tail = PillTooltipTail.size(for: direction)
        let cardRect: CGRect
        var tailRect: CGRect
        switch direction {
        case .right:
            cardRect = CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width - tail.width, height: rect.height)
            tailRect = CGRect(x: cardRect.maxX, y: rect.midY - tail.height / 2,
                              width: tail.width, height: tail.height)
        case .left:
            tailRect = CGRect(x: rect.minX, y: rect.midY - tail.height / 2,
                              width: tail.width, height: tail.height)
            cardRect = CGRect(x: rect.minX + tail.width, y: rect.minY,
                              width: rect.width - tail.width, height: rect.height)
        case .up:
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: rect.minY,
                              width: tail.width, height: tail.height)
            cardRect = CGRect(x: rect.minX, y: rect.minY + tail.height,
                              width: rect.width, height: rect.height - tail.height)
        case .down:
            cardRect = CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height - tail.height)
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: cardRect.maxY,
                              width: tail.width, height: tail.height)
        }
        switch direction {
        case .right, .left: tailRect.origin.y += tailOffset
        case .down, .up:          tailRect.origin.x += tailOffset
        }

        return RoundedRectangle(cornerRadius: 18.6, style: .circular)
            .path(in: cardRect)
            .union(PillTooltipTail(direction: direction).path(in: tailRect))
    }
}

// Original design-frame measurements at Codenotch's Small (0.8) scale.
enum PillMetrics {
    static let scale: CGFloat = 44.0 / 117.0 * 0.8
    static let depth: CGFloat = 186 * scale
    static let curl: CGFloat = 103 * scale
    static let start: CGFloat = 32
    static let ring: CGFloat = 117 * scale
    static let labelGap: CGFloat = 26.9 * scale
    static let labelHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 27 * (44.0 / 117.0) / 0.714)
        return ceil(font.ascender - font.descender + font.leading) * 0.8
    }()
    static let cell = ring + labelGap + labelHeight
    static let pitch = cell + 83.5 * scale
    static let length = 2 * curl + (69.5 + 50.1) * scale + 2 * cell + 83.5 * scale
    static func depth(for edge: PillEdge) -> CGFloat { edge.isVertical ? depth : (186 - 117) * scale + cell }
    static func length(for edge: PillEdge) -> CGFloat { edge.isVertical ? length : 2 * curl + (69.5 + 50.1) * scale + 2 * ring + 83.5 * scale }
    static func ringCenter(_ index: Int, edge: PillEdge = .right) -> CGFloat {
        start + curl + (edge.isVertical ? 69.5 : (69.5 + 50.1) / 2) * scale + ring / 2
            + CGFloat(index) * (edge.isVertical ? pitch : ring + 83.5 * scale)
    }
}

/// Codenotch samples a full rectangular system-glass surface, then masks it.
/// A separate small glass shape produces different rims and refraction.
struct PillGlass: View {
    var sampleSize = CGSize(width: 100, height: 100)
    var interactive = false
    static var available: Bool { if #available(macOS 26.0, *) { true } else { false } }
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.frame(width: sampleSize.width, height: sampleSize.height)
                .glassEffect(interactive ? .regular.interactive() : .regular, in: Rectangle())
        } else { Color.black }
    }
}

struct PillArcBand: Shape {
    let trim: ClosedRange<CGFloat>
    let lineWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        Circle().trim(from: trim.lowerBound, to: trim.upperBound)
            .path(in: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

struct PillOrb: View {
    let edge: PillEdge
    let moving: Bool
    let hovered: Bool
    let glassy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let radius: CGFloat = 76 * PillMetrics.scale
    private let stroke: CGFloat = 18 * PillMetrics.scale
    private var trim: ClosedRange<CGFloat> {
        let lower: CGFloat
        switch edge { case .right: lower = 0.75; case .left, .top: lower = 0.5; case .bottom: lower = 0.25 }
        let start = moving ? ((edge.isVertical ? 0.75 : 1.25) - lower).truncatingRemainder(dividingBy: 1) : lower
        return start...(start + 0.25)
    }
    var body: some View {
        ZStack {
            Group {
                if glassy { PillGlass() } else { Color.black }
            }.frame(width: radius * 2 + stroke, height: radius * 2 + stroke)
                .clipShape(PillArcBand(trim: trim, lineWidth: stroke))
                .opacity(hovered ? 0 : 1).scaleEffect(hovered ? 0.86 : 1)
            Group {
                if glassy { PillGlass(interactive: true) } else { Color.black }
            }.frame(width: 124 * PillMetrics.scale, height: 124 * PillMetrics.scale)
                .clipShape(Circle()).opacity(hovered ? 1 : 0).scaleEffect(hovered ? 1 : 1.1)
            Image(systemName: moving ? "hand.draw" : "gearshape")
                .font(.system(size: 56 * PillMetrics.scale, weight: .regular))
                .opacity(hovered ? 1 : 0).scaleEffect(hovered ? 1 : 0.5)
                .rotationEffect(.degrees(hovered ? 0 : -60))
        }.frame(width: radius * 2 + stroke, height: radius * 2 + stroke)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.7), value: hovered)
    }
}
