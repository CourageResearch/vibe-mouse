import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit
import ApplicationServices
import IOKit
import IOKit.hidsystem

final class MouseChordMonitor {
    enum WindowArrowShortcut {
        case left
        case right
        case up
        case down
        case moveDisplayLeft
        case moveDisplayRight
    }

    struct ScrollDebugSample: Sendable {
        let timestamp: TimeInterval
        let reverseEnabled: Bool
        let remapEligible: Bool
        let remapApplied: Bool
        let directionInvertedFromDevice: Bool
        let hasPreciseDeltas: Bool
        let phaseRaw: UInt
        let momentumPhaseRaw: UInt
        let scrollCount: Int64
        let instantMouser: Int64
        let isContinuous: Int64
        let deltaAxis1: Int64
        let fixedPtDeltaAxis1: Int64
        let pointDeltaAxis1: Int64
        let acceleratedDeltaAxis1: Int64
        let rawDeltaAxis1: Int64
    }

    enum StartResult {
        case started
        case failed(String)
    }

    private enum CenterClickAction {
        case passThrough
        case openNewTab(CGPoint)
        case autoScroll
    }

    var chordWindowSeconds: TimeInterval = 0.06
    var onChord: (@MainActor @Sendable () -> Void)?
    var onF4KeyDown: (@MainActor @Sendable () -> Void)?
    var onCapsLockKeyDown: (@MainActor @Sendable () -> Void)?
    var onEscapeKeyDown: (@MainActor @Sendable () -> Void)?
    var disableCapsLockLockingWhileIntercepting = false {
        didSet {
            applyCapsLockLockingModeIfNeeded()
        }
    }
    var onSideButtonDown: (@MainActor @Sendable (_ buttonNumber: Int64) -> Void)?
    var onPrimaryClickDown: (@MainActor @Sendable () -> Void)?
    var onWindowArrowShortcut: (@MainActor @Sendable (_ shortcut: WindowArrowShortcut) -> Void)?
    var onSearchClipboardShortcut: (@MainActor @Sendable () -> Void)?
    var onCopyAndSearchShortcut: (@MainActor @Sendable (_ previousPasteboardChangeCount: Int) -> Void)?
    var onScrollDebugSample: (@MainActor @Sendable (_ sample: ScrollDebugSample) -> Void)?
    var shouldSuppressPrimaryClick: (() -> Bool)?
    var palmControlShortcutRemappingEnabled = true
    var interceptedSideMouseButtons: Set<Int64> = []
    var reverseScrollingEnabled = false
    var mouseScrollSpeed: Double = 13
    var postReleaseTriggerDelaySeconds: TimeInterval = 0
    var minimumTriggerIntervalSeconds: TimeInterval = 0.20
    var releasePollIntervalSeconds: TimeInterval = 0.005
    var maximumReleaseWaitSeconds: TimeInterval = 0.50

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var attachedRunLoop: CFRunLoop?
    private var fallbackGlobalKeyMonitor: Any?
    private var fallbackLocalKeyMonitor: Any?

    private var leftDown = false
    private var rightDown = false
    private var suppressUntilButtonsUp = false
    private var chordTriggeredForCurrentPress = false
    private var chordPendingActionAfterRelease = false
    private var leftDownTime: TimeInterval?
    private var rightDownTime: TimeInterval?
    private var suppressF4KeyUp = false
    private var suppressNextLeftMouseUp = false
    private var altCommandModeActive = false
    private var activeOptionKeyCode = CGKeyCode(kVK_Option)
    private var physicalControlKeyDown = false
    private var suppressCopyAndSearchKeyUp = false
    private var suppressSearchClipboardKeyUp = false
    private var suppressedWindowArrowKeyUps: Set<Int64> = []
    private var suppressedAltCommandKeyUps: Set<Int64> = []
    private var suppressedSideButtons: Set<Int64> = []
    private var lastChordTriggerDispatchTime: TimeInterval = 0
    private var lastKeyboardTriggerDispatchTime: TimeInterval = 0
    private var releasePollTimer: DispatchSourceTimer?
    private var releasePollStartedAt: TimeInterval?
    private var didApplyCapsLockLockingOverride = false
    private var originalCapsLockDoesLockValue: UInt32?

    private let supportedSideMouseButtons: Set<Int64> = [2]
    private let palmControlCommandKeyCodes: Set<Int64> = [
        Int64(kVK_ANSI_A),
        Int64(kVK_ANSI_B),
        Int64(kVK_ANSI_C),
        Int64(kVK_ANSI_D),
        Int64(kVK_ANSI_F),
        Int64(kVK_ANSI_I),
        Int64(kVK_ANSI_K),
        Int64(kVK_ANSI_L),
        Int64(kVK_ANSI_N),
        Int64(kVK_ANSI_O),
        Int64(kVK_ANSI_P),
        Int64(kVK_ANSI_R),
        Int64(kVK_ANSI_S),
        Int64(kVK_ANSI_T),
        Int64(kVK_ANSI_U),
        Int64(kVK_ANSI_V),
        Int64(kVK_ANSI_W),
        Int64(kVK_ANSI_X),
        Int64(kVK_ANSI_Z),
        Int64(kVK_ANSI_0),
        Int64(kVK_ANSI_1),
        Int64(kVK_ANSI_2),
        Int64(kVK_ANSI_3),
        Int64(kVK_ANSI_4),
        Int64(kVK_ANSI_5),
        Int64(kVK_ANSI_6),
        Int64(kVK_ANSI_7),
        Int64(kVK_ANSI_8),
        Int64(kVK_ANSI_9),
        Int64(kVK_ANSI_Equal),
        Int64(kVK_ANSI_Minus),
        Int64(kVK_Return),
        Int64(kVK_ANSI_KeypadEnter),
    ]
    private let nxSystemDefinedEventTypeRawValue: UInt32 = 14 // NX_SYSDEFINED
    private let nxSubtypeAuxControlButtons: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private let nxSubtypeMenu: Int16 = 16 // NX_SUBTYPE_MENU
    private let nxKeyStateDown: Int64 = 0xA
    private let nxKeyStateUp: Int64 = 0xB
    // F4/search commonly arrives as one of these media/system key types.
    private let supportedF4SystemKeyTypes: Set<Int64> = [13, 25, 160]
    private let fixedPointScalePerPoint: Int64 = 6_554
    private let syntheticEventUserData: Int64 = 0x564D0A17

