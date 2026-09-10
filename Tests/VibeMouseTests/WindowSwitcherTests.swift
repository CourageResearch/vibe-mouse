import XCTest
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
@testable import VibeMouse

final class WindowSwitcherInputTests: XCTestCase {
    func testAltTabStartsAllWindowsAndShiftReversesWhileCycling() {
        var input = WindowSwitcherInput()
        let started = input.keyDown(Int64(kVK_Tab), flags: .maskAlternate, isRepeat: false, enabled: true)
        XCTAssertTrue(started.handled)
        XCTAssertEqual(started.action, .beginAllWindows(backwards: false))
        XCTAssertTrue(input.keyUp(Int64(kVK_Tab)))
        XCTAssertNil(input.flagsChanged(.maskAlternate))
        for flags: CGEventFlags in [[.maskAlternate, .maskShift], .maskAlternate] {
            XCTAssertEqual(input.keyDown(Int64(kVK_Tab), flags: flags, isRepeat: false,
                enabled: true).action, .step(backwards: flags.contains(.maskShift)))
        }
        XCTAssertEqual(input.keyDown(Int64(kVK_LeftArrow), flags: [.maskAlternate, .maskShift],
            isRepeat: false, enabled: true).action, .step(backwards: true))
        XCTAssertEqual(input.keyDown(Int64(kVK_UpArrow), flags: .maskAlternate,
            isRepeat: false, enabled: true).action, .moveRow(backwards: true))
        XCTAssertEqual(input.keyDown(Int64(kVK_DownArrow), flags: .maskAlternate,
            isRepeat: false, enabled: true).action, .moveRow(backwards: false))
        XCTAssertEqual(input.flagsChanged(.maskShift), .finish)
        XCTAssertTrue(input.keyDown(Int64(kVK_Tab), flags: [], isRepeat: true, enabled: true).handled)
        XCTAssertTrue(input.keyUp(Int64(kVK_Tab)))
        XCTAssertFalse(input.keyDown(Int64(kVK_Tab), flags: [], isRepeat: false, enabled: true).handled)
    }

    func testAllWindowsRequiresAltWithoutOtherModifiers() {
        for flags: CGEventFlags in [[], .maskShift, .maskCommand, .maskControl,
            [.maskControl, .maskShift], [.maskCommand, .maskShift],
            [.maskAlternate, .maskShift, .maskCommand], [.maskAlternate, .maskShift, .maskControl],
            [.maskAlternate, .maskShift, .maskSecondaryFn]] {
            var input = WindowSwitcherInput()
            XCTAssertFalse(input.keyDown(Int64(kVK_Tab), flags: flags, isRepeat: false, enabled: true).handled)
        }
        var input = WindowSwitcherInput()
        XCTAssertFalse(input.keyDown(Int64(kVK_Tab), flags: .maskAlternate,
            isRepeat: false, enabled: false).handled)
    }

    func testVerticalArrowsOnlyNavigateTheAllWindowsGrid() {
        for key in [kVK_UpArrow, kVK_DownArrow] {
            var input = WindowSwitcherInput()
            _ = input.keyDown(Int64(kVK_ANSI_Grave), flags: .maskCommand, isRepeat: false, enabled: true)
            let result = input.keyDown(Int64(key), flags: .maskCommand, isRepeat: false, enabled: true)
            XCTAssertFalse(result.handled)
            XCTAssertEqual(result.action, .cancel)
        }
    }

    func testEachModifierBeginsAndReleaseFinishesEvenWithShiftHeld() {
        for modifier in WindowSwitchModifier.allCases {
            var input = WindowSwitcherInput()
            let result = input.keyDown(Int64(kVK_ANSI_Grave), flags: modifier.flag, isRepeat: false, enabled: true)
            XCTAssertTrue(result.handled)
            XCTAssertEqual(result.action, .begin(modifier, backwards: false))
            XCTAssertNil(input.flagsChanged([modifier.flag, .maskShift]))
            XCTAssertEqual(input.flagsChanged(.maskShift), .finish)
            XCTAssertTrue(input.keyUp(Int64(kVK_ANSI_Grave)))
            XCTAssertNil(input.flagsChanged([]))
        }
    }

