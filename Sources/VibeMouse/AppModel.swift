@preconcurrency import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            applyMonitorState()
        }
    }

    @Published var chordWindowMs: Double {
        didSet {
            defaults.set(chordWindowMs, forKey: Self.chordWindowKey)
            monitor.chordWindowSeconds = max(0.02, chordWindowMs / 1_000.0)
        }
    }

    @Published var sideButtonPasteEnabled: Bool {
        didSet {
            defaults.set(sideButtonPasteEnabled, forKey: Self.sideButtonPasteEnabledKey)
            configureSideButtonCallback()
            applyMonitorState()
        }
    }

    @Published var forwardButtonDictationEnabled: Bool {
        didSet {
            defaults.set(forwardButtonDictationEnabled, forKey: Self.forwardButtonDictationEnabledKey)
            configureSideButtonCallback()
            applyMonitorState()
        }
    }

    @Published var experimentalForwardGesturesEnabled: Bool {
        didSet {
            defaults.set(experimentalForwardGesturesEnabled, forKey: Self.experimentalForwardGesturesEnabledKey)
            clearExperimentalForwardGestureState()
            configureSideButtonCallback()
            applyMonitorState()
        }
    }

    @Published var capsLockScreenshotEnabled: Bool {
        didSet {
            defaults.set(capsLockScreenshotEnabled, forKey: Self.capsLockScreenshotEnabledKey)
            configureKeyboardCaptureCallbacks()
            applyMonitorState()
        }
    }

    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var monitorRunning = false
    @Published private(set) var screenshotCaptureInProgress = false
    @Published private(set) var monitorStatusMessage = "Not started"
    @Published private(set) var lastActionMessage = "Ready"

    var menuBarSymbolName: String {
        if screenshotCaptureInProgress { return "camera.aperture" }
        if !isEnabled { return "computermouse" }
        if !monitorRunning { return "exclamationmark.triangle" }
        return "computermouse.fill"
    }

    var dictationShortcutLabel: String {
        "Control+Option+Command+D"
    }

    private static let enabledKey = "mouseChordShot.enabled"
    private static let chordWindowKey = "mouseChordShot.chordWindowMs"
    private static let sideButtonPasteEnabledKey = "mouseChordShot.paste.sideButtonEnabled"
    private static let forwardButtonDictationEnabledKey = "mouseChordShot.dictation.forwardButtonEnabled"
    private static let experimentalForwardGesturesEnabledKey = "mouseChordShot.forward.experimentalGesturesEnabled"
    private static let capsLockScreenshotEnabledKey = "mouseChordShot.screenshot.capsLockEnabled"
    private static let backSideButtonNumber: Int64 = 3
    private static let forwardSideButtonNumber: Int64 = 4
    private static let forwardComboDecisionDelaySeconds: TimeInterval = 0.07
    private static let forwardDoubleClickWindowSeconds: TimeInterval = 0.24
    private static let forwardDragStartThresholdPoints: CGFloat = 10
    private static let returnAfterDictationStopDelaySeconds: TimeInterval = 0.12

    private let defaults: UserDefaults
    private let monitor: MouseChordMonitor
    private let screenshotService: ScreenshotService
    private let pasteService: PasteService
    private let dictationService: DictationService
    private let dragSelectionOverlay: DragSelectionOverlay
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var pasteInProgress = false
    private var dictationInProgress = false
    private var dictationLikelyActive = false
    private var pendingForwardActionTask: Task<Void, Never>?
    private var pendingForwardSingleClickTask: Task<Void, Never>?
    private var lastPasteTriggerTime: TimeInterval = 0
    private var lastDictationTriggerTime: TimeInterval = 0
    private var forwardPressStartLocation: CGPoint?
    private var forwardPressCurrentLocation: CGPoint?
    private var forwardDragSelectionInProgress = false

    init(
        defaults: UserDefaults = .standard,
        monitor: MouseChordMonitor = MouseChordMonitor(),
        screenshotService: ScreenshotService = ScreenshotService(),
        pasteService: PasteService = PasteService(),
        dictationService: DictationService = DictationService(),
        dragSelectionOverlay: DragSelectionOverlay = DragSelectionOverlay()
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.screenshotService = screenshotService
        self.pasteService = pasteService
        self.dictationService = dictationService
        self.dragSelectionOverlay = dragSelectionOverlay
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.chordWindowMs = defaults.object(forKey: Self.chordWindowKey) as? Double ?? 60
        self.sideButtonPasteEnabled = defaults.object(forKey: Self.sideButtonPasteEnabledKey) as? Bool ?? true
        self.forwardButtonDictationEnabled = defaults.object(
            forKey: Self.forwardButtonDictationEnabledKey
        ) as? Bool ?? true
        self.experimentalForwardGesturesEnabled = defaults.object(
            forKey: Self.experimentalForwardGesturesEnabledKey
        ) as? Bool ?? false
        self.capsLockScreenshotEnabled = defaults.object(
            forKey: Self.capsLockScreenshotEnabledKey
        ) as? Bool ?? true

        self.monitor.chordWindowSeconds = max(0.02, self.chordWindowMs / 1_000.0)
        self.monitor.onChord = { [weak self] in
            self?.handleChordTriggered()
        }
        configureKeyboardCaptureCallbacks()
        configureSideButtonCallback()

        refreshPermissions()
        requestRequiredPermissionsOnFirstLaunch()
        applyMonitorState()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissions()
                self.applyMonitorState()
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.monitor.stop()
            }
        }
    }

    func refreshPermissions() {
        accessibilityTrusted = Permissions.accessibilityTrusted(prompt: false)
        screenRecordingGranted = Permissions.screenRecordingGranted(prompt: false)
    }

    func requestAllPermissions() {
        lastActionMessage = "Requesting permissions..."
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = Permissions.accessibilityTrusted(prompt: true)
        _ = Permissions.screenRecordingGranted(prompt: true)
        refreshPermissions()
        if !accessibilityTrusted {
            Permissions.openAccessibilitySettings()
            Permissions.revealAppInFinder()
            lastActionMessage = "Add/enable Vibe Mouse in Accessibility (use + if not listed)."
            applyMonitorState()
            return
        }
        if !screenRecordingGranted {
            Permissions.openScreenRecordingSettings()
            Permissions.revealAppInFinder()
            lastActionMessage = "Add/enable Vibe Mouse in Screen & System Audio Recording (use + if not listed)."
            applyMonitorState()
            return
        }
        applyMonitorState()
        lastActionMessage = "Permissions prompt sent."
    }

    func requestAccessibilityPermission() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = Permissions.accessibilityTrusted(prompt: true)
        refreshPermissions()
        if !accessibilityTrusted {
            Permissions.openAccessibilitySettings()
            Permissions.revealAppInFinder()
            lastActionMessage = "Add/enable Vibe Mouse in Accessibility (use + if not listed)."
        } else {
            lastActionMessage = "Accessibility permission granted."
        }
        applyMonitorState()
    }

    func requestScreenRecordingPermission() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = Permissions.screenRecordingGranted(prompt: true)
        refreshPermissions()
        if !screenRecordingGranted {
            Permissions.openScreenRecordingSettings()
            lastActionMessage = "Enable Vibe Mouse in Screen & System Audio Recording (use + if it is not listed)."
        } else {
            lastActionMessage = "Screen Recording permission granted."
        }
    }

    func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    func openScreenRecordingSettings() {
        Permissions.openScreenRecordingSettings()
    }

    func openInputMonitoringSettings() {
        Permissions.openInputMonitoringSettings()
    }

    func revealInstalledAppInFinder() {
        Permissions.revealAppInFinder()
        lastActionMessage = "Finder opened. Use + in macOS Settings and choose Vibe Mouse.app."
    }

    func triggerManualScreenshot() {
        runScreenshot()
    }

    private func requestRequiredPermissionsOnFirstLaunch() {
        let hasShownPrompt = defaults.bool(forKey: "mouseChordShot.didRequestPermissions")
        guard !hasShownPrompt else { return }
        defaults.set(true, forKey: "mouseChordShot.didRequestPermissions")

        _ = Permissions.accessibilityTrusted(prompt: true)
        refreshPermissions()
    }

    private func applyMonitorState() {
        guard isEnabled else {
            clearForwardPendingTasks()
            clearExperimentalForwardGestureState()
            monitor.stop()
            monitorRunning = false
            monitorStatusMessage = "Disabled"
            return
        }

        if screenshotCaptureInProgress {
            clearForwardPendingTasks()
            clearExperimentalForwardGestureState()
            monitor.stop()
            monitorRunning = false
            monitorStatusMessage = "Paused while screenshot tool is active"
            return
        }

        monitor.chordWindowSeconds = max(0.02, chordWindowMs / 1_000.0)

        switch monitor.start() {
        case .started:
            monitorRunning = true
            if accessibilityTrusted {
                monitorStatusMessage = monitorListeningStatusDescription()
            } else {
                monitorStatusMessage = "Waiting for Accessibility permission"
            }
        case .failed(let reason):
            monitorRunning = false
            monitorStatusMessage = reason
        }
    }

    private func handleChordTriggered() {
        guard isEnabled else { return }
        runScreenshot()
    }

    private func handleKeyboardCaptureTriggered() {
        guard isEnabled else { return }
        runScreenshot()
    }

    private func handleSideButtonDown(_ buttonNumber: Int64) {
        guard isEnabled else { return }
        guard buttonNumber == Self.forwardSideButtonNumber else { return }

        if experimentalForwardGesturesEnabled {
            handleExperimentalForwardDown()
            return
        }

        clearForwardPendingTasks()
        let comboDelayNanoseconds = UInt64((Self.forwardComboDecisionDelaySeconds * 1_000_000_000).rounded())
        pendingForwardActionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: comboDelayNanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.pendingForwardActionTask = nil

                if self.sideButtonPasteEnabled, self.isBackSideButtonDown() {
                    self.runPasteFromSideButtonCombo()
                    return
                }

                if self.forwardButtonDictationEnabled {
                    self.runDictationFromForwardButton()
                }
            }
        }
    }

    private func handleSideButtonUp(_ buttonNumber: Int64, location: CGPoint) {
        guard isEnabled, experimentalForwardGesturesEnabled else { return }
        guard buttonNumber == Self.forwardSideButtonNumber else { return }
        handleExperimentalForwardUp(location: location)
    }

    private func handleSideButtonDragged(_ buttonNumber: Int64, location: CGPoint) {
        guard isEnabled, experimentalForwardGesturesEnabled else { return }
        guard buttonNumber == Self.forwardSideButtonNumber else { return }
        handleExperimentalForwardDragged(location: location)
    }

    private func handleExperimentalForwardDown() {
        clearExperimentalForwardGestureState()
        let currentLocation = NSEvent.mouseLocation
        forwardPressStartLocation = currentLocation
        forwardPressCurrentLocation = currentLocation
    }

    private func handleExperimentalForwardDragged(location: CGPoint) {
        guard let startLocation = forwardPressStartLocation else { return }
        forwardPressCurrentLocation = location

        if !forwardDragSelectionInProgress {
            let deltaX = location.x - startLocation.x
            let deltaY = location.y - startLocation.y
            let dragDistance = hypot(deltaX, deltaY)
            guard dragDistance >= Self.forwardDragStartThresholdPoints else { return }

            pendingForwardSingleClickTask?.cancel()
            pendingForwardSingleClickTask = nil
            forwardDragSelectionInProgress = true
            lastActionMessage = "Release Forward to capture selected area."
        }

        dragSelectionOverlay.updateSelection(from: startLocation, to: location)
    }

    private func handleExperimentalForwardUp(location: CGPoint) {
        guard let startLocation = forwardPressStartLocation else { return }
        let didDragSelect = forwardDragSelectionInProgress
        let endLocation = location

        clearExperimentalForwardGestureState()

        if didDragSelect {
            runForwardDragScreenshot(from: startLocation, to: endLocation)
            return
        }

        handleForwardSingleOrDoubleClick()
    }

    private func runScreenshot() {
        refreshPermissions()

        guard !screenshotCaptureInProgress else {
            lastActionMessage = "A screenshot capture is already in progress."
            return
        }

        guard ensureScreenRecordingPermissionForScreenshot() else { return }

        screenshotCaptureInProgress = true
        applyMonitorState()
        lastActionMessage = "Screenshot mode active. Click and drag an area..."
        screenshotService.captureInteractiveToClipboard { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screenshotCaptureInProgress = false
                self.applyMonitorState()

                switch result {
                case .success:
                    self.lastActionMessage = "Screenshot captured to clipboard."
                case .failure(.cancelled):
                    self.lastActionMessage = "Screenshot canceled."
                case .failure(.alreadyRunning):
                    self.lastActionMessage = "A screenshot capture is already in progress."
                case .failure(.failed(let message)):
                    self.lastActionMessage = "Screenshot failed: \(message)"
                }
            }
        }
    }

    private func runPasteFromSideButtonCombo() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        // Defend against hardware bounce/repeat events causing duplicate paste.
        if currentTime - lastPasteTriggerTime < 0.18 {
            return
        }
        lastPasteTriggerTime = currentTime

        guard !pasteInProgress else { return }
        guard ensureAccessibilityForAutomation(triggerLabel: "paste shortcut") else { return }

        pasteInProgress = true
        lastActionMessage = "Pasting clipboard via Back+Forward chord..."
        pasteService.pasteClipboard { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pasteInProgress = false
                switch result {
                case .success:
                    self.lastActionMessage = "Clipboard pasted (Back + Forward side-button chord)."
                case .failure(.failed(let message)):
                    self.lastActionMessage = "Could not paste clipboard: \(message)"
                }
            }
        }
    }

    private func runPasteFromForwardDoubleClick() {
        guard sideButtonPasteEnabled else {
            lastActionMessage = "Forward double-click paste is disabled in Behavior."
            return
        }

        let currentTime = ProcessInfo.processInfo.systemUptime
        if currentTime - lastPasteTriggerTime < 0.18 {
            return
        }
        lastPasteTriggerTime = currentTime

        guard !pasteInProgress else { return }
        guard ensureAccessibilityForAutomation(triggerLabel: "paste shortcut") else { return }

        pasteInProgress = true
        lastActionMessage = "Pasting clipboard via Forward double-click..."
        pasteService.pasteClipboard { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pasteInProgress = false
                switch result {
                case .success:
                    self.lastActionMessage = "Clipboard pasted (Forward double-click)."
                case .failure(.failed(let message)):
                    self.lastActionMessage = "Could not paste clipboard: \(message)"
                }
            }
        }
    }

    private func runDictationFromForwardButton() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        if currentTime - lastDictationTriggerTime < 0.18 {
            return
        }
        lastDictationTriggerTime = currentTime

        guard !dictationInProgress else { return }
        guard ensureAccessibilityForAutomation(triggerLabel: "dictation shortcut") else { return }
        let wasLikelyActive = dictationLikelyActive

        dictationInProgress = true
        lastActionMessage = wasLikelyActive
            ? "Stopping Dictation via Forward button..."
            : "Starting Dictation via Forward button..."
        dictationService.toggleDictation { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dictationInProgress = false
                switch result {
                case .success:
                    self.dictationLikelyActive = !wasLikelyActive
                    if wasLikelyActive {
                        self.lastActionMessage = "Dictation stopped. Sending Return..."
                        self.sendReturnAfterDictationStop()
                    } else {
                        self.lastActionMessage = "Dictation started (Forward side button)."
                    }
                case .failure(.failed(let message)):
                    self.lastActionMessage = "Could not toggle Dictation: \(message)"
                }
            }
        }
    }

    private func runForwardDragScreenshot(from startLocation: CGPoint, to endLocation: CGPoint) {
        refreshPermissions()
        guard ensureScreenRecordingPermissionForScreenshot() else { return }

        guard !screenshotCaptureInProgress else {
            lastActionMessage = "A screenshot capture is already in progress."
            return
        }

        screenshotCaptureInProgress = true
        applyMonitorState()
        lastActionMessage = "Capturing selected area..."
        screenshotService.captureRectangleToClipboard(from: startLocation, to: endLocation) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screenshotCaptureInProgress = false
                self.applyMonitorState()

                switch result {
                case .success:
                    self.lastActionMessage = "Screenshot captured to clipboard (Forward drag)."
                case .failure(.cancelled):
                    self.lastActionMessage = "Forward-drag screenshot canceled."
                case .failure(.alreadyRunning):
                    self.lastActionMessage = "A screenshot capture is already in progress."
                case .failure(.failed(let message)):
                    self.lastActionMessage = "Screenshot failed: \(message)"
                }
            }
        }
    }

    private func handleForwardSingleOrDoubleClick() {
        if let pendingTask = pendingForwardSingleClickTask {
            pendingTask.cancel()
            pendingForwardSingleClickTask = nil
            runPasteFromForwardDoubleClick()
            return
        }

        let waitNanoseconds = UInt64((Self.forwardDoubleClickWindowSeconds * 1_000_000_000).rounded())
        pendingForwardSingleClickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: waitNanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.pendingForwardSingleClickTask = nil
                guard self.forwardButtonDictationEnabled else {
                    self.lastActionMessage = "Forward single-click Dictation is disabled in Behavior."
                    return
                }
                self.runDictationFromForwardButton()
            }
        }
    }

    private func ensureAccessibilityForAutomation(triggerLabel: String) -> Bool {
        refreshPermissions()

        if !accessibilityTrusted {
            lastActionMessage = "Accessibility permission is required for \(triggerLabel)."
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = Permissions.accessibilityTrusted(prompt: true)
            refreshPermissions()
            guard accessibilityTrusted else {
                Permissions.openAccessibilitySettings()
                Permissions.revealAppInFinder()
                lastActionMessage = "Add/enable Vibe Mouse in Accessibility (use + if not listed)."
                applyMonitorState()
                return false
            }
            applyMonitorState()
        }

        return true
    }

    private func ensureScreenRecordingPermissionForScreenshot() -> Bool {
        if !screenRecordingGranted {
            lastActionMessage = "Screen Recording permission is required."
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = Permissions.screenRecordingGranted(prompt: true)
            refreshPermissions()
            guard screenRecordingGranted else {
                Permissions.openScreenRecordingSettings()
                Permissions.revealAppInFinder()
                lastActionMessage = "Add/enable Vibe Mouse in Screen & System Audio Recording (use + if not listed)."
                return false
            }
        }

        return true
    }

    private func configureSideButtonCallback() {
        var interceptedButtons: Set<Int64> = []
        if sideButtonPasteEnabled || forwardButtonDictationEnabled || experimentalForwardGesturesEnabled {
            interceptedButtons.insert(Self.forwardSideButtonNumber)
        }

        monitor.interceptedSideMouseButtons = interceptedButtons
        if !interceptedButtons.isEmpty {
            monitor.onSideButtonDown = { [weak self] buttonNumber in
                self?.handleSideButtonDown(buttonNumber)
            }
            monitor.onSideButtonUp = { [weak self] buttonNumber, location in
                self?.handleSideButtonUp(buttonNumber, location: location)
            }
            monitor.onSideButtonDragged = { [weak self] buttonNumber, location in
                self?.handleSideButtonDragged(buttonNumber, location: location)
            }
        } else {
            monitor.onSideButtonDown = nil
            monitor.onSideButtonUp = nil
            monitor.onSideButtonDragged = nil
        }
    }

    private func configureKeyboardCaptureCallbacks() {
        monitor.disableCapsLockLockingWhileIntercepting = capsLockScreenshotEnabled

        // F4 screenshot trigger is intentionally disabled.
        monitor.onF4KeyDown = nil

        if capsLockScreenshotEnabled {
            monitor.onCapsLockKeyDown = { [weak self] in
                self?.handleKeyboardCaptureTriggered()
            }
        } else {
            monitor.onCapsLockKeyDown = nil
        }
    }

    private func monitorListeningStatusDescription() -> String {
        let screenshotSegment = "screenshot (\(screenshotTriggerLabel))"
        if experimentalForwardGesturesEnabled {
            var forwardSegments: [String] = ["Forward drag screenshot capture"]
            if forwardButtonDictationEnabled {
                forwardSegments.append("Forward single-click Dictation toggle")
            }
            if sideButtonPasteEnabled {
                forwardSegments.append("Forward double-click paste")
            }
            return "Listening for \(screenshotSegment) and \(forwardSegments.joined(separator: ", "))"
        }

        let backSegment = "Back+Forward paste chord"
        let forwardSegment = "Forward button Dictation toggle"

        if sideButtonPasteEnabled && forwardButtonDictationEnabled {
            return "Listening for \(screenshotSegment), \(backSegment), and \(forwardSegment)"
        }

        if sideButtonPasteEnabled {
            return "Listening for \(screenshotSegment) and \(backSegment)"
        }

        if forwardButtonDictationEnabled {
            return "Listening for \(screenshotSegment) and \(forwardSegment)"
        }

        return "Listening for \(screenshotSegment)"
    }

    private var screenshotTriggerLabel: String {
        if capsLockScreenshotEnabled {
            return "Caps Lock or left+right"
        }
        return "left+right"
    }

    private func clearForwardPendingTasks() {
        pendingForwardActionTask?.cancel()
        pendingForwardActionTask = nil
        pendingForwardSingleClickTask?.cancel()
        pendingForwardSingleClickTask = nil
    }

    private func clearExperimentalForwardGestureState() {
        forwardPressStartLocation = nil
        forwardPressCurrentLocation = nil
        forwardDragSelectionInProgress = false
        dragSelectionOverlay.hide()
    }

    private func sendReturnAfterDictationStop() {
        let delay = Self.returnAfterDictationStopDelaySeconds
        Task { @MainActor [weak self] in
            guard let self else { return }

            if delay > 0 {
                let nanoseconds = UInt64((delay * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            self.dictationService.pressReturn { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.lastActionMessage = "Dictation stopped and Return sent."
                    case .failure(.failed(let message)):
                        self.lastActionMessage = "Dictation stopped, but Return failed: \(message)"
                    }
                }
            }
        }
    }

    private func isBackSideButtonDown() -> Bool {
        guard let backButton = CGMouseButton(rawValue: UInt32(Self.backSideButtonNumber)) else {
            return false
        }

        return CGEventSource.buttonState(
            .combinedSessionState,
            button: backButton
        )
    }
}
