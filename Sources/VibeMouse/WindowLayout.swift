import Foundation

/// Geometry and transitions use Accessibility coordinates (origin at the top left).
enum WindowLayout: CaseIterable {
    case left, right, topLeft, topRight, bottomLeft, bottomRight, bottom, maximized

    var horizontalSide: Int? {
        switch self {
        case .left, .topLeft, .bottomLeft: -1
        case .right, .topRight, .bottomRight: 1
        case .bottom, .maximized: nil
        }
    }

    func frame(in bounds: CGRect) -> CGRect {
        let splitX = bounds.minX + (bounds.width / 2).rounded(.down)
        let splitY = bounds.minY + (bounds.height / 2).rounded(.down)
        switch self {
        case .left:
            return CGRect(x: bounds.minX, y: bounds.minY, width: splitX - bounds.minX, height: bounds.height)
        case .right:
            return CGRect(x: splitX, y: bounds.minY, width: bounds.maxX - splitX, height: bounds.height)
        case .topLeft:
            return CGRect(x: bounds.minX, y: bounds.minY, width: splitX - bounds.minX, height: splitY - bounds.minY)
        case .topRight:
            return CGRect(x: splitX, y: bounds.minY, width: bounds.maxX - splitX, height: splitY - bounds.minY)
        case .bottomLeft:
            return CGRect(x: bounds.minX, y: splitY, width: splitX - bounds.minX, height: bounds.maxY - splitY)
        case .bottomRight:
            return CGRect(x: splitX, y: splitY, width: bounds.maxX - splitX, height: bounds.maxY - splitY)
        case .bottom:
            return CGRect(x: bounds.minX, y: splitY, width: bounds.width, height: bounds.maxY - splitY)
        case .maximized:
            return bounds
        }
    }

    func onSide(_ direction: Int) -> WindowLayout {
        switch self {
        case .topLeft, .topRight: direction < 0 ? .topLeft : .topRight
        case .bottomLeft, .bottomRight: direction < 0 ? .bottomLeft : .bottomRight
        default: direction < 0 ? .left : .right
        }
    }

    static func matching(_ frame: CGRect, in bounds: CGRect) -> WindowLayout? {
        allCases.first { WindowGeometry.isClose(frame, to: $0.frame(in: bounds), tolerance: 8) }
    }
}

struct WindowDisplay: Equatable {
    let id: UInt32
    let frame: CGRect
    let visibleFrame: CGRect
}

enum WindowCommand {
    case snapLeft, snapRight, snapUp, snapDown, moveDisplayLeft, moveDisplayRight
}

struct WindowPlacement {
    let display: WindowDisplay
    let layout: WindowLayout?
    let frame: CGRect
    let message: String
}

