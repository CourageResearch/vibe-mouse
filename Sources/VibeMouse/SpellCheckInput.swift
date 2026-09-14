import CoreGraphics
import Carbon.HIToolbox

// Observe physical input before any remapping. A modifier used in a chord is
// never a spelling tap, even when it is released before the other key.
struct SpellCheckInput {
    private var candidate: (code: Int64, started: TimeInterval)?
    private var previousFlags: CGEventFlags = []
    private var heldKeys: Set<Int64> = []
    private var heldButtons: Set<Int> = []
    var maximumTapDuration: TimeInterval = 0.5

    mutating func reconcileHeldInputs(isKeyDown: (Int64) -> Bool, isButtonDown: (Int) -> Bool) {
        // Other event taps can consume a release. Do not let one lost key-up
        // permanently prevent all future modifier taps.
        heldKeys = heldKeys.filter(isKeyDown)
        heldButtons = heldButtons.filter(isButtonDown)
    }

    mutating func handle(type: CGEventType, code: Int64, flags: CGEventFlags,
                         time: TimeInterval, enabled: Bool) -> Bool {
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
        guard enabled else { reset(); return false }
        switch type {
        case .keyDown: heldKeys.insert(code)
        case .keyUp: heldKeys.remove(code)
        case .leftMouseDown: heldButtons.insert(0)
        case .leftMouseUp: heldButtons.remove(0)
        case .rightMouseDown: heldButtons.insert(1)
        case .rightMouseUp: heldButtons.remove(1)
        case .otherMouseDown: heldButtons.insert(2)
        case .otherMouseUp: heldButtons.remove(2)
        default: break
        }
        if type == .flagsChanged {
            defer { previousFlags = modifiers }
            if let held = candidate {
                candidate = nil
                return code == held.code && modifiers.isEmpty
                    && time >= held.started && time - held.started <= maximumTapDuration
            }
            guard previousFlags.isEmpty, heldKeys.isEmpty, heldButtons.isEmpty else { return false }
            let flag: CGEventFlags
            switch Int(code) {
            case kVK_Command, kVK_RightCommand: flag = .maskCommand
            case kVK_Option, kVK_RightOption: flag = .maskAlternate
            default: return false
            }
            if modifiers == flag { candidate = (code, time) }
        } else {
            // Mouse movement is harmless; clicks, scrolling, keys and media keys
            // all mean the modifier is participating in another action.
            switch type {
            case .mouseMoved: break
            default: candidate = nil
            }
        }
        return false
    }

    mutating func reset() {
        candidate = nil
        previousFlags = []
        heldKeys.removeAll()
        heldButtons.removeAll()
    }
}
