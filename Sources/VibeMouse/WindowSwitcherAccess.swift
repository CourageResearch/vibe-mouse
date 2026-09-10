import AppKit
import ApplicationServices

// AX handles are immutable references here. Discovery runs on one actor, and
// activation only uses its returned handles after discovery has completed.
struct SwitchableWindow: @unchecked Sendable, Identifiable {
    let id = UUID()
    let element: AXUIElement
    let processIdentifier: pid_t
    let appName: String
    var windowID: CGWindowID?
    let title: String
    let frame: CGRect
    let minimized: Bool
    var isFocused = false
}

@MainActor
protocol WindowSwitcherAccess {
    func frontmostApplication() -> NSRunningApplication?
    func windows(for pid: pid_t, scope: WindowSwitchScope) async -> [SwitchableWindow]
    func activate(_ window: SwitchableWindow) -> Bool
}

@MainActor
final class SystemWindowSwitcherAccess: WindowSwitcherAccess {
    private let discovery = WindowSwitcherDiscovery()

    func frontmostApplication() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    func windows(for pid: pid_t, scope: WindowSwitchScope) async -> [SwitchableWindow] {
        let applications: [WindowSwitchApplication]
        switch scope {
        case .currentApplication:
            applications = [WindowSwitchApplication(pid: pid,
                name: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App")]
        case .allApplications:
            // Regular apps include hidden/minimized windows. Accessory apps are
            // also eligible; the window-role filter excludes menus and HUDs.
            applications = NSWorkspace.shared.runningApplications
                .filter { !$0.isTerminated && $0.activationPolicy != .prohibited }
                .map { WindowSwitchApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "App") }
        }
        return await discovery.windows(for: applications, frontmostPID: pid)
    }

    func activate(_ window: SwitchableWindow) -> Bool {
        let pid = window.processIdentifier
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            return false
        }
        AXUIElementSetMessagingTimeout(window.element, 0.2)
        if window.minimized {
            guard AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString,
                                              kCFBooleanFalse) == .success else { return false }
        }
        guard application.activate(options: [.activateIgnoringOtherApps]) else { return false }
        _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
        return AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) == .success
    }
}

private struct WindowSwitchApplication: Sendable {
    let pid: pid_t
    let name: String
}

enum WindowSwitcherOrdering {
    static func ordered(_ windows: [SwitchableWindow], frontmostPID: pid_t,
                        frontToBackWindowIDs: [CGWindowID]) -> [SwitchableWindow] {
        let positions = Dictionary(frontToBackWindowIDs.enumerated().map { ($0.element, $0.offset) },
                                   uniquingKeysWith: min)
        return windows.enumerated().sorted { lhs, rhs in
            let lFocused = lhs.element.processIdentifier == frontmostPID && lhs.element.isFocused
            let rFocused = rhs.element.processIdentifier == frontmostPID && rhs.element.isFocused
            if lFocused != rFocused { return lFocused }
            let lOrder = lhs.element.windowID.flatMap { positions[$0] } ?? Int.max
            let rOrder = rhs.element.windowID.flatMap { positions[$0] } ?? Int.max
            return lOrder == rOrder ? lhs.offset < rhs.offset : lOrder < rOrder
        }.map(\.element)
    }
}

private actor WindowSwitcherDiscovery {
    func windows(for applications: [WindowSwitchApplication], frontmostPID: pid_t) -> [SwitchableWindow] {
        // Take one global stacking-order snapshot for a stable cycle, rather
        // than grouping windows by app or reordering them as the user cycles.
        let descriptions = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let byPID = Dictionary(grouping: descriptions) { $0[kCGWindowOwnerPID as String] as? Int ?? -1 }
        let applications = applications.sorted { lhs, rhs in
            if lhs.pid == frontmostPID { return rhs.pid != frontmostPID }
            if rhs.pid == frontmostPID { return false }
            return lhs.pid < rhs.pid
        }
        var result: [SwitchableWindow] = []
        for application in applications {
            if Task.isCancelled { return [] }
            result += windows(for: application, descriptions: byPID[Int(application.pid)] ?? [])
        }
        return WindowSwitcherOrdering.ordered(result, frontmostPID: frontmostPID,
            frontToBackWindowIDs: descriptions.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    private func windows(for application: WindowSwitchApplication,
                         descriptions: [[String: Any]]) -> [SwitchableWindow] {
        let pid = application.pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let elements = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let focused = value(app, kAXFocusedWindowAttribute)
        var result: [SwitchableWindow] = []

        for element in elements {
            if Task.isCancelled { return [] }
            AXUIElementSetMessagingTimeout(element, 0.1)
            guard value(element, kAXRoleAttribute) as? String == kAXWindowRole,
                  let subrole = value(element, kAXSubroleAttribute) as? String,
                  [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole),
                  let frame = frame(element), frame.width > 0, frame.height > 0 else { continue }
            let title = value(element, kAXTitleAttribute) as? String ?? ""
            let minimized = value(element, kAXMinimizedAttribute) as? Bool ?? false

            result.append(SwitchableWindow(element: element, processIdentifier: pid, appName: application.name,
                windowID: nil, title: title.isEmpty ? "Untitled window" : title, frame: frame,
                minimized: minimized, isFocused: focused.map { CFEqual(element, $0) } ?? false))
        }
        let sources = descriptions.compactMap { item -> WindowPreviewSource? in
            guard let id = item[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return WindowPreviewSource(windowID: id, processIdentifier: pid,
                title: item[kCGWindowName as String] as? String ?? "", frame: frame)
        }
        let matches = WindowPreviewMatching.match(result, sources: sources)
        for index in result.indices { result[index].windowID = matches[result[index].id]?.windowID }
        return result
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = value(window, kAXPositionAttribute), let size = value(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
