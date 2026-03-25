import AppKit
import SwiftUI

@MainActor
final class DictationCursorOverlay {
    private let indicatorSize = CGSize(width: 52, height: 52)
    private var window: NSWindow?
    private var followTimer: Timer?
    private var isVisible = false

    func show() {
        buildWindowIfNeeded()
        updatePosition()
        guard let window else { return }
        guard !isVisible else { return }

        window.orderFrontRegardless()
        startFollowTimer()
        isVisible = true
    }

    func hide() {
        followTimer?.invalidate()
        followTimer = nil
        window?.orderOut(nil)
        isVisible = false
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let contentView = NSHostingView(rootView: DictationCursorIndicatorView())
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

    private func startFollowTimer() {
        followTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func updatePosition() {
        guard let window else { return }

        let mouseLocation = NSEvent.mouseLocation
        let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        let bounds = containingScreen?.frame ?? CGRect(origin: .zero, size: indicatorSize)

        var origin = CGPoint(
            x: mouseLocation.x - indicatorSize.width / 2,
            y: mouseLocation.y - indicatorSize.height / 2
        )

        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - indicatorSize.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - indicatorSize.height)

        window.setFrame(NSRect(origin: origin, size: indicatorSize), display: isVisible)
    }
}

private struct DictationCursorIndicatorView: View {
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.53, blue: 0.34),
                            Color(red: 1.0, green: 0.30, blue: 0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3.5
                )
                .frame(width: 34, height: 34)
                .scaleEffect(pulse ? 1.08 : 0.84)
                .opacity(pulse ? 0.40 : 0.95)

            Circle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.25)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.42, blue: 0.26),
                                Color(red: 0.92, green: 0.15, blue: 0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.20), radius: 5, x: 0, y: 2)
            .offset(x: 8, y: 8)
        }
        .frame(width: 52, height: 52)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.92).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