    func start() -> StartResult {
        if eventTap != nil {
            return .started
        }

        let mask = maskFor(.leftMouseDown)
            | maskFor(.leftMouseUp)
            | maskFor(.rightMouseDown)
            | maskFor(.rightMouseUp)
            | maskFor(.leftMouseDragged)
            | maskFor(.rightMouseDragged)
            | maskFor(.scrollWheel)
            | maskFor(.otherMouseDown)
            | maskFor(.otherMouseUp)
            | maskFor(.otherMouseDragged)
            | maskFor(.keyDown)
            | maskFor(.keyUp)
            | maskFor(.flagsChanged)
            | maskForRawType(nxSystemDefinedEventTypeRawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return .failed("Event tap unavailable. Enable Accessibility and Input Monitoring, then restart.")
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return .failed("Could not create run loop source for mouse events.")
        }

        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.attachedRunLoop = runLoop
        installFallbackKeyMonitorsIfNeeded()
        applyCapsLockLockingModeIfNeeded()
        resetState()
        return .started
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let runLoopSource, let attachedRunLoop {
            CFRunLoopRemoveSource(attachedRunLoop, runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        attachedRunLoop = nil
        restoreCapsLockLockingModeIfNeeded()
        removeFallbackKeyMonitors()
        resetState()
    }

    private func maskFor(_ type: CGEventType) -> CGEventMask {
        1 << type.rawValue
    }

    private func maskForRawType(_ rawType: UInt32) -> CGEventMask {
        1 << CGEventMask(rawType)
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<MouseChordMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventUserData {
            return Unmanaged.passUnretained(event)
        }

        if type.rawValue == nxSystemDefinedEventTypeRawValue {
            return handleSystemDefinedEvent(event)
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            resetState()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            if shouldSuppressPrimaryClick?() == true {
                suppressNextLeftMouseUp = true
                dispatchPrimaryClickDownTrigger()
                return nil
            }
            leftDown = true
            leftDownTime = now()
            if maybeTriggerChord() {
                return nil
            }
            _ = remapPalmControlMouseShortcutIfNeeded(event)
            return Unmanaged.passUnretained(event)

        case .rightMouseDown:
            rightDown = true
            rightDownTime = now()
            if maybeTriggerChord() {
                return nil
            }
            return suppressUntilButtonsUp ? nil : Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if suppressNextLeftMouseUp {
                suppressNextLeftMouseUp = false
                return nil
            }
            leftDown = false
            let shouldSuppress = suppressUntilButtonsUp
            resetIfIdle()
            if !shouldSuppress {
                _ = remapPalmControlMouseShortcutIfNeeded(event)
            }
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)

        case .rightMouseUp:
            rightDown = false
            let shouldSuppress = suppressUntilButtonsUp
            resetIfIdle()
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)

        case .leftMouseDragged:
            if !suppressUntilButtonsUp {
                _ = remapPalmControlMouseShortcutIfNeeded(event)
            }
            return suppressUntilButtonsUp ? nil : Unmanaged.passUnretained(event)

        case .rightMouseDragged:
            return suppressUntilButtonsUp ? nil : Unmanaged.passUnretained(event)

        case .scrollWheel:
            return handleScrollWheel(event)

        case .otherMouseDown:
            return handleOtherMouseDown(event)

        case .otherMouseUp:
            return handleOtherMouseUp(event)

        case .otherMouseDragged:
            return handleOtherMouseDragged(event)

        case .keyDown:
            return handleKeyDown(event)

        case .keyUp:
            return handleKeyUp(event)

        case .flagsChanged:
            return handleFlagsChanged(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func maybeTriggerChord() -> Bool {
        guard leftDown, rightDown else { return false }
        guard !chordTriggeredForCurrentPress else { return false }
        guard let leftDownTime, let rightDownTime else { return false }

        let delta = abs(leftDownTime - rightDownTime)
        guard delta <= chordWindowSeconds else { return false }

        chordTriggeredForCurrentPress = true
        suppressUntilButtonsUp = true
        // Fire immediately so screenshot startup overlaps the user's button release/mouse move.
        chordPendingActionAfterRelease = false
        startReleasePolling()
        dispatchChordTrigger()
        return true
    }

    private func handleOtherMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        if supportedSideMouseButtons.contains(buttonNumber) {
            guard interceptedSideMouseButtons.contains(buttonNumber),
                  onSideButtonDown != nil else {
                return Unmanaged.passUnretained(event)
            }

            // Match Windows/browser behavior: center-clicking a link becomes a
            // Command-click (open in a new tab), while center-clicking elsewhere
            // toggles auto-scroll.
            if shouldSuppressPrimaryClick?() != true {
                switch centerClickAction(at: event.location) {
                case .passThrough:
                    // Chrome and other browsers already implement Windows-style
                    // middle-click tab closing. Leave both physical events intact.
                    return Unmanaged.passUnretained(event)

                case .openNewTab(let clickPoint):
                    // Consume both halves of the physical center click so it cannot
                    // also start auto-scroll or trigger browser-specific fallback
                    // behavior. Ignore repeat-down events until its matching up.
                    if suppressedSideButtons.contains(buttonNumber) {
                        return nil
                    }
                    let cursorRestorePoint = clickPoint == event.location ? nil : event.location
                    if postOpenLinkInNewTabClick(
                        at: clickPoint,
                        restoreCursorTo: cursorRestorePoint
                    ) {
                        suppressedSideButtons.insert(buttonNumber)
                        return nil
                    }
                    return Unmanaged.passUnretained(event)

                case .autoScroll:
                    break
                }
            }

            // Some devices emit repeated down events while the side button is still held.
            // Ignore duplicates until we see the corresponding up event.
            if suppressedSideButtons.contains(buttonNumber) {
                return nil
            }

            suppressedSideButtons.insert(buttonNumber)
            dispatchSideButtonDownTrigger(buttonNumber: buttonNumber)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func centerClickAction(at point: CGPoint) -> CenterClickAction {
        guard let application = NSWorkspace.shared.frontmostApplication else { return .autoScroll }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.08)

        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            applicationElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
              var currentElement = hitElement else {
            return .autoScroll
        }

        // Browser tabs expose AXTab or the AXTabButton subrole. Passing their
        // physical middle click through lets the browser close them natively.
        // Web links can return a text/image child, so walk up for AXLink. Gmail
        // inbox rows are different: only their nested subject control exposes
        // AXLink and understands Command-click.
        var gmailRow: AXUIElement?
        var isInsideGmail = false
        for _ in 0..<16 {
            let role = accessibilityRole(of: currentElement)
            if isBrowserTabElement(currentElement, role: role) {
                return .passThrough
            }
            if role == NSAccessibility.Role.link.rawValue {
                return .openNewTab(point)
            }
            if role == NSAccessibility.Role.row.rawValue, gmailRow == nil {
                gmailRow = currentElement
            }
            if role == "AXWebArea",
               isGmailWebArea(currentElement) {
                isInsideGmail = true
            }
            if role == "AXWindow", isGmailWindow(currentElement) {
                isInsideGmail = true
            }

            guard let parent = accessibilityElement(
                currentElement,
                attribute: kAXParentAttribute as String
            ) else {
                break
            }
            currentElement = parent
        }

        guard isInsideGmail,
              let gmailRow,
              let messageLink = firstLinkDescendant(of: gmailRow),
              let linkCenter = accessibilityFrameCenter(of: messageLink) else {
            return .autoScroll
        }
        return .openNewTab(linkCenter)
    }

    private func isBrowserTabElement(_ element: AXUIElement, role: String?) -> Bool {
        if role == "AXTab" {
            return true
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success,
              let subrole = value as? String else {
            return false
        }
        return subrole == "AXTabButton"
    }

    private func accessibilityRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func accessibilityElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func isGmailWebArea(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXURLAttribute as CFString,
            &value
        ) == .success,
              let value else {
            return false
        }

        let urlString: String?
        if let url = value as? URL {
            urlString = url.absoluteString
        } else {
            urlString = value as? String
        }

        guard let urlString else { return false }
        let normalizedURL = urlString.lowercased()
        if let host = URL(string: normalizedURL)?.host {
            return host == "mail.google.com"
        }
        return normalizedURL == "mail.google.com"
            || normalizedURL.hasPrefix("mail.google.com/")
    }

    private func isGmailWindow(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &value
        ) == .success,
              let title = value as? String else {
            return false
        }
        return title.localizedCaseInsensitiveContains("Gmail")
    }

    private func firstLinkDescendant(of root: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = accessibilityChildren(of: root)
            .map { ($0, 1) }
        var index = 0

        while index < queue.count, index < 96 {
            let candidate = queue[index]
            index += 1

            if accessibilityRole(of: candidate.element) == NSAccessibility.Role.link.rawValue {
                return candidate.element
            }
            if candidate.depth < 4 {
                queue.append(contentsOf: accessibilityChildren(of: candidate.element).map {
                    ($0, candidate.depth + 1)
                })
            }
        }
        return nil
    }

    private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func accessibilityFrameCenter(of element: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func postOpenLinkInNewTabClick(
        at point: CGPoint,
        restoreCursorTo cursorRestorePoint: CGPoint?
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            return false
        }

        for event in [mouseDown, mouseUp] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
        }

        // The synthetic marker lets these events pass through this tap without
        // entering chord logic.
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        if let cursorRestorePoint {
            CGWarpMouseCursorPosition(cursorRestorePoint)
        }
        return true
    }

    private func handleOtherMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        if suppressedSideButtons.contains(buttonNumber) {
            suppressedSideButtons.remove(buttonNumber)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleOtherMouseDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        if suppressedSideButtons.contains(buttonNumber) {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleScrollWheel(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let remapEligible = reverseScrollingEnabled && shouldApplyMouseWheelRemap(to: event)
        let shouldRemap = remapEligible
        if onScrollDebugSample != nil, remapEligible {
            dispatchScrollDebugSample(
                buildScrollDebugSample(
                    from: event,
                    remapEligible: remapEligible,
                    remapApplied: shouldRemap
                )
            )
        }

        if shouldRemap {
            applyWindowsStyleVerticalScroll(on: event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func shouldApplyMouseWheelRemap(to event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else {
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            return !isContinuous
        }

        // Leave trackpad-class events completely untouched.
        if nsEvent.hasPreciseScrollingDeltas {
            return false
        }

        // Defensive check: if phase/momentum is present, treat as gesture-based.
        if nsEvent.phase.rawValue != 0 || nsEvent.momentumPhase.rawValue != 0 {
            return false
        }

        return true
    }

    private func applyWindowsStyleVerticalScroll(on event: CGEvent) {
        let sourceValues: [Int64] = [
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventRawDeltaAxis1),
        ]
        guard var direction = sourceValues.first(where: { $0 != 0 }) else { return }
        direction = direction > 0 ? 1 : -1

        // If macOS reports direction as inverted-from-device, flip to match
        // classic Windows wheel semantics (wheel toward user -> page down).
        if shouldInvertForWindowsStyle(event) {
            direction = -direction
        }

        let clampedSpeed = max(4.0, min(36.0, mouseScrollSpeed))
        let pointMagnitude = Int64(clampedSpeed.rounded())
        let fixedPointMagnitude = pointMagnitude * fixedPointScalePerPoint

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: direction)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: direction * pointMagnitude)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: direction * fixedPointMagnitude)
        event.setIntegerValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: direction)
        event.setIntegerValueField(.scrollWheelEventRawDeltaAxis1, value: direction)
    }

    private func shouldInvertForWindowsStyle(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return true
        }
        return nsEvent.isDirectionInvertedFromDevice
    }

