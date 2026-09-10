import XCTest
import CoreGraphics
import Carbon.HIToolbox
@testable import VibeMouse

@MainActor
final class KeyboardTests: XCTestCase {
    func makeMonitor(physicallyHeld: Set<CGKeyCode> = []) -> MouseChordMonitor {
        let monitor = MouseChordMonitor()
        monitor.isKeyPhysicallyDown = { physicallyHeld.contains($0) }
        return monitor
    }
    func key(_ code: Int, down: Bool = true, flags: CGEventFlags = [], repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    func modifier(_ code: Int, flags: CGEventFlags, monitor: MouseChordMonitor) {
        let event = key(code, flags: flags)
        event.type = .flagsChanged
        _ = monitor.handleEvent(type: .flagsChanged, event: event)
    }

    func click(_ monitor: MouseChordMonitor) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
            event.flags = []
            _ = monitor.handleEvent(type: type, event: event)
        }
    }

    func testWindowPreviewActionsStayOrderedAndDoNotSynthesizeCommandKeys() async {
        let monitor = makeMonitor()
        var actions: [WindowSwitchAction] = []
        var emitted = 0
        monitor.postEvent = { _ in emitted += 1 }
        monitor.onWindowSwitchAction = { actions.append($0) }
        for (flag, code, modifierName) in [(CGEventFlags.maskControl, kVK_Control, WindowSwitchModifier.control),
                                         (.maskCommand, kVK_Command, .command),
                                         (.maskAlternate, kVK_Option, .option)] {
            XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_ANSI_Grave, flags: flag)))
            XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_ANSI_Grave, down: false, flags: flag)))
            XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_ANSI_Grave, flags: [flag, .maskShift])))
            modifier(code, flags: .maskShift, monitor: monitor)
            XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_ANSI_Grave, down: false)))
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            XCTAssertEqual(Array(actions.suffix(3)), [.begin(modifierName, backwards: false), .step(backwards: true), .finish])
        }
        XCTAssertEqual(emitted, 0)
    }

    func testWindowPreviewConsumesArrowsBeforeWindowTilingAndEscapeBeforeApp() async {
        let monitor = makeMonitor()
        var actions: [WindowSwitchAction] = []
        monitor.onWindowSwitchAction = { actions.append($0) }
        monitor.onWindowArrowShortcut = { _ in XCTFail("Preview arrow moved a window") }
        monitor.onEscapeKeyDown = { XCTFail("Preview Escape leaked to another action") }
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_ANSI_Grave, flags: .maskCommand))
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_RightArrow, flags: .maskCommand)))
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_RightArrow, down: false)))
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_Escape, flags: .maskCommand)))
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_Escape, down: false)))
        modifier(kVK_Command, flags: [], monitor: monitor)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(actions, [.begin(.command, backwards: false), .step(backwards: false), .cancel])
    }

    func testStoppingMonitorCancelsEvenAfterQuickRelease() async {
        let monitor = makeMonitor()
        var actions: [WindowSwitchAction] = []
        monitor.onWindowSwitchAction = { actions.append($0) }
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_ANSI_Grave, flags: .maskControl))
        modifier(kVK_Control, flags: [], monitor: monitor)
        monitor.stop()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(actions, [.begin(.control, backwards: false), .finish, .cancel])
    }

    func testAltShiftTabUsesWindowGridWithoutSynthesizingAppSwitcherKeys() async {
        let monitor = makeMonitor()
        var actions: [WindowSwitchAction] = []
        monitor.onWindowSwitchAction = { actions.append($0) }
        monitor.postEvent = { _ in XCTFail("All-window shortcut opened the native app switcher") }
        monitor.onWindowArrowShortcut = { _ in XCTFail("Grid arrow tiled a window") }
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: [.maskAlternate, .maskShift])))
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_Tab, down: false)))
        modifier(kVK_Shift, flags: .maskAlternate, monitor: monitor)
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: .maskAlternate)))
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_DownArrow, flags: .maskAlternate)))
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_DownArrow, down: false)))
        modifier(kVK_Option, flags: [], monitor: monitor)
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_Tab, down: false)))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(actions, [.beginAllWindows(backwards: true), .step(backwards: false), .moveRow(backwards: false), .finish])
    }

    func testAltTabKeepsWindowGridWhenShiftIsAdded() async {
        let monitor = makeMonitor()
        var actions: [WindowSwitchAction] = []
        var emitted: [CGEvent] = []
        monitor.onWindowSwitchAction = { actions.append($0) }
        monitor.postEvent = { emitted.append($0) }
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: .maskAlternate))
        _ = monitor.handleEvent(type: .keyUp, event: key(kVK_Tab, down: false, flags: .maskAlternate))
        modifier(kVK_Shift, flags: [.maskAlternate, .maskShift], monitor: monitor)
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: [.maskAlternate, .maskShift]))
        modifier(kVK_Option, flags: .maskShift, monitor: monitor)
        _ = monitor.handleEvent(type: .keyUp, event: key(kVK_Tab, down: false, flags: .maskShift))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(actions, [.beginAllWindows(backwards: false), .step(backwards: true), .finish])
        XCTAssertTrue(emitted.isEmpty)
    }

    func testPreviewClickChoosesCardAndConsumesMouseUpEvenAfterModifierRelease() async {
        for (flags, modifierCode) in [(CGEventFlags.maskAlternate, kVK_Option),
                                      (.maskControl, kVK_Control), (.maskCommand, kVK_Command)] {
            let monitor = makeMonitor()
            var actions: [WindowSwitchAction] = []
            monitor.onWindowSwitchAction = { actions.append($0) }
            monitor.postEvent = { _ in XCTFail("Preview click emitted a shortcut") }
            monitor.shouldSuppressPrimaryClick = { XCTFail("Preview click reached auto-scroll"); return true }
            monitor.onChord = { XCTFail("Preview click started a screenshot") }
            let id = UUID()
            var hit: WindowSwitcherPointerTarget? = .window(id)
            monitor.windowSwitcherPointerTarget = { _ in hit }
            _ = monitor.handleEvent(type: .keyDown, event: key(kVK_ANSI_Grave, flags: flags))
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                               mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: .left)!
            down.flags = flags
            XCTAssertNil(monitor.handleEvent(type: .leftMouseDown, event: down))
            modifier(modifierCode, flags: [], monitor: monitor)
            hit = nil // The overlay can disappear before the mouse is released.
            for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                    mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)!
                XCTAssertNil(monitor.handleEvent(type: type, event: event))
            }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            XCTAssertEqual(actions.filter { if case .chooseWindow = $0 { return true }; return false }, [.chooseWindow(id)])
            XCTAssertFalse(actions.contains(.cancel))
            XCTAssertEqual(Array(actions.suffix(2)), [.chooseWindow(id), .finish])
        }
    }

    func testPreviewBackgroundAndOtherButtonsNeverTriggerMouseActions() async {
        let monitor = makeMonitor()
        var actions: [WindowSwitchAction] = []
        monitor.onWindowSwitchAction = { actions.append($0) }
        monitor.windowSwitcherPointerTarget = { _ in .background }
        monitor.onChord = { XCTFail("Preview mouse chord started a screenshot") }
        monitor.onSideButtonDown = { _ in XCTFail("Preview middle click started auto-scroll") }
        monitor.interceptedSideMouseButtons = [2]
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: .maskAlternate))
        for (downType, upType, button) in [(CGEventType.leftMouseDown, CGEventType.leftMouseUp, CGMouseButton.left),
                                           (.rightMouseDown, .rightMouseUp, .right),
                                           (.otherMouseDown, .otherMouseUp, .center)] {
            for type in [downType, upType] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                    mouseCursorPosition: .zero, mouseButton: button)!
                XCTAssertNil(monitor.handleEvent(type: type, event: event))
            }
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(actions, [.beginAllWindows(backwards: false)])
    }

    func testClickOutsidePreviewCancelsAndPassesThrough() async {
        let monitor = makeMonitor()
        var actions: [WindowSwitchAction] = []
        monitor.onWindowSwitchAction = { actions.append($0) }
        monitor.windowSwitcherPointerTarget = { _ in nil }
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: .maskAlternate))
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
            withExtendedLifetime(event) { XCTAssertNotNil(monitor.handleEvent(type: type, event: event)) }
        }
        modifier(kVK_Option, flags: [], monitor: monitor)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(actions, [.beginAllWindows(backwards: false), .cancel])
    }

    func testPreviewScrollingBypassesGlobalMouseAcceleration() {
        let monitor = makeMonitor()
        monitor.windowSwitcherPointerTarget = { _ in .background }
        monitor.reverseScrollingEnabled = true
        monitor.mouseScrollSpeed = 36
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: 3, wheel2: 0, wheel3: 0)!
        let original = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        withExtendedLifetime(event) { XCTAssertNotNil(monitor.handleEvent(type: .scrollWheel, event: event)) }
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), original)
    }

    func testCtrlYReleasesZEvenWhenCtrlWasReleasedFirst() {
        let monitor = makeMonitor()
        let down = key(kVK_ANSI_Y, flags: [.maskControl])
        _ = monitor.handleEvent(type: .keyDown, event: down)
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_Z))
        modifier(kVK_Control, flags: [], monitor: monitor)
        let up = key(kVK_ANSI_Y, down: false)
        _ = monitor.handleEvent(type: .keyUp, event: up)
        XCTAssertEqual(up.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_Z))
        XCTAssertTrue(up.flags.contains([.maskCommand, .maskShift]))
    }

    func testClickDoesNotClearHeldKeyboardRemap() {
        let monitor = makeMonitor()
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_ANSI_Y, flags: [.maskControl]))
        click(monitor)
        let up = key(kVK_ANSI_Y, down: false)
        _ = monitor.handleEvent(type: .keyUp, event: up)
        XCTAssertEqual(up.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_Z))
    }

    func testClickDoesNotLosePhysicalCtrlState() {
        let monitor = makeMonitor(physicallyHeld: [CGKeyCode(kVK_Control)])
        modifier(kVK_Control, flags: [.maskControl], monitor: monitor)
        click(monitor)
        let down = key(kVK_ANSI_V)
        _ = monitor.handleEvent(type: .keyDown, event: down)
        XCTAssertTrue(down.flags.contains(.maskCommand))
    }

    func testClickDoesNotEndAltTabAndAltReleasedFirstStillReleasesTab() {
        let monitor = makeMonitor()
        var emitted: [CGEvent] = []
        monitor.postEvent = { emitted.append($0) }
        modifier(kVK_Option, flags: [.maskAlternate], monitor: monitor)
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: [.maskAlternate])))
        let countBeforeClick = emitted.count
        click(monitor)
        XCTAssertEqual(emitted.count, countBeforeClick)
        modifier(kVK_Option, flags: [], monitor: monitor)
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_Tab, down: false)))
        XCTAssertEqual(emitted.last?.type, .keyUp)
        XCTAssertEqual(emitted.last?.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_Tab))
    }

    func testCommandArrowsDispatchWindowActionsWithEitherControlArrowSetting() async {
        let bindings: [(Int, CGEventFlags, MouseChordMonitor.WindowArrowShortcut)] = [
            (kVK_LeftArrow, [], .left), (kVK_RightArrow, [], .right),
            (kVK_UpArrow, [], .up), (kVK_DownArrow, [], .down),
            (kVK_LeftArrow, [.maskShift], .moveDisplayLeft),
            (kVK_RightArrow, [.maskShift], .moveDisplayRight),
        ]
        for controlArrowsEnabled in [true, false] {
            for navigationFlags: CGEventFlags in [[], [.maskSecondaryFn, .maskNumericPad]] {
                let monitor = makeMonitor()
                monitor.controlArrowWindowShortcutsEnabled = controlArrowsEnabled
                let dispatched = expectation(description: "Command arrow actions dispatched")
                dispatched.expectedFulfillmentCount = bindings.count
                var received: [MouseChordMonitor.WindowArrowShortcut] = []
                monitor.onWindowArrowShortcut = {
                    received.append($0)
                    dispatched.fulfill()
                }
                for (code, extraFlags, _) in bindings {
                    let flags = navigationFlags.union(extraFlags).union(.maskCommand)
                    XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(code, flags: flags)))
                    XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(code, down: false)))
                }
                await fulfillment(of: [dispatched], timeout: 2)
                XCTAssertEqual(received, bindings.map { $0.2 })
            }
        }
    }

    func testWindowKeyRepeatStaysSuppressedAfterModifierRelease() async {
        for (modifierCode, flags) in [(kVK_Control, CGEventFlags.maskControl),
                                      (kVK_Command, .maskCommand), (kVK_RightCommand, .maskCommand)] {
            let monitor = makeMonitor()
            let dispatched = expectation(description: "Window action fires once per tap")
            dispatched.assertForOverFulfill = true
            monitor.onWindowArrowShortcut = { _ in dispatched.fulfill() }
            modifier(modifierCode, flags: flags, monitor: monitor)
            XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_RightArrow, flags: flags)))
            XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_RightArrow, flags: flags, repeatKey: true)))
            modifier(modifierCode, flags: [], monitor: monitor)
            XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_RightArrow, repeatKey: true)))
            click(monitor)
            XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_RightArrow, down: false)))
            let plainArrow = key(kVK_RightArrow, flags: [.maskSecondaryFn, .maskNumericPad])
            withExtendedLifetime(plainArrow) {
                XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: plainArrow))
            }
            await fulfillment(of: [dispatched], timeout: 2)
        }
    }

    func testControlFnReleaseCanChangeKeycodeWithoutLeakingRepeatOrKeyUp() {
        let monitor = makeMonitor()
        var functionHeld = true
        monitor.isKeyPhysicallyDown = { $0 == CGKeyCode(kVK_Function) && functionHeld }
        monitor.onWindowArrowShortcut = { _ in }
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_Home, flags: [.maskControl, .maskSecondaryFn])))
        functionHeld = false
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: key(kVK_LeftArrow, repeatKey: true)))
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_LeftArrow, down: false)))
        let plainArrow = key(kVK_LeftArrow)
        withExtendedLifetime(plainArrow) {
            XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: plainArrow))
        }
    }

    func testBareNavigationKeysWithMacFunctionFlagsNeverMoveWindows() {
        let codes = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                     kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
        let flagVariants: [CGEventFlags] = [
            [], [.maskNumericPad], [.maskSecondaryFn],
            [.maskSecondaryFn, .maskNumericPad], [.maskShift, .maskSecondaryFn, .maskNumericPad],
        ]
        for flags in flagVariants {
            for code in codes {
                let monitor = makeMonitor()
                monitor.onWindowArrowShortcut = { _ in XCTFail("Unmodified navigation moved a window") }
                for repeatKey in [false, true] {
                    let event = key(code, flags: flags, repeatKey: repeatKey)
                    withExtendedLifetime(event) {
                        XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: event))
                    }
                    XCTAssertEqual(event.flags, flags)
                    XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(code))
                }
                let up = key(code, down: false, flags: flags)
                withExtendedLifetime(up) {
                    XCTAssertNotNil(monitor.handleEvent(type: .keyUp, event: up))
                }
            }
        }
    }

    func testMissingControlReleaseCannotMakeNextPlainArrowAWindowShortcut() {
        let monitor = makeMonitor()
        monitor.onWindowArrowShortcut = { _ in XCTFail("Stale Control state moved a window") }
        modifier(kVK_Control, flags: [.maskControl], monitor: monitor)
        // Simulate a missed flagsChanged release; hardware state is now up.
        for code in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow] {
            let event = key(code, flags: [.maskSecondaryFn, .maskNumericPad])
            withExtendedLifetime(event) {
                XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: event))
            }
            XCTAssertFalse(event.flags.contains(.maskControl))
            XCTAssertFalse(event.flags.contains(.maskCommand))
        }
        let letter = key(kVK_ANSI_C)
        withExtendedLifetime(letter) {
            XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: letter))
        }
        XCTAssertFalse(letter.flags.contains(.maskCommand))
    }

    func testFnNavigationPassesThroughInsteadOfMovingWindows() {
        let monitor = makeMonitor(physicallyHeld: [CGKeyCode(kVK_Function)])
        monitor.onWindowArrowShortcut = { _ in XCTFail("Fn should no longer move windows") }
        for flags: CGEventFlags in [[], [.maskSecondaryFn], [.maskSecondaryFn, .maskShift],
                                   [.maskCommand, .maskSecondaryFn]] {
            for code in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                         kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown] {
                for event in [key(code, flags: flags), key(code, flags: flags, repeatKey: true),
                              key(code, down: false, flags: flags)] {
                    withExtendedLifetime(event) {
                        XCTAssertNotNil(monitor.handleEvent(type: event.type, event: event))
                    }
                    XCTAssertEqual(event.flags, flags)
                    XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(code))
                }
            }
        }
    }

    func testUnboundCommandCombinationsPassThrough() {
        let monitor = makeMonitor()
        monitor.onWindowArrowShortcut = { _ in XCTFail("Unbound Command shortcut moved a window") }
        let events = [
            key(kVK_LeftArrow, flags: [.maskCommand, .maskAlternate]),
            key(kVK_RightArrow, flags: [.maskCommand, .maskControl]),
            key(kVK_LeftArrow, flags: [.maskCommand, .maskHelp]),
            key(kVK_UpArrow, flags: [.maskCommand, .maskShift]),
            key(kVK_DownArrow, flags: [.maskCommand, .maskShift]),
        ] + [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown].map {
            key($0, flags: [.maskCommand, .maskSecondaryFn])
        }
        for event in events {
            let oldFlags = event.flags
            withExtendedLifetime(event) {
                XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: event))
            }
            XCTAssertEqual(event.flags, oldFlags)
        }
    }

    func testCommandArrowsPassThroughWithoutWindowCallback() {
        let monitor = makeMonitor()
        for code in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow] {
            let event = key(code, flags: [.maskCommand, .maskSecondaryFn])
            withExtendedLifetime(event) {
                XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: event))
            }
            XCTAssertEqual(event.flags, [.maskCommand, .maskSecondaryFn])
        }
    }

    func testTypingModeRestoresWordSelectionWhileDedicatedWindowKeysStillWork() {
        let monitor = makeMonitor()
        monitor.controlArrowWindowShortcutsEnabled = false
        monitor.onWindowArrowShortcut = { _ in }
        let selection = key(kVK_LeftArrow, flags: [.maskControl, .maskShift])
        XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: selection))
        XCTAssertTrue(selection.flags.contains([.maskAlternate, .maskShift]))
        XCTAssertFalse(selection.flags.contains(.maskControl))
        _ = monitor.handleEvent(type: .keyUp, event: key(kVK_LeftArrow, down: false))
        XCTAssertNil(monitor.handleEvent(type: .keyDown,
            event: key(kVK_LeftArrow, flags: [.maskControl, .maskAlternate, .maskShift])))
    }

    func testCtrlTabAndOtherCommandShortcutsPassThrough() {
        let monitor = makeMonitor()
        monitor.onWindowArrowShortcut = { _ in }
        for event in [key(kVK_Tab, flags: [.maskControl]), key(kVK_Tab, flags: [.maskControl, .maskShift]),
                      key(kVK_Tab, flags: [.maskCommand]), key(kVK_ANSI_C, flags: [.maskCommand])] {
            let oldFlags = event.flags
            XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: event))
            XCTAssertEqual(event.flags, oldFlags)
        }
    }

    func testCtrlOptionVPassesThroughWithoutSearchingOrSynthesizingKeys() {
        for releaseModifiersFirst in [false, true] {
            let monitor = makeMonitor()
            monitor.onCopyAndSearchShortcut = { _ in XCTFail("Removed shortcut triggered a search") }
            var emitted: [CGEvent] = []
            monitor.postEvent = { emitted.append($0) }
            let shortcutFlags: CGEventFlags = [.maskControl, .maskAlternate]
            let remainingFlags: CGEventFlags = releaseModifiersFirst ? [] : shortcutFlags
            for event in [
                key(kVK_ANSI_V, flags: shortcutFlags),
                key(kVK_ANSI_V, flags: remainingFlags, repeatKey: true),
                key(kVK_ANSI_V, down: false, flags: remainingFlags),
            ] {
                let originalFlags = event.flags
                withExtendedLifetime(event) {
                    XCTAssertNotNil(monitor.handleEvent(type: event.type, event: event))
                }
                XCTAssertEqual(event.flags, originalFlags)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_V))
            }
            XCTAssertTrue(emitted.isEmpty)
        }
    }

    func testCtrlVStillPastesWithBalancedKeyUp() {
        let monitor = makeMonitor()
        let down = key(kVK_ANSI_V, flags: [.maskControl])
        let up = key(kVK_ANSI_V, down: false)
        for event in [down, up] {
            withExtendedLifetime(event) {
                XCTAssertNotNil(monitor.handleEvent(type: event.type, event: event))
            }
            XCTAssertEqual(event.flags, [.maskCommand])
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_V))
        }
    }

    func testCtrlShiftCStillCopiesAndSearchesOnce() async {
        let monitor = makeMonitor()
        let searched = expectation(description: "Copy-and-search dispatched once")
        searched.assertForOverFulfill = true
        monitor.onCopyAndSearchShortcut = { _ in searched.fulfill() }
        var emitted: [CGEvent] = []
        monitor.postEvent = { emitted.append($0) }
        XCTAssertNil(monitor.handleEvent(type: .keyDown,
            event: key(kVK_ANSI_C, flags: [.maskControl, .maskShift])))
        XCTAssertNil(monitor.handleEvent(type: .keyDown,
            event: key(kVK_ANSI_C, repeatKey: true)))
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: key(kVK_ANSI_C, down: false)))
        XCTAssertEqual(emitted.map(\.type), [.keyDown, .keyUp])
        for event in emitted {
            XCTAssertEqual(event.flags, [.maskCommand])
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_C))
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), InputEventMarker.synthetic)
        }
        await fulfillment(of: [searched], timeout: 2)
    }

    func testCtrlClickKeepsCommandThroughRelease() {
        let monitor = makeMonitor()
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        down.flags = [.maskControl]
        _ = monitor.handleEvent(type: .leftMouseDown, event: down)
        modifier(kVK_Control, flags: [], monitor: monitor)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)!
        up.flags = []
        _ = monitor.handleEvent(type: .leftMouseUp, event: up)
        XCTAssertTrue(down.flags.contains(.maskCommand))
        XCTAssertTrue(up.flags.contains(.maskCommand))
    }

    func testCtrlHomeShiftSelectsToDocumentStartWithBalancedKeyUp() {
        let monitor = makeMonitor()
        let down = key(kVK_Home, flags: [.maskControl, .maskShift])
        _ = monitor.handleEvent(type: .keyDown, event: down)
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_UpArrow))
        XCTAssertTrue(down.flags.contains([.maskCommand, .maskShift]))
        let up = key(kVK_Home, down: false)
        _ = monitor.handleEvent(type: .keyUp, event: up)
        XCTAssertEqual(up.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_UpArrow))
    }

    func testStopBalancesHeldRemappedKeys() {
        let monitor = makeMonitor()
        var emitted: [CGEvent] = []
        monitor.postEvent = { emitted.append($0) }
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_ANSI_Y, flags: [.maskControl]))
        monitor.stop()
        XCTAssertEqual(emitted.last?.type, .keyUp)
        XCTAssertEqual(emitted.last?.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_Z))
    }

    func testShiftDuringAltTabKeepsVirtualCommandHeld() {
        let monitor = makeMonitor()
        monitor.postEvent = { _ in }
        _ = monitor.handleEvent(type: .keyDown, event: key(kVK_Tab, flags: [.maskAlternate]))
        let shift = key(kVK_Shift, flags: [.maskAlternate, .maskShift])
        shift.type = .flagsChanged
        _ = monitor.handleEvent(type: .flagsChanged, event: shift)
        XCTAssertTrue(shift.flags.contains([.maskCommand, .maskShift]))
        XCTAssertFalse(shift.flags.contains(.maskAlternate))
    }

    func testGeneratedAutoScrollIsNotReversedOrAcceleratedAgain() {
        let monitor = makeMonitor()
        monitor.reverseScrollingEnabled = true
        monitor.mouseScrollSpeed = 36
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: 3, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.eventSourceUserData, value: InputEventMarker.synthetic)
        let before = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        XCTAssertNotNil(monitor.handleEvent(type: .scrollWheel, event: event))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), before)
    }
}
