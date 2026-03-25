@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation

final class TextInputFocusService: @unchecked Sendable {
    struct Target: Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let appName: String
    }

    private let editableAttribute = "AXEditable"
    private let focusedAttribute = "AXFocused"
    private let textInputRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
    ]

    func captureFrontmostTarget(excluding bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Target? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let bundleIdentifier, application.bundleIdentifier == bundleIdentifier {
            return nil
        }

        return Target(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            appName: application.localizedName ?? application.bundleIdentifier ?? "Unknown App"
        )
    }

    func captureTarget(bundleIdentifier: String, fallbackAppNameContains: String? = nil) -> Target? {
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }

        if let application = applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return Target(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                appName: application.localizedName ?? application.bundleIdentifier ?? "Unknown App"
            )
        }

        if let fallbackAppNameContains,
           let application = applications.first(where: {
               ($0.localizedName ?? "").localizedCaseInsensitiveContains(fallbackAppNameContains)
           }) {
            return Target(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                appName: application.localizedName ?? application.bundleIdentifier ?? "Unknown App"
            )
        }

        return nil
    }

    func focusTextInput(in target: Target?) -> Bool {
        guard let target else { return false }
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated else {
            return false
        }

        _ = application.activate(options: [.activateIgnoringOtherApps])

        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        if let focusedElement = copyElement(appElement, attribute: kAXFocusedUIElementAttribute as String),
           isEditableElement(focusedElement) {
            return focus(element: focusedElement)
        }

        var roots: [AXUIElement] = []
        if let focusedWindow = copyElement(appElement, attribute: kAXFocusedWindowAttribute as String) {
            roots.append(focusedWindow)
        }
        if let mainWindow = copyElement(appElement, attribute: kAXMainWindowAttribute as String) {
            roots.append(mainWindow)
        }
        roots.append(contentsOf: copyElements(appElement, attribute: kAXWindowsAttribute as String))

        var visited = Set<String>()
        for root in roots {
            if let input = findEditableDescendant(startingAt: root, visited: &visited) {
                return focus(element: input)
            }
        }

        return false
    }

    private func findEditableDescendant(
        startingAt root: AXUIElement,
        visited: inout Set<String>,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth <= 16 else { return nil }

        let identifier = "\(Unmanaged.passUnretained(root).toOpaque())"
        guard visited.insert(identifier).inserted else { return nil }

        if isEditableElement(root) {
            return root
        }

        for attribute in [kAXChildrenAttribute as String, kAXContentsAttribute as String] {
            for child in copyElements(root, attribute: attribute) {
                if let editable = findEditableDescendant(startingAt: child, visited: &visited, depth: depth + 1) {
                    return editable
                }
            }
        }

        return nil
    }

    private func isEditableElement(_ element: AXUIElement) -> Bool {
        let role = copyString(element, attribute: kAXRoleAttribute as String) ?? ""
        if textInputRoles.contains(role) {
            return true
        }
        return copyBool(element, attribute: editableAttribute) ?? false
    }

    private func focus(element: AXUIElement) -> Bool {
        let setResult = AXUIElementSetAttributeValue(element, focusedAttribute as CFString, kCFBooleanTrue)
        if setResult == .success {
            return true
        }

        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return pressResult == .success
    }

    private func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        guard let value else { return nil }
        return (value as! AXUIElement)
    }

    private func copyElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func copyString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func copyBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? Bool
    }
}
