import XCTest
import AppKit
import ApplicationServices
@testable import VibeMouse

private func previewWindow(_ number: UInt32, pid: pid_t? = nil, windowID: CGWindowID? = nil,
                           title: String? = nil, frame: CGRect? = nil, minimized: Bool = false) -> SwitchableWindow {
    let owner = pid ?? pid_t(100 + number)
    return SwitchableWindow(element: AXUIElementCreateApplication(owner), processIdentifier: owner, appName: "App",
        windowID: windowID, title: title ?? "Window \(number)",
        frame: frame ?? CGRect(x: 50, y: 50, width: 800, height: 600), minimized: minimized)
}

private func previewSource(_ window: SwitchableWindow, id: CGWindowID) -> WindowPreviewSource {
    WindowPreviewSource(windowID: id, processIdentifier: window.processIdentifier, title: window.title, frame: window.frame)
}

private func previewImage() -> CGImage {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return context.makeImage()!
}

private func transparentPreviewImage() -> CGImage {
    CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

final class WindowPreviewImageTests: XCTestCase {
    func testTransparentCaptureIsRejectedButOpaqueBlackWindowIsValid() {
        XCTAssertFalse(WindowPreviewImage.hasVisiblePixels(transparentPreviewImage()))
        XCTAssertTrue(WindowPreviewImage.hasVisiblePixels(previewImage()))
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertTrue(WindowPreviewImage.hasVisiblePixels(context.makeImage()!))
    }
}

final class WindowPreviewMatchingTests: XCTestCase {
    func testChromeProfileSuffixesDisambiguateWindowsWithIdenticalFrames() {
        let frame = CGRect(x: 1720, y: 30, width: 1720, height: 1410)
        func chrome(_ title: String) -> SwitchableWindow {
            SwitchableWindow(element: AXUIElementCreateApplication(100), processIdentifier: 100,
                appName: "Google Chrome", windowID: nil, title: title, frame: frame, minimized: false)
        }
        let first = chrome("Inbox - Google Chrome - Personal")
        let second = chrome("Project notes - Google Chrome - Work")
        let sources = [WindowPreviewSource(windowID: 10, processIdentifier: 100, title: "Inbox", frame: frame),
                       WindowPreviewSource(windowID: 11, processIdentifier: 100, title: "Project notes", frame: frame)]
        let matches = WindowPreviewMatching.match([first, second], sources: sources)
        XCTAssertEqual(matches[first.id]?.windowID, 10)
        XCTAssertEqual(matches[second.id]?.windowID, 11)
        // Identical page titles in different profiles remain ambiguous.
        let duplicate = chrome("Inbox - Google Chrome - Work")
        XCTAssertTrue(WindowPreviewMatching.match([first, duplicate], sources: [sources[0]]).isEmpty)
    }

    func testMissingIDUsesFreshCaptureMetadataAndToleratesSmallFrameDifferences() {
        let window = previewWindow(1)
        let source = WindowPreviewSource(windowID: 10, processIdentifier: window.processIdentifier,
            title: "", frame: window.frame.offsetBy(dx: 3, dy: -3))
        XCTAssertEqual(WindowPreviewMatching.match([window], sources: [source])[window.id], source)
    }

    func testAmbiguousWindowsAndOtherProcessesNeverReceiveTheWrongPreview() {
        let a = previewWindow(1, pid: 100, title: "Same")
        let b = previewWindow(2, pid: 100, title: "Same")
        let source = previewSource(a, id: 10)
        XCTAssertTrue(WindowPreviewMatching.match([a, b], sources: [source]).isEmpty)
        XCTAssertTrue(WindowPreviewMatching.match([a], sources: [source, previewSource(b, id: 11)]).isEmpty)
        let otherApp = previewWindow(3, pid: 200, title: "Same")
        XCTAssertTrue(WindowPreviewMatching.match([otherApp], sources: [source]).isEmpty)
    }

    func testKnownIDsAreReservedBeforeFallbackAndStrongMatchesWinRegardlessOfOrder() {
        let known = previewWindow(1, pid: 100, windowID: 10, title: "Same")
        let unknown = previewWindow(2, pid: 100, title: "Same")
        let sources = [previewSource(known, id: 10), previewSource(unknown, id: 11)]
        for windows in [[known, unknown], [unknown, known]] {
            let matches = WindowPreviewMatching.match(windows, sources: sources)
            XCTAssertEqual(matches[known.id]?.windowID, 10)
            XCTAssertEqual(matches[unknown.id]?.windowID, 11)
        }
        let weaker = previewWindow(3, pid: 100, title: "Different")
        let matches = WindowPreviewMatching.match([weaker, unknown], sources: [sources[1]])
        XCTAssertNil(matches[weaker.id])
        XCTAssertEqual(matches[unknown.id]?.windowID, 11)
    }
}

@MainActor
final class WindowPreviewCacheTests: XCTestCase {
    func testCacheSurvivesNewCardIDsAndMinimizationButRejectsReusedWindowNumbers() {
        let cache = WindowPreviewCache()
        let image = previewImage()
        let original = previewWindow(1, windowID: 10)
        cache.insert(image, for: original)
        let rediscovered = previewWindow(1, title: "Renamed", minimized: true)
        XCTAssertNotEqual(original.id, rediscovered.id)
        XCTAssertTrue(cache.image(for: rediscovered) === image)
        XCTAssertNil(cache.image(for: previewWindow(2, windowID: 10)))
        XCTAssertNil(cache.image(for: previewWindow(1, windowID: 11)))
    }

    func testCacheExpiresAndHasABoundedCapacity() {
        let cache = WindowPreviewCache(capacity: 2, lifetime: 10)
        let image = previewImage(), date = Date()
        let windows = (1...3).map { previewWindow(UInt32($0)) }
        for (offset, window) in windows.enumerated() {
            cache.insert(image, for: window, now: date.addingTimeInterval(Double(offset)))
        }
        XCTAssertNil(cache.image(for: windows[0], now: date.addingTimeInterval(3)))
        XCTAssertNotNil(cache.image(for: windows[1], now: date.addingTimeInterval(3)))
        XCTAssertNil(cache.image(for: windows[1], now: date.addingTimeInterval(11)))
        XCTAssertNotNil(cache.image(for: windows[2], now: date.addingTimeInterval(11)))
        XCTAssertNil(cache.image(for: windows[2], now: date.addingTimeInterval(12)))
    }
}

@MainActor
private final class FakePreviewCapture: WindowPreviewCapturing {
    var unavailabilityReason: String?
    var available: [WindowPreviewSource] = []
    var snapshots: [[WindowPreviewSource]] = []
    var sourceRequests = 0
    var requested: [CGWindowID] = []
    var pending: [CGWindowID: [CheckedContinuation<CGImage, any Error>]] = [:]
    var onRequest: ((CGWindowID) -> Void)?

    func sources() async throws -> [WindowPreviewSource] {
        sourceRequests += 1
        return snapshots.isEmpty ? available : snapshots.removeFirst()
    }
    func capture(_ source: WindowPreviewSource) async throws -> CGImage {
        requested.append(source.windowID)
        return try await withCheckedThrowingContinuation {
            pending[source.windowID, default: []].append($0)
            onRequest?(source.windowID)
        }
    }
    func resolve(_ id: CGWindowID, result: Result<CGImage, any Error>) {
        guard pending[id]?.isEmpty == false else { return XCTFail("No pending capture for \(id)") }
        pending[id]?.removeFirst().resume(with: result)
    }
    func resolveAll() {
        for continuations in pending.values {
            for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        }
        pending = [:]
    }
}

@MainActor
final class WindowPreviewLoaderTests: XCTestCase {
    private func waitFor(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Preview operation did not finish", file: file, line: line)
    }

    func testTransparentCaptureRetriesWithoutReplacingUsableCachedThumbnail() async {
        let capture = FakePreviewCapture(), cache = WindowPreviewCache()
        let window = previewWindow(1), cachedImage = previewImage()
        cache.insert(cachedImage, for: window)
        capture.available = [previewSource(window, id: 10)]
        let loader = WindowPreviewLoader(capture: capture, cache: cache, retryDelay: .zero)
        var shown: [CGImage] = []
        loader.start(windows: [window], selectedIndex: 0, onPreview: { _, image in shown.append(image) }, onStatus: { _ in })
        await waitFor { capture.requested.count == 1 }
        capture.resolve(10, result: .success(transparentPreviewImage()))
        await waitFor { capture.requested.count == 2 }
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first === cachedImage)
        XCTAssertTrue(cache.image(for: window) === cachedImage)
        let freshImage = previewImage()
        capture.resolve(10, result: .success(freshImage))
        await waitFor { shown.count == 2 }
        XCTAssertTrue(shown.last === freshImage)
        loader.stop()
    }

    func testIndependentCapturesDoNotWaitForSlowWindowsAndSelectionMovesToFrontOfQueue() async {
        let capture = FakePreviewCapture()
        let windows = (1...6).map { previewWindow(UInt32($0)) }
        capture.available = windows.enumerated().map { previewSource($0.element, id: UInt32($0.offset + 1)) }
        let loader = WindowPreviewLoader(capture: capture, retryDelay: .zero)
        var shown: Set<UUID> = []
        loader.start(windows: windows, selectedIndex: 1, onPreview: { id, _ in shown.insert(id) }, onStatus: { _ in })
        await waitFor { capture.requested.count == 3 }
        XCTAssertEqual(Set(capture.requested), [1, 2, 3])
        loader.select(windows[5].id)
        capture.resolve(1, result: .success(previewImage()))
        await waitFor { capture.requested.count == 4 }
        XCTAssertEqual(capture.requested.last, 6)
        XCTAssertTrue(shown.contains(windows[0].id))
        XCTAssertFalse(shown.contains(windows[1].id))
        loader.stop()
        capture.resolveAll()
    }

    func testCaptureFailureRetriesAndRefreshesSourcesWithoutRepeatingSuccessfulWindows() async {
        let capture = FakePreviewCapture()
        let windows = [previewWindow(1), previewWindow(2)]
        capture.available = windows.enumerated().map { previewSource($0.element, id: UInt32($0.offset + 1)) }
        let loader = WindowPreviewLoader(capture: capture, retryDelay: .zero)
        var shown: Set<UUID> = []
        loader.start(windows: windows, selectedIndex: 0, onPreview: { id, _ in shown.insert(id) }, onStatus: { _ in })
        await waitFor { capture.requested.count == 2 }
        capture.resolve(1, result: .failure(WindowPreviewCaptureError.noImage))
        capture.resolve(2, result: .success(previewImage()))
        await waitFor { capture.requested.count == 3 }
        XCTAssertEqual(capture.requested.filter { $0 == 2 }.count, 1)
        XCTAssertEqual(capture.sourceRequests, 2)
        capture.resolve(1, result: .success(previewImage()))
        await waitFor { shown.count == 2 }
        loader.stop()
    }

    func testSourcesMissingOnFirstPassAreRecoveredIncludingMinimizedWindows() async {
        let capture = FakePreviewCapture()
        let window = previewWindow(1, minimized: true)
        capture.snapshots = [[], [previewSource(window, id: 10)]]
        let loader = WindowPreviewLoader(capture: capture, retryDelay: .zero)
        var shown = false
        loader.start(windows: [window], selectedIndex: 0, onPreview: { _, _ in shown = true }, onStatus: { _ in })
        await waitFor { capture.requested == [10] }
        capture.resolve(10, result: .success(previewImage()))
        await waitFor { shown }
        XCTAssertEqual(capture.sourceRequests, 2)
        loader.stop()
    }

    func testReopeningImmediatelyShowsCachedMinimizedWindowWithoutCapturingAgain() async {
        let capture = FakePreviewCapture(), cache = WindowPreviewCache()
        let window = previewWindow(1)
        capture.available = [previewSource(window, id: 10)]
        let loader = WindowPreviewLoader(capture: capture, cache: cache, retryDelay: .zero)
        var shown: [UUID] = []
        loader.start(windows: [window], selectedIndex: 0, onPreview: { id, _ in shown.append(id) }, onStatus: { _ in })
        await waitFor { capture.requested == [10] }
        capture.resolve(10, result: .success(previewImage()))
        await waitFor { shown == [window.id] }
        loader.stop()
        let minimized = previewWindow(1, minimized: true)
        loader.start(windows: [minimized], selectedIndex: 0, onPreview: { id, _ in shown.append(id) }, onStatus: { _ in })
        XCTAssertEqual(shown, [window.id, minimized.id])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(capture.requested, [10])
        loader.stop()
    }

    func testOldCaptureCannotUpdateNewSessionOrPoisonCache() async {
        let capture = FakePreviewCapture(), cache = WindowPreviewCache()
        let window = previewWindow(1)
        capture.available = [previewSource(window, id: 10)]
        let loader = WindowPreviewLoader(capture: capture, cache: cache, retryDelay: .zero)
        var oldShown = false, newShown = false
        loader.start(windows: [window], selectedIndex: 0, onPreview: { _, _ in oldShown = true }, onStatus: { _ in })
        await waitFor { capture.requested.count == 1 }
        loader.start(windows: [window], selectedIndex: 0, onPreview: { _, _ in newShown = true }, onStatus: { _ in })
        await waitFor { capture.requested.count == 2 }
        capture.resolve(10, result: .success(previewImage()))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(oldShown)
        XCTAssertFalse(newShown)
        XCTAssertNil(cache.image(for: window))
        capture.resolve(10, result: .success(previewImage()))
        await waitFor { newShown }
        loader.stop()
    }

    func testSelectingAnUnavailablePreviewRetriesAfterInitialAttemptsFinish() async {
        let capture = FakePreviewCapture()
        let window = previewWindow(1)
        let loader = WindowPreviewLoader(capture: capture, retryDelay: .zero)
        var status = "", shown = false
        loader.start(windows: [window], selectedIndex: 0, onPreview: { _, _ in shown = true }, onStatus: { status = $0 })
        await waitFor { !status.isEmpty }
        XCTAssertEqual(capture.sourceRequests, 2)
        capture.available = [previewSource(window, id: 10)]
        loader.select(window.id)
        await waitFor { capture.requested == [10] }
        capture.resolve(10, result: .success(previewImage()))
        await waitFor { shown }
        loader.stop()
    }

    func testRevokedPermissionClearsCacheAndDoesNotStartCapture() {
        let capture = FakePreviewCapture(), cache = WindowPreviewCache()
        let window = previewWindow(1)
        cache.insert(previewImage(), for: window)
        capture.unavailabilityReason = "Screen Recording required"
        let loader = WindowPreviewLoader(capture: capture, cache: cache)
        var status = ""
        loader.start(windows: [window], selectedIndex: 0, onPreview: { _, _ in XCTFail("Permission was revoked") },
                     onStatus: { status = $0 })
        XCTAssertEqual(status, "Screen Recording required")
        XCTAssertNil(cache.image(for: window))
        XCTAssertEqual(capture.sourceRequests, 0)
        loader.stop()
    }

    func testCaptureDeadlineCompletesOnceAndIgnoresLateCallback() async {
        var request: WindowPreviewCaptureRequest?
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                request = WindowPreviewCaptureRequest(continuation: continuation, timeoutSeconds: 0.01)
            }
            XCTFail("Expected the capture to time out")
        } catch {
            guard case WindowPreviewCaptureError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        request?.finish(.success(previewImage()))
        request?.finish(.failure(WindowPreviewCaptureError.noImage))
    }

    // Explicit opt-in: exercise actual AX discovery and ScreenCaptureKit without
    // activating windows, displaying an overlay, or writing captured images.
    func testLivePreviewsWithoutChangingFocusedWindow() async throws {
        guard ProcessInfo.processInfo.environment["VIBE_MOUSE_LIVE_PREVIEW_CHECK"] == "1" else {
            throw XCTSkip("Set VIBE_MOUSE_LIVE_PREVIEW_CHECK=1 to check current windows in memory.")
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Live check requires existing Accessibility and Screen Recording permission.")
        }
        let access = SystemWindowSwitcherAccess(), capture = SystemWindowPreviewCapture()
        let app = try XCTUnwrap(access.frontmostApplication())
        let windows = await access.windows(for: app.processIdentifier, scope: .allApplications)
        guard !windows.isEmpty else { throw XCTSkip("No windows available for a live check.") }
        let sources = try await capture.sources()
        let matches = WindowPreviewMatching.match(windows, sources: sources)
        if ProcessInfo.processInfo.environment["VIBE_MOUSE_LIVE_PREVIEW_DETAILS"] == "1" {
            for window in windows {
                print("AX \(window.appName) pid=\(window.processIdentifier) id=\(window.windowID ?? 0) "
                    + "frame=\(window.frame) titleHash=\(window.title.hashValue) minimized=\(window.minimized)")
            }
            for source in sources where windows.contains(where: { $0.processIdentifier == source.processIdentifier }) {
                print("SC pid=\(source.processIdentifier) id=\(source.windowID) frame=\(source.frame) titleHash=\(source.title.hashValue)")
            }
        }
        let loader = WindowPreviewLoader(capture: capture)
        var shown: Set<UUID> = [], status = ""
        loader.start(windows: windows, selectedIndex: 0, onPreview: { id, image in
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
            shown.insert(id)
        }, onStatus: { status = $0 })
        let deadline = Date().addingTimeInterval(20)
        while shown.count < windows.count, status.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        loader.stop()
        for (name, appWindows) in Dictionary(grouping: windows, by: \.appName).sorted(by: { $0.key < $1.key }) {
            print("LIVE PREVIEWS \(name): \(appWindows.filter { shown.contains($0.id) }.count)/\(appWindows.count), "
                + "minimized=\(appWindows.filter(\.minimized).count), "
                + "unmatched=\(appWindows.filter { matches[$0.id] == nil }.count)")
        }
        XCTAssertFalse(shown.isEmpty, "None of the current windows produced a preview: \(status)")
    }
}
