import AppKit
import ApplicationServices

@MainActor
final class WindowTilerService {
    enum Command {
        case snapLeft
        case snapRight
        case snapUp
        case snapDown
        case moveDisplayLeft
        case moveDisplayRight
    }

    enum TilingError: Error {
        case noFocusedApplication
        case noFocusedWindow
        case unsupportedWindow
        case cannotMoveWindow(String)
    }

    private struct LastHorizontalSnap {
        let direction: CGFloat
        let processIdentifier: pid_t
        let timestamp: TimeInterval
    }

    private struct DisplayArea {
        let screen: NSScreen
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private static let repeatedHorizontalShortcutWindowSeconds: TimeInterval = 2.25

    private var lastHorizontalSnap: LastHorizontalSnap?

    func perform(_ command: Command) -> Result<String, TilingError> {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return .failure(.noFocusedApplication)
        }

        guard let window = focusedWindow(for: application) else {
            return .failure(.noFocusedWindow)
        }

        guard let currentFrame = frame(of: window) else {
            return .failure(.unsupportedWindow)
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return .failure(.cannotMoveWindow("No screens found."))
        }

        let displays = displayAreas(for: screens)
        let currentDisplay = display(containing: currentFrame, displays: displays)
        let targetFrame: CGRect?
        let description: String

        switch command {
        case .snapLeft:
            let currentLeft = leftHalf(of: currentDisplay.visibleFrame)
            if shouldMoveHorizontallyAcrossDisplays(
                currentFrame: currentFrame,
                currentDisplay: currentDisplay,
                direction: -1,
                processIdentifier: application.processIdentifier
            ),
               let nextDisplay = adjacentDisplay(from: currentDisplay, direction: -1, displays: displays) {
                targetFrame = rightHalf(of: nextDisplay.visibleFrame)
                description = "Window moved to the right side of the left display."
            } else {
                targetFrame = currentLeft
                description = "Window snapped left."
            }

        case .snapRight:
            let currentRight = rightHalf(of: currentDisplay.visibleFrame)
            if shouldMoveHorizontallyAcrossDisplays(
                currentFrame: currentFrame,
                currentDisplay: currentDisplay,
                direction: 1,
                processIdentifier: application.processIdentifier
            ),
               let nextDisplay = adjacentDisplay(from: currentDisplay, direction: 1, displays: displays) {
                targetFrame = leftHalf(of: nextDisplay.visibleFrame)
                description = "Window moved to the left side of the right display."
            } else {
                targetFrame = currentRight
                description = "Window snapped right."
            }

        case .snapUp:
            if isClose(currentFrame, to: leftHalf(of: currentDisplay.visibleFrame)) {
                targetFrame = topLeftQuarter(of: currentDisplay.visibleFrame)
                description = "Window snapped top-left."
            } else if isClose(currentFrame, to: rightHalf(of: currentDisplay.visibleFrame)) {
                targetFrame = topRightQuarter(of: currentDisplay.visibleFrame)
                description = "Window snapped top-right."
            } else {
                targetFrame = currentDisplay.visibleFrame
                description = "Window maximized."
            }

        case .snapDown:
            if isClose(currentFrame, to: leftHalf(of: currentDisplay.visibleFrame))
                || isClose(currentFrame, to: topLeftQuarter(of: currentDisplay.visibleFrame)) {
                targetFrame = bottomLeftQuarter(of: currentDisplay.visibleFrame)
                description = "Window snapped bottom-left."
            } else if isClose(currentFrame, to: rightHalf(of: currentDisplay.visibleFrame))
                        || isClose(currentFrame, to: topRightQuarter(of: currentDisplay.visibleFrame)) {
                targetFrame = bottomRightQuarter(of: currentDisplay.visibleFrame)
                description = "Window snapped bottom-right."
            } else if isClose(currentFrame, to: currentDisplay.visibleFrame) {
                targetFrame = centeredRestoreFrame(in: currentDisplay.visibleFrame)
                description = "Window restored to center."
            } else {
                targetFrame = bottomHalf(of: currentDisplay.visibleFrame)
                description = "Window snapped bottom."
            }

        case .moveDisplayLeft:
            guard let nextDisplay = adjacentDisplay(from: currentDisplay, direction: -1, displays: displays) else {
                return .failure(.cannotMoveWindow("No display to the left."))
            }
            targetFrame = move(currentFrame, from: currentDisplay.visibleFrame, to: nextDisplay.visibleFrame)
            description = "Window moved to the left display."

        case .moveDisplayRight:
            guard let nextDisplay = adjacentDisplay(from: currentDisplay, direction: 1, displays: displays) else {
                return .failure(.cannotMoveWindow("No display to the right."))
            }
            targetFrame = move(currentFrame, from: currentDisplay.visibleFrame, to: nextDisplay.visibleFrame)
            description = "Window moved to the right display."
        }

        guard let targetFrame else {
            return .failure(.cannotMoveWindow("No target frame found."))
        }

        if let failureMessage = setFrame(targetFrame.integral, for: window) {
            return .failure(.cannotMoveWindow(failureMessage))
        } else {
            rememberHorizontalSnapIfNeeded(command: command, processIdentifier: application.processIdentifier)
            return .success(description)
        }
    }

    private func shouldMoveHorizontallyAcrossDisplays(
        currentFrame: CGRect,
        currentDisplay: DisplayArea,
        direction: CGFloat,
        processIdentifier: pid_t
    ) -> Bool {
        let snappedFrame = direction < 0
            ? leftHalf(of: currentDisplay.visibleFrame)
            : rightHalf(of: currentDisplay.visibleFrame)

        if isClose(currentFrame, to: snappedFrame)
            || isOnHorizontalSide(currentFrame, of: currentDisplay.visibleFrame, direction: direction) {
            return true
        }

        guard let lastHorizontalSnap,
              lastHorizontalSnap.processIdentifier == processIdentifier,
              lastHorizontalSnap.direction == direction else {
            return false
        }

        return ProcessInfo.processInfo.systemUptime - lastHorizontalSnap.timestamp
            <= Self.repeatedHorizontalShortcutWindowSeconds
    }

