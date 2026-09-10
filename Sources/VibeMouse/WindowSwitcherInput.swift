import CoreGraphics
import Carbon.HIToolbox

enum WindowSwitchModifier: String, Sendable, CaseIterable {
    case command = "Command", control = "Ctrl", option = "Alt"

    var flag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .control: .maskControl
        case .option: .maskAlternate
        }
    }
}

enum WindowSwitchAction: Equatable, Sendable {
    case begin(WindowSwitchModifier, backwards: Bool)
    case beginAllWindows(backwards: Bool)
    case step(backwards: Bool)
    case moveRow(backwards: Bool)
    case finish
    case cancel
}

enum WindowSwitchScope: Equatable, Sendable {
    case currentApplication, allApplications
}

// This state machine does no window queries or drawing inside the event tap.
// Suppressed key-ups survive dismissal, including releasing the modifier first.
struct WindowSwitcherInput {
    private(set) var modifier: WindowSwitchModifier?
    private var scope = WindowSwitchScope.currentApplication
    private var suppressedKeys: Set<Int64> = []

    mutating func keyDown(_ code: Int64, flags: CGEventFlags, isRepeat: Bool,
                          enabled: Bool) -> (handled: Bool, action: WindowSwitchAction?) {
        if isRepeat, suppressedKeys.contains(code), modifier == nil { return (true, nil) }

        if modifier != nil {
            switch Int(code) {
            case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter:
                suppressedKeys.insert(code)
                modifier = nil
                return (true, Int(code) == kVK_Escape ? .cancel : .finish)
            case kVK_ANSI_Grave, kVK_Tab, kVK_LeftArrow, kVK_RightArrow:
                suppressedKeys.insert(code)
                let backwards = Int(code) == kVK_LeftArrow
                    || (Int(code) != kVK_RightArrow && flags.contains(.maskShift))
                return (true, .step(backwards: backwards))
            case kVK_UpArrow where scope == .allApplications,
                 kVK_DownArrow where scope == .allApplications:
                suppressedKeys.insert(code)
                return (true, .moveRow(backwards: Int(code) == kVK_UpArrow))
            default:
                modifier = nil
                return (false, .cancel)
            }
        }

        guard enabled, !isRepeat,
              !flags.contains(.maskSecondaryFn) else { return (false, nil) }
        let modifiers = WindowSwitchModifier.allCases.filter { flags.contains($0.flag) }
        guard modifiers.count == 1, let held = modifiers.first else { return (false, nil) }
        if Int(code) == kVK_Tab, held == .option {
            modifier = .option
            scope = .allApplications
            suppressedKeys.insert(code)
            return (true, .beginAllWindows(backwards: flags.contains(.maskShift)))
        }
        guard Int(code) == kVK_ANSI_Grave else { return (false, nil) }
        modifier = held
        scope = .currentApplication
        suppressedKeys.insert(code)
        return (true, .begin(held, backwards: flags.contains(.maskShift)))
    }

    mutating func keyUp(_ code: Int64) -> Bool {
        suppressedKeys.remove(code) != nil
    }

    mutating func flagsChanged(_ flags: CGEventFlags) -> WindowSwitchAction? {
        guard let modifier, !flags.contains(modifier.flag) else { return nil }
        self.modifier = nil
        return .finish
    }

    mutating func cancel() -> WindowSwitchAction? {
        guard modifier != nil else { return nil }
        modifier = nil
        return .cancel
    }

    mutating func reset() {
        modifier = nil
        suppressedKeys.removeAll()
    }
}
