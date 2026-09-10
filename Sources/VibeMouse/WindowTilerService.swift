import AppKit
import ApplicationServices

struct WindowTarget {
    let window: AXUIElement
    let processIdentifier: pid_t
}

@MainActor
protocol WindowAccess {
    func focusedTarget() -> WindowTarget?
    func frame(of window: AXUIElement) -> CGRect?
    func isFullScreen(_ window: AXUIElement) -> Bool
    func setPosition(_ position: CGPoint, on window: AXUIElement) -> AXError
    func setSize(_ size: CGSize, on window: AXUIElement) -> AXError
    func displayAreas() -> [WindowDisplay]
}

@MainActor
final class WindowTilerService {
    typealias Command = WindowCommand

    enum TilingError: Error {
        case noFocusedApplication, noFocusedWindow, unsupportedWindow
        case cannotMoveWindow(String)
    }

    private struct WindowState {
        let window: AXUIElement
        let processIdentifier: pid_t
        let layout: WindowLayout?
        let appliedFrame: CGRect
        let restoreFrame: CGRect
        let display: WindowDisplay
    }

    private struct Request {
        let command: Command
        let window: AXUIElement
        let processIdentifier: pid_t
        let completion: @MainActor (Result<String, TilingError>) -> Void
    }

    private var states: [WindowState] = []
    private var requests: [Request] = []
    private var worker: Task<Void, Never>?
    private let access: any WindowAccess

    init(access: any WindowAccess = MacWindowAccess()) {
        self.access = access
    }

    func cancelPendingCommands() {
        requests.removeAll()
        worker?.cancel()
        worker = nil
    }

    func perform(_ command: Command, completion: @escaping @MainActor (Result<String, TilingError>) -> Void) {
        guard let target = access.focusedTarget() else {
            completion(.failure(.noFocusedWindow))
            return
        }

        // Capture the window when the key is pressed, then serialize work. Fast taps
        // see the previous accepted result and never borrow state from another window.
        requests.append(Request(command: command, window: target.window,
                                processIdentifier: target.processIdentifier, completion: completion))
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !requests.isEmpty, !Task.isCancelled {
                let request = requests.removeFirst()
                let result = await apply(request)
                guard !Task.isCancelled else { return }
                request.completion(result)
            }
            worker = nil
        }
    }

    private func apply(_ request: Request) async -> Result<String, TilingError> {
        let window = request.window
        guard let currentFrame = access.frame(of: window), !access.isFullScreen(window) else {
            return .failure(.unsupportedWindow)
        }
        let displays = access.displayAreas()
        guard let display = WindowGeometry.display(containing: currentFrame, in: displays) else {
            return .failure(.cannotMoveWindow("No screens found."))
        }
        let previous = states.first {
            $0.processIdentifier == request.processIdentifier && CFEqual($0.window, window)
        }
        // Remember the actual accepted frame, including minimum-size constraints.
        // A manual drag/resize invalidates layout memory and becomes the new restore size.
        let unchanged = previous.map {
            $0.display.id == display.id && $0.display.visibleFrame == display.visibleFrame
                && WindowGeometry.isClose(currentFrame, to: $0.appliedFrame)
        } ?? false
        let layout = unchanged ? previous?.layout : WindowLayout.matching(currentFrame, in: display.visibleFrame)
        var restoreFrame = unchanged ? previous!.restoreFrame : currentFrame
        guard let placement = WindowGeometry.plan(
            request.command, currentFrame: currentFrame, layout: layout, display: display,
            displays: displays, restoreFrame: unchanged ? restoreFrame : nil
        ) else {
            return .failure(.cannotMoveWindow("No display in that direction."))
        }
        if display.id != placement.display.id {
            restoreFrame = WindowGeometry.moved(restoreFrame, from: display.visibleFrame,
                                               to: placement.display.visibleFrame)
        }

        let result = await setFrame(placement, for: window)
        guard !Task.isCancelled else { return .failure(.cannotMoveWindow("Window movement canceled.")) }
        switch result {
        case .failure(let error):
            states.removeAll { CFEqual($0.window, window) }
            return .failure(error)
        case .success(let appliedFrame):
            states.removeAll { CFEqual($0.window, window) }
            states.append(WindowState(window: window, processIdentifier: request.processIdentifier,
                layout: placement.layout, appliedFrame: appliedFrame,
                restoreFrame: placement.layout == nil ? appliedFrame : restoreFrame, display: placement.display))
            if states.count > 64 { states.removeFirst(states.count - 64) }
            let constrained = !WindowGeometry.isClose(appliedFrame, to: placement.frame)
            return .success(placement.message + (constrained ? " App minimum size kept." : ""))
        }
    }

    private func setFrame(_ placement: WindowPlacement, for window: AXUIElement) async -> Result<CGRect, TilingError> {
        // Small -> large displays can reject enlargement until after the move;
        // large -> small displays can clamp the move until after the shrink.
        // Resize/move, then resize/align again on the destination, with bounded readback.
        for _ in 0..<2 {
            guard !Task.isCancelled else { break }
            guard access.setSize(placement.frame.size, on: window) == .success,
                  access.setPosition(placement.frame.origin, on: window) == .success else {
                return .failure(.cannotMoveWindow("Window refused move or resize."))
            }
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { break }
            guard access.setSize(placement.frame.size, on: window) == .success else {
                return .failure(.cannotMoveWindow("Window refused resize on the target display."))
            }
            guard let resized = access.frame(of: window) else { return .failure(.unsupportedWindow) }
            let origin = WindowGeometry.alignedOrigin(size: resized.size, placement: placement)
            guard access.setPosition(origin, on: window) == .success else {
                return .failure(.cannotMoveWindow("Window refused edge alignment."))
            }
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { break }
            if let actual = access.frame(of: window) {
                let expected = CGRect(origin: WindowGeometry.alignedOrigin(size: actual.size, placement: placement),
                                      size: actual.size)
                let sizeAccepted = actual.width >= placement.frame.width - 3
                    && actual.height >= placement.frame.height - 3
                if sizeAccepted, WindowGeometry.isClose(actual, to: expected) {
                    return .success(actual)
                }
            }
        }
        return .failure(.cannotMoveWindow("Window did not settle at the requested position. Try again."))
    }
}

@MainActor
private final class MacWindowAccess: WindowAccess {
    func focusedTarget() -> WindowTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = copyElement(app, attribute: kAXFocusedWindowAttribute)
                ?? copyElement(app, attribute: kAXMainWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.2)
        return WindowTarget(window: window, processIdentifier: application.processIdentifier)
    }

    func setPosition(_ position: CGPoint, on window: AXUIElement) -> AXError {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    func setSize(_ size: CGSize, on window: AXUIElement) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = copyValue(window, attribute: kAXPositionAttribute),
              let sizeValue = copyValue(window, attribute: kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyValue(_ element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    func displayAreas() -> [WindowDisplay] {
        let screens = NSScreen.screens
        let anchor = screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? screens.first?.frame.maxY ?? 0
        func convert(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: anchor - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return nil }
            return WindowDisplay(id: id, frame: convert(screen.frame), visibleFrame: convert(screen.visibleFrame))
        }
    }
}