    private func rememberHorizontalSnapIfNeeded(command: Command, processIdentifier: pid_t) {
        let direction: CGFloat?
        switch command {
        case .snapLeft, .moveDisplayLeft:
            direction = -1
        case .snapRight, .moveDisplayRight:
            direction = 1
        case .snapUp, .snapDown:
            direction = nil
        }

        guard let direction else {
            lastHorizontalSnap = nil
            return
        }

        lastHorizontalSnap = LastHorizontalSnap(
            direction: direction,
            processIdentifier: processIdentifier,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    private func focusedWindow(for application: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let focusedWindow = copyElement(appElement, attribute: kAXFocusedWindowAttribute) {
            return focusedWindow
        }
        return copyElement(appElement, attribute: kAXMainWindowAttribute)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = copyCGPoint(window, attribute: kAXPositionAttribute),
              let size = copyCGSize(window, attribute: kAXSizeAttribute),
              size.width > 1,
              size.height > 1 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func setFrame(_ frame: CGRect, for window: AXUIElement) -> String? {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return "Could not create window frame values."
        }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        guard positionResult == .success, sizeResult == .success else {
            return "Window refused move or resize. position=\(positionResult.rawValue) size=\(sizeResult.rawValue)"
        }
        return nil
    }

    private func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func copyCGPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func copyCGSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func displayAreas(for screens: [NSScreen]) -> [DisplayArea] {
        let yAxisAnchor = screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? screens[0].frame.maxY

        return screens.map { screen in
            DisplayArea(
                screen: screen,
                frame: axFrame(from: screen.frame, yAxisAnchor: yAxisAnchor),
                visibleFrame: axFrame(from: screen.visibleFrame, yAxisAnchor: yAxisAnchor)
            )
        }
    }

    private func axFrame(from appKitFrame: CGRect, yAxisAnchor: CGFloat) -> CGRect {
        CGRect(
            x: appKitFrame.minX,
            y: yAxisAnchor - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    private func display(containing frame: CGRect, displays: [DisplayArea]) -> DisplayArea {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containingDisplay = displays.first(where: { $0.frame.contains(center) }) {
            return containingDisplay
        }

        return displays.min { lhs, rhs in
            distanceSquared(from: center, to: lhs.frame) < distanceSquared(from: center, to: rhs.frame)
        } ?? displays[0]
    }

    private func adjacentDisplay(
        from display: DisplayArea,
        direction: CGFloat,
        displays: [DisplayArea]
    ) -> DisplayArea? {
        let candidates = displays.filter { candidate in
            guard candidate.screen !== display.screen else { return false }
            return direction < 0
                ? candidate.frame.midX < display.frame.midX
                : candidate.frame.midX > display.frame.midX
        }

        return candidates.min { lhs, rhs in
            let lhsScore = abs(lhs.frame.midX - display.frame.midX) + abs(lhs.frame.midY - display.frame.midY) * 0.25
            let rhsScore = abs(rhs.frame.midX - display.frame.midX) + abs(rhs.frame.midY - display.frame.midY) * 0.25
            return lhsScore < rhsScore
        }
    }

    private func leftHalf(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
    }

    private func rightHalf(of frame: CGRect) -> CGRect {
        CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
    }

    private func bottomHalf(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
    }

    private func topLeftQuarter(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height / 2)
    }

    private func topRightQuarter(of frame: CGRect) -> CGRect {
        CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height / 2)
    }

    private func bottomLeftQuarter(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.midY, width: frame.width / 2, height: frame.height / 2)
    }

    private func bottomRightQuarter(of frame: CGRect) -> CGRect {
        CGRect(x: frame.midX, y: frame.midY, width: frame.width / 2, height: frame.height / 2)
    }

    private func centeredRestoreFrame(in frame: CGRect) -> CGRect {
        let size = CGSize(width: frame.width * 0.72, height: frame.height * 0.72)
        return CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func move(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let width = min(frame.width, target.width)
        let height = min(frame.height, target.height)
        let relativeX = source.width > 0 ? (frame.minX - source.minX) / source.width : 0
        let relativeY = source.height > 0 ? (frame.minY - source.minY) / source.height : 0
        let rawFrame = CGRect(
            x: target.minX + relativeX * target.width,
            y: target.minY + relativeY * target.height,
            width: width,
            height: height
        )
        return clamped(rawFrame, inside: target)
    }

    private func clamped(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let minX = bounds.minX
        let maxX = bounds.maxX - width
        let minY = bounds.minY
        let maxY = bounds.maxY - height
        return CGRect(
            x: min(max(frame.minX, minX), maxX),
            y: min(max(frame.minY, minY), maxY),
            width: width,
            height: height
        )
    }

    private func isClose(_ lhs: CGRect, to rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 18
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func isOnHorizontalSide(_ frame: CGRect, of screenFrame: CGRect, direction: CGFloat) -> Bool {
        let edgeTolerance: CGFloat = 72
        let sideTolerance: CGFloat = 96

        if direction < 0 {
            return frame.minX <= screenFrame.minX + edgeTolerance
                && frame.midX <= screenFrame.midX + sideTolerance
        }

        return frame.maxX >= screenFrame.maxX - edgeTolerance
            && frame.midX >= screenFrame.midX - sideTolerance
    }

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