    func testShiftBacktickAndArrowsCycleBothDirections() {
        var input = WindowSwitcherInput()
        XCTAssertEqual(input.keyDown(Int64(kVK_ANSI_Grave), flags: [.maskControl, .maskShift],
            isRepeat: false, enabled: true).action, .begin(.control, backwards: true))
        XCTAssertEqual(input.keyDown(Int64(kVK_ANSI_Grave), flags: .maskControl,
            isRepeat: true, enabled: true).action, .step(backwards: false))
        XCTAssertEqual(input.keyDown(Int64(kVK_LeftArrow), flags: .maskControl,
            isRepeat: false, enabled: true).action, .step(backwards: true))
        XCTAssertEqual(input.keyDown(Int64(kVK_RightArrow), flags: [.maskControl, .maskShift],
            isRepeat: false, enabled: true).action, .step(backwards: false))
    }

    func testPlainTypingMixedModifiersAndCtrlTabPassThrough() {
        for flags: CGEventFlags in [[], .maskShift, [.maskControl, .maskAlternate],
                                    [.maskCommand, .maskControl], [.maskCommand, .maskSecondaryFn]] {
            var input = WindowSwitcherInput()
            XCTAssertFalse(input.keyDown(Int64(kVK_ANSI_Grave), flags: flags, isRepeat: false, enabled: true).handled)
        }
        var input = WindowSwitcherInput()
        XCTAssertFalse(input.keyDown(Int64(kVK_Tab), flags: .maskControl, isRepeat: false, enabled: true).handled)
        XCTAssertFalse(input.keyDown(Int64(kVK_ANSI_Grave), flags: .maskCommand, isRepeat: false, enabled: false).handled)
    }

    func testEscapeAndEnterConsumeTheirKeyUpsAndDoNotCommitAgainOnRelease() {
        for code in [kVK_Escape, kVK_Return] {
            var input = WindowSwitcherInput()
            _ = input.keyDown(Int64(kVK_ANSI_Grave), flags: .maskCommand, isRepeat: false, enabled: true)
            let result = input.keyDown(Int64(code), flags: .maskCommand, isRepeat: false, enabled: true)
            XCTAssertTrue(result.handled)
            XCTAssertEqual(result.action, code == kVK_Escape ? .cancel : .finish)
            XCTAssertTrue(input.keyUp(Int64(code)))
            XCTAssertTrue(input.keyUp(Int64(kVK_ANSI_Grave)))
            XCTAssertNil(input.flagsChanged([]))
        }
    }

    func testRepeatAfterModifierReleaseNeverTypesBackticks() {
        var input = WindowSwitcherInput()
        _ = input.keyDown(Int64(kVK_ANSI_Grave), flags: .maskControl, isRepeat: false, enabled: true)
        _ = input.flagsChanged([])
        let repeatEvent = input.keyDown(Int64(kVK_ANSI_Grave), flags: [], isRepeat: true, enabled: true)
        XCTAssertTrue(repeatEvent.handled)
        XCTAssertNil(repeatEvent.action)
        XCTAssertTrue(input.keyUp(Int64(kVK_ANSI_Grave)))
        XCTAssertFalse(input.keyDown(Int64(kVK_ANSI_Grave), flags: [], isRepeat: false, enabled: true).handled)
    }

    func testUnrelatedShortcutCancelsAndPassesThrough() {
        var input = WindowSwitcherInput()
        _ = input.keyDown(Int64(kVK_ANSI_Grave), flags: .maskCommand, isRepeat: false, enabled: true)
        let result = input.keyDown(Int64(kVK_ANSI_W), flags: .maskCommand, isRepeat: false, enabled: true)
        XCTAssertFalse(result.handled)
        XCTAssertEqual(result.action, .cancel)
        XCTAssertNil(input.flagsChanged([]))
    }
}

@MainActor
private final class FakeSwitcherAccess: WindowSwitcherAccess {
    var pending: [CheckedContinuation<[SwitchableWindow], Never>] = []
    var activated: [UUID] = []
    var activatedOwners: [pid_t] = []
    var requestedScopes: [WindowSwitchScope] = []
    var activationSucceeds = true
    func frontmostApplication() -> NSRunningApplication? { .current }
    func windows(for pid: pid_t, scope: WindowSwitchScope) async -> [SwitchableWindow] {
        requestedScopes.append(scope)
        return await withCheckedContinuation { pending.append($0) }
    }
    func activate(_ window: SwitchableWindow) -> Bool {
        activated.append(window.id)
        activatedOwners.append(window.processIdentifier)
        return activationSucceeds
    }
    func resolve(_ windows: [SwitchableWindow]) { pending.removeFirst().resume(returning: windows) }
}

