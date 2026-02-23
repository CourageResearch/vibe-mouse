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

    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var monitorRunning = false
    @Published private(set) var screenshotCaptureInProgress = false
    @Published private(set) var monitorStatusMessage = "Not started"
    @Published private(set) var lastActionMessage = "Ready"

    var menuBarSymbolName: String {
        if screenshotCaptureInProgress { return "camera.aperture" }
        if !isEnabled { return "camera" }
        if !monitorRunning { return "exclamationmark.triangle" }
        return "camera.viewfinder"
    }

    private static let enabledKey = "mouseChordShot.enabled"
    private static let chordWindowKey = "mouseChordShot.chordWindowMs"

    private let defaults: UserDefaults
    private let monitor: MouseChordMonitor
    private let screenshotService: ScreenshotService
    private var activationObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        monitor: MouseChordMonitor = MouseChordMonitor(),
        screenshotService: ScreenshotService = ScreenshotService()
    ) {
        self.defaults = defaults
        self.monitor = monitor
        self.screenshotService = screenshotService
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.chordWindowMs = defaults.object(forKey: Self.chordWindowKey) as? Double ?? 60

        self.monitor.chordWindowSeconds = max(0.02, self.chordWindowMs / 1_000.0)
        self.monitor.onChord = { [weak self] in
            self?.handleChordTriggered()
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
            lastActionMessage = "Add/enable Mouse Chord Shot in Accessibility (use + if not listed)."
            applyMonitorState()
            return
        }
        if !screenRecordingGranted {
            Permissions.openScreenRecordingSettings()
            Permissions.revealAppInFinder()
            lastActionMessage = "Add/enable Mouse Chord Shot in Screen & System Audio Recording (use + if not listed)."
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
            lastActionMessage = "Add/enable Mouse Chord Shot in Accessibility (use + if not listed)."
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
            lastActionMessage = "Enable Mouse Chord Shot in Screen & System Audio Recording (use + if it is not listed)."
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
        lastActionMessage = "Finder opened. Use + in macOS Settings and choose Mouse Chord Shot.app."
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
                monitorStatusMessage = "Listening for left+right chord"
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
                lastActionMessage = "Add/enable Mouse Chord Shot in Screen & System Audio Recording (use + if not listed)."
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
}
