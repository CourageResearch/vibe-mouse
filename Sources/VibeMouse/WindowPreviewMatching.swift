import AppKit

struct WindowPreviewSource: Sendable, Equatable {
    let windowID: CGWindowID
    let processIdentifier: pid_t
    let title: String
    let frame: CGRect
}

enum WindowPreviewMatching {
    static func match(_ windows: [SwitchableWindow], sources: [WindowPreviewSource]) -> [UUID: WindowPreviewSource] {
        var result: [UUID: WindowPreviewSource] = [:]
        var used: Set<CGWindowID> = []
        // Reserve known IDs first, including windows captured in an earlier pass.
        for window in windows {
            if let source = sources.first(where: {
                $0.windowID == window.windowID && $0.processIdentifier == window.processIdentifier
            }), used.insert(source.windowID).inserted {
                result[window.id] = source
            }
        }

        // AX and ScreenCaptureKit can disagree slightly about bounds and titles.
        // Only accept a mutual, unique best match so similar windows cannot steal
        // each other's thumbnails. Leave unresolved ties as icons.
        while true {
            let remaining = windows.filter { result[$0.id] == nil }
            let available = sources.filter { !used.contains($0.windowID) }
            let candidates = remaining.flatMap { window in
                available.compactMap { source -> (UUID, WindowPreviewSource, Int)? in
                    guard window.processIdentifier == source.processIdentifier else { return nil }
                    let sameFrame = abs(window.frame.minX - source.frame.minX) <= 4
                        && abs(window.frame.minY - source.frame.minY) <= 4
                        && abs(window.frame.width - source.frame.width) <= 4
                        && abs(window.frame.height - source.frame.height) <= 4
                    let titleScore: Int
                    if window.title == "Untitled window" || window.title.isEmpty || source.title.isEmpty {
                        titleScore = 0
                    } else if window.title == source.title {
                        titleScore = 2
                    } else {
                        titleScore = comparableTitle(window.title, appName: window.appName)
                            == comparableTitle(source.title, appName: window.appName) ? 1 : 0
                    }
                    guard sameFrame || titleScore > 0 else { return nil }
                    return (window.id, source, (sameFrame ? 4 : 0) + titleScore)
                }
            }
            let accepted = candidates.filter { candidate in
                !candidates.contains { other in
                    (other.0 != candidate.0 || other.1.windowID != candidate.1.windowID)
                        && (other.0 == candidate.0 || other.1.windowID == candidate.1.windowID)
                        && other.2 >= candidate.2
                }
            }
            guard !accepted.isEmpty else { break }
            for (id, source, _) in accepted {
                result[id] = source
                used.insert(source.windowID)
            }
        }
        return result
    }

    private static func comparableTitle(_ title: String, appName: String) -> String {
        // Chrome exposes "Page - Google Chrome - Profile" through AX, but
        // only "Page" through WindowServer/ScreenCaptureKit. Strip the owning
        // app's decoration, keeping exact title matches stronger than this fallback.
        for separator in [" - ", " — ", " – "] {
            guard let range = title.range(of: separator + appName, options: .backwards) else { continue }
            let suffix = title[range.upperBound...]
            if suffix.isEmpty || suffix.hasPrefix(separator) {
                let pageTitle = String(title[..<range.lowerBound])
                if !pageTitle.isEmpty { return pageTitle }
            }
        }
        return title
    }
}

@MainActor
final class WindowPreviewCache {
    private struct Entry {
        let window: SwitchableWindow
        let image: CGImage
        let capturedAt: Date
    }
    private var entries: [Entry] = []
    private let capacity: Int
    private let lifetime: TimeInterval
    var nextExpiration: Date? { entries.first.map { $0.capturedAt.addingTimeInterval(lifetime) } }

    init(capacity: Int = 48, lifetime: TimeInterval = 120) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
    }

    func image(for window: SwitchableWindow, now: Date = Date()) -> CGImage? {
        prune(now: now)
        return entries.last(where: { sameWindow($0.window, window) })?.image
    }

    func insert(_ image: CGImage, for window: SwitchableWindow, now: Date = Date()) {
        prune(now: now)
        entries.removeAll { sameWindow($0.window, window) }
        entries.append(Entry(window: window, image: image, capturedAt: now))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func prune(now: Date = Date()) { entries.removeAll { now.timeIntervalSince($0.capturedAt) >= lifetime } }
    func removeAll() { entries.removeAll() }

    private func sameWindow(_ lhs: SwitchableWindow, _ rhs: SwitchableWindow) -> Bool {
        // UUIDs change at each discovery. AX identity survives title/geometry
        // changes and minimization; a reused numeric window ID is insufficient.
        lhs.processIdentifier == rhs.processIdentifier && CFEqual(lhs.element, rhs.element)
            && (lhs.windowID == nil || rhs.windowID == nil || lhs.windowID == rhs.windowID)
    }
}
