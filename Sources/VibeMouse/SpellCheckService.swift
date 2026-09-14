import AppKit
import ApplicationServices
import os

struct SpellingWord: Equatable {
    let text: String
    let range: NSRange
    let anchorRange: NSRange

    static func atSelection(_ selection: NSRange, in text: String) -> SpellingWord? {
        let source = text as NSString
        guard source.length <= 100_000, selection.location != NSNotFound,
              selection.location <= source.length,
              selection.length <= source.length - selection.location else { return nil }
        var result: SpellingWord?
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            let end = NSMaxRange(range)
            guard selection.location >= range.location,
                  selection.location < end || (selection.length == 0 && selection.location == end),
                  NSMaxRange(selection) <= end else { return }
            let anchor = min(selection.location, end - 1)
            result = SpellingWord(text: source.substring(with: range), range: range,
                                 anchorRange: source.rangeOfComposedCharacterSequence(at: anchor))
            stop.pointee = true
        }
        return result
    }
}

struct SpellingTarget {
    let element: AXUIElement
    let processIdentifier: pid_t
    let value: String
    let selection: NSRange
}

struct SpellingPointerTarget {
    let element: AXUIElement
    let processIdentifier: pid_t
    let point: CGPoint
}

@MainActor
protocol SpellingAccess {
    func focusedTarget() -> SpellingTarget?
    func bounds(for range: NSRange, in target: SpellingTarget) -> CGRect?
    func stillFocused(_ target: SpellingTarget, at point: CGPoint) -> Bool
    func showContextMenu(at point: CGPoint) -> Bool
    func pointerTarget() -> SpellingPointerTarget?
    func stillUnderPointer(_ target: SpellingPointerTarget) -> Bool
}

@MainActor
final class SpellCheckService {
    private let access: any SpellingAccess
    private let isMisspelled: (String) -> Bool
    private let logger = Logger(subsystem: "com.courageresearch.mousechordshot", category: "Spelling")

    init(access: any SpellingAccess = SystemSpellingAccess(),
         isMisspelled: @escaping (String) -> Bool = { word in
             NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: nil,
                 wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
         }) {
        self.access = access
        self.isMisspelled = isMisspelled
    }

    // Runs after modifier release, outside the event tap. The owning app keeps
    // its native correction menu, dictionary, replacement behavior and undo.
    func showSuggestions() -> String? {
        guard let target = access.focusedTarget() else {
            return showAtPointer(reason: "Text cursor unavailable")
        }
        guard let word = SpellingWord.atSelection(target.selection, in: target.value),
              isMisspelled(word.text) else {
            return showAtPointer(reason: "No spelling correction at the text cursor")
        }
        guard let bounds = access.bounds(for: word.anchorRange, in: target),
              !bounds.isNull, !bounds.isInfinite, bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            return showAtPointer(reason: "Word position unavailable")
        }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        guard access.stillFocused(target, at: point) else {
            logger.info("Spelling canceled: text focus or target changed")
            return nil
        }
        let requested = access.showContextMenu(at: point)
        logger.info("Spelling menu at text cursor requested: \(requested)")
        return requested ? "Requested the word's spelling menu." : nil
    }

    private func showAtPointer(reason: String) -> String? {
        // Some web editors omit text ranges or disagree with the system's
        // dictionary. Let their native menu resolve the word under the pointer.
        guard let target = access.pointerTarget(), access.stillUnderPointer(target) else {
            logger.info("Spelling unavailable: \(reason, privacy: .public); no editable field under pointer")
            return "\(reason). Point the mouse at the underlined word and tap Alt."
        }
        let requested = access.showContextMenu(at: target.point)
        logger.info("Spelling menu under pointer requested: \(requested)")
        return requested ? "Requested spelling suggestions under the mouse pointer." : nil
    }
}

@MainActor
final class SystemSpellingAccess: SpellingAccess {
    func pointerTarget() -> SpellingPointerTarget? {
        guard modifiersAreReleased(), let app = NSWorkspace.shared.frontmostApplication,
              let point = CGEvent(source: nil)?.location,
              let hit = element(at: point),
              let editable = editableAncestor(of: hit) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(editable, &pid) == .success, pid == app.processIdentifier else { return nil }
        return SpellingPointerTarget(element: editable, processIdentifier: pid, point: point)
    }

    func stillUnderPointer(_ target: SpellingPointerTarget) -> Bool {
        guard let current = pointerTarget() else { return false }
        return current.processIdentifier == target.processIdentifier
            && CFEqual(current.element, target.element)
            && hypot(current.point.x - target.point.x, current.point.y - target.point.y) < 3
    }

    func focusedTarget() -> SpellingTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let focused = elementAttribute(kAXFocusedUIElementAttribute, on: application),
              let element = editableAncestor(of: focused),
              let text = attribute(kAXValueAttribute, on: element) as? String,
              let value = attribute(kAXSelectedTextRangeAttribute, on: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0 else { return nil }
        return SpellingTarget(element: element, processIdentifier: app.processIdentifier,
                              value: text, selection: NSRange(location: selection.location, length: selection.length))
    }

    func bounds(for range: NSRange, in target: SpellingTarget) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(target.element,
            kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    func stillFocused(_ target: SpellingTarget, at point: CGPoint) -> Bool {
        // Cancel stale work if the user typed, moved the caret, changed apps, or
        // another surface now covers the word. Never click an arbitrary fallback.
        guard modifiersAreReleased(),
              let current = focusedTarget(), current.processIdentifier == target.processIdentifier,
              CFEqual(current.element, target.element), current.value == target.value,
              current.selection == target.selection else { return false }
        guard var element = element(at: point) else { return false }
        for _ in 0..<12 {
            if CFEqual(element, target.element) { return true }
            guard let parent = elementAttribute(kAXParentAttribute, on: element) else { return false }
            element = parent
        }
        return false
    }

    func showContextMenu(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                                 mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                               mouseCursorPosition: point, mouseButton: .right) else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: InputEventMarker.synthetic)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func modifiersAreReleased() -> Bool {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return hit
    }

    private func editableAncestor(of hit: AXUIElement) -> AXUIElement? {
        var element = hit
        for _ in 0..<8 {
            if attribute(kAXSubroleAttribute, on: element) as? String == kAXSecureTextFieldSubrole { return nil }
            if let role = attribute(kAXRoleAttribute, on: element) as? String,
               [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
                return element
            }
            guard let parent = elementAttribute(kAXParentAttribute, on: element) else { return nil }
            element = parent
        }
        return nil
    }

    private func elementAttribute(_ name: String, on element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, on: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
