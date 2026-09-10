import XCTest
@testable import VibeMouse

final class WindowLayoutTests: XCTestCase {
    let screen = WindowDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                               visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850))
    let right = WindowDisplay(id: 2, frame: CGRect(x: 1440, y: -300, width: 2560, height: 1440),
                              visibleFrame: CGRect(x: 1440, y: -275, width: 2560, height: 1390))

    func testMaximizedAndEdgeFloatingWindowsSnapBeforeThrowing() throws {
        for frame in [screen.visibleFrame, CGRect(x: 0, y: 25, width: 850, height: 700)] {
            let layout = WindowLayout.matching(frame, in: screen.visibleFrame)
            let result = try XCTUnwrap(WindowGeometry.plan(.snapRight, currentFrame: frame, layout: layout,
                display: screen, displays: [screen, right], restoreFrame: nil))
            XCTAssertEqual(result.display.id, screen.id)
            XCTAssertEqual(result.layout, .right)
        }
    }

    func testRepeatedRightStepsThroughBothHalvesOnNextDisplay() throws {
        let first = try XCTUnwrap(WindowGeometry.plan(.snapRight, currentFrame: WindowLayout.right.frame(in: screen.visibleFrame),
            layout: .right, display: screen, displays: [screen, right], restoreFrame: nil))
        XCTAssertEqual(first.display, right)
        XCTAssertEqual(first.layout, .left)
        let second = try XCTUnwrap(WindowGeometry.plan(.snapRight, currentFrame: first.frame,
            layout: first.layout, display: first.display, displays: [screen, right], restoreFrame: nil))
        XCTAssertEqual(second.display, right)
        XCTAssertEqual(second.layout, .right)
        let third = try XCTUnwrap(WindowGeometry.plan(.snapRight, currentFrame: second.frame,
            layout: second.layout, display: right, displays: [screen, right], restoreFrame: nil))
        XCTAssertEqual(third.frame, second.frame)
    }

    func testQuarterThrowKeepsTopOrBottomRow() throws {
        for (source, expected) in [(WindowLayout.topRight, WindowLayout.topLeft), (.bottomRight, .bottomLeft)] {
            let result = try XCTUnwrap(WindowGeometry.plan(.snapRight, currentFrame: source.frame(in: screen.visibleFrame),
                layout: source, display: screen, displays: [screen, right], restoreFrame: nil))
            XCTAssertEqual(result.display, right)
            XCTAssertEqual(result.layout, expected)
        }
    }

    func testDirectDisplayMoveScalesSnappedLayoutToDifferentSizeScreen() throws {
        for layout in WindowLayout.allCases {
            let result = try XCTUnwrap(WindowGeometry.plan(.moveDisplayRight, currentFrame: layout.frame(in: screen.visibleFrame),
                layout: layout, display: screen, displays: [screen, right], restoreFrame: nil))
            XCTAssertEqual(result.layout, layout)
            XCTAssertEqual(result.frame, layout.frame(in: right.visibleFrame))
        }
    }

    func testDownUnwindsToTheSavedFloatingFrame() throws {
        let saved = CGRect(x: 210, y: 90, width: 890, height: 720)
        var layout: WindowLayout? = .topLeft
        var frame = WindowLayout.topLeft.frame(in: screen.visibleFrame)
        for expected in [WindowLayout.left, .bottomLeft, nil] {
            let result = try XCTUnwrap(WindowGeometry.plan(.snapDown, currentFrame: frame, layout: layout,
                display: screen, displays: [screen, right], restoreFrame: saved))
            XCTAssertEqual(result.layout, expected)
            layout = result.layout
            frame = result.frame
        }
        XCTAssertEqual(frame, saved)
    }

    func testMaximizeRestoreUsesOriginalFrame() throws {
        let saved = CGRect(x: 77, y: 64, width: 950, height: 680)
        let result = try XCTUnwrap(WindowGeometry.plan(.snapDown, currentFrame: screen.visibleFrame, layout: .maximized,
            display: screen, displays: [screen], restoreFrame: saved))
        XCTAssertEqual(result.frame, saved)
    }

    func testBottomQuarterUpKeepsColumn() throws {
        let result = try XCTUnwrap(WindowGeometry.plan(.snapUp, currentFrame: .zero, layout: .bottomRight,
            display: screen, displays: [screen], restoreFrame: nil))
        XCTAssertEqual(result.layout, .topRight)
    }

    func testNoLeftNeighborDoesNotWrapAround() {
        XCTAssertNil(WindowGeometry.plan(.moveDisplayLeft, currentFrame: screen.visibleFrame, layout: .maximized,
            display: screen, displays: [screen, right], restoreFrame: nil))
    }

    func testAboveDisplayIsNotMistakenForRightNeighbor() {
        let above = WindowDisplay(id: 3, frame: CGRect(x: 100, y: -1080, width: 3840, height: 1080),
                                  visibleFrame: CGRect(x: 100, y: -1055, width: 3840, height: 1055))
        XCTAssertEqual(WindowGeometry.adjacent(to: screen, direction: 1, in: [screen, above, right]), right)
        XCTAssertNil(WindowGeometry.adjacent(to: screen, direction: 1, in: [screen, above]))
    }

    func testLargestOverlapWinsAndTieIsStable() {
        let spanning = CGRect(x: 1000, y: 50, width: 1000, height: 600)
        XCTAssertEqual(WindowGeometry.display(containing: spanning, in: [screen, right]), right)
        let duplicate = WindowDisplay(id: 3, frame: screen.frame, visibleFrame: screen.visibleFrame)
        XCTAssertEqual(WindowGeometry.display(containing: screen.frame, in: [duplicate, screen]), screen)
    }

    func testFloatingMovesPreserveCenterAndEdges() {
        let a = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let b = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let centered = CGRect(x: 320, y: 150, width: 800, height: 600)
        let moved = WindowGeometry.moved(centered, from: a, to: b)
        XCTAssertEqual(moved.midX, b.midX)
        XCTAssertEqual(moved.midY, b.midY)
        XCTAssertEqual(WindowGeometry.moved(moved, from: b, to: a), centered)
        let edge = CGRect(x: 640, y: 275, width: 800, height: 600)
        let movedEdge = WindowGeometry.moved(edge, from: a, to: b)
        XCTAssertEqual(movedEdge.maxX, b.maxX)
        XCTAssertEqual(movedEdge.maxY, b.maxY)
    }

    func testMinimumWindowSizeStaysAlignedRightAndBottom() {
        let placement = WindowPlacement(display: screen, layout: .bottomRight,
            frame: WindowLayout.bottomRight.frame(in: screen.visibleFrame), message: "")
        let origin = WindowGeometry.alignedOrigin(size: CGSize(width: 900, height: 600), placement: placement)
        XCTAssertEqual(origin, CGPoint(x: 540, y: 275))
    }

    func testOddDisplayWidthHasNoGapOrOverlap() {
        let bounds = CGRect(x: -1513, y: 25, width: 1513, height: 901)
        let left = WindowLayout.left.frame(in: bounds), right = WindowLayout.right.frame(in: bounds)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.width + right.width, bounds.width)
    }
}
