import AppKit
import OSLog

@MainActor
final class WindowPreviewLoader {
    private struct CaptureResult: Sendable {
        let window: SwitchableWindow
        let image: CGImage?
        let error: String?
    }
    private let capture: any WindowPreviewCapturing
    private let cache: WindowPreviewCache
    private let retryDelay: Duration
    private let logger = Logger(subsystem: "com.courageresearch.mousechordshot", category: "WindowPreviews")
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var windows: [SwitchableWindow] = []
    private var selectedID: UUID?
    private var completed: Set<UUID> = []
    private var lastRetry: [UUID: Date] = [:]
    private var onPreview: ((UUID, CGImage) -> Void)?
    private var onStatus: ((String) -> Void)?

    init(capture: any WindowPreviewCapturing = SystemWindowPreviewCapture(),
         cache: WindowPreviewCache = WindowPreviewCache(), retryDelay: Duration = .milliseconds(180)) {
        self.capture = capture
        self.cache = cache
        self.retryDelay = retryDelay
    }

    isolated deinit { task?.cancel(); expiryTask?.cancel() }

    func start(windows: [SwitchableWindow], selectedIndex: Int,
               onPreview: @escaping (UUID, CGImage) -> Void, onStatus: @escaping (String) -> Void) {
        stop()
        guard !windows.isEmpty else { return }
        if let reason = capture.unavailabilityReason {
            cache.removeAll()
            expiryTask?.cancel()
            onStatus(reason)
            return
        }
        let id = UUID()
        sessionID = id
        self.windows = windows
        self.onPreview = onPreview
        self.onStatus = onStatus
        selectedID = windows[min(max(0, selectedIndex), windows.count - 1)].id
        logger.info("Starting previews for \(windows.count) windows")
        for window in windows {
            if let image = cache.image(for: window) {
                logger.info("Cached preview: \(window.appName, privacy: .public) pid=\(window.processIdentifier) window=\(window.windowID ?? 0) minimized=\(window.minimized)")
                onPreview(window.id, image)
                // A last-known frame is more useful than waiting on a minimized
                // window. Previously unseen minimized windows are still tried.
                if window.minimized { completed.insert(window.id) }
            }
        }
        task = Task { [weak self] in
            await self?.load(windows, sessionID: id, passes: 2)
        }
    }

    func select(_ id: UUID) {
        selectedID = id
        guard task == nil, !completed.contains(id), let sessionID,
              let window = windows.first(where: { $0.id == id }),
              Date().timeIntervalSince(lastRetry[id] ?? .distantPast) >= 1 else { return }
        lastRetry[id] = Date()
        task = Task { [weak self] in
            await self?.load([window], sessionID: sessionID, passes: 1)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sessionID = nil
        windows = []
        completed = []
        lastRetry = [:]
        onPreview = nil
        onStatus = nil
    }

    private func load(_ requested: [SwitchableWindow], sessionID id: UUID, passes: Int) async {
        for pass in 0..<passes {
            guard !Task.isCancelled, sessionID == id else { return }
            let pending = requested.filter { !completed.contains($0.id) }
            guard !pending.isEmpty else { break }
            if pass > 0 {
                do { try await Task.sleep(for: retryDelay) } catch { return }
            }
            do {
                let sources = try await capture.sources()
                guard !Task.isCancelled, sessionID == id else { return }
                // Match against the entire session, so a retry cannot borrow
                // another card's source just because that card already loaded.
                let matches = WindowPreviewMatching.match(windows, sources: sources)
                await capturePass(pending, matches: matches, sessionID: id)
            } catch {
                guard !Task.isCancelled, sessionID == id else { return }
                logger.info("Window source discovery failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard !Task.isCancelled, sessionID == id else { return }
        task = nil
        if requested.contains(where: { !completed.contains($0.id) && cache.image(for: $0) == nil }) {
            onStatus?("Some thumbnails are unavailable. Select a window to retry its preview.")
        }
    }

    private func capturePass(_ pending: [SwitchableWindow], matches: [UUID: WindowPreviewSource],
                             sessionID id: UUID) async {
        var remaining = pending.filter { matches[$0.id] != nil }
        for window in pending where matches[window.id] == nil {
            logger.info("No unambiguous preview source: \(window.appName, privacy: .public) pid=\(window.processIdentifier) window=\(window.windowID ?? 0) minimized=\(window.minimized)")
        }
        await withTaskGroup(of: CaptureResult.self) { group in
            var active = 0
            while !remaining.isEmpty || active > 0 {
                guard !Task.isCancelled, sessionID == id else { group.cancelAll(); return }
                // Keep three independent captures moving. Re-read selection on
                // every completion so keyboard navigation reprioritizes the queue.
                while active < 3, !remaining.isEmpty {
                    let index = remaining.firstIndex(where: { $0.id == selectedID }) ?? 0
                    let window = remaining.remove(at: index)
                    guard let source = matches[window.id] else { continue }
                    active += 1
                    group.addTask { [capture, window, source] in
                        do {
                            try Task.checkCancellation()
                            let image = try await capture.capture(source)
                            guard WindowPreviewImage.hasVisiblePixels(image) else {
                                throw WindowPreviewCaptureError.transparentImage
                            }
                            return CaptureResult(window: window, image: image, error: nil)
                        } catch {
                            return CaptureResult(window: window, image: nil, error: String(describing: error))
                        }
                    }
                }
                guard let result = await group.next() else { break }
                active -= 1
                guard !Task.isCancelled, sessionID == id else { group.cancelAll(); return }
                if let image = result.image {
                    logger.info("Captured preview: \(result.window.appName, privacy: .public) pid=\(result.window.processIdentifier) window=\(result.window.windowID ?? 0) size=\(image.width)x\(image.height)")
                    completed.insert(result.window.id)
                    cache.insert(image, for: result.window)
                    scheduleExpiration()
                    onPreview?(result.window.id, image)
                } else {
                    logger.info("Preview capture failed: \(result.window.appName, privacy: .public) pid=\(result.window.processIdentifier) window=\(result.window.windowID ?? 0) minimized=\(result.window.minimized) error=\(result.error ?? "unknown", privacy: .public)")
                }
            }
        }
    }

    private func scheduleExpiration() {
        expiryTask?.cancel()
        guard let expiration = cache.nextExpiration else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiration.timeIntervalSinceNow))) } catch { return }
            guard let self else { return }
            self.cache.prune()
            self.scheduleExpiration()
        }
    }
}
