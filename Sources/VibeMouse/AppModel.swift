@preconcurrency import AppKit
import Combine
import Foundation
import ServiceManagement

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

    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false

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
    @Published private(set) var monitorStatusMessage = "Not started"
    @Published private(set) var lastActionMessage = "Ready"

    var menuBarSymbolName: String {
        if screenshotCaptureInProgress { return "camera.aperture" }
        if !isEnabled { return "computermouse" }
        if !monitorRunning { return "exclamationmark.triangle" }
        return "computermouse.fill"
    }

    var scrollEventLogPath: String {
        Self.scrollEventLogURL.path
    }

    var buildVersionLabel: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (.some(shortVersion), .some(buildVersion)) where !shortVersion.isEmpty && !buildVersion.isEmpty:
            return "Version \(shortVersion) (\(buildVersion))"
        case let (_, .some(buildVersion)) where !buildVersion.isEmpty:
            return "Build \(buildVersion)"
        case let (.some(shortVersion), _) where !shortVersion.isEmpty:
            return "Version \(shortVersion)"
        default:
            return "Build unavailable"
        }
    }

    var runtimeOriginLabel: String {
        let executablePath = Bundle.main.executableURL?.path ?? ""
        if executablePath.contains(".app/Contents/MacOS/") {
            return "Running from app bundle"
        }
        return "Running direct from repo build"
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
    private static let capsLockScreenshotEnabledKey = "mouseChordShot.screenshot.capsLockEnabled"
    private static let reverseScrollingEnabledKey = "mouseChordShot.scroll.reverseEnabled"
    private static let mouseScrollSpeedKey = "mouseChordShot.scroll.mouseSpeed"
    private static let scrollEventLoggingEnabledKey = "mouseChordShot.scroll.debugLogEnabled"
    private static let scrollEventLogURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("vibe-mouse-scroll.log", isDirectory: false)
    private static let scrollLogDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let centerMouseButtonNumber: Int64 = 2

    private let defaults: UserDefaults
    private let monitor: MouseChordMonitor
    private let screenshotService: ScreenshotService
    private let windowsAutoScrollService: WindowsAutoScrollService
    private let windowTilerService: WindowTilerService
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        monitor: MouseChordMonitor = MouseChordMonitor(),
        screenshotService: ScreenshotService = ScreenshotService(),
        windowsAutoScrollService: WindowsAutoScrollService = WindowsAutoScrollService(),
        windowTilerService: WindowTilerService = WindowTilerService()
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.screenshotService = screenshotService
        self.windowsAutoScrollService = windowsAutoScrollService
        self.windowTilerService = windowTilerService

        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.chordWindowMs = defaults.object(forKey: Self.chordWindowKey) as? Double ?? 60
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

        self.monitor.chordWindowSeconds = max(0.02, self.chordWindowMs / 1_000.0)
        self.monitor.reverseScrollingEnabled = self.reverseScrollingEnabled
        self.monitor.mouseScrollSpeed = self.mouseScrollSpeed
        self.monitor.onChord = { [weak self] in
            self?.handleChordTriggered()
        }
        self.monitor.onPrimaryClickDown = { [weak self] in
            self?.handlePrimaryClickDown()
        }
        self.monitor.onWindowArrowShortcut = { [weak self] shortcut in
            self?.handleWindowArrowShortcut(shortcut)
        }
        self.monitor.shouldSuppressPrimaryClick = { [weak self] in
            MainActor.assumeIsolated {
                self?.windowsAutoScrollService.isActive ?? false
            }
        }

        configureKeyboardCaptureCallbacks()
        configureSideButtonCallback()
        configureScrollDebugLoggingCallback()
        refreshLaunchAtLoginStatus()
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
                self.refreshLaunchAtLoginStatus()
                self.applyMonitorState()
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windowsAutoScrollService.stop()
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

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            refreshLaunchAtLoginStatus()
            if launchAtLoginRequiresApproval {
                lastActionMessage = "Launch at Login is pending approval in System Settings > General > Login Items."
            } else {
                lastActionMessage = enabled
                    ? "Launch at Login enabled."
                    : "Launch at Login disabled."
            }
        } catch {
            refreshLaunchAtLoginStatus()
            lastActionMessage = "Could not update Launch at Login: \(error.localizedDescription)"
        }
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

    private func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
        launchAtLoginRequiresApproval = status == .requiresApproval
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
            windowsAutoScrollService.stop()
            monitorRunning = false
            monitorStatusMessage = "Disabled"
            return
        }

        if screenshotCaptureInProgress {
            monitor.stop()
            windowsAutoScrollService.stop()
            monitorRunning = false
            monitorStatusMessage = "Paused while screenshot tool is active"
            return
        }

        monitor.chordWindowSeconds = max(0.02, chordWindowMs / 1_000.0)

        switch monitor.start() {
        case .started:
            monitorRunning = true
            monitorStatusMessage = accessibilityTrusted
                ? monitorListeningStatusDescription()
                : "Waiting for Accessibility permission"
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

    private func handleWindowArrowShortcut(_ shortcut: MouseChordMonitor.WindowArrowShortcut) {
        guard isEnabled else { return }
        windowsAutoScrollService.stop()

        let command: WindowTilerService.Command = switch shortcut {
        case .left:
            .snapLeft
        case .right:
            .snapRight
        case .up:
            .snapUp
        case .down:
            .snapDown
        case .moveDisplayLeft:
            .moveDisplayLeft
        case .moveDisplayRight:
            .moveDisplayRight
        }

        switch windowTilerService.perform(command) {
        case .success(let message):
            lastActionMessage = message
        case .failure(let error):
            lastActionMessage = windowTilerFailureMessage(error)
        }

        applyMonitorState()
    }

    private func handleSideButtonDown(_ buttonNumber: Int64) {
        guard isEnabled, buttonNumber == Self.centerMouseButtonNumber else { return }

        windowsAutoScrollService.toggle(at: NSEvent.mouseLocation)
        lastActionMessage = windowsAutoScrollService.isActive
            ? "Auto-scroll active. Move the mouse up/down; center click or Escape stops it."
            : "Auto-scroll stopped."
    }

    private func runScreenshot() {
        refreshPermissions()
        windowsAutoScrollService.stop()

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

    private func handleEscapeKeyDown() {
        guard windowsAutoScrollService.isActive else { return }
        windowsAutoScrollService.stop()
        lastActionMessage = "Auto-scroll stopped."
    }

    private func handlePrimaryClickDown() {
        guard windowsAutoScrollService.isActive else { return }
        windowsAutoScrollService.stop()
        lastActionMessage = "Auto-scroll stopped."
    }

    private func windowTilerFailureMessage(_ error: WindowTilerService.TilingError) -> String {
        switch error {
        case .noFocusedApplication:
            return "No frontmost app found for window movement."
        case .noFocusedWindow:
            return "No focused window found to move."
        case .unsupportedWindow:
            return "Focused window does not support move/resize."
        case .cannotMoveWindow(let message):
            return "Could not move window: \(message)"
        }
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
        monitor.interceptedSideMouseButtons = [Self.centerMouseButtonNumber]
        monitor.onSideButtonDown = { [weak self] buttonNumber in
            self?.handleSideButtonDown(buttonNumber)
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

    private func monitorListeningStatusDescription() -> String {
        let screenshotSegment = "screenshot (\(screenshotTriggerLabel), clipboard-only)"
        let keyboardSegment = "palm Ctrl shortcuts"
        let windowSegment = "Ctrl+Alt+Arrow window tiling"
        let autoScrollSegment = "center-click auto-scroll"
        let scrollSegment = reverseScrollingEnabled ? ", reversed scrolling" : ""
        let debugSegment = scrollEventLoggingEnabled ? ", scroll debug logging" : ""

        return "Listening for \(screenshotSegment), \(keyboardSegment), \(windowSegment), and \(autoScrollSegment)\(scrollSegment)\(debugSegment)"
    }

    private var screenshotTriggerLabel: String {
        if capsLockScreenshotEnabled {
            return "Caps Lock or left+right"
        }
        return "left+right"
    }
}
