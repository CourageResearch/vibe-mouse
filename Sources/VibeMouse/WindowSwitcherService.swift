import AppKit
import ScreenCaptureKit

@MainActor
final class WindowSwitcherService {
    private struct Session {
        let id = UUID()
        let pid: pid_t
        var offset: Int
        var pendingRows = 0
        var windows: [SwitchableWindow]?
        var finishWhenReady = false

        var selectedIndex: Int {
            guard let count = windows?.count, count > 0 else { return 0 }
            return ((offset % count) + count) % count
        }
    }

    let model = WindowSwitcherViewModel()
    var onDismiss: (() -> Void)?
    var onStatus: ((String) -> Void)?
    private let access: any WindowSwitcherAccess
    private let presentation: any WindowSwitcherPresentation
    private let capturePreviews: Bool
    private var session: Session?
    private var discoveryTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init(access: any WindowSwitcherAccess = SystemWindowSwitcherAccess(),
         presentation: any WindowSwitcherPresentation = WindowSwitcherPanel(),
         capturePreviews: Bool = true) {
        self.access = access
        self.presentation = presentation
        self.capturePreviews = capturePreviews
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let session = self.session, let pid, session.pid != pid else { return }
                self.clear(notify: true)
            }
        }
    }

    isolated deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func handle(_ action: WindowSwitchAction) {
        switch action {
        case .begin(_, let backwards):
            begin(scope: .currentApplication, backwards: backwards)

        case .beginAllWindows(let backwards):
            begin(scope: .allApplications, backwards: backwards)

        case .step(let backwards):
            guard session != nil, session?.finishWhenReady == false else { return }
            session?.offset += backwards ? -1 : 1
            model.selectedIndex = session?.selectedIndex ?? 0

        case .moveRow(let backwards):
            guard session != nil, session?.finishWhenReady == false else { return }
            if session?.windows == nil {
                session?.pendingRows += backwards ? -1 : 1
            } else {
                session?.offset += (backwards ? -1 : 1) * model.layout.columns
                model.selectedIndex = session?.selectedIndex ?? 0
            }

        case .finish:
            guard session != nil else { return }
            if session?.windows == nil {
                session?.finishWhenReady = true
                presentation.hide()
            } else {
                commit()
            }

        case .cancel:
            clear()
        }
    }

    private func begin(scope: WindowSwitchScope, backwards: Bool) {
        clear(notify: false)
        guard let app = access.frontmostApplication() else { return }
        let session = Session(pid: app.processIdentifier, offset: backwards ? -1 : 1)
        self.session = session
        model.scope = scope
        model.appName = scope == .allApplications ? "All windows" : app.localizedName ?? "App"
        model.appIcon = scope == .allApplications ? nil : app.icon
        discoveryTask = Task { [weak self, access] in
            let windows = await access.windows(for: app.processIdentifier, scope: scope)
            guard !Task.isCancelled, let self, self.session?.id == session.id else { return }
            guard !windows.isEmpty else {
                self.onStatus?("No switchable windows. Check Accessibility permission in Settings.")
                self.clear(notify: true)
                return
            }
            self.model.layout = WindowSwitcherLayout(scope: scope, windowCount: windows.count,
                screenSize: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800))
            self.session?.windows = windows
            let rowOffset = (self.session?.pendingRows ?? 0) * self.model.layout.columns
            self.session?.offset += rowOffset
            if self.session?.finishWhenReady == true {
                self.commit()
                return
            }
            for pid in Set(windows.map(\.processIdentifier)) {
                self.model.appIcons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
            }
            self.model.windows = windows
            self.model.selectedIndex = self.session?.selectedIndex ?? 0
            self.presentation.show(model: self.model)
            self.loadPreviews(windows, sessionID: session.id)
        }
    }

    private func commit() {
        guard let session, let windows = session.windows, !windows.isEmpty else { return }
        let selected = windows[session.selectedIndex]
        clear()
        let success = access.activate(selected)
        onStatus?(success ? "Switched to \(selected.title)." : "Couldn't focus that window. It may have closed.")
    }

    private func clear(notify: Bool = false) {
        discoveryTask?.cancel()
        discoveryTask = nil
        previewTask?.cancel()
        previewTask = nil
        session = nil
        presentation.hide()
        model.windows = []
        model.previews = [:]
        model.appIcons = [:]
        if notify { onDismiss?() }
    }

    private func loadPreviews(_ windows: [SwitchableWindow], sessionID: UUID) {
        guard capturePreviews else { return }
        guard CGPreflightScreenCaptureAccess() else {
            onStatus?("Enable Screen Recording in Vibe Mouse Settings for thumbnails.")
            return
        }
        guard #available(macOS 14.0, *) else {
            onStatus?("Window thumbnails require macOS 14 or later.")
            return
        }
        // Capture only the listed windows, once per switch. Images stay in
        // memory and are discarded on dismissal; nothing is saved or uploaded.
        previewTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let self, !Task.isCancelled, self.session?.id == sessionID else { return }
                let selectedIndex = self.model.selectedIndex
                let captureOrder = Array(windows[selectedIndex...]) + Array(windows[..<selectedIndex])
                for window in captureOrder {
                    guard !Task.isCancelled, self.session?.id == sessionID else { return }
                    guard !window.minimized, let id = window.windowID,
                          let source = content.windows.first(where: { $0.windowID == id }) else { continue }
                    let config = SCStreamConfiguration()
                    let scale = min(1, 640 / max(1, max(source.frame.width, source.frame.height)))
                    config.width = max(1, Int(source.frame.width * scale))
                    config.height = max(1, Int(source.frame.height * scale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: source)
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                        guard !Task.isCancelled, self.session?.id == sessionID else { return }
                        self.model.previews[window.id] = NSImage(cgImage: image,
                            size: NSSize(width: image.width, height: image.height))
                    }
                }
            } catch {
                guard let self, self.session?.id == sessionID else { return }
                self.onStatus?("Thumbnails unavailable. You can still switch by window title.")
            }
        }
    }
}
