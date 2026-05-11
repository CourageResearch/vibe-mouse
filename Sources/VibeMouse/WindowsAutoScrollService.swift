import AppKit
import SwiftUI

@MainActor
final class WindowsAutoScrollService {
    private let overlay = AutoScrollAnchorOverlay()
    private var timer: Timer?
    private var anchorPoint: CGPoint?
    private var fractionalScrollRemainder: CGFloat = 0
    private let deadZone: CGFloat = 18
    private let maximumLinesPerTick: CGFloat = 5

    var isActive: Bool {
        anchorPoint != nil
    }

    func toggle(at point: CGPoint) {
        if isActive {
            stop()
        } else {
            start(at: point)
        }
    }

    func start(at point: CGPoint) {
        stop()
        anchorPoint = point
        overlay.show(at: point)

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        anchorPoint = nil
        fractionalScrollRemainder = 0
        overlay.hide()
    }

    private func tick() {
        guard let anchorPoint else { return }

        let mouseLocation = NSEvent.mouseLocation
        let verticalDistance = mouseLocation.y - anchorPoint.y
        guard abs(verticalDistance) > deadZone else { return }

        let signedDistance = verticalDistance - (verticalDistance > 0 ? deadZone : -deadZone)
        let direction: CGFloat = signedDistance > 0 ? 1 : -1
        let magnitude = min(maximumLinesPerTick, pow(abs(signedDistance) / 42, 1.25))
        let desiredDelta = (direction * magnitude) + fractionalScrollRemainder
        let wholeDelta = desiredDelta.rounded(.towardZero)
        fractionalScrollRemainder = desiredDelta - wholeDelta
        let scrollDelta = Int32(wholeDelta)
        guard scrollDelta != 0 else { return }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .line,
                wheelCount: 1,
                wheel1: scrollDelta,
                wheel2: 0,
                wheel3: 0
              ) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }
}

@MainActor
private final class AutoScrollAnchorOverlay {
    private let indicatorSize = CGSize(width: 58, height: 58)
    private var window: NSWindow?

    func show(at point: CGPoint) {
        buildWindowIfNeeded()
        guard let window else { return }
        window.setFrame(NSRect(origin: origin(for: point), size: indicatorSize), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let contentView = NSHostingView(rootView: AutoScrollAnchorView())
        contentView.frame = NSRect(origin: .zero, size: indicatorSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: indicatorSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = contentView
        window.orderOut(nil)
        self.window = window
    }

    private func origin(for point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - indicatorSize.width / 2,
            y: point.y - indicatorSize.height / 2
        )
    }
}

private struct AutoScrollAnchorView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.38), lineWidth: 1.5)
                )

            VStack(spacing: 3) {
                Image(systemName: "chevron.up")
                Circle()
                    .fill(Color.primary.opacity(0.72))
                    .frame(width: 5, height: 5)
                Image(systemName: "chevron.down")
            }
            .font(.system(size: 14, weight: .black))
            .foregroundStyle(Color.primary.opacity(0.82))
        }
        .frame(width: 58, height: 58)
    }
}
