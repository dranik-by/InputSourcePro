import XCTest
@testable import Input_Source_Pro

/// Verifies the pure geometry behind placing the indicator next to the mouse
/// pointer: a fixed gap to the pointer's bottom-right, clamped so the whole
/// indicator stays inside the screen's visible frame.
final class IndicatorNearMousePointTests: XCTestCase {
    private let size = CGSize(width: 60, height: 30)
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testPlacesIndicatorBelowRightOfPointer() {
        let point = IndicatorPosition.pointNearMouse(
            mouseLocation: CGPoint(x: 100, y: 500), size: size, visibleFrame: frame
        )

        // 12pt gap on both axes; the origin is the bottom-left corner, so the
        // indicator's top edge sits 12pt below the pointer.
        XCTAssertEqual(point, CGPoint(x: 112, y: 458))
    }

    func testClampsInsideRightEdge() {
        let point = IndicatorPosition.pointNearMouse(
            mouseLocation: CGPoint(x: 990, y: 500), size: size, visibleFrame: frame
        )

        XCTAssertEqual(point.x, 1000 - 60 - 5)
        XCTAssertEqual(point.y, 458)
    }

    func testClampsInsideBottomEdge() {
        let point = IndicatorPosition.pointNearMouse(
            mouseLocation: CGPoint(x: 100, y: 10), size: size, visibleFrame: frame
        )

        XCTAssertEqual(point.x, 112)
        XCTAssertEqual(point.y, 5)
    }

    func testClampsInsideLeftAndTopOfOffsetScreen() {
        // A secondary display whose visible frame does not start at the origin,
        // with the pointer in its menu bar (above the visible frame).
        let secondary = CGRect(x: 1000, y: 100, width: 1000, height: 800)

        let point = IndicatorPosition.pointNearMouse(
            mouseLocation: CGPoint(x: 990, y: 920), size: size, visibleFrame: secondary
        )

        XCTAssertEqual(point.x, 1000 + 5)
        XCTAssertEqual(point.y, 900 - 30 - 5)
    }
}
