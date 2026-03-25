@preconcurrency import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit

final class PasteService: @unchecked Sendable {
    enum PasteError: Error {
        case failed(String)
    }

    private struct PasteboardSnapshot {
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
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

    func pasteText(_ text: String, completion: @escaping @Sendable (Result<Void, PasteError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async {
                completion(.success(()))
            }
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(trimmed, forType: .string) else {
            DispatchQueue.main.async {
                completion(.failure(.failed("Could not write transcript to clipboard.")))
            }
            return
        }

        pasteClipboard { [weak self] result in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self else { return }
                self.restorePasteboard(snapshot, to: NSPasteboard.general)
            }
            completion(result)
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
        if let pasteboardItems = pasteboard.pasteboardItems {
            items = pasteboardItems.map { item in
                item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type: type, data: data)
                }
            }
        } else {
            items = []
        }

        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restoredItems: [NSPasteboardItem] = snapshot.items.map { itemEntries in
            let item = NSPasteboardItem()
            for entry in itemEntries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
