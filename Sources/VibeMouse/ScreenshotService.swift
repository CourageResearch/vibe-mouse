@preconcurrency import Foundation
import AppKit
import CoreGraphics

final class ScreenshotService: @unchecked Sendable {
    enum CaptureError: Error {
        case alreadyRunning
        case cancelled
        case failed(String)
    }

    private let queue = DispatchQueue(label: "mouseChordShot.screenshot")
    private var inProgress = false

    func captureInteractiveToClipboard(completion: @escaping @Sendable (Result<Void, CaptureError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            guard !self.inProgress else {
                DispatchQueue.main.async {
                    completion(.failure(.alreadyRunning))
                }
                return
            }

            self.inProgress = true
            defer { self.inProgress = false }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-c"]

            do {
                try process.run()
                process.waitUntilExit()

                let result: Result<Void, CaptureError>
                if process.terminationStatus == 0 {
                    result = .success(())
                } else if process.terminationStatus == 1 {
                    result = .failure(.cancelled)
                } else {
                    result = .failure(.failed("Exit code \(process.terminationStatus)"))
                }

                DispatchQueue.main.async {
                    completion(result)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.failed(error.localizedDescription)))
                }
            }
        }
    }

    func captureRectangleToClipboard(
        from startPoint: CGPoint,
        to endPoint: CGPoint,
        completion: @escaping @Sendable (Result<Void, CaptureError>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            guard !self.inProgress else {
                DispatchQueue.main.async {
                    completion(.failure(.alreadyRunning))
                }
                return
            }

            self.inProgress = true
            defer { self.inProgress = false }

            let normalizedRect = Self.normalizedRect(from: startPoint, to: endPoint)
            guard normalizedRect.width >= 3, normalizedRect.height >= 3 else {
                DispatchQueue.main.async {
                    completion(.failure(.cancelled))
                }
                return
            }

            guard let captureRectArgument = Self.captureRectArgument(forLowerLeftGlobalRect: normalizedRect) else {
                DispatchQueue.main.async {
                    completion(.failure(.failed("Could not convert selection area to screenshot coordinates.")))
                }
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-R", captureRectArgument, "-c"]

            do {
                try process.run()
                process.waitUntilExit()

                let result: Result<Void, CaptureError>
                if process.terminationStatus == 0 {
                    result = .success(())
                } else if process.terminationStatus == 1 {
                    result = .failure(.cancelled)
                } else {
                    result = .failure(.failed("Exit code \(process.terminationStatus)"))
                }

                DispatchQueue.main.async {
                    completion(result)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.failed(error.localizedDescription)))
                }
            }
        }
    }

    private static func normalizedRect(from startPoint: CGPoint, to endPoint: CGPoint) -> CGRect {
        let minX = min(startPoint.x, endPoint.x)
        let minY = min(startPoint.y, endPoint.y)
        let width = abs(endPoint.x - startPoint.x)
        let height = abs(endPoint.y - startPoint.y)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private static func captureRectArgument(forLowerLeftGlobalRect rect: CGRect) -> String? {
        let desktopTopY = DispatchQueue.main.sync {
            NSScreen.screens.map(\.frame.maxY).max() ?? 0
        }
        guard desktopTopY > 0 else { return nil }

        let x = Int(rect.minX.rounded(.down))
        let y = Int((desktopTopY - rect.maxY).rounded(.down))
        let width = Int(rect.width.rounded(.up))
        let height = Int(rect.height.rounded(.up))
        guard width > 0, height > 0 else { return nil }

        return "\(x),\(y),\(width),\(height)"
    }
}
