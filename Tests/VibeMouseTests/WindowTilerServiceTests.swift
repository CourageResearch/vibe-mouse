import XCTest
import ApplicationServices
@testable import VibeMouse

@MainActor
private final class FakeWindowAccess: WindowAccess {
    // Handles are only identities; no AX reads or writes reach these processes.
    let handles = [AXUIElementCreateApplication(1), AXUIElementCreateApplication(2)]
    var focused = 0
    var frames = [CGRect(x: 180, y: 90, width: 820, height: 650),
                  CGRect(x: 230, y: 120, width: 860, height: 690)]
    var minimumSize = CGSize.zero
    var refusesResize = false
    var fullScreen = false
    var positionWrites = 0
    let displays = [
        WindowDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                      visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850)),
        WindowDisplay(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                      visibleFrame: CGRect(x: 1440, y: 25, width: 1920, height: 1030)),
    ]
    func index(_ window: AXUIElement) -> Int { handles.firstIndex { CFEqual($0, window) }! }
    func focusedTarget() -> WindowTarget? { WindowTarget(window: handles[focused], processIdentifier: 42) }
    func frame(of window: AXUIElement) -> CGRect? { frames[index(window)] }
    func isFullScreen(_ window: AXUIElement) -> Bool { fullScreen }
    func displayAreas() -> [WindowDisplay] { displays }
    func setPosition(_ position: CGPoint, on window: AXUIElement) -> AXError {
        frames[index(window)].origin = position
        positionWrites += 1
        return .success
    }
    func setSize(_ size: CGSize, on window: AXUIElement) -> AXError {
        if refusesResize { return .failure }
        frames[index(window)].size = CGSize(width: max(size.width, minimumSize.width),
                                            height: max(size.height, minimumSize.height))
        return .success
    }
}

@MainActor
final class WindowTilerServiceTests: XCTestCase {
    func run(_ command: WindowCommand, on service: WindowTilerService) async -> Result<String, WindowTilerService.TilingError> {
        await withCheckedContinuation { continuation in
            service.perform(command) { continuation.resume(returning: $0) }
        }
    }

    func testSeparateWindowsOfSameAppKeepSeparateRestoreFrames() async throws {
        let access = FakeWindowAccess(), service: WindowTilerService
        service = WindowTilerService(access: access)
        let original = access.frames
        _ = try await run(.snapUp, on: service).get()
        access.focused = 1
        _ = try await run(.snapUp, on: service).get()
        _ = try await run(.snapDown, on: service).get()
        XCTAssertEqual(access.frames[1], original[1])
        access.focused = 0
        _ = try await run(.snapDown, on: service).get()
        XCTAssertEqual(access.frames[0], original[0])
    }

    func testRapidQueuedCommandsCaptureWindowAndAdvanceInOrder() async {
        let access = FakeWindowAccess(), service: WindowTilerService
        service = WindowTilerService(access: access)
        let finished = expectation(description: "Three queued actions")
        finished.expectedFulfillmentCount = 3
        for command in [WindowCommand.snapRight, .snapRight, .snapRight] {
            service.perform(command) { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                finished.fulfill()
            }
        }
        // Changing focus after queuing must not move this second window.
        let otherOriginal = access.frames[1]
        access.focused = 1
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(access.frames[0], WindowLayout.right.frame(in: access.displays[1].visibleFrame))
        XCTAssertEqual(access.frames[1], otherOriginal)
    }

    func testMinimumWidthIsRememberedAsSnapAndCanThrowLater() async throws {
        let access = FakeWindowAccess()
        access.minimumSize = CGSize(width: 900, height: 600)
        let service = WindowTilerService(access: access)
        let message = try await run(.snapRight, on: service).get()
        XCTAssertTrue(message.contains("minimum size"))
        XCTAssertEqual(access.frames[0].maxX, access.displays[0].visibleFrame.maxX)
        _ = try await run(.snapRight, on: service).get()
        XCTAssertEqual(access.frames[0], WindowLayout.left.frame(in: access.displays[1].visibleFrame))
    }

    func testManualResizeBecomesNewRestoreFrame() async throws {
        let access = FakeWindowAccess(), service: WindowTilerService
        service = WindowTilerService(access: access)
        _ = try await run(.snapRight, on: service).get()
        let manual = CGRect(x: 120, y: 95, width: 1000, height: 700)
        access.frames[0] = manual
        _ = try await run(.snapUp, on: service).get()
        _ = try await run(.snapDown, on: service).get()
        XCTAssertEqual(access.frames[0], manual)
    }

    func testWindowRefusalDoesNotReportSuccessOrMovePosition() async {
        let access = FakeWindowAccess(), service: WindowTilerService
        service = WindowTilerService(access: access)
        access.refusesResize = true
        if case .success = await run(.snapRight, on: service) { XCTFail("Refused resize must fail") }
        XCTAssertEqual(access.positionWrites, 0)
    }

    func testFullScreenWindowIsNotResized() async {
        let access = FakeWindowAccess()
        access.fullScreen = true
        let service = WindowTilerService(access: access)
        let original = access.frames
        if case .success = await run(.snapRight, on: service) { XCTFail("Full screen must be rejected") }
        XCTAssertEqual(access.frames, original)
    }
}
