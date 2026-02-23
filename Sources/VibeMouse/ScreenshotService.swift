@preconcurrency import Foundation

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
}
