import AppKit
import ScreenCaptureKit

@MainActor
protocol WindowPreviewCapturing: AnyObject, Sendable {
    var unavailabilityReason: String? { get }
    func sources() async throws -> [WindowPreviewSource]
    func capture(_ source: WindowPreviewSource) async throws -> CGImage
}

enum WindowPreviewCaptureError: Error {
    case unavailable, windowClosed, timedOut, noImage, transparentImage
}

enum WindowPreviewImage {
    static func hasVisiblePixels(_ image: CGImage) -> Bool {
        // A successfully returned image can still be entirely transparent.
        // Normalize the pixel layout instead of assuming the source alpha order.
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            let pixels = bytes.bindMemory(to: UInt8.self)
            return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
        }
    }
}

@MainActor
final class SystemWindowPreviewCapture: WindowPreviewCapturing {
    private var windows: [CGWindowID: SCWindow] = [:]

    var unavailabilityReason: String? {
        guard CGPreflightScreenCaptureAccess() else {
            return "Enable Screen Recording in Vibe Mouse Settings for thumbnails."
        }
        guard #available(macOS 14.0, *) else { return "Window thumbnails require macOS 14 or later." }
        return nil
    }

    func sources() async throws -> [WindowPreviewSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        return content.windows.compactMap { window in
            guard let app = window.owningApplication, window.windowLayer == 0,
                  window.frame.width > 0, window.frame.height > 0 else { return nil }
            return WindowPreviewSource(windowID: window.windowID, processIdentifier: app.processID,
                                       title: window.title ?? "", frame: window.frame)
        }
    }

    func capture(_ source: WindowPreviewSource) async throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw WindowPreviewCaptureError.unavailable }
        try Task.checkCancellation()
        guard let window = windows[source.windowID],
              window.owningApplication?.processID == source.processIdentifier else {
            throw WindowPreviewCaptureError.windowClosed
        }
        let config = SCStreamConfiguration()
        let scale = min(1, 640 / max(1, max(window.frame.width, window.frame.height)))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // A minimized or unavailable window may never produce a frame. Resume
        // the caller after a deadline even if the system callback arrives late.
        return try await withCheckedThrowingContinuation { continuation in
            let request = WindowPreviewCaptureRequest(continuation: continuation)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                Task { @MainActor in
                    if let image { request.finish(.success(image)) }
                    else { request.finish(.failure(error ?? WindowPreviewCaptureError.noImage)) }
                }
            }
        }
    }
}

@MainActor
final class WindowPreviewCaptureRequest {
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private var timeout: Task<Void, Never>?

    init(continuation: CheckedContinuation<CGImage, any Error>, timeoutSeconds: Double = 1.5) {
        self.continuation = continuation
        timeout = Task {
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
            self.finish(.failure(WindowPreviewCaptureError.timedOut))
        }
    }

    func finish(_ result: Result<CGImage, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}
