@preconcurrency import Foundation
import CoreGraphics
import Carbon.HIToolbox

final class DictationService: @unchecked Sendable {
    enum DictationError: Error {
        case failed(String)
    }

    // Must match the shortcut configured in macOS Keyboard > Dictation.
    private let dictationShortcutKeyCode = CGKeyCode(kVK_ANSI_D)
    private let dictationShortcutFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    func toggleDictation(completion: @escaping @Sendable (Result<Void, DictationError>) -> Void) {
        postKey(
            keyCode: dictationShortcutKeyCode,
            flags: dictationShortcutFlags,
            failureMessage: "Could not create Dictation shortcut keyboard events.",
            completion: completion
        )
    }

    func pressReturn(completion: @escaping @Sendable (Result<Void, DictationError>) -> Void) {
        postKey(
            keyCode: CGKeyCode(kVK_Return),
            flags: [],
            failureMessage: "Could not create Return key keyboard events.",
            completion: completion
        )
    }

    private func postKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        failureMessage: String,
        completion: @escaping @Sendable (Result<Void, DictationError>) -> Void
    ) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            DispatchQueue.main.async {
                completion(.failure(.failed("Could not create keyboard event source.")))
            }
            return
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            DispatchQueue.main.async {
                completion(.failure(.failed(failureMessage)))
            }
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.async {
            completion(.success(()))
        }
    }
}
