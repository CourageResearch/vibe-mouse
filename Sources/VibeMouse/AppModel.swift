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

    @Published var pressReturnOnDictationStop: Bool {
        didSet {
            defaults.set(pressReturnOnDictationStop, forKey: Self.pressReturnOnDictationStopKey)
        }
    }

    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var monitorRunning = false
    @Published private(set) var screenshotCaptureInProgress = false
    @Published private(set) var dictationActive = false
    @Published private(set) var monitorStatusMessage = "Not started"
    @Published private(set) var lastActionMessage = "Ready"

    var menuBarSymbolName: String {
        if screenshotCaptureInProgress { return "camera.aperture" }
        if !isEnabled { return "computermouse" }
        if !monitorRunning { return "exclamationmark.triangle" }
        return "computermouse.fill"
    }

    private static let enabledKey = "mouseChordShot.enabled"
    private static let chordWindowKey = "mouseChordShot.chordWindowMs"
    private static let pressReturnOnDictationStopKey = "mouseChordShot.dictation.pressReturnOnStop"

    private let defaults: UserDefaults
    private let monitor: MouseChordMonitor
    private let screenshotService: ScreenshotService
    private let dictationService: DictationService
    private let pasteService: PasteService
    private var activationObserver: NSObjectProtocol?
    private var middleButtonHeldForDictation = false
    private var dictationStartInProgress = false
    private var dictationStopInProgress = false
    private var stopDictationAfterStartCompletes = false
    private var startDictationAfterStopCompletes = false
    private var dictationTargetProcessID: pid_t?
    private var pasteInProgress = false

    init(
        defaults: UserDefaults = .standard,
        monitor: MouseChordMonitor = MouseChordMonitor(),
        screenshotService: ScreenshotService = ScreenshotService(),
        dictationService: DictationService = DictationService(),
        pasteService: PasteService = PasteService()
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.screenshotService = screenshotService
        self.dictationService = dictationService
        self.pasteService = pasteService
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.chordWindowMs = defaults.object(forKey: Self.chordWindowKey) as? Double ?? 60
        self.pressReturnOnDictationStop = defaults.object(forKey: Self.pressReturnOnDictationStopKey) as? Bool ?? true

        self.monitor.chordWindowSeconds = max(0.02, self.chordWindowMs / 1_000.0)
        self.monitor.onChord = { [weak self] in
            self?.handleChordTriggered()
        }
        self.monitor.onMiddleButtonDown = { [weak self] in
            self?.handleMiddleButtonDown()
        }
        self.monitor.onMiddleButtonUp = { [weak self] in
            self?.handleMiddleButtonUp()
        }
        self.monitor.onSideButtonDown = { [weak self] buttonNumber in
            self?.handleSideButtonDown(buttonNumber)
        }

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
            monitor.stop()
            monitorRunning = false
            monitorStatusMessage = "Disabled"
            return
        }

        if screenshotCaptureInProgress {
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
                monitorStatusMessage = "Listening for left+right screenshot, middle-button push-to-talk, and side-button paste"
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

    private func handleMiddleButtonDown() {
        guard isEnabled else { return }
        startDictationPushToTalk()
    }

    private func handleMiddleButtonUp() {
        guard isEnabled else { return }
        stopDictationPushToTalk()
    }

    private func handleSideButtonDown(_ buttonNumber: Int64) {
        guard isEnabled else { return }
        runPasteFromSideButton(buttonNumber)
    }

    private func runScreenshot() {
        refreshPermissions()

        guard !screenshotCaptureInProgress else {
            lastActionMessage = "A screenshot capture is already in progress."
            return
        }

        if !screenRecordingGranted {
            lastActionMessage = "Screen Recording permission is required."
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = Permissions.screenRecordingGranted(prompt: true)
            refreshPermissions()
            guard screenRecordingGranted else {
                Permissions.openScreenRecordingSettings()
                Permissions.revealAppInFinder()
                lastActionMessage = "Add/enable Vibe Mouse in Screen & System Audio Recording (use + if not listed)."
                return
            }
        }

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

    private func runPasteFromSideButton(_ buttonNumber: Int64) {
        guard !pasteInProgress else { return }
        guard ensureAccessibilityForAutomation(triggerLabel: "paste shortcut") else { return }

        pasteInProgress = true
        lastActionMessage = "Pasting clipboard via side button..."
        pasteService.pasteClipboard { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pasteInProgress = false
                switch result {
                case .success:
                    let sideLabel = buttonNumber == 3 ? "Back side button" : "Forward side button"
                    self.lastActionMessage = "Clipboard pasted (\(sideLabel))."
                case .failure(.failed(let message)):
                    self.lastActionMessage = "Could not paste clipboard: \(message)"
                }
            }
        }
    }

    private func startDictationPushToTalk() {
        middleButtonHeldForDictation = true
        stopDictationAfterStartCompletes = false

        guard !dictationStartInProgress else { return }
        if dictationStopInProgress {
            startDictationAfterStopCompletes = true
            lastActionMessage = "Waiting for previous dictation stop to finish..."
            return
        }
        guard !dictationActive else { return }
        guard ensureAccessibilityForAutomation(triggerLabel: "dictation trigger") else { return }

        startDictationAfterStopCompletes = false
        dictationStartInProgress = true
        dictationTargetProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lastActionMessage = "Starting dictation..."

        dictationService.startDictation(targetProcessID: dictationTargetProcessID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dictationStartInProgress = false
                switch result {
                case .success:
                    self.dictationActive = true
                    if self.stopDictationAfterStartCompletes || !self.middleButtonHeldForDictation {
                        self.stopDictationAfterStartCompletes = false
                        self.stopDictationAfterPushToTalkStart()
                    } else {
                        self.lastActionMessage = "Dictation active while middle button is held. Release to stop."
                    }
                case .failure(.alreadyRunning):
                    self.lastActionMessage = "Dictation trigger is already in progress."
                case .failure(.failed(let message)):
                    self.dictationActive = false
                    self.dictationTargetProcessID = nil
                    self.lastActionMessage = "Could not start dictation: \(message)"
                }
            }
        }
    }

    private func stopDictationPushToTalk() {
        middleButtonHeldForDictation = false
        startDictationAfterStopCompletes = false

        if dictationStartInProgress {
            stopDictationAfterStartCompletes = true
            return
        }

        guard dictationActive else { return }
        guard !dictationStopInProgress else { return }

        stopDictationAfterStartCompletes = false
        stopDictationAfterPushToTalkStart()
    }

    private func stopDictationAfterPushToTalkStart() {
        guard !dictationStopInProgress else { return }

        dictationStopInProgress = true
        let shouldPressReturn = pressReturnOnDictationStop
        let targetProcessID = dictationTargetProcessID
        lastActionMessage = shouldPressReturn
            ? "Stopping dictation on release and pressing Return..."
            : "Stopping dictation on release..."

        dictationService.stopDictation(
            targetProcessID: targetProcessID,
            pressReturnAfterStop: shouldPressReturn
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dictationStopInProgress = false
                switch result {
                case .success:
                    self.dictationActive = false
                    self.dictationTargetProcessID = nil
                    self.lastActionMessage = shouldPressReturn
                        ? "Dictation stopped and Return pressed."
                        : "Dictation stopped."
                case .failure(.alreadyRunning):
                    self.lastActionMessage = "Dictation trigger is already in progress."
                case .failure(.failed(let message)):
                    if message.localizedCaseInsensitiveContains("dictation")
                        && message.localizedCaseInsensitiveContains("menu item") {
                        self.dictationActive = false
                        self.dictationTargetProcessID = nil
                    }
                    self.lastActionMessage = "Could not stop dictation: \(message)"
                }

                if self.startDictationAfterStopCompletes, self.middleButtonHeldForDictation {
                    self.startDictationAfterStopCompletes = false
                    self.startDictationPushToTalk()
                }
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
}