@MainActor
private final class FakeSwitcherPanel: WindowSwitcherPresentation {
    var visible = false
    var showCount = 0
    var pointerHit: WindowSwitcherPointerTarget?
    func show(model: WindowSwitcherViewModel) { visible = true; showCount += 1 }
    func hide() { visible = false }
    func pointerTarget(at point: CGPoint) -> WindowSwitcherPointerTarget? { visible ? pointerHit : nil }
}

@MainActor
final class WindowSwitcherServiceTests: XCTestCase {
    private func windows(_ count: Int) -> [SwitchableWindow] {
        (0..<count).map { index in
            SwitchableWindow(element: AXUIElementCreateApplication(pid_t(100 + index)),
                processIdentifier: pid_t(100 + index), appName: "App \(index)", windowID: nil,
                title: "Window \(index)", frame: CGRect(x: 0, y: 0, width: 800, height: 600), minimized: false)
        }
    }

    private func drain() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func testAllWindowsDiscoversEveryAppAndActivatesTheSelectedOwner() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        let choices = windows(9)
        service.handle(.beginAllWindows(backwards: false))
        service.handle(.moveRow(backwards: false))
        await drain()
        access.resolve(choices)
        await drain()
        XCTAssertEqual(access.requestedScopes, [.allApplications])
        XCTAssertEqual(service.model.scope, .allApplications)
        XCTAssertEqual(service.model.appName, "All windows")
        XCTAssertEqual(service.model.selectedIndex, 1 + service.model.layout.columns)
        XCTAssertTrue(access.activated.isEmpty)
        service.handle(.moveRow(backwards: true))
        XCTAssertEqual(service.model.selectedIndex, 1)
        service.handle(.finish)
        XCTAssertEqual(access.activated, [choices[1].id])
        XCTAssertEqual(access.activatedOwners, [choices[1].processIdentifier])
        XCTAssertFalse(panel.visible)
    }

    func testAllWindowsQuickReleaseUsesSelectedWindowsApp() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        let choices = windows(4)
        service.handle(.beginAllWindows(backwards: false))
        service.handle(.step(backwards: false))
        service.handle(.finish)
        await drain()
        access.resolve(choices)
        await drain()
        XCTAssertEqual(access.requestedScopes, [.allApplications])
        XCTAssertEqual(access.activatedOwners, [choices[2].processIdentifier])
        XCTAssertEqual(panel.showCount, 0)
    }

    func testClickChoosesItsWindowInEitherPreviewAndReleaseCannotChooseAgain() async {
        for action in [WindowSwitchAction.begin(.control, backwards: false), .beginAllWindows(backwards: false)] {
            let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
            let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
            let choices = windows(4)
            var dismissals = 0
            service.onDismiss = { dismissals += 1 }
            service.handle(action)
            await drain()
            access.resolve(choices)
            await drain()
            XCTAssertEqual(service.model.selectedIndex, 1)
            service.model.onChooseWindow?(choices[3].id)
            service.handle(.finish)
            service.model.onChooseWindow?(choices[3].id)
            XCTAssertEqual(access.activated, [choices[3].id])
            XCTAssertEqual(access.activatedOwners, [choices[3].processIdentifier])
            XCTAssertEqual(dismissals, 1)
            XCTAssertFalse(panel.visible)
        }
    }

    func testPointerHitTestingOnlyWorksWhilePreviewIsVisibleAndIgnoresOldCards() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        let choices = windows(3)
        panel.pointerHit = .window(choices[2].id)
        service.handle(.beginAllWindows(backwards: false))
        XCTAssertNil(service.pointerTarget(at: .zero))
        await drain()
        access.resolve(choices)
        await drain()
        XCTAssertEqual(service.pointerTarget(at: .zero), .window(choices[2].id))
        service.handle(.chooseWindow(UUID()))
        XCTAssertTrue(panel.visible)
        XCTAssertTrue(access.activated.isEmpty)
        service.handle(.cancel)
        XCTAssertNil(service.pointerTarget(at: .zero))
        service.handle(.chooseWindow(choices[2].id))
        XCTAssertTrue(access.activated.isEmpty)
    }

    func testAltShiftTabCanStartAllWindowsInReverse() async {
        var input = WindowSwitcherInput()
        let action = input.keyDown(Int64(kVK_Tab), flags: [.maskAlternate, .maskShift],
                                   isRepeat: false, enabled: true).action
        XCTAssertEqual(action, .beginAllWindows(backwards: true))
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        let choices = windows(4)
        guard let action else { return XCTFail("Alt+Shift+Tab didn't start the preview") }
        service.handle(action)
        service.handle(.finish)
        await drain()
        access.resolve(choices)
        await drain()
        XCTAssertEqual(access.activated, [choices[3].id])
        XCTAssertEqual(panel.showCount, 0)
    }

    func testAppOnlyShortcutRetainsItsScopeAfterAllWindows() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        service.handle(.beginAllWindows(backwards: false))
        await drain()
        service.handle(.cancel)
        service.handle(.begin(.command, backwards: false))
        await drain()
        access.resolve(windows(9))
        await drain()
        XCTAssertFalse(panel.visible)
        access.resolve(windows(2))
        await drain()
        XCTAssertEqual(access.requestedScopes, [.allApplications, .currentApplication])
        XCTAssertEqual(service.model.scope, .currentApplication)
        XCTAssertEqual(service.model.windows.count, 2)
        service.handle(.cancel)
    }

    func testQuickReleaseCommitsAfterDiscoveryWithoutFlashingPanel() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        let choices = windows(3)
        service.handle(.begin(.command, backwards: false))
        service.handle(.step(backwards: false))
        service.handle(.finish)
        await drain()
        access.resolve(choices)
        await drain()
        XCTAssertEqual(access.activated, [choices[2].id])
        XCTAssertEqual(panel.showCount, 0)
        XCTAssertTrue(service.model.previews.isEmpty)
    }

    func testCancelWhileLoadingNeverShowsOrActivates() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        service.handle(.begin(.control, backwards: false))
        await drain()
        service.handle(.cancel)
        access.resolve(windows(3))
        await drain()
        service.handle(.finish)
        XCTAssertTrue(access.activated.isEmpty)
        XCTAssertEqual(panel.showCount, 0)
    }

    func testReverseWrapAndNoFocusUntilRelease() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        let choices = windows(3)
        service.handle(.begin(.option, backwards: true))
        await drain()
        access.resolve(choices)
        await drain()
        XCTAssertTrue(panel.visible)
        XCTAssertEqual(service.model.selectedIndex, 2)
        XCTAssertTrue(access.activated.isEmpty)
        service.handle(.step(backwards: false))
        XCTAssertEqual(service.model.selectedIndex, 0)
        service.handle(.finish)
        service.handle(.finish)
        XCTAssertEqual(access.activated, [choices[0].id])
        XCTAssertFalse(panel.visible)
    }

    func testOldDiscoveryCannotReplaceNewSession() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        service.handle(.begin(.command, backwards: false))
        await drain()
        service.handle(.begin(.control, backwards: true))
        await drain()
        access.resolve(windows(4))
        await drain()
        XCTAssertFalse(panel.visible)
        let choices = windows(2)
        access.resolve(choices)
        await drain()
        XCTAssertEqual(service.model.windows.map(\.id), choices.map(\.id))
        service.handle(.finish)
        XCTAssertEqual(access.activated, [choices[1].id])
    }

    func testEmptyAndSingleWindowAreSafe() async {
        for count in [0, 1] {
            let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
            let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
            service.handle(.begin(.command, backwards: false))
            await drain()
            access.resolve(windows(count))
            await drain()
            service.handle(.finish)
            XCTAssertEqual(access.activated.count, count)
            XCTAssertFalse(panel.visible)
        }
    }

    func testCancelVisiblePreviewClearsImagesWithoutFocusingAnything() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        let choices = windows(2)
        service.handle(.begin(.command, backwards: false))
        await drain()
        access.resolve(choices)
        await drain()
        service.model.previews[choices[0].id] = NSImage(size: NSSize(width: 20, height: 20))
        service.handle(.cancel)
        service.handle(.finish)
        XCTAssertFalse(panel.visible)
        XCTAssertTrue(service.model.windows.isEmpty)
        XCTAssertTrue(service.model.previews.isEmpty)
        XCTAssertTrue(access.activated.isEmpty)
    }

    func testClosedWindowReportsFailureAndDismisses() async {
        let access = FakeSwitcherAccess(), panel = FakeSwitcherPanel()
        access.activationSucceeds = false
        let service = WindowSwitcherService(access: access, presentation: panel, capturePreviews: false)
        var status = ""
        service.onStatus = { status = $0 }
        service.handle(.begin(.command, backwards: false))
        await drain()
        access.resolve(windows(2))
        await drain()
        service.handle(.finish)
        XCTAssertFalse(panel.visible)
        XCTAssertTrue(status.contains("Couldn't focus"))
    }

    // Opt-in artifact for visual QA; renders only this app's view with fixture
    // content, never captures or manipulates the user's desktop.
    func testRenderPreviewFixture() async throws {
        guard let output = ProcessInfo.processInfo.environment["VIBE_MOUSE_PREVIEW_RENDER"] else {
            throw XCTSkip("Set VIBE_MOUSE_PREVIEW_RENDER to export the preview fixture.")
        }
        _ = NSApplication.shared
        let model = WindowSwitcherViewModel()
        model.appName = "Google Chrome"
        model.appIcon = NSWorkspace.shared.icon(forFile: "/Applications/Google Chrome.app")
        model.windows = windows(3)
        model.selectedIndex = 1
        let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.97, alpha: 1).setFill()
            NSRect(x: 0, y: 320, width: 640, height: 40).fill()
            ("Window preview" as NSString).draw(at: NSPoint(x: 42, y: 225), withAttributes: [
                .font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.black,
            ])
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 42, y: 60, width: 260, height: 130), xRadius: 10, yRadius: 10).fill()
            return true
        }
        for window in model.windows { model.previews[window.id] = image }
        let view = NSHostingView(rootView: WindowSwitcherView(model: model).frame(width: 790, height: 257))
        view.frame = NSRect(x: 0, y: 0, width: 790, height: 257)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        await drain()
        XCTAssertEqual(model.hitRegions.cards.count, model.windows.count)
        for choice in model.windows {
            let frame = try XCTUnwrap(model.hitRegions.cards[choice.id])
            XCTAssertEqual(model.hitRegions.target(at: CGPoint(x: frame.midX, y: frame.midY)), .window(choice.id))
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
        window.contentView = nil
    }

    func testRenderAllWindowsFixture() async throws {
        guard let output = ProcessInfo.processInfo.environment["VIBE_MOUSE_ALL_WINDOWS_RENDER"] else {
            throw XCTSkip("Set VIBE_MOUSE_ALL_WINDOWS_RENDER to export the all-windows fixture.")
        }
        _ = NSApplication.shared
        let model = WindowSwitcherViewModel()
        model.scope = .allApplications
        model.appName = "All windows"
        let names = ["Google Chrome", "Terminal", "Finder"]
        let bundles = ["com.google.Chrome", "com.apple.Terminal", "com.apple.finder"]
        let titles = ["Project notes", "Build output", "Downloads", "Design references", "Local server",
                      "Documents", "Research", "Tests", "Screenshots"]
        let colors: [NSColor] = [.systemBlue, .systemTeal, .systemIndigo]
        model.windows = titles.enumerated().map { index, title in
            let owner = index % names.count
            let pid = pid_t(200 + owner)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundles[owner]) {
                model.appIcons[pid] = NSWorkspace.shared.icon(forFile: url.path)
            }
            return SwitchableWindow(element: AXUIElementCreateApplication(pid), processIdentifier: pid,
                appName: names[owner], windowID: nil, title: title,
                frame: CGRect(x: 0, y: 0, width: 640, height: 360), minimized: false)
        }
        for (index, window) in model.windows.enumerated() {
            let color = colors[index % colors.count]
            model.previews[window.id] = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                color.withAlphaComponent(0.18).setFill()
                NSRect(x: 0, y: 320, width: 640, height: 40).fill()
                (window.title as NSString).draw(at: NSPoint(x: 38, y: 230), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.black,
                ])
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 38, y: 55, width: 270, height: 135),
                             xRadius: 10, yRadius: 10).fill()
                return true
            }
        }
        model.selectedIndex = 1
        model.layout = WindowSwitcherLayout(scope: .allApplications, windowCount: model.windows.count,
                                            screenSize: CGSize(width: 1200, height: 800))
        let view = NSHostingView(rootView: WindowSwitcherView(model: model)
            .frame(width: model.layout.width, height: model.layout.height))
        view.frame = NSRect(x: 0, y: 0, width: model.layout.width, height: model.layout.height)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        await drain()
        let selected = model.windows[model.selectedIndex]
        let selectedFrame = try XCTUnwrap(model.hitRegions.cards[selected.id])
        XCTAssertEqual(model.hitRegions.target(at: CGPoint(x: selectedFrame.midX, y: selectedFrame.midY)), .window(selected.id))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        window.contentView = nil
    }
}

