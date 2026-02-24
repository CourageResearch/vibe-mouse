import AppKit

@MainActor
final class DragSelectionOverlay {
    private final class OverlayView: NSView {
        var screenFrame: CGRect = .zero
        var selectionRectInGlobal: CGRect = .null {
            didSet {
                needsDisplay = true
            }
        }

        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill()
            dirtyRect.fill()

            guard !selectionRectInGlobal.isNull else { return }

            let localRect = CGRect(
                x: selectionRectInGlobal.minX - screenFrame.minX,
                y: selectionRectInGlobal.minY - screenFrame.minY,
                width: selectionRectInGlobal.width,
                height: selectionRectInGlobal.height
            ).intersection(bounds)

            guard !localRect.isNull, !localRect.isEmpty else { return }

            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            localRect.fill()

            NSColor.systemBlue.withAlphaComponent(0.92).setStroke()
            let strokeRect = localRect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(rect: strokeRect)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private struct OverlayItem {
        let screenFrame: CGRect
        let window: NSWindow
        let view: OverlayView
    }

    private var overlays: [OverlayItem] = []
    private var isVisible = false

    func updateSelection(from startPoint: CGPoint, to endPoint: CGPoint) {
        let selectionRect = CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )

        rebuildOverlaysIfNeeded()
        for overlay in overlays {
            overlay.view.selectionRectInGlobal = selectionRect
        }

        guard !isVisible else { return }
        for overlay in overlays {
            overlay.window.orderFrontRegardless()
        }
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        for overlay in overlays {
            overlay.window.orderOut(nil)
            overlay.view.selectionRectInGlobal = .null
        }
        isVisible = false
    }

    private func rebuildOverlaysIfNeeded() {
        let screenFrames = NSScreen.screens.map(\.frame)
        let existingFrames = overlays.map(\.screenFrame)
        guard screenFrames != existingFrames else { return }

        for overlay in overlays {
            overlay.window.orderOut(nil)
            overlay.window.close()
        }
        overlays.removeAll()

        for screen in NSScreen.screens {
            let frame = screen.frame
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
            view.screenFrame = frame
            view.wantsLayer = true

            let window = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view

            overlays.append(
                OverlayItem(screenFrame: frame, window: window, view: view)
            )
        }
    }
}
