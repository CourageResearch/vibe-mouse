import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum Permissions {
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func screenRecordingGranted(prompt: Bool) -> Bool {
        if prompt {
            return CGRequestScreenCaptureAccess()
        }
        return CGPreflightScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    static func openInputMonitoringSettings() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    static func revealAppInFinder() {
        if Bundle.main.bundleURL.pathExtension == "app" {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            return
        }

        if let executableURL = Bundle.main.executableURL {
            var url = executableURL
            while url.path != "/" {
                if url.pathExtension == "app" {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    return
                }
                url.deleteLastPathComponent()
            }
        }
    }

    private static func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