final class WindowSwitcherOrderingTests: XCTestCase {
    func testGlobalStackingOrderInterleavesAppsAndKeepsFocusedWindowFirst() {
        func window(_ id: CGWindowID?, pid: pid_t, focused: Bool = false, minimized: Bool = false) -> SwitchableWindow {
            SwitchableWindow(element: AXUIElementCreateApplication(pid), processIdentifier: pid, appName: "App",
                windowID: id, title: "Window", frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                minimized: minimized, isFocused: focused)
        }
        let chrome = window(1, pid: 100, focused: true)
        let otherChrome = window(2, pid: 100)
        let terminal = window(3, pid: 200, focused: true)
        let minimized = window(nil, pid: 300, minimized: true)
        let hidden = window(nil, pid: 400)
        let result = WindowSwitcherOrdering.ordered([otherChrome, chrome, terminal, minimized, hidden],
            frontmostPID: 100, frontToBackWindowIDs: [3, 1, 2])
        XCTAssertEqual(result.map(\.id), [chrome, terminal, otherChrome, minimized, hidden].map(\.id))
    }

    func testGridFitsSmallScreensAndScrollsAfterThreeRows() {
        for size in [CGSize(width: 640, height: 480), CGSize(width: 1200, height: 800),
                     CGSize(width: 3000, height: 1600)] {
            for count in [1, 3, 9, 80] {
                let layout = WindowSwitcherLayout(scope: .allApplications, windowCount: count, screenSize: size)
                XCTAssertLessThanOrEqual(layout.columns, min(4, count))
                XCTAssertGreaterThanOrEqual(layout.columns, 1)
                XCTAssertLessThanOrEqual(layout.width, size.width - 48)
                XCTAssertLessThanOrEqual(layout.height, size.height - 64)
            }
        }
        let size = CGSize(width: 1200, height: 800)
        XCTAssertEqual(WindowSwitcherLayout(scope: .allApplications, windowCount: 80, screenSize: size).height,
                       WindowSwitcherLayout(scope: .allApplications, windowCount: 12, screenSize: size).height)
    }
}

