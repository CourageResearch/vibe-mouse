import AppKit

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
    private let previewLoader: WindowPreviewLoader
    private var session: Session?
    private var discoveryTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init(access: any WindowSwitcherAccess = SystemWindowSwitcherAccess(),
         presentation: any WindowSwitcherPresentation = WindowSwitcherPanel(),
         capturePreviews: Bool = true,
         previewLoader: WindowPreviewLoader = WindowPreviewLoader()) {
        self.access = access
        self.presentation = presentation
        self.capturePreviews = capturePreviews
        self.previewLoader = previewLoader
        model.onChooseWindow = { [weak self] id in self?.handle(.chooseWindow(id)) }
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
            prioritizeSelectedPreview()

        case .moveRow(let backwards):
            guard session != nil, session?.finishWhenReady == false else { return }
            if session?.windows == nil {
                session?.pendingRows += backwards ? -1 : 1
            } else {
                session?.offset += (backwards ? -1 : 1) * model.layout.columns
                model.selectedIndex = session?.selectedIndex ?? 0
                prioritizeSelectedPreview()
            }

        case .chooseWindow(let id):
            guard let windows = session?.windows, let index = windows.firstIndex(where: { $0.id == id }) else { return }
            session?.offset = index
            commit(notify: true)

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

    func pointerTarget(at point: CGPoint) -> WindowSwitcherPointerTarget? {
        guard session?.windows != nil, session?.finishWhenReady == false else { return nil }
        return presentation.pointerTarget(at: point)
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

    private func commit(notify: Bool = false) {
        guard let session, let windows = session.windows, !windows.isEmpty else { return }
        let selected = windows[session.selectedIndex]
        clear(notify: notify)
        let success = access.activate(selected)
        onStatus?(success ? "Switched to \(selected.title)." : "Couldn't focus that window. It may have closed.")
    }

    private func clear(notify: Bool = false) {
        discoveryTask?.cancel()
        discoveryTask = nil
        previewLoader.stop()
        session = nil
        presentation.hide()
        model.windows = []
        model.previews = [:]
        model.appIcons = [:]
        model.hitRegions = WindowSwitcherHitRegions()
        if notify { onDismiss?() }
    }

    private func loadPreviews(_ windows: [SwitchableWindow], sessionID: UUID) {
        guard capturePreviews else { return }
        previewLoader.start(windows: windows, selectedIndex: model.selectedIndex, onPreview: { [weak self] id, image in
            guard let self, self.session?.id == sessionID else { return }
            self.model.previews[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }, onStatus: { [weak self] status in
            guard let self, self.session?.id == sessionID else { return }
            self.onStatus?(status)
        })
    }

    private func prioritizeSelectedPreview() {
        guard model.windows.indices.contains(model.selectedIndex) else { return }
        previewLoader.select(model.windows[model.selectedIndex].id)
    }
}
