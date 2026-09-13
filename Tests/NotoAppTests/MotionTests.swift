import XCTest
import AppKit
@testable import NotoApp

final class MotionTests: XCTestCase {
    @MainActor func testKeyboardCommandsStayImmediateAndPointerRestoresMotion() {
        defer { NotoMotion.record(.leftMouseDown) }
        NotoMotion.record(.keyDown)
        for story: NotoMotion.Story in [.feedback, .navigation, .layout] {
            XCTAssertNil(NotoMotion.animation(story, reduced: false))
        }
        NotoMotion.record(.mouseMoved)
        XCTAssertNil(NotoMotion.animation(.layout, reduced: false), "Incidental movement must not animate the result of a key command")
        NotoMotion.record(.leftMouseDown)
        XCTAssertNotNil(NotoMotion.animation(.navigation, reduced: false))
        NotoMotion.record(.rightMouseDown)
        XCTAssertNotNil(NotoMotion.animation(.layout, reduced: false))
    }

    @MainActor func testReduceMotionWinsOverPointerInput() {
        NotoMotion.record(.leftMouseDown)
        for story: NotoMotion.Story in [.feedback, .navigation, .layout] {
            XCTAssertNil(NotoMotion.animation(story, reduced: true))
        }
    }
}
