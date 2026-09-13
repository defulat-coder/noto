import XCTest
import SwiftUI
import NotoCore
@testable import NotoApp

final class PillTests: XCTestCase {
    func testDueSummaryExcludesUnscheduledFromOverdueAndChangesAtMidnight() throws {
        let store = try Store(url: nil)
        _ = try store.add(kind: "todo", text: "未安排")
        _ = try store.add(kind: "todo", text: "逾期", due: "2026-09-12")
        _ = try store.add(kind: "todo", text: "今天", due: "2026-09-13")
        _ = try store.add(kind: "todo", text: "明天", due: "2026-09-14")
        _ = try store.add(kind: "todo", text: "今天完成", due: "2026-09-13", status: "completed")
        let todos = try store.todos(status: "all")
        let today = PillSummary(todos: todos, today: "2026-09-13")
        XCTAssertEqual(today.overdue, 1)
        XCTAssertEqual(today.todayOpen, 2)
        XCTAssertEqual(today.todayDone, 1)
        XCTAssertEqual(today.openCount, 4)
        let tomorrow = PillSummary(todos: todos, today: "2026-09-14")
        XCTAssertEqual(tomorrow.todayOpen, 3)
        XCTAssertEqual(tomorrow.overdue, 2)
        XCTAssertEqual(tomorrow.todayDone, 0)
    }

    @MainActor func testNotchStaysWithinEveryEdgeAndCellsDoNotOverlap() {
        for edge in PillEdge.allCases {
            let size = edge.isVertical ? CGSize(width: 70, height: 260) : CGSize(width: 260, height: 70)
            let bounds = CGRect(origin: .zero, size: size)
            let path = NotchSilhouette(edge: edge).path(in: bounds)
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(path.boundingRect))
            XCTAssertFalse(path.isEmpty)
        }
        let elements: [PillElement] = [.move, .today, .compose, .settings]
        for element in elements {
            XCTAssertGreaterThanOrEqual(element.centerAlong - element.extent / 2, 0)
            XCTAssertLessThanOrEqual(element.centerAlong + element.extent / 2, PillController.barLength)
        }
        for index in 1..<elements.count {
            XCTAssertLessThan(elements[index-1].centerAlong + elements[index-1].extent / 2,
                              elements[index].centerAlong - elements[index].extent / 2)
        }
    }
    @MainActor func testPlacementRoundTripOnOffsetDisplay() {
        let screen = CGRect(x: -1512, y: 300, width: 1512, height: 982)
        for edge in PillEdge.allCases {
            let size = PillController.windowSize(for: edge)
            let anchor = edge.isVertical ? size.height - PillController.bodyLength / 2 : PillController.bodyLength / 2
            for fraction in [0.25, 0.5, 0.75] {
                let frame = PillPlacement.frame(screen: screen, size: size, edge: edge, offset: fraction, anchor: anchor)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(PillPlacement.offset(frame: frame, screen: screen, edge: edge, anchor: anchor), fraction, accuracy: 0.002)
                switch edge {
                case .left: XCTAssertEqual(frame.minX, screen.minX)
                case .right: XCTAssertEqual(frame.maxX, screen.maxX)
                case .top: XCTAssertEqual(frame.maxY, screen.maxY)
                case .bottom: XCTAssertEqual(frame.minY, screen.minY)
                }
            }
        }
    }

    @MainActor func testHostingContainerKeepsReservedWindowSize() {
        _ = NSApplication.shared
        let size = PillController.windowSize(for: .right)
        let panel = PillPanel(contentRect: CGRect(origin: .zero, size: size))
        let container = PillContainerView(frame: CGRect(origin: .zero, size: size))
        let hosting = PillHostingView(rootView: PillRootView(model: PillModel()))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.size, size)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertNil(container.hitTest(CGPoint(x: 100, y: 100)))
        panel.close()
    }

    @MainActor func testHoverTargetsAndCardBridgeOnAllEdges() throws {
        let name = "Noto.PillTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppModel(store: try Store(url: nil))
        for edge in PillEdge.allCases {
            defaults.set(edge.rawValue, forKey: "pillEdge")
            let controller = PillController(appModel: app, defaults: defaults)
            let size = PillController.windowSize(for: edge)
            func point(across: CGFloat, along: CGFloat) -> CGPoint {
                switch edge {
                case .left: CGPoint(x: across, y: along)
                case .right: CGPoint(x: size.width - across, y: along)
                case .top: CGPoint(x: along, y: across)
                case .bottom: CGPoint(x: along, y: size.height - across)
                }
            }
            for element: PillElement in [.move, .today, .compose, .settings] {
                XCTAssertEqual(controller.hoverTarget(at: point(across: 35, along: element.centerAlong(for: edge))), element)
            }
            controller.model.hovered = .today
            XCTAssertEqual(controller.hoverTarget(at: point(across: PillMetrics.depth(for: edge) + PillController.cardGap / 2, along: PillElement.today.centerAlong(for: edge))), .today)
            XCTAssertEqual(controller.hoverTarget(at: point(across: 120, along: PillElement.today.centerAlong(for: edge))), .today)
            XCTAssertNil(controller.hoverTarget(at: CGPoint(x: -20, y: -20)))
        }
    }

    func testCarryChoosesPhysicalScreenEdge() {
        let screen = CGRect(x: -1600, y: 200, width: 1600, height: 1000)
        XCTAssertEqual(PillPlacement.nearestEdge(point: CGPoint(x: -1590, y: 700), screen: screen), .left)
        XCTAssertEqual(PillPlacement.nearestEdge(point: CGPoint(x: -5, y: 700), screen: screen), .right)
        XCTAssertEqual(PillPlacement.nearestEdge(point: CGPoint(x: -800, y: 1195), screen: screen), .top)
        XCTAssertEqual(PillPlacement.nearestEdge(point: CGPoint(x: -800, y: 205), screen: screen), .bottom)
    }

}
