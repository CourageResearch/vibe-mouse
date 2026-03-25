@preconcurrency import AppKit
import Combine
import Carbon.HIToolbox
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum DictationBackend: String, CaseIterable, Identifiable {
        case appleDictation = "apple"
        case whisperCpp = "whisper.cpp"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .appleDictation:
                return "Apple Dictation"
            case .whisperCpp:
                return "whisper.cpp (local)"
            }
        }
    }

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

    @Published var forwardButtonDictationEnabled: Bool {
        didSet {
            defaults.set(forwardButtonDictationEnabled, forKey: Self.forwardButtonDictationEnabledKey)
            configureSideButtonCallback()
            applyMonitorState()
        }
    }

    @Published var screenshotPasteStartsDictationEnabled: Bool {
        didSet {
            defaults.set(
                screenshotPasteStartsDictationEnabled,
                forKey: Self.screenshotPasteStartsDictationEnabledKey
            )
            if !screenshotPasteStartsDictationEnabled {
                disarmScreenshotAutoDictationStop()
            }
            applyMonitorState()
        }
    }

    @Published var dictationBackend: DictationBackend {
        didSet {
            defaults.set(dictationBackend.rawValue, forKey: Self.dictationBackendKey)
            if dictationBackend != .appleDictation {
                dictationLikelyActive = false
                dictationActive = whisperDictationService.isRecording
            }
            applyMonitorState()
        }
    }

    @Published var whisperModelPreset: WhisperDictationService.ModelPreset {
        didSet {
            defaults.set(whisperModelPreset.rawValue, forKey: Self.whisperModelPresetKey)
            applyMonitorState()
        }
    }

    @Published var whisperExecutablePath: String {
        didSet {
            defaults.set(whisperExecutablePath, forKey: Self.whisperExecutablePathKey)
        }
    }

    @Published var whisperModelDirectoryPath: String {
        didSet {
            defaults.set(whisperModelDirectoryPath, forKey: Self.whisperModelDirectoryPathKey)
        }
    }

    @Published var whisperMicrophoneSelectionID: String {
        didSet {
            defaults.set(whisperMicrophoneSelectionID, forKey: Self.whisperMicrophoneSelectionKey)
        }
    }

    @Published var whisperDebugRecordingsEnabled: Bool {
        didSet {
            defaults.set(whisperDebugRecordingsEnabled, forKey: Self.whisperDebugRecordingsEnabledKey)
        }
    }

    @Published var capsLockScreenshotEnabled: Bool {
        didSet {
            defaults.set(capsLockScreenshotEnabled, forKey: Self.capsLockScreenshotEnabledKey)
            configureKeyboardCaptureCallbacks()
            applyMonitorState()
        }
    }

    @Published var reverseScrollingEnabled: Bool {
        didSet {
            defaults.set(reverseScrollingEnabled, forKey: Self.reverseScrollingEnabledKey)
            monitor.reverseScrollingEnabled = reverseScrollingEnabled
        }
    }

    @Published var mouseScrollSpeed: Double {
        didSet {
            let clamped = max(4, min(36, mouseScrollSpeed))
            if clamped != mouseScrollSpeed {
                mouseScrollSpeed = clamped
                return
            }
            defaults.set(mouseScrollSpeed, forKey: Self.mouseScrollSpeedKey)
            monitor.mouseScrollSpeed = mouseScrollSpeed
        }
    }

    @Published var scrollEventLoggingEnabled: Bool {
        didSet {
            defaults.set(scrollEventLoggingEnabled, forKey: Self.scrollEventLoggingEnabledKey)
            configureScrollDebugLoggingCallback()
            lastActionMessage = scrollEventLoggingEnabled
                ? "Scroll debug logging enabled (\(Self.scrollEventLogURL.path))."
                : "Scroll debug logging disabled."
        }
    }

    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var monitorRunning = false
    @Published private(set) var screenshotCaptureInProgress = false
    @Published private(set) var dictationActive = false {
        didSet {
            updateDictationCursorOverlay()
        }
    }
    @Published private(set) var whisperMicrophoneOptions: [WhisperDictationService.InputDeviceOption] = []
    @Published private(set) var monitorStatusMessage = "Not started"
    @Published private(set) var lastActionMessage = "Ready"

    var menuBarSymbolName: String {
        if screenshotCaptureInProgress { return "camera.aperture" }
        if dictationActive { return "mic.fill" }
        if !isEnabled { return "computermouse" }
        if !monitorRunning { return "exclamationmark.triangle" }
        return "computermouse.fill"
    }

    var dictationShortcutLabel: String {
        "Control+Option+Command+D"
    }

    var isAppleDictationBackendSelected: Bool {
        dictationBackend == .appleDictation
    }

    var isWhisperBackendSelected: Bool {
        dictationBackend == .whisperCpp
    }

    var screenshotPasteStartsDictationActive: Bool {
        forwardButtonDictationEnabled && screenshotPasteStartsDictationEnabled
    }

    var whisperModelFileName: String {
        whisperModelPreset.fileName
    }

    var whisperDebugRecordingsPath: String {
        WhisperDictationService.debugRecordingsDirectoryPath
    }

    var whisperSelectedMicrophoneSummary: String {
        whisperMicrophoneOptions.first(where: { $0.id == whisperMicrophoneSelectionID })?.displayName
            ?? WhisperDictationService.availableInputOptions().first(where: { $0.id == whisperMicrophoneSelectionID })?.displayName
            ?? "System Default"
    }

    var dictationEventLogPath: String {
        Self.dictationEventLogURL.path
    }

    var scrollEventLogPath: String {
        Self.scrollEventLogURL.path
    }

    private var appDisplayName: String {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        if let bundleName, !bundleName.isEmpty {
            return bundleName
        }
        return "Vibe Mouse"
    }

    private static let enabledKey = "mouseChordShot.enabled"
    private static let chordWindowKey = "mouseChordShot.chordWindowMs"
    private static let forwardButtonDictationEnabledKey = "mouseChordShot.dictation.forwardButtonEnabled"
    private static let screenshotPasteStartsDictationEnabledKey = "mouseChordShot.dictation.screenshotPasteStarts"
    private static let dictationBackendKey = "mouseChordShot.dictation.backend"
    private static let whisperModelPresetKey = "mouseChordShot.dictation.whisper.modelPreset"
    private static let whisperExecutablePathKey = "mouseChordShot.dictation.whisper.executablePath"
    private static let whisperModelDirectoryPathKey = "mouseChordShot.dictation.whisper.modelDirectoryPath"
    private static let whisperMicrophoneSelectionKey = "mouseChordShot.dictation.whisper.microphoneSelectionID"
    private static let whisperDebugRecordingsEnabledKey = "mouseChordShot.dictation.whisper.debugRecordingsEnabled"
    private static let capsLockScreenshotEnabledKey = "mouseChordShot.screenshot.capsLockEnabled"
    private static let reverseScrollingEnabledKey = "mouseChordShot.scroll.reverseEnabled"
    private static let mouseScrollSpeedKey = "mouseChordShot.scroll.mouseSpeed"
    private static let scrollEventLoggingEnabledKey = "mouseChordShot.scroll.debugLogEnabled"
    private static let scrollEventLogURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("vibe-mouse-scroll.log", isDirectory: false)
    private static let dictationEventLogURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("vibe-mouse-dictation.log", isDirectory: false)
    private static let scrollLogDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let forwardSideButtonNumber: Int64 = 4
    private static let returnAfterDictationStopDelaySeconds: TimeInterval = 0.12
    private static let dictationAutoStopTimeoutSeconds: TimeInterval = 20
    private static let textInputFocusSettleDelaySeconds: TimeInterval = 0.08
    private static let screenshotAutoPasteDelaySeconds: TimeInterval = 0.14
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let codexAppName = "Codex"
    private static let codexVoicePrefixes = ["codex", "code"]
    private static let footPedalTranslatedKeyCode = Int64(kVK_ANSI_B)
    private static let footPedalSuppressionWindowSeconds: TimeInterval = 0.75
    private static let recordingStartSoundPath = "/System/Library/Sounds/Glass.aiff"
    private static let recordingStopSoundPath = "/System/Library/Sounds/Pop.aiff"

    private let defaults: UserDefaults
    private let monitor: MouseChordMonitor
    private let footPedalMonitor: FootPedalMonitor
    private let soundCuePlayer: SoundCuePlayer
    private let dictationCursorOverlay: DictationCursorOverlay
    private let textInputFocusService: TextInputFocusService
    private let screenshotService: ScreenshotService
    private let pasteService: PasteService
    private let dictationService: DictationService
    private let whisperDictationService: WhisperDictationService
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var pasteInProgress = false
    private var dictationInProgress = false
    private var dictationLikelyActive = false
    private var dictationAutoStopTask: Task<Void, Never>?
    private var lastDictationTriggerTime: TimeInterval = 0
    private var lastSoundCueRequestTime: TimeInterval?
    private var screenshotAutoPasteArmed = false
    private var screenshotAutoDictationStopArmed = false
    private var footPedalSuppressionDeadline: TimeInterval = 0

    init(
        defaults: UserDefaults = .standard,
        monitor: MouseChordMonitor = MouseChordMonitor(),
        footPedalMonitor: FootPedalMonitor = FootPedalMonitor(),
        dictationCursorOverlay: DictationCursorOverlay = DictationCursorOverlay(),
        textInputFocusService: TextInputFocusService = TextInputFocusService(),
        screenshotService: ScreenshotService = ScreenshotService(),
        pasteService: PasteService = PasteService(),
        dictationService: DictationService = DictationService(),
        whisperDictationService: WhisperDictationService = WhisperDictationService()
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.footPedalMonitor = footPedalMonitor
        self.soundCuePlayer = SoundCuePlayer(
            startPath: Self.recordingStartSoundPath,
            stopPath: Self.recordingStopSoundPath
        )
        self.dictationCursorOverlay = dictationCursorOverlay
        self.textInputFocusService = textInputFocusService
        self.screenshotService = screenshotService
        self.pasteService = pasteService
        self.dictationService = dictationService
        self.whisperDictationService = whisperDictationService
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.chordWindowMs = defaults.object(forKey: Self.chordWindowKey) as? Double ?? 60
        self.forwardButtonDictationEnabled = defaults.object(
            forKey: Self.forwardButtonDictationEnabledKey
        ) as? Bool ?? true
        self.screenshotPasteStartsDictationEnabled = defaults.object(
            forKey: Self.screenshotPasteStartsDictationEnabledKey
        ) as? Bool ?? false
        self.dictationBackend = DictationBackend(
            rawValue: defaults.string(forKey: Self.dictationBackendKey) ?? DictationBackend.appleDictation.rawValue
        ) ?? .appleDictation
        self.whisperModelPreset = WhisperDictationService.ModelPreset(
            rawValue: defaults.string(
                forKey: Self.whisperModelPresetKey
            ) ?? WhisperDictationService.ModelPreset.smallEn.rawValue
        ) ?? .smallEn
        self.whisperExecutablePath = defaults.string(forKey: Self.whisperExecutablePathKey) ?? ""
        self.whisperModelDirectoryPath = defaults.string(
            forKey: Self.whisperModelDirectoryPathKey
        ) ?? WhisperDictationService.defaultModelDirectoryPath
        self.whisperMicrophoneSelectionID = defaults.string(
            forKey: Self.whisperMicrophoneSelectionKey
        ) ?? WhisperDictationService.preferredMicrophoneSelectionID()
        self.whisperDebugRecordingsEnabled = defaults.object(
            forKey: Self.whisperDebugRecordingsEnabledKey
        ) as? Bool ?? true
        self.capsLockScreenshotEnabled = defaults.object(
            forKey: Self.capsLockScreenshotEnabledKey
        ) as? Bool ?? true
        self.reverseScrollingEnabled = defaults.object(
            forKey: Self.reverseScrollingEnabledKey
        ) as? Bool ?? false
        self.mouseScrollSpeed = defaults.object(
            forKey: Self.mouseScrollSpeedKey
        ) as? Double ?? 13
        self.scrollEventLoggingEnabled = defaults.object(
            forKey: Self.scrollEventLoggingEnabledKey
        ) as? Bool ?? false
        defaults.set(self.whisperMicrophoneSelectionID, forKey: Self.whisperMicrophoneSelectionKey)

        self.monitor.chordWindowSeconds = max(0.02, self.chordWindowMs / 1_000.0)
        self.monitor.reverseScrollingEnabled = self.reverseScrollingEnabled
        self.monitor.mouseScrollSpeed = self.mouseScrollSpeed
        self.monitor.onChord = { [weak self] in
            self?.handleChordTriggered()
        }
        self.monitor.shouldSuppressKeyEvent = { [weak self] keyCode, eventType in
            MainActor.assumeIsolated {
                self?.shouldSuppressTranslatedFootPedalKey(keyCode: keyCode, eventType: eventType) ?? false
            }
        }
        self.footPedalMonitor.onPedalDown = { [weak self] in
            self?.handleFootPedalDown()
        }
        self.monitor.onPrimaryClickUp = { [weak self] location in
            self?.handlePrimaryClickUp(location)
        }
        self.monitor.onEscapeKeyDown = { [weak self] in
            self?.handleEscapeKeyDown()
        }
        self.whisperDictationService.eventLogger = { [weak self] event in
            self?.appendDictationEventLog(event)
        }
        configureKeyboardCaptureCallbacks()
        configureSideButtonCallback()
        configureScrollDebugLoggingCallback()
        refreshWhisperMicrophoneOptions()

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
                self.refreshWhisperMicrophoneOptions()
                self.updateDictationCursorOverlay()
                self.applyMonitorState()
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dictationCursorOverlay.hide()
                self?.monitor.stop()
                self?.footPedalMonitor.stop()
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
            lastActionMessage = "Add/enable \(appDisplayName) in Accessibility (use + if not listed)."
            applyMonitorState()
            return
        }
        if !screenRecordingGranted {
            Permissions.openScreenRecordingSettings()
            Permissions.revealAppInFinder()
            lastActionMessage = "Add/enable \(appDisplayName) in Screen & System Audio Recording (use + if not listed)."
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
            lastActionMessage = "Add/enable \(appDisplayName) in Accessibility (use + if not listed)."
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
            lastActionMessage = "Enable \(appDisplayName) in Screen & System Audio Recording (use + if it is not listed)."
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
        lastActionMessage = "Finder opened. Use + in macOS Settings and choose \(appDisplayName).app."
    }

    func triggerManualScreenshot() {
        runScreenshot()
    }

    func openScrollEventLogInFinder() {
        let fileManager = FileManager.default
        let logURL = Self.scrollEventLogURL
        if fileManager.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
            lastActionMessage = "Opened scroll log in Finder."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([logURL.deletingLastPathComponent()])
        lastActionMessage = "Scroll log file not created yet. Scroll once with logging enabled."
    }

    func clearScrollEventLog() {
        do {
            if FileManager.default.fileExists(atPath: Self.scrollEventLogURL.path) {
                try FileManager.default.removeItem(at: Self.scrollEventLogURL)
                lastActionMessage = "Cleared scroll debug log."
            } else {
                lastActionMessage = "Scroll debug log is already empty."
            }
        } catch {
            lastActionMessage = "Could not clear scroll debug log: \(error.localizedDescription)"
        }
    }

    func openDictationEventLogInFinder() {
        let fileManager = FileManager.default
        let logURL = Self.dictationEventLogURL
        if fileManager.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
            lastActionMessage = "Opened dictation debug log in Finder."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([logURL.deletingLastPathComponent()])
        lastActionMessage = "Dictation debug log not created yet. Try dictation once first."
    }

    func clearDictationEventLog() {
        do {
            if FileManager.default.fileExists(atPath: Self.dictationEventLogURL.path) {
                try FileManager.default.removeItem(at: Self.dictationEventLogURL)
                lastActionMessage = "Cleared dictation debug log."
            } else {
                lastActionMessage = "Dictation debug log is already empty."
            }
        } catch {
            lastActionMessage = "Could not clear dictation debug log: \(error.localizedDescription)"
        }
    }

    func openWhisperModelDirectoryInFinder() {
        let directoryURL = URL(fileURLWithPath: expandedWhisperModelDirectoryPath(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
            lastActionMessage = "Opened whisper model directory in Finder."
        } catch {
            lastActionMessage = "Could not open whisper model directory: \(error.localizedDescription)"
        }
    }

    func openWhisperDebugRecordingsInFinder() {
        let directoryURL = URL(fileURLWithPath: whisperDebugRecordingsPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
            lastActionMessage = "Opened whisper debug recordings in Finder."
        } catch {
            lastActionMessage = "Could not open whisper debug recordings: \(error.localizedDescription)"
        }
    }

    private func refreshWhisperMicrophoneOptions() {
        whisperMicrophoneOptions = WhisperDictationService.availableInputOptions()
        let availableIDs = Set(whisperMicrophoneOptions.map(\.id))
        guard availableIDs.contains(whisperMicrophoneSelectionID) else {
            whisperMicrophoneSelectionID = WhisperDictationService.preferredMicrophoneSelectionID()
            return
        }
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
            footPedalMonitor.stop()
            monitorRunning = false
            monitorStatusMessage = "Disabled"
            return
        }

        if screenshotCaptureInProgress {
            monitor.stop()
            footPedalMonitor.stop()
            monitorRunning = false
            monitorStatusMessage = "Paused while screenshot tool is active"
            return
        }

        monitor.chordWindowSeconds = max(0.02, chordWindowMs / 1_000.0)

        switch monitor.start() {
        case .started:
            _ = footPedalMonitor.start()
            monitorRunning = true
            if accessibilityTrusted {
                monitorStatusMessage = monitorListeningStatusDescription()
            } else {
                monitorStatusMessage = "Waiting for Accessibility permission"
            }
        case .failed(let reason):
            footPedalMonitor.stop()
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
        appendDictationEventLog("forward_button_down")

        guard forwardButtonDictationEnabled else { return }
        appendDictationEventLog("forward_button_resolved action=dictation backend=\(dictationBackend.rawValue)")
        runDictationFromForwardButton()
    }

    private func handleFootPedalDown() {
        guard isEnabled else { return }

        armFootPedalSuppressionWindow()
        appendDictationEventLog("foot_pedal_down")

        guard forwardButtonDictationEnabled else {
            lastActionMessage = "Foot pedal dictation is disabled in Behavior."
            return
        }

        runDictationFromForwardButton()
    }

    private func runScreenshot() {
        refreshPermissions()
        disarmScreenshotAutoPaste()

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
                    self.armScreenshotAutoPaste()
                    self.lastActionMessage = self.screenshotAutoPastePrompt()
                case .failure(.cancelled):
                    self.disarmScreenshotAutoPaste()
                    self.lastActionMessage = "Screenshot canceled."
                case .failure(.alreadyRunning):
                    self.disarmScreenshotAutoPaste()
                    self.lastActionMessage = "A screenshot capture is already in progress."
                case .failure(.failed(let message)):
                    self.disarmScreenshotAutoPaste()
                    self.lastActionMessage = "Screenshot failed: \(message)"
                }
            }
        }
    }

    private func runDictationFromForwardButton(armStopOnNextPrimaryClickAfterStart: Bool = false) {
        let dictationLooksActive: Bool = switch dictationBackend {
        case .appleDictation:
            dictationLikelyActive
        case .whisperCpp:
            whisperDictationService.isRecording
        }

        if !dictationLooksActive {
            let currentTime = ProcessInfo.processInfo.systemUptime
            if currentTime - lastDictationTriggerTime < 0.18 {
                return
            }
            lastDictationTriggerTime = currentTime
        }

        guard !dictationInProgress else { return }
        switch dictationBackend {
        case .appleDictation:
            runAppleDictationFromForwardButton(armStopOnNextPrimaryClickAfterStart: armStopOnNextPrimaryClickAfterStart)
        case .whisperCpp:
            runWhisperDictationFromForwardButton(armStopOnNextPrimaryClickAfterStart: armStopOnNextPrimaryClickAfterStart)
        }
    }

    private func runAppleDictationFromForwardButton(armStopOnNextPrimaryClickAfterStart: Bool) {
        guard ensureAccessibilityForAutomation(triggerLabel: "dictation shortcut") else { return }
        let wasLikelyActive = dictationLikelyActive
        appendDictationEventLog("apple_dictation_toggle requested currently_active=\(wasLikelyActive ? 1 : 0)")

        dictationInProgress = true
        if wasLikelyActive {
            dictationLikelyActive = false
            dictationActive = false
            disarmScreenshotAutoDictationStop()
        }
        lastActionMessage = wasLikelyActive
            ? "Stopping Apple Dictation via Forward button..."
            : "Starting Apple Dictation via Forward button..."
        dictationService.toggleDictation { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dictationInProgress = false
                switch result {
                case .success:
                    self.dictationLikelyActive = !wasLikelyActive
                    self.dictationActive = self.dictationLikelyActive
                    if wasLikelyActive {
                        self.disarmScreenshotAutoDictationStop()
                        self.appendDictationEventLog("apple_dictation stopped")
                        self.cancelDictationAutoStop()
                        self.lastActionMessage = "Apple Dictation stopped. Sending Return..."
                        self.sendReturnAfterDictationStop()
                    } else {
                        if armStopOnNextPrimaryClickAfterStart {
                            self.armScreenshotAutoDictationStop()
                        } else {
                            self.disarmScreenshotAutoDictationStop()
                        }
                        self.appendDictationEventLog("apple_dictation started")
                        self.scheduleDictationAutoStop(for: .appleDictation)
                        self.lastActionMessage = armStopOnNextPrimaryClickAfterStart
                            ? "Apple Dictation started. Next left click will stop it."
                            : "Apple Dictation started (Forward side button)."
                    }
                case .failure(.failed(let message)):
                    if wasLikelyActive {
                        self.dictationLikelyActive = true
                        self.dictationActive = true
                    }
                    self.appendDictationEventLog("apple_dictation error=\(message)")
                    self.lastActionMessage = "Could not toggle Apple Dictation: \(message)"
                }
            }
        }
    }

    private func runWhisperDictationFromForwardButton(armStopOnNextPrimaryClickAfterStart: Bool) {
        let currentlyRecording = whisperDictationService.isRecording
        let configuration = WhisperDictationService.Configuration(
            modelPreset: whisperModelPreset,
            executablePath: whisperExecutablePath,
            modelDirectoryPath: whisperModelDirectoryPath,
            language: "en",
            keepDebugRecordings: whisperDebugRecordingsEnabled,
            microphoneSelectionID: whisperMicrophoneSelectionID
        )
        appendDictationEventLog(
            "whisper_toggle requested currently_recording=\(currentlyRecording ? 1 : 0) model=\(whisperModelPreset.rawValue) microphone_selection=\(whisperMicrophoneSelectionID)"
        )

        if currentlyRecording {
            stopWhisperDictationRecording()
            return
        }

        startWhisperDictationRecording(
            configuration: configuration,
            armStopOnNextPrimaryClickAfterStart: armStopOnNextPrimaryClickAfterStart
        )
    }

    private func startWhisperDictationRecording(
        configuration: WhisperDictationService.Configuration,
        armStopOnNextPrimaryClickAfterStart: Bool
    ) {
        dictationInProgress = true
        lastActionMessage = "Starting whisper.cpp recording (\(whisperModelPreset.displayName))..."
        appendDictationEventLog(
            "whisper_start cue_strategy=audible_first output=\(soundCuePlayer.currentOutputDescription()) microphone_selection=\(whisperMicrophoneSelectionID)"
        )
        playRecordingStartSound()

        whisperDictationService.startRecording(configuration: configuration) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dictationInProgress = false

                switch result {
                case .success(.started):
                    self.dictationActive = true
                    if armStopOnNextPrimaryClickAfterStart {
                        self.armScreenshotAutoDictationStop()
                    } else {
                        self.disarmScreenshotAutoDictationStop()
                    }
                    self.appendDictationEventLog("whisper_recording started")
                    self.scheduleDictationAutoStop(for: .whisperCpp)
                    self.lastActionMessage = armStopOnNextPrimaryClickAfterStart
                        ? "whisper.cpp recording started. Next left click will stop and transcribe."
                        : "whisper.cpp recording started. Press Forward again to stop and transcribe."

                case .failure(.failed(let message)):
                    self.disarmScreenshotAutoDictationStop()
                    self.dictationActive = self.whisperDictationService.isRecording
                    self.appendDictationEventLog("whisper_recording error=\(message)")
                    self.lastActionMessage = "whisper.cpp dictation failed: \(message)"

                case .success(.transcribed):
                    self.appendDictationEventLog("whisper_recording unexpected_transcribed_on_start")
                }
            }
        }
    }

    private func stopWhisperDictationRecording() {
        dictationInProgress = true
        dictationActive = false
        disarmScreenshotAutoDictationStop()
        lastActionMessage = "Stopping whisper.cpp recording and transcribing..."

        whisperDictationService.stopRecordingAndTranscribe { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dictationInProgress = false

                switch result {
                case .success(.transcribed(let transcript)):
                    self.dictationActive = false
                    self.appendDictationEventLog("whisper_recording stopped transcript_chars=\(transcript.count)")
                    self.cancelDictationAutoStop()
                    self.playRecordingStopSound()
                    self.handleWhisperTranscriptReady(transcript)

                case .failure(.failed(let message)):
                    self.dictationActive = self.whisperDictationService.isRecording
                    self.appendDictationEventLog("whisper_recording error=\(message)")
                    self.lastActionMessage = "whisper.cpp dictation failed: \(message)"

                case .success(.started):
                    self.appendDictationEventLog("whisper_recording unexpected_started_on_stop")
                }
            }
        }
    }

    private func handleWhisperTranscriptReady(_ transcript: String) {
        if isIgnoredWhisperTranscript(transcript) {
            appendDictationEventLog("whisper_transcript ignored_blank_marker")
            lastActionMessage = "whisper.cpp finished, but no speech was detected."
            return
        }

        let routing = routeWhisperTranscript(transcript)
        let trimmedTranscript = routing.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if routing.focusCodex {
            guard ensureAccessibilityForAutomation(triggerLabel: "text insertion") else { return }
        }

        let focusedTextInput = routing.focusCodex
            ? focusCodexTextInput(reason: "whisper_paste")
            : false

        guard !trimmedTranscript.isEmpty else {
            if routing.focusCodex {
                lastActionMessage = focusedTextInput
                    ? "Focused Codex."
                    : "Could not focus Codex."
                return
            }
            appendDictationEventLog("whisper_transcript blank")
            lastActionMessage = "whisper.cpp finished, but no speech was detected."
            return
        }

        guard !pasteInProgress else { return }
        guard ensureAccessibilityForAutomation(triggerLabel: "text insertion") else { return }
        appendDictationEventLog(
            "whisper_transcript ready chars=\(trimmedTranscript.count) codex=\(routing.focusCodex ? 1 : 0)"
        )
        let didFocusTarget = routing.focusCodex ? focusedTextInput : false

        pasteInProgress = true
        lastActionMessage = didFocusTarget
            ? "whisper.cpp transcript ready. Focusing text field..."
            : "whisper.cpp transcript ready. Pasting text..."
        Task { @MainActor [weak self] in
            guard let self else { return }
            if didFocusTarget {
                let nanoseconds = UInt64((Self.textInputFocusSettleDelaySeconds * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            self.lastActionMessage = "whisper.cpp transcript ready. Pasting text..."
            self.pasteService.pasteText(trimmedTranscript) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pasteInProgress = false

                    switch result {
                    case .success:
                        self.appendDictationEventLog("whisper_transcript pasted")
                        self.lastActionMessage = "whisper.cpp transcript pasted. Sending Return..."
                        self.sendReturnAfterWhisperTranscriptPaste()
                    case .failure(.failed(let message)):
                        self.appendDictationEventLog("whisper_transcript paste_error=\(message)")
                        self.lastActionMessage = "Transcript ready, but paste failed: \(message)"
                    }
                }
            }
        }
    }

    private func handleEscapeKeyDown() {
        let dictationLooksActive: Bool = switch dictationBackend {
        case .appleDictation:
            dictationLikelyActive
        case .whisperCpp:
            whisperDictationService.isRecording
        }

        guard dictationLooksActive else { return }
        guard !dictationInProgress else { return }

        appendDictationEventLog("escape_key action=stop_dictation")
        lastActionMessage = "Stopping dictation via Escape..."
        runDictationFromForwardButton()
    }

    private func handlePrimaryClickUp(_ location: CGPoint) {
        if screenshotAutoPasteArmed {
            handleScreenshotAutoPasteClickUp(location)
            return
        }

        handleScreenshotAutoDictationStopClick()
    }

    private func handleScreenshotAutoPasteClickUp(_ location: CGPoint) {
        guard !screenshotCaptureInProgress else { return }
        guard !pasteInProgress else { return }

        screenshotAutoPasteArmed = false
        guard ensureAccessibilityForAutomation(triggerLabel: "screenshot auto-paste") else { return }

        pasteInProgress = true
        lastActionMessage = "Pasting screenshot into the clicked field..."
        let clickX = Int(location.x.rounded())
        let clickY = Int(location.y.rounded())

        Task { @MainActor [weak self] in
            guard let self else { return }

            let nanoseconds = UInt64((Self.screenshotAutoPasteDelaySeconds * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanoseconds)

            self.pasteService.pasteClipboard { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pasteInProgress = false

                    switch result {
                    case .success:
                        if self.screenshotPasteStartsDictationActive {
                            self.lastActionMessage = "Screenshot pasted after click at (\(clickX), \(clickY)). Starting dictation..."
                            self.appendDictationEventLog("screenshot_auto_paste success action=start_dictation")
                            self.runDictationFromForwardButton(armStopOnNextPrimaryClickAfterStart: true)
                        } else {
                            self.lastActionMessage = "Screenshot pasted after click at (\(clickX), \(clickY))."
                        }
                    case .failure(.failed(let message)):
                        self.lastActionMessage = "Could not auto-paste screenshot: \(message)"
                    }
                }
            }
        }
    }

    private func armScreenshotAutoPaste() {
        screenshotAutoPasteArmed = true
        disarmScreenshotAutoDictationStop()
    }

    private func disarmScreenshotAutoPaste() {
        screenshotAutoPasteArmed = false
    }

    private func armScreenshotAutoDictationStop() {
        screenshotAutoDictationStopArmed = true
    }

    private func disarmScreenshotAutoDictationStop() {
        screenshotAutoDictationStopArmed = false
    }

    private func screenshotAutoPastePrompt() -> String {
        if screenshotPasteStartsDictationActive {
            return "Screenshot captured. Click the target field to paste it and start dictation. The next left click will stop dictation."
        }
        return "Screenshot captured. Click the target field to paste it."
    }

    private func handleScreenshotAutoDictationStopClick() {
        guard screenshotAutoDictationStopArmed else { return }
        guard !dictationInProgress else { return }

        let dictationLooksActive: Bool = switch dictationBackend {
        case .appleDictation:
            dictationLikelyActive
        case .whisperCpp:
            whisperDictationService.isRecording
        }

        guard dictationLooksActive else {
            disarmScreenshotAutoDictationStop()
            return
        }

        appendDictationEventLog("screenshot_auto_dictation_stop action=next_primary_click")
        lastActionMessage = "Stopping dictation after next-click shortcut..."
        runDictationFromForwardButton()
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
                lastActionMessage = "Add/enable \(appDisplayName) in Accessibility (use + if not listed)."
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
                lastActionMessage = "Add/enable \(appDisplayName) in Screen & System Audio Recording (use + if not listed)."
                return false
            }
        }

        return true
    }

    private func configureSideButtonCallback() {
        var interceptedButtons: Set<Int64> = []
        if forwardButtonDictationEnabled {
            interceptedButtons.insert(Self.forwardSideButtonNumber)
        }

        monitor.interceptedSideMouseButtons = interceptedButtons
        if !interceptedButtons.isEmpty {
            monitor.onSideButtonDown = { [weak self] buttonNumber in
                self?.handleSideButtonDown(buttonNumber)
            }
            monitor.onSideButtonUp = nil
            monitor.onSideButtonDragged = nil
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
        monitor.onEscapeKeyDown = { [weak self] in
            self?.handleEscapeKeyDown()
        }

        if capsLockScreenshotEnabled {
            monitor.onCapsLockKeyDown = { [weak self] in
                self?.handleKeyboardCaptureTriggered()
            }
        } else {
            monitor.onCapsLockKeyDown = nil
        }
    }

    private func configureScrollDebugLoggingCallback() {
        guard scrollEventLoggingEnabled else {
            monitor.onScrollDebugSample = nil
            return
        }

        monitor.onScrollDebugSample = { [weak self] sample in
            self?.appendScrollDebugSample(sample)
        }
    }

    private func appendScrollDebugSample(_ sample: MouseChordMonitor.ScrollDebugSample) {
        let timestamp = Self.scrollLogDateFormatter.string(from: Date(timeIntervalSince1970: sample.timestamp))
        let line = [
            "ts=\(timestamp)",
            "reverse=\(sample.reverseEnabled ? 1 : 0)",
            "eligible=\(sample.remapEligible ? 1 : 0)",
            "remap=\(sample.remapApplied ? 1 : 0)",
            "deviceInverted=\(sample.directionInvertedFromDevice ? 1 : 0)",
            "precise=\(sample.hasPreciseDeltas ? 1 : 0)",
            "phase=\(sample.phaseRaw)",
            "momentum=\(sample.momentumPhaseRaw)",
            "count=\(sample.scrollCount)",
            "instant=\(sample.instantMouser)",
            "continuous=\(sample.isContinuous)",
            "delta=\(sample.deltaAxis1)",
            "fixed=\(sample.fixedPtDeltaAxis1)",
            "point=\(sample.pointDeltaAxis1)",
            "accel=\(sample.acceleratedDeltaAxis1)",
            "raw=\(sample.rawDeltaAxis1)",
        ].joined(separator: " ")

        let fileManager = FileManager.default
        let logURL = Self.scrollEventLogURL
        let header = "scroll-debug-v1\n"

        if !fileManager.fileExists(atPath: logURL.path) {
            try? header.write(to: logURL, atomically: true, encoding: .utf8)
        }

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            lastActionMessage = "Could not write scroll debug log: \(error.localizedDescription)"
        }
    }

    private func appendDictationEventLog(_ event: String) {
        let timestamp = Self.scrollLogDateFormatter.string(from: Date())
        let line = "\(timestamp) \(event)"
        let logURL = Self.dictationEventLogURL
        let fileManager = FileManager.default
        let header = "dictation-debug-v1\n"

        if !fileManager.fileExists(atPath: logURL.path) {
            try? header.write(to: logURL, atomically: true, encoding: .utf8)
        }

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            lastActionMessage = "Could not write dictation debug log: \(error.localizedDescription)"
        }
    }

    private func updateDictationCursorOverlay() {
        if dictationActive {
            dictationCursorOverlay.show()
        } else {
            dictationCursorOverlay.hide()
        }
    }

    private func monitorListeningStatusDescription() -> String {
        let screenshotSegment = "screenshot (\(screenshotTriggerLabel))"
        let screenshotPasteSegment = "click-to-paste after capture"
        let screenshotAutoDictationSegment = "screenshot paste can auto-start dictation"
        let scrollSegment = reverseScrollingEnabled ? ", reversed scrolling" : ""
        let debugSegment = scrollEventLoggingEnabled ? ", scroll debug logging" : ""
        let dictationSegment = dictationListeningSegment()
        let forwardSegment = dictationSegment

        if screenshotPasteStartsDictationActive && forwardButtonDictationEnabled {
            return "Listening for \(screenshotSegment), \(screenshotPasteSegment), \(forwardSegment), and \(screenshotAutoDictationSegment)\(scrollSegment)\(debugSegment)"
        }

        if forwardButtonDictationEnabled {
            return "Listening for \(screenshotSegment), \(screenshotPasteSegment), and \(forwardSegment)\(scrollSegment)\(debugSegment)"
        }

        return "Listening for \(screenshotSegment) and \(screenshotPasteSegment)\(scrollSegment)\(debugSegment)"
    }

    private func dictationListeningSegment() -> String {
        switch dictationBackend {
        case .appleDictation:
            return "Forward button or foot pedal Apple Dictation toggle"
        case .whisperCpp:
            return "Forward button or foot pedal whisper.cpp (\(whisperModelPreset.displayName))"
        }
    }

    private func routeWhisperTranscript(_ transcript: String) -> (transcript: String, focusCodex: Bool) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredTranscript = trimmedTranscript.lowercased()

        for prefix in Self.codexVoicePrefixes {
            guard loweredTranscript.hasPrefix(prefix) else { continue }
            let prefixEndIndex = trimmedTranscript.index(trimmedTranscript.startIndex, offsetBy: prefix.count)
            let remainder = String(trimmedTranscript[prefixEndIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",:;-. "))
            appendDictationEventLog("voice_route prefix=\(prefix.replacingOccurrences(of: " ", with: "_")) target=codex")
            return (remainder, true)
        }

        return (trimmedTranscript, false)
    }

    private func isIgnoredWhisperTranscript(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()

        let ignoredMarkers: Set<String> = [
            "[blank_audio]",
            "[blank audio]",
            "[ blank_audio ]",
            "[ blank audio ]",
            "[silence]",
            "[ silence ]",
        ]

        return ignoredMarkers.contains(folded)
    }

    private func codexTextInputTarget() -> TextInputFocusService.Target? {
        textInputFocusService.captureTarget(
            bundleIdentifier: Self.codexBundleIdentifier,
            fallbackAppNameContains: Self.codexAppName
        )
    }

    @discardableResult
    private func focusCodexTextInput(reason: String) -> Bool {
        let target = codexTextInputTarget()
        let success = textInputFocusService.focusTextInput(in: target)
        appendDictationEventLog(
            "text_input_focus reason=\(reason) success=\(success ? 1 : 0) app=\(target?.appName ?? "Codex") bundle=\(target?.bundleIdentifier ?? Self.codexBundleIdentifier)"
        )
        return success
    }

    private func armFootPedalSuppressionWindow() {
        footPedalSuppressionDeadline = ProcessInfo.processInfo.systemUptime + Self.footPedalSuppressionWindowSeconds
    }

    private func shouldSuppressTranslatedFootPedalKey(keyCode: Int64, eventType: CGEventType) -> Bool {
        guard eventType == .keyDown || eventType == .keyUp else { return false }
        guard keyCode == Self.footPedalTranslatedKeyCode else { return false }
        return ProcessInfo.processInfo.systemUptime <= footPedalSuppressionDeadline
    }

    private var screenshotTriggerLabel: String {
        if capsLockScreenshotEnabled {
            return "Caps Lock or left+right"
        }
        return "left+right"
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

    private func sendReturnAfterWhisperTranscriptPaste() {
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
                        self.lastActionMessage = "whisper.cpp transcript pasted and Return sent."
                    case .failure(.failed(let message)):
                        self.lastActionMessage = "Transcript pasted, but Return failed: \(message)"
                    }
                }
            }
        }
    }

    private func scheduleDictationAutoStop(for backend: DictationBackend) {
        cancelDictationAutoStop()

        let timeoutNanoseconds = UInt64((Self.dictationAutoStopTimeoutSeconds * 1_000_000_000).rounded())
        dictationAutoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.dictationAutoStopTask = nil
                self.handleDictationAutoStopTimeout(for: backend)
            }
        }
    }

    private func cancelDictationAutoStop() {
        dictationAutoStopTask?.cancel()
        dictationAutoStopTask = nil
    }

    private func playRecordingStartSound() {
        playSoundCue(.start)
    }

    private func playRecordingStopSound() {
        playSoundCue(.stop)
    }

    private func playSoundCue(_ cue: SoundCuePlayer.Cue) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let idleMilliseconds: Int? = {
            guard let lastSoundCueRequestTime else { return nil }
            return Int(((requestedAt - lastSoundCueRequestTime) * 1_000).rounded())
        }()
        lastSoundCueRequestTime = requestedAt

        let soundPath = soundCuePlayer.descriptor(for: cue)
        let outputDescription = soundCuePlayer.currentOutputDescription()
        appendDictationEventLog(
            "sound \(cue.rawValue) requested path=\(soundPath) output=\(outputDescription) idle_ms=\(idleMilliseconds.map(String.init) ?? "none")"
        )

        let playbackStart = playSoundCueNow(
            cue,
            requestedAt: requestedAt,
            label: cue.rawValue,
            outputDescription: outputDescription
        )

        let queueElapsedMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - requestedAt) * 1_000).rounded()
        )
        appendDictationEventLog(
            "sound \(cue.rawValue) queued elapsed_ms=\(queueElapsedMilliseconds) mode=\(playbackStart.mode.rawValue) started=\(playbackStart.started ? 1 : 0)"
        )
    }

    @discardableResult
    private func playSoundCueNow(
        _ cue: SoundCuePlayer.Cue,
        requestedAt: TimeInterval,
        label: String,
        outputDescription: String
    ) -> SoundCuePlayer.PlaybackStart {
        let playbackStart = soundCuePlayer.play(cue) { [weak self] playbackMode, success in
            let elapsedMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - requestedAt) * 1_000).rounded()
            )
            Task { @MainActor [weak self] in
                self?.appendDictationEventLog(
                    "sound \(label) completion elapsed_ms=\(elapsedMilliseconds) mode=\(playbackMode.rawValue) success=\(success ? 1 : 0) output=\(outputDescription)"
                )
            }
        }
        return playbackStart
    }

    private func handleDictationAutoStopTimeout(for backend: DictationBackend) {
        switch backend {
        case .appleDictation:
            guard dictationLikelyActive, !dictationInProgress else { return }
            guard ensureAccessibilityForAutomation(triggerLabel: "dictation auto-stop") else { return }

            dictationInProgress = true
            lastActionMessage = "Apple Dictation reached 20 seconds. Stopping automatically..."
            dictationService.toggleDictation { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.dictationInProgress = false
                    switch result {
                    case .success:
                        self.dictationLikelyActive = false
                        self.dictationActive = false
                        self.disarmScreenshotAutoDictationStop()
                        self.lastActionMessage = "Apple Dictation auto-stopped after 20 seconds. Sending Return..."
                        self.sendReturnAfterDictationStop()
                    case .failure(.failed(let message)):
                        self.lastActionMessage = "Could not auto-stop Apple Dictation: \(message)"
                    }
                }
            }

        case .whisperCpp:
            guard whisperDictationService.isRecording, !dictationInProgress else { return }
            lastActionMessage = "whisper.cpp reached 20 seconds. Stopping automatically..."
            runWhisperDictationFromForwardButton(armStopOnNextPrimaryClickAfterStart: false)
        }
    }

    private func expandedWhisperModelDirectoryPath() -> String {
        NSString(string: whisperModelDirectoryPath).expandingTildeInPath
    }
}