enum WindowGeometry {
    static func isClose(_ lhs: CGRect, to rhs: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.maxX - rhs.maxX) <= tolerance && abs(lhs.maxY - rhs.maxY) <= tolerance
    }

    static func display(containing frame: CGRect, in displays: [WindowDisplay]) -> WindowDisplay? {
        displays.sorted { lhs, rhs in
            let a = intersectionArea(frame, lhs.frame)
            let b = intersectionArea(frame, rhs.frame)
            if a != b { return a > b }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let da = distanceSquared(center, to: lhs.frame)
            let db = distanceSquared(center, to: rhs.frame)
            return da == db ? lhs.id < rhs.id : da < db
        }.first
    }

    static func adjacent(to source: WindowDisplay, direction: Int, in displays: [WindowDisplay]) -> WindowDisplay? {
        // A screen directly above/below is not a left/right neighbor merely because
        // it is wider or slightly offset. Require a screen beyond the horizontal edge.
        let candidates = displays.filter {
            $0.id != source.id && (direction < 0
                ? $0.frame.maxX <= source.frame.minX + 1
                : $0.frame.minX >= source.frame.maxX - 1)
        }
        func score(_ candidate: WindowDisplay) -> CGFloat {
            let horizontal = direction < 0
                ? max(0, source.frame.minX - candidate.frame.maxX)
                : max(0, candidate.frame.minX - source.frame.maxX)
            let vertical = max(0, source.frame.minY - candidate.frame.maxY, candidate.frame.minY - source.frame.maxY)
            return horizontal + vertical * 4
                + abs(candidate.frame.midY - source.frame.midY) * 0.1
                + abs(candidate.frame.midX - source.frame.midX) * 0.01
        }
        return candidates.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.id < $1.id : a < b
        }.first
    }

    static func moved(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let width = min(frame.width, target.width), height = min(frame.height, target.height)
        // Normalize the available travel, not the full screen width. A centered or
        // edge-aligned floating window stays centered or edge-aligned on either screen.
        func fraction(_ origin: CGFloat, start: CGFloat, travel: CGFloat) -> CGFloat {
            travel > 1 ? min(1, max(0, (origin - start) / travel)) : 0.5
        }
        let x = fraction(frame.minX, start: source.minX, travel: source.width - frame.width)
        let y = fraction(frame.minY, start: source.minY, travel: source.height - frame.height)
        return CGRect(x: target.minX + x * (target.width - width),
                      y: target.minY + y * (target.height - height), width: width, height: height).integral
    }

    static func fitted(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width), height = min(frame.height, bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    static func alignedOrigin(size: CGSize, placement: WindowPlacement) -> CGPoint {
        let target = placement.frame, bounds = placement.display.visibleFrame
        var x = target.minX, y = target.minY
        if placement.layout?.horizontalSide == 1 { x = bounds.maxX - size.width }
        if [.bottom, .bottomLeft, .bottomRight].contains(placement.layout) { y = bounds.maxY - size.height }
        // Respect an app's minimum size while keeping its title bar accessible.
        x = max(bounds.minX, min(x, bounds.maxX - size.width))
        y = max(bounds.minY, min(y, bounds.maxY - size.height))
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    static func plan(_ command: WindowCommand, currentFrame: CGRect, layout: WindowLayout?,
                     display: WindowDisplay, displays: [WindowDisplay], restoreFrame: CGRect?) -> WindowPlacement? {
        var destination = display
        let next: WindowLayout?
        var floatingFrame: CGRect?
        switch command {
        case .snapLeft, .snapRight:
            let direction = command == .snapLeft ? -1 : 1
            if layout?.horizontalSide == direction,
               let neighbor = adjacent(to: display, direction: direction, in: displays) {
                destination = neighbor
                next = (layout ?? .left).onSide(-direction)
            } else {
                next = (layout ?? .left).onSide(direction)
            }
        case .snapUp:
            switch layout {
            case .left, .bottomLeft: next = .topLeft
            case .right, .bottomRight: next = .topRight
            default: next = .maximized
            }
        case .snapDown:
            switch layout {
            case .topLeft: next = .left
            case .topRight: next = .right
            case .left: next = .bottomLeft
            case .right: next = .bottomRight
            case .maximized, .bottomLeft, .bottomRight, .bottom:
                next = nil
                floatingFrame = fitted(restoreFrame ?? display.visibleFrame.insetBy(
                    dx: display.visibleFrame.width * 0.14, dy: display.visibleFrame.height * 0.14
                ), in: display.visibleFrame)
            case nil: next = .bottom
            }
        case .moveDisplayLeft, .moveDisplayRight:
            let direction = command == .moveDisplayLeft ? -1 : 1
            guard let neighbor = adjacent(to: display, direction: direction, in: displays) else { return nil }
            destination = neighbor
            next = layout
            floatingFrame = moved(currentFrame, from: display.visibleFrame, to: neighbor.visibleFrame)
        }
        let frame = next?.frame(in: destination.visibleFrame) ?? floatingFrame ?? currentFrame
        let label: String = switch next {
        case .left: "left half"
        case .right: "right half"
        case .topLeft: "top-left quarter"
        case .topRight: "top-right quarter"
        case .bottomLeft: "bottom-left quarter"
        case .bottomRight: "bottom-right quarter"
        case .bottom: "bottom half"
        case .maximized: "maximized"
        case nil: "restored size"
        }
        return WindowPlacement(display: destination, layout: next, frame: frame,
            message: destination.id == display.id ? "Window: \(label)." : "Window moved to the neighboring display (\(label)).")
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private static func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let x = max(0, rect.minX - point.x, point.x - rect.maxX)
        let y = max(0, rect.minY - point.y, point.y - rect.maxY)
        return x * x + y * y
    }
}