    private func buildScrollDebugSample(
        from event: CGEvent,
        remapEligible: Bool,
        remapApplied: Bool
    ) -> ScrollDebugSample {
        let nsEvent = NSEvent(cgEvent: event)
        return ScrollDebugSample(
            timestamp: Date().timeIntervalSince1970,
            reverseEnabled: reverseScrollingEnabled,
            remapEligible: remapEligible,
            remapApplied: remapApplied,
            directionInvertedFromDevice: nsEvent?.isDirectionInvertedFromDevice ?? false,
            hasPreciseDeltas: nsEvent?.hasPreciseScrollingDeltas ?? false,
            phaseRaw: nsEvent?.phase.rawValue ?? 0,
            momentumPhaseRaw: nsEvent?.momentumPhase.rawValue ?? 0,
            scrollCount: event.getIntegerValueField(.scrollWheelEventScrollCount),
            instantMouser: event.getIntegerValueField(.scrollWheelEventInstantMouser),
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous),
            deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            fixedPtDeltaAxis1: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1),
            pointDeltaAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            acceleratedDeltaAxis1: event.getIntegerValueField(.scrollWheelEventAcceleratedDeltaAxis1),
            rawDeltaAxis1: event.getIntegerValueField(.scrollWheelEventRawDeltaAxis1)
        )
    }

    private func dispatchScrollDebugSample(_ sample: ScrollDebugSample) {
        let callback = onScrollDebugSample
        Task { @MainActor in
            callback?(sample)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if handleCopyAndSearchShortcutIfNeeded(event, keyCode: keyCode, isAutoRepeat: isAutoRepeat) {
            return nil
        }

        if handleSearchClipboardShortcutIfNeeded(event, keyCode: keyCode, isAutoRepeat: isAutoRepeat) {
            return nil
        }

        if handleWindowArrowShortcutIfNeeded(event, keyCode: keyCode, isAutoRepeat: isAutoRepeat) {
            return nil
        }

        if remapAltCommandShortcutIfNeeded(event, keyCode: keyCode, isKeyDown: true) {
            return nil
        }

        if remapAltSpaceShortcutIfNeeded(event, keyCode: keyCode) {
            return Unmanaged.passUnretained(event)
        }

        if remapPalmControlShortcutIfNeeded(event, keyCode: keyCode) {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == Int64(kVK_CapsLock) {
            guard onCapsLockKeyDown != nil else {
                return Unmanaged.passUnretained(event)
            }

            dispatchCapsLockTrigger()
            forceCapsLockOff()
            return nil
        }

        if keyCode == Int64(kVK_Escape) {
            guard onEscapeKeyDown != nil else {
                return Unmanaged.passUnretained(event)
            }

            if !isAutoRepeat {
                dispatchEscapeTrigger()
            }
            return Unmanaged.passUnretained(event)
        }

        if keyCode == Int64(kVK_F4) {
            guard onF4KeyDown != nil else {
                return Unmanaged.passUnretained(event)
            }

            // Ignore key repeat so holding F4 doesn't repeatedly launch screenshot mode.
            if isAutoRepeat {
                return nil
            }

            suppressF4KeyUp = true
            dispatchF4Trigger()
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == Int64(kVK_ANSI_C), suppressCopyAndSearchKeyUp {
            suppressCopyAndSearchKeyUp = false
            return nil
        }

        if keyCode == Int64(kVK_ANSI_V), suppressSearchClipboardKeyUp {
            suppressSearchClipboardKeyUp = false
            return nil
        }

        if suppressedWindowArrowKeyUps.remove(keyCode) != nil {
            return nil
        }

        if remapAltCommandShortcutIfNeeded(event, keyCode: keyCode, isKeyDown: false) {
            return nil
        }

        if remapAltSpaceShortcutIfNeeded(event, keyCode: keyCode) {
            return Unmanaged.passUnretained(event)
        }

        if remapPalmControlShortcutIfNeeded(event, keyCode: keyCode) {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == Int64(kVK_CapsLock) {
            guard onCapsLockKeyDown != nil else {
                return Unmanaged.passUnretained(event)
            }
            forceCapsLockOff()
            return nil
        }

        if keyCode == Int64(kVK_F4) {
            let shouldSuppress = suppressF4KeyUp
            suppressF4KeyUp = false
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleCopyAndSearchShortcutIfNeeded(
        _ event: CGEvent,
        keyCode: Int64,
        isAutoRepeat: Bool
    ) -> Bool {
        guard keyCode == Int64(kVK_ANSI_C), onCopyAndSearchShortcut != nil else { return false }

        let flags = event.flags
        let hasControl = flags.contains(.maskControl) || physicalControlKeyDown
        guard hasControl,
              flags.contains(.maskShift),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskSecondaryFn) else {
            return false
        }

        suppressCopyAndSearchKeyUp = true
        if !isAutoRepeat {
            let previousPasteboardChangeCount = NSPasteboard.general.changeCount
            postSyntheticKeyEvent(keyCode: CGKeyCode(kVK_ANSI_C), keyDown: true, flags: [.maskCommand])
            postSyntheticKeyEvent(keyCode: CGKeyCode(kVK_ANSI_C), keyDown: false, flags: [.maskCommand])
            dispatchCopyAndSearchTrigger(previousPasteboardChangeCount: previousPasteboardChangeCount)
        }
        return true
    }

    private func handleSearchClipboardShortcutIfNeeded(
        _ event: CGEvent,
        keyCode: Int64,
        isAutoRepeat: Bool
    ) -> Bool {
        guard keyCode == Int64(kVK_ANSI_V), onSearchClipboardShortcut != nil else { return false }

        let flags = event.flags
        let hasControl = flags.contains(.maskControl) || physicalControlKeyDown
        guard hasControl,
              flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskShift),
              !flags.contains(.maskSecondaryFn) else {
            return false
        }

        suppressSearchClipboardKeyUp = true
        if !isAutoRepeat {
            dispatchKeyboardTrigger(onSearchClipboardShortcut)
        }
        return true
    }

    private func handleWindowArrowShortcutIfNeeded(
        _ event: CGEvent,
        keyCode: Int64,
        isAutoRepeat: Bool
    ) -> Bool {
        guard let shortcut = windowArrowShortcut(for: event, keyCode: keyCode) else { return false }
        suppressedWindowArrowKeyUps.insert(keyCode)
        if !isAutoRepeat {
            dispatchWindowArrowShortcut(shortcut)
        }
        return true
    }

    private func windowArrowShortcut(for event: CGEvent, keyCode: Int64) -> WindowArrowShortcut? {
        guard onWindowArrowShortcut != nil else { return nil }

        let flags = event.flags
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)
        let hasAlternate = flags.contains(.maskAlternate)
        let hasFunction = flags.contains(.maskSecondaryFn)

        if hasControl, !hasCommand, !hasAlternate {
            return windowArrowShortcut(forArrowKeyCode: keyCode, flags: flags)
        }

        if hasFunction, !hasControl, !hasCommand, !hasAlternate {
            return windowArrowShortcut(forFnKeyCode: keyCode, flags: flags)
        }

        return nil
    }

    private func isArrowKey(_ keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_LeftArrow)
            || keyCode == Int64(kVK_RightArrow)
            || keyCode == Int64(kVK_UpArrow)
            || keyCode == Int64(kVK_DownArrow)
    }

    private func windowArrowShortcut(forArrowKeyCode keyCode: Int64, flags: CGEventFlags) -> WindowArrowShortcut? {
        guard isArrowKey(keyCode) else { return nil }
        return windowArrowShortcut(forLogicalDirectionKeyCode: keyCode, flags: flags)
    }

    private func windowArrowShortcut(forFnKeyCode keyCode: Int64, flags: CGEventFlags) -> WindowArrowShortcut? {
        switch keyCode {
        case Int64(kVK_Home):
            return windowArrowShortcut(forLogicalDirectionKeyCode: Int64(kVK_LeftArrow), flags: flags)
        case Int64(kVK_End):
            return windowArrowShortcut(forLogicalDirectionKeyCode: Int64(kVK_RightArrow), flags: flags)
        case Int64(kVK_PageUp):
            return windowArrowShortcut(forLogicalDirectionKeyCode: Int64(kVK_UpArrow), flags: flags)
        case Int64(kVK_PageDown):
            return windowArrowShortcut(forLogicalDirectionKeyCode: Int64(kVK_DownArrow), flags: flags)
        default:
            return nil
        }
    }

    private func windowArrowShortcut(
        forLogicalDirectionKeyCode keyCode: Int64,
        flags: CGEventFlags
    ) -> WindowArrowShortcut? {
        let wantsDisplayMove = flags.contains(.maskShift)
        switch keyCode {
        case Int64(kVK_LeftArrow):
            return wantsDisplayMove ? .moveDisplayLeft : .left
        case Int64(kVK_RightArrow):
            return wantsDisplayMove ? .moveDisplayRight : .right
        case Int64(kVK_UpArrow):
            return wantsDisplayMove ? nil : .up
        case Int64(kVK_DownArrow):
            return wantsDisplayMove ? nil : .down
        default:
            return nil
        }
    }

    private func remapAltSpaceShortcutIfNeeded(_ event: CGEvent, keyCode: Int64) -> Bool {
        guard keyCode == Int64(kVK_Space) else { return false }

        let flags = event.flags
        guard flags.contains(.maskAlternate),
              !flags.contains(.maskControl),
              !flags.contains(.maskCommand),
              !flags.contains(.maskSecondaryFn) else {
            return false
        }

        var remappedFlags = flags
        remappedFlags.remove(.maskAlternate)
        remappedFlags.insert(.maskCommand)
        event.flags = remappedFlags
        return true
    }

    private func remapAltCommandShortcutIfNeeded(_ event: CGEvent, keyCode: Int64, isKeyDown: Bool) -> Bool {
        guard isAltCommandShortcutKey(keyCode) else { return false }

        if isKeyDown {
            guard let remappedFlags = altCommandModeActive
                    ? Optional(altCommandActiveFlags(from: event.flags))
                    : altCommandFlags(from: event.flags) else {
                return false
            }

            beginAltCommandModeIfNeeded(flags: remappedFlags)
            suppressedAltCommandKeyUps.insert(keyCode)
            postSyntheticKeyEvent(keyCode: CGKeyCode(keyCode), keyDown: true, flags: remappedFlags)
            return true
        }

        guard suppressedAltCommandKeyUps.remove(keyCode) != nil else { return false }
        if altCommandModeActive {
            let remappedFlags = altCommandActiveFlags(from: event.flags)
            postSyntheticKeyEvent(keyCode: CGKeyCode(keyCode), keyDown: false, flags: remappedFlags)
        }
        return true
    }

    private func isAltCommandShortcutKey(_ keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_Tab) || keyCode == Int64(kVK_ANSI_Grave)
    }

    private func altCommandFlags(from flags: CGEventFlags) -> CGEventFlags? {
        guard flags.contains(.maskAlternate),
              !flags.contains(.maskControl),
              !flags.contains(.maskCommand),
              !flags.contains(.maskSecondaryFn) else {
            return nil
        }

        return altCommandActiveFlags(from: flags)
    }

    private func altCommandActiveFlags(from flags: CGEventFlags) -> CGEventFlags {
        var remappedFlags = flags
        remappedFlags.remove(.maskAlternate)
        remappedFlags.insert(.maskCommand)
        return remappedFlags
    }

    private func beginAltCommandModeIfNeeded(flags: CGEventFlags) {
        guard !altCommandModeActive else { return }
        altCommandModeActive = true

        var optionReleaseFlags = flags
        optionReleaseFlags.remove(.maskAlternate)
        optionReleaseFlags.remove(.maskCommand)
        postSyntheticKeyEvent(keyCode: activeOptionKeyCode, keyDown: false, flags: optionReleaseFlags)
        postSyntheticKeyEvent(keyCode: CGKeyCode(kVK_Command), keyDown: true, flags: flags)
    }

    private func endAltCommandModeIfNeeded(flags: CGEventFlags) {
        guard altCommandModeActive else { return }
        altCommandModeActive = false

        var releaseFlags = flags
        releaseFlags.remove(.maskAlternate)
        releaseFlags.remove(.maskCommand)
        postSyntheticKeyEvent(keyCode: CGKeyCode(kVK_Command), keyDown: false, flags: releaseFlags)
    }

    private func isOptionModifierKey(_ keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_Option) || keyCode == Int64(kVK_RightOption)
    }

    private func isControlModifierKey(_ keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_Control) || keyCode == Int64(kVK_RightControl)
    }

    private func postSyntheticKeyEvent(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let syntheticEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }

        syntheticEvent.flags = flags
        syntheticEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
        syntheticEvent.post(tap: .cghidEventTap)
    }

    private func remapPalmControlShortcutIfNeeded(_ event: CGEvent, keyCode: Int64) -> Bool {
        guard palmControlShortcutRemappingEnabled else { return false }

        guard let baseFlags = palmControlBaseFlags(from: event.flags) else { return false }

        if keyCode == Int64(kVK_Delete) || keyCode == Int64(kVK_ForwardDelete) {
            var wordDeleteFlags = baseFlags
            wordDeleteFlags.insert(.maskAlternate)
            event.flags = wordDeleteFlags
            return true
        }

        var remappedFlags = baseFlags
        remappedFlags.insert(.maskCommand)

        if keyCode == Int64(kVK_ANSI_Y) {
            var redoFlags = remappedFlags
            redoFlags.insert(.maskShift)
            event.flags = redoFlags
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_ANSI_Z))
            return true
        }

        guard palmControlCommandKeyCodes.contains(keyCode) else { return false }

        event.flags = remappedFlags
        return true
    }

    private func remapPalmControlMouseShortcutIfNeeded(_ event: CGEvent) -> Bool {
        guard palmControlShortcutRemappingEnabled else { return false }
        guard var remappedFlags = palmControlBaseFlags(from: event.flags) else { return false }

        remappedFlags.insert(.maskCommand)
        event.flags = remappedFlags
        return true
    }

    private func palmControlBaseFlags(from flags: CGEventFlags) -> CGEventFlags? {
        guard flags.contains(.maskControl) || physicalControlKeyDown,
              !flags.contains(.maskCommand),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskHelp) else {
            return nil
        }

        var baseFlags = flags
        baseFlags.remove(.maskControl)
        baseFlags.remove(.maskSecondaryFn)
        return baseFlags
    }

    private func handleSystemDefinedEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard onF4KeyDown != nil else {
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        let subtypeRaw = Int16(nsEvent.subtype.rawValue)
        guard subtypeRaw == nxSubtypeAuxControlButtons || subtypeRaw == nxSubtypeMenu else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = Int64(nsEvent.data1)
        let systemKeyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isAutoRepeat = (keyFlags & 0x1) != 0
        let isF4LikeSystemKey = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_F4)
            || supportedF4SystemKeyTypes.contains(systemKeyType)

        guard isF4LikeSystemKey else {
            return Unmanaged.passUnretained(event)
        }

        if keyState == nxKeyStateDown {
            if isAutoRepeat {
                return nil
            }

            if isF4LikeSystemKey {
                suppressF4KeyUp = true
                dispatchF4Trigger()
            }
            return nil
        }

        if keyState == nxKeyStateUp {
            if isF4LikeSystemKey {
                let shouldSuppress = suppressF4KeyUp
                suppressF4KeyUp = false
                return shouldSuppress ? nil : Unmanaged.passUnretained(event)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if isOptionModifierKey(keyCode) {
            if event.flags.contains(.maskAlternate) {
                activeOptionKeyCode = CGKeyCode(keyCode)
            } else {
                endAltCommandModeIfNeeded(flags: event.flags)
            }
        }

        if isControlModifierKey(keyCode) {
            physicalControlKeyDown = event.flags.contains(.maskControl)
        }

        if keyCode == Int64(kVK_CapsLock) {
            guard onCapsLockKeyDown != nil else {
                return Unmanaged.passUnretained(event)
            }

            dispatchCapsLockTrigger()
            forceCapsLockOff()
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func installFallbackKeyMonitorsIfNeeded() {
        if fallbackGlobalKeyMonitor == nil {
            fallbackGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.systemDefined, .keyDown, .keyUp, .flagsChanged]
            ) { [weak self] event in
                self?.handleFallbackObservedEvent(event)
            }
        }

        if fallbackLocalKeyMonitor == nil {
            fallbackLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.systemDefined, .keyDown, .keyUp, .flagsChanged]
            ) { [weak self] event in
                self?.handleFallbackObservedEvent(event)
                return event
            }
        }
    }

    private func removeFallbackKeyMonitors() {
        if let fallbackGlobalKeyMonitor {
            NSEvent.removeMonitor(fallbackGlobalKeyMonitor)
            self.fallbackGlobalKeyMonitor = nil
        }

        if let fallbackLocalKeyMonitor {
            NSEvent.removeMonitor(fallbackLocalKeyMonitor)
            self.fallbackLocalKeyMonitor = nil
        }
    }

    private func handleFallbackObservedEvent(_ event: NSEvent) {
        let hasF4Handler = onF4KeyDown != nil
        let hasEscapeHandler = onEscapeKeyDown != nil
        guard hasF4Handler || hasEscapeHandler else { return }

        if event.type == .keyDown {
            guard !event.isARepeat else { return }
            if event.keyCode == UInt16(kVK_Escape), hasEscapeHandler {
                dispatchEscapeTrigger()
                return
            }
            if event.keyCode == UInt16(kVK_F4), hasF4Handler {
                dispatchF4Trigger()
                return
            }
            return
        }

        guard hasF4Handler else { return }
        guard event.type == .systemDefined else { return }

        let subtypeRaw = Int16(event.subtype.rawValue)
        guard subtypeRaw == nxSubtypeAuxControlButtons || subtypeRaw == nxSubtypeMenu else { return }

        let data1 = Int64(event.data1)
        let systemKeyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isAutoRepeat = (keyFlags & 0x1) != 0
        let isF4LikeSystemKey = supportedF4SystemKeyTypes.contains(systemKeyType)

        if isF4LikeSystemKey {
            guard keyState == nxKeyStateDown, !isAutoRepeat else { return }
            dispatchF4Trigger()
            return
        }
    }

    private func resetIfIdle() {
        if !leftDown && !rightDown {
            completePendingChordIfNeeded()
        }
    }

    private func startReleasePolling() {
        stopReleasePolling()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(0.001, releasePollIntervalSeconds)
        let intervalNanoseconds = UInt64((interval * 1_000_000_000).rounded())
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNanoseconds)),
            repeating: .nanoseconds(Int(intervalNanoseconds))
        )
        timer.setEventHandler { [weak self] in
            self?.pollForChordRelease()
        }

        releasePollStartedAt = now()
        releasePollTimer = timer
        timer.resume()
    }

    private func stopReleasePolling() {
        releasePollTimer?.setEventHandler {}
        releasePollTimer?.cancel()
        releasePollTimer = nil
        releasePollStartedAt = nil
    }

    private func pollForChordRelease() {
        guard chordPendingActionAfterRelease || suppressUntilButtonsUp else {
            stopReleasePolling()
            return
        }

        if areChordButtonsPhysicallyUp() {
            completePendingChordIfNeeded()
            return
        }

        if let releasePollStartedAt, now() - releasePollStartedAt > maximumReleaseWaitSeconds {
            resetState()
        }
    }

    private func areChordButtonsPhysicallyUp() -> Bool {
        let leftIsDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let rightIsDown = CGEventSource.buttonState(.combinedSessionState, button: .right)
        return !leftIsDown && !rightIsDown
    }

    private func completePendingChordIfNeeded() {
        let shouldFire = chordPendingActionAfterRelease
        resetState()
        if shouldFire {
            dispatchChordTrigger()
        }
    }

    private func dispatchChordTrigger() {
        let currentTime = now()
        guard currentTime - lastChordTriggerDispatchTime >= minimumTriggerIntervalSeconds else { return }
        lastChordTriggerDispatchTime = currentTime

        let callback = onChord
        let delay = max(0, postReleaseTriggerDelaySeconds)
        Task {
            if delay > 0 {
                let ns = UInt64((delay * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: ns)
            }
            await MainActor.run {
                callback?()
            }
        }
    }

    private func dispatchF4Trigger() {
        dispatchKeyboardTrigger(onF4KeyDown)
    }

    private func dispatchCapsLockTrigger() {
        dispatchKeyboardTrigger(onCapsLockKeyDown)
    }

    private func dispatchEscapeTrigger() {
        dispatchKeyboardTrigger(onEscapeKeyDown)
    }

    private func forceCapsLockOff() {
        let matching = IOServiceMatching(kIOHIDSystemClass)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard openResult == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }

        _ = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
    }

    private func applyCapsLockLockingModeIfNeeded() {
        if !disableCapsLockLockingWhileIntercepting {
            restoreCapsLockLockingModeIfNeeded()
            return
        }

        guard eventTap != nil else { return }

        if !didApplyCapsLockLockingOverride {
            originalCapsLockDoesLockValue = getHIDParameterValue(for: kIOHIDKeyboardCapsLockDoesLockKey)
            didApplyCapsLockLockingOverride = true
        }

        _ = setHIDParameterValue(0, for: kIOHIDKeyboardCapsLockDoesLockKey)
        forceCapsLockOff()
    }

    private func restoreCapsLockLockingModeIfNeeded() {
        guard didApplyCapsLockLockingOverride else { return }

        let restoreValue = originalCapsLockDoesLockValue ?? 1
        _ = setHIDParameterValue(restoreValue, for: kIOHIDKeyboardCapsLockDoesLockKey)
        originalCapsLockDoesLockValue = nil
        didApplyCapsLockLockingOverride = false
    }

    private func getHIDParameterValue(for key: String) -> UInt32? {
        let matching = IOServiceMatching(kIOHIDSystemClass)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard openResult == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }

        var value: UInt32 = 0
        var size = IOByteCount(MemoryLayout<UInt32>.size)
        let result = IOHIDGetParameter(connect, key as CFString, size, &value, &size)
        guard result == KERN_SUCCESS else { return nil }
        return value
    }

    private func setHIDParameterValue(_ value: UInt32, for key: String) -> kern_return_t {
        let matching = IOServiceMatching(kIOHIDSystemClass)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return KERN_FAILURE }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard openResult == KERN_SUCCESS else { return openResult }
        defer { IOServiceClose(connect) }

        var mutableValue = value
        return IOHIDSetParameter(
            connect,
            key as CFString,
            &mutableValue,
            IOByteCount(MemoryLayout<UInt32>.size)
        )
    }

    private func dispatchKeyboardTrigger(_ callback: (@MainActor @Sendable () -> Void)?) {
        let currentTime = now()
        guard currentTime - lastKeyboardTriggerDispatchTime >= minimumTriggerIntervalSeconds else { return }
        lastKeyboardTriggerDispatchTime = currentTime

        Task { @MainActor in
            callback?()
        }
    }

    private func dispatchSideButtonDownTrigger(buttonNumber: Int64) {
        let callback = onSideButtonDown
        Task { @MainActor in
            callback?(buttonNumber)
        }
    }

    private func dispatchPrimaryClickDownTrigger() {
        let callback = onPrimaryClickDown
        Task { @MainActor in
            callback?()
        }
    }

    private func dispatchWindowArrowShortcut(_ shortcut: WindowArrowShortcut) {
        let callback = onWindowArrowShortcut
        Task { @MainActor in
            callback?(shortcut)
        }
    }

    private func dispatchCopyAndSearchTrigger(previousPasteboardChangeCount: Int) {
        let callback = onCopyAndSearchShortcut
        Task { @MainActor in
            callback?(previousPasteboardChangeCount)
        }
    }

    private func resetState() {
        stopReleasePolling()
        endAltCommandModeIfNeeded(flags: [])
        leftDown = false
        rightDown = false
        physicalControlKeyDown = false
        suppressF4KeyUp = false
        suppressCopyAndSearchKeyUp = false
        suppressSearchClipboardKeyUp = false
        suppressNextLeftMouseUp = false
        suppressUntilButtonsUp = false
        suppressedWindowArrowKeyUps.removeAll()
        suppressedAltCommandKeyUps.removeAll()
        suppressedSideButtons.removeAll()
        chordTriggeredForCurrentPress = false
        chordPendingActionAfterRelease = false
        leftDownTime = nil
        rightDownTime = nil
    }

    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
