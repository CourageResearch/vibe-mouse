@preconcurrency import Foundation
import CoreGraphics
import Carbon.HIToolbox

final class PasteService: @unchecked Sendable {
    enum PasteError: Error {
        case failed(String)
    }

    func pasteClipboard(completion: @escaping @Sendable (Result<Void, PasteError>) -> Void) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            DispatchQueue.main.async {
                completion(.failure(.failed("Could not create keyboard event source.")))
            }
            return
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            DispatchQueue.main.async {
                completion(.failure(.failed("Could not create Cmd+V keyboard events.")))
            }
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.async {
            completion(.success(()))
        }
    }
}