@MainActor
final class WindowSwitcherPointerTests: XCTestCase {
    func testPointerCoordinatesWorkOnDisplaysAboveBelowAndLeftOfPrimary() {
        let id = UUID()
        let regions = WindowSwitcherHitRegions(viewport: CGRect(x: 18, y: 50, width: 300, height: 180),
            cards: [id: CGRect(x: 24, y: 58, width: 232, height: 160)])
        for origin in [CGPoint(x: 100, y: 100), CGPoint(x: -700, y: 100),
                       CGPoint(x: 100, y: 1200), CGPoint(x: 100, y: -900)] {
            let panelFrame = CGRect(origin: origin, size: CGSize(width: 330, height: 257))
            let topLeft = CGPoint(x: panelFrame.minX, y: 1080 - panelFrame.maxY)
            XCTAssertEqual(WindowSwitcherPanel.pointerTarget(
                at: CGPoint(x: topLeft.x + 100, y: topLeft.y + 100), panelFrame: panelFrame,
                screenTop: 1080, regions: regions), .window(id))
            XCTAssertEqual(WindowSwitcherPanel.pointerTarget(
                at: CGPoint(x: topLeft.x + 100, y: topLeft.y + 20), panelFrame: panelFrame,
                screenTop: 1080, regions: regions), .background)
            XCTAssertNil(WindowSwitcherPanel.pointerTarget(
                at: CGPoint(x: topLeft.x - 1, y: topLeft.y + 100), panelFrame: panelFrame,
                screenTop: 1080, regions: regions))
        }
    }

    func testScrolledCardsCannotBeClickedBehindHeaderOrOutsideViewport() {
        let id = UUID()
        let regions = WindowSwitcherHitRegions(viewport: CGRect(x: 18, y: 50, width: 300, height: 180),
            cards: [id: CGRect(x: 24, y: -30, width: 232, height: 160)])
        XCTAssertEqual(regions.target(at: CGPoint(x: 100, y: 20)), .background)
        XCTAssertEqual(regions.target(at: CGPoint(x: 100, y: 70)), .window(id))
        XCTAssertEqual(regions.target(at: CGPoint(x: 310, y: 70)), .background)
    }
}
