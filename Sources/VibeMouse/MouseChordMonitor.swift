import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit
import IOKit
import IOKit.hidsystem

final class MouseChordMonitor {
    enum StartResult {
        case started
        case failed(String)
    }

    var chordWindowSeconds: TimeInterval = 0.06
    var onChord: (@MainActor @Sendable () -> Void)?
    var onF4KeyDown: (@MainActor @Sendable () -> Void)?
    var onCapsLockKeyDown: (@MainActor @Sendable () -> Void)?
    var disableCapsLockLockingWhileIntercepting = false {
        didSet {
            applyCapsLockLockingModeIfNeeded()
        }
    }
    var onSideButtonDown: (@MainActor @Sendable (_ buttonNumber: Int64) -> Void)?
    var onSideButtonUp: (@MainActor @Sendable (_ buttonNumber: Int64, _ location: CGPoint) -> Void)?
    var onSideButtonDragged: (@MainActor @Sendable (_ buttonNumber: Int64, _ location: CGPoint) -> Void)?
    var interceptedSideMouseButtons: Set<Int64> = []
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
    private var suppressedSideButtons: Set<Int64> = []
    private var lastChordTriggerDispatchTime: TimeInterval = 0
    private var lastKeyboardTriggerDispatchTime: TimeInterval = 0
    private var releasePollTimer: DispatchSourceTimer?
    private var releasePollStartedAt: TimeInterval?
    private var didApplyCapsLockLockingOverride = false
    private var originalCapsLockDoesLockValue: UInt32?

    private let supportedSideMouseButtons: Set<Int64> = [3, 4]
    private let nxSystemDefinedEventTypeRawValue: UInt32 = 14 // NX_SYSDEFINED
    private let nxSubtypeAuxControlButtons: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private let nxSubtypeMenu: Int16 = 16 // NX_SUBTYPE_MENU
    private let nxKeyStateDown: Int64 = 0xA
    private let nxKeyStateUp: Int64 = 0xB
    // F4/search commonly arrives as one of these media/system key types.
    private let supportedF4SystemKeyTypes: Set<Int64> = [13, 25, 160]

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
            leftDown = true
            leftDownTime = now()
            if maybeTriggerChord() {
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .rightMouseDown:
            rightDown = true
            rightDownTime = now()
            if maybeTriggerChord() {
                return nil
            }
            return suppressUntilButtonsUp ? nil : Unmanaged.passUnretained(event)

        case .leftMouseUp:
            leftDown = false
            let shouldSuppress = suppressUntilButtonsUp
            resetIfIdle()
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)

        case .rightMouseUp:
            rightDown = false
            let shouldSuppress = suppressUntilButtonsUp
            resetIfIdle()
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)

        case .leftMouseDragged, .rightMouseDragged:
            return suppressUntilButtonsUp ? nil : Unmanaged.passUnretained(event)

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
            let hasHandler = onSideButtonDown != nil || onSideButtonUp != nil || onSideButtonDragged != nil
            guard interceptedSideMouseButtons.contains(buttonNumber),
                  hasHandler else {
                return Unmanaged.passUnretained(event)
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

    private func handleOtherMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        if suppressedSideButtons.contains(buttonNumber) {
            suppressedSideButtons.remove(buttonNumber)
            dispatchSideButtonUpTrigger(buttonNumber: buttonNumber, location: event.location)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleOtherMouseDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        if suppressedSideButtons.contains(buttonNumber) {
            dispatchSideButtonDraggedTrigger(buttonNumber: buttonNumber, location: event.location)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if keyCode == Int64(kVK_CapsLock) {
            guard onCapsLockKeyDown != nil else {
                return Unmanaged.passUnretained(event)
            }

            dispatchCapsLockTrigger()
            forceCapsLockOff()
            return nil
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
        guard hasF4Handler else { return }

        if event.type == .keyDown {
            guard !event.isARepeat else { return }
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

    private func dispatchSideButtonUpTrigger(buttonNumber: Int64, location: CGPoint) {
        let callback = onSideButtonUp
        Task { @MainActor in
            callback?(buttonNumber, location)
        }
    }

    private func dispatchSideButtonDraggedTrigger(buttonNumber: Int64, location: CGPoint) {
        let callback = onSideButtonDragged
        Task { @MainActor in
            callback?(buttonNumber, location)
        }
    }

    private func resetState() {
        stopReleasePolling()
        leftDown = false
        rightDown = false
        suppressF4KeyUp = false
        suppressUntilButtonsUp = false
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
