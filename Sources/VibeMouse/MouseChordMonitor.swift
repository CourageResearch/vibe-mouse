import Foundation
import CoreGraphics

final class MouseChordMonitor {
    enum StartResult {
        case started
        case failed(String)
    }

    var chordWindowSeconds: TimeInterval = 0.06
    var onChord: (@MainActor @Sendable () -> Void)?
    var onMiddleButtonDown: (@MainActor @Sendable () -> Void)?
    var onMiddleButtonUp: (@MainActor @Sendable () -> Void)?
    var onSideButtonDown: (@MainActor @Sendable (_ buttonNumber: Int64) -> Void)?
    var postReleaseTriggerDelaySeconds: TimeInterval = 0
    var minimumTriggerIntervalSeconds: TimeInterval = 0.20
    var releasePollIntervalSeconds: TimeInterval = 0.005
    var maximumReleaseWaitSeconds: TimeInterval = 0.50

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var attachedRunLoop: CFRunLoop?

    private var leftDown = false
    private var rightDown = false
    private var suppressUntilButtonsUp = false
    private var chordTriggeredForCurrentPress = false
    private var chordPendingActionAfterRelease = false
    private var leftDownTime: TimeInterval?
    private var rightDownTime: TimeInterval?
    private var suppressMiddleButtonUntilUp = false
    private var suppressedSideButtons: Set<Int64> = []
    private var lastChordTriggerDispatchTime: TimeInterval = 0
    private var releasePollTimer: DispatchSourceTimer?
    private var releasePollStartedAt: TimeInterval?

    private let middleMouseButtonNumber: Int64 = 2
    private let supportedSideMouseButtons: Set<Int64> = [3, 4]

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

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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
        resetState()
    }

    private func maskFor(_ type: CGEventType) -> CGEventMask {
        1 << type.rawValue
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<MouseChordMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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

        if buttonNumber == middleMouseButtonNumber {
            guard onMiddleButtonDown != nil || onMiddleButtonUp != nil else {
                return Unmanaged.passUnretained(event)
            }

            suppressMiddleButtonUntilUp = true
            dispatchMiddleButtonDownTrigger()
            return nil
        }

        if supportedSideMouseButtons.contains(buttonNumber) {
            guard onSideButtonDown != nil else {
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

        if buttonNumber == middleMouseButtonNumber {
            let shouldSuppress = suppressMiddleButtonUntilUp
            suppressMiddleButtonUntilUp = false
            if shouldSuppress {
                dispatchMiddleButtonUpTrigger()
            }
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        if suppressedSideButtons.contains(buttonNumber) {
            suppressedSideButtons.remove(buttonNumber)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleOtherMouseDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        if buttonNumber == middleMouseButtonNumber {
            return suppressMiddleButtonUntilUp ? nil : Unmanaged.passUnretained(event)
        }

        if suppressedSideButtons.contains(buttonNumber) {
            return nil
        }

        return Unmanaged.passUnretained(event)
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

    private func dispatchMiddleButtonDownTrigger() {
        let callback = onMiddleButtonDown
        Task { @MainActor in
            callback?()
        }
    }

    private func dispatchMiddleButtonUpTrigger() {
        let callback = onMiddleButtonUp
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

    private func resetState() {
        stopReleasePolling()
        leftDown = false
        rightDown = false
        suppressUntilButtonsUp = false
        suppressMiddleButtonUntilUp = false
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
