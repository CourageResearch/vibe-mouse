@preconcurrency import Foundation

final class DictationService: @unchecked Sendable {
    private enum Action {
        case start
        case stop(pressReturn: Bool)

        func scriptLines(targetProcessID: pid_t?) -> [String] {
            switch self {
            case .start:
                return DictationService.menuClickScript(
                    targetProcessID: targetProcessID,
                    menuTitles: ["Start Dictation…", "Start Dictation..."],
                    errorMessage: "Could not find an enabled Start Dictation menu item in the target app."
                )
            case .stop(let pressReturn):
                return DictationService.menuClickScript(
                    targetProcessID: targetProcessID,
                    // Some apps/macOS contexts keep this as "Start Dictation…" even while dictation is active.
                    menuTitles: [
                        "Stop Dictation",
                        "Stop Dictation…",
                        "Stop Dictation...",
                        "Start Dictation…",
                        "Start Dictation..."
                    ],
                    errorMessage: "Could not find an enabled dictation stop/toggle menu item in the target app.",
                    pressReturnAfterClick: pressReturn
                )
            }
        }
    }

    enum TriggerError: Error {
        case alreadyRunning
        case failed(String)
    }

    private let queue = DispatchQueue(label: "mouseChordShot.dictation")
    private var inProgress = false

    func startDictation(
        targetProcessID: pid_t?,
        completion: @escaping @Sendable (Result<Void, TriggerError>) -> Void
    ) {
        run(action: .start, targetProcessID: targetProcessID, completion: completion)
    }

    func stopDictation(
        targetProcessID: pid_t?,
        pressReturnAfterStop: Bool,
        completion: @escaping @Sendable (Result<Void, TriggerError>) -> Void
    ) {
        run(action: .stop(pressReturn: pressReturnAfterStop), targetProcessID: targetProcessID, completion: completion)
    }

    private func run(
        action: Action,
        targetProcessID: pid_t?,
        completion: @escaping @Sendable (Result<Void, TriggerError>) -> Void
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

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = action.scriptLines(targetProcessID: targetProcessID).flatMap { ["-e", $0] }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let result: Result<Void, TriggerError>
                if process.terminationStatus == 0 {
                    result = .success(())
                } else {
                    let message = stderr.isEmpty ? (stdout.isEmpty ? "osascript exit code \(process.terminationStatus)" : stdout) : stderr
                    result = .failure(.failed(message))
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

    private static func menuClickScript(
        targetProcessID: pid_t?,
        menuTitles: [String],
        errorMessage: String,
        pressReturnAfterClick: Bool = false
    ) -> [String] {
        let menuTitlesList = menuTitles
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ", ")

        var lines: [String] = [
            "tell application \"System Events\"",
        ]

        lines.append(contentsOf: targetProcessResolutionLines(targetProcessID: targetProcessID))

        lines.append(contentsOf: [
            "tell targetProcess",
            // Retries help when menu state lags briefly as dictation starts/stops.
            "repeat 12 times",
            "repeat with barItem in menu bar items of menu bar 1",
            "repeat with dictationTitle in {\(menuTitlesList)}",
            "try",
            "set itemTitle to contents of dictationTitle",
            "set candidateItem to menu item itemTitle of menu 1 of barItem",
            "if enabled of candidateItem then",
            "click candidateItem",
            "end if",
            "end try",
            "end repeat",
            "end repeat",
            "delay 0.05",
            "end repeat",
            "error \"\(errorMessage.replacingOccurrences(of: "\"", with: "\\\""))\"",
            "end tell",
        ])

        if let clickIndex = lines.firstIndex(of: "click candidateItem") {
            var successTail = [String]()
            if pressReturnAfterClick {
                successTail.append(contentsOf: [
                    // Small delay helps ensure dictated text commits before submitting.
                    "delay 0.08",
                    "tell application \"System Events\" to key code 36",
                ])
            }
            successTail.append("return \"OK\"")
            lines.insert(contentsOf: successTail, at: clickIndex + 1)
        }

        lines.append("end tell")
        return lines
    }

    private static func targetProcessResolutionLines(targetProcessID: pid_t?) -> [String] {
        guard let targetProcessID else {
            return [
                "set targetProcess to first application process whose frontmost is true",
            ]
        }

        return [
            "set targetProcess to missing value",
            "try",
            "set targetProcess to first application process whose unix id is \(Int(targetProcessID))",
            "end try",
            "if targetProcess is missing value then",
            "set targetProcess to first application process whose frontmost is true",
            "end if",
        ]
    }
}
