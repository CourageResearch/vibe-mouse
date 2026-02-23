import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerCard
                    behaviorCard
                    permissionsCard
                    statusCard
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.isEnabled },
            set: { model.isEnabled = $0 }
        )
    }

    private var chordBinding: Binding<Double> {
        Binding(
            get: { model.chordWindowMs },
            set: { model.chordWindowMs = $0 }
        )
    }

    private var pressReturnOnDictationStopBinding: Binding<Bool> {
        Binding(
            get: { model.pressReturnOnDictationStop },
            set: { model.pressReturnOnDictationStop = $0 }
        )
    }

    private var sideButtonPasteBinding: Binding<Bool> {
        Binding(
            get: { model.sideButtonPasteEnabled },
            set: { model.sideButtonPasteEnabled = $0 }
        )
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VibingMouseBadge(size: 52, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 10) {
                Text("Vibe Mouse")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))

                Text("Three global shortcuts: capture, paste, and hold-to-talk dictation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("How It Works")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            ShortcutLegendItem(
                                systemImage: "camera.viewfinder",
                                title: "Capture",
                                gesture: "Left + Right",
                                detail: "Take screenshot to clipboard",
                                tint: .blue
                            )
                            ShortcutLegendItem(
                                systemImage: "doc.on.clipboard",
                                title: "Paste",
                                gesture: "Side Button",
                                detail: model.sideButtonPasteEnabled ? "Paste clipboard (Cmd+V)" : "Enable in Behavior",
                                tint: model.sideButtonPasteEnabled ? .green : .gray,
                                enabled: model.sideButtonPasteEnabled
                            )
                            ShortcutLegendItem(
                                systemImage: "waveform.and.mic",
                                title: "Dictate",
                                gesture: "Hold Middle",
                                detail: "Release to stop dictation",
                                tint: .orange
                            )
                        }

                        VStack(spacing: 10) {
                            ShortcutLegendItem(
                                systemImage: "camera.viewfinder",
                                title: "Capture",
                                gesture: "Left + Right",
                                detail: "Take screenshot to clipboard",
                                tint: .blue
                            )
                            ShortcutLegendItem(
                                systemImage: "doc.on.clipboard",
                                title: "Paste",
                                gesture: "Side Button",
                                detail: model.sideButtonPasteEnabled ? "Paste clipboard (Cmd+V)" : "Enable in Behavior",
                                tint: model.sideButtonPasteEnabled ? .green : .gray,
                                enabled: model.sideButtonPasteEnabled
                            )
                            ShortcutLegendItem(
                                systemImage: "waveform.and.mic",
                                title: "Dictate",
                                gesture: "Hold Middle",
                                detail: "Release to stop dictation",
                                tint: .orange
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .cardStyle()
    }

    private var behaviorCard: some View {
        SettingsCard(
            title: "Behavior",
            subtitle: "Tune the screenshot chord trigger and enable or disable the global mouse shortcuts."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable mouse shortcuts")
                            .font(.headline)
                        Text("When enabled, the app listens globally for left+right screenshot capture and middle-button push-to-talk dictation (hold to talk, release to stop).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(14)
                .roundedSurface()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable side-button paste")
                            .font(.headline)
                        Text("Use side mouse buttons (Back/Forward) to send Cmd+V. When off, side buttons are passed through to apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: sideButtonPasteBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(14)
                .roundedSurface()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Chord timing window (screenshot)")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(model.chordWindowMs)) ms")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                    }

                    Slider(value: chordBinding, in: 20...200, step: 5)
                        .tint(.accentColor)

                    HStack {
                        Text("20 ms")
                        Spacer()
                        Text("Lower = stricter timing")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("200 ms")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
                .roundedSurface()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Press Return when releasing dictation")
                            .font(.headline)
                        Text("When you release the middle button, stop dictation and optionally send Return to the same app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: pressReturnOnDictationStopBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(14)
                .roundedSurface()
            }
        }
    }

    private var permissionsCard: some View {
        SettingsCard(
            title: "Permissions",
            subtitle: "Grant system access so the app can monitor clicks and capture the screen."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(
                    title: "Accessibility",
                    description: "Required to listen for global mouse events.",
                    isGranted: model.accessibilityTrusted,
                    requestTitle: "Request",
                    requestAction: model.requestAccessibilityPermission,
                    openTitle: "Open Settings",
                    openAction: model.openAccessibilitySettings
                )

                PermissionRow(
                    title: "Screen Recording",
                    description: "Required for interactive screenshot capture.",
                    isGranted: model.screenRecordingGranted,
                    requestTitle: "Request",
                    requestAction: model.requestScreenRecordingPermission,
                    openTitle: "Open Settings",
                    openAction: model.openScreenRecordingSettings
                )

                PermissionRow(
                    title: "Input Monitoring",
                    description: "Sometimes required on macOS for global mouse taps on certain setups.",
                    isGranted: nil,
                    requestTitle: nil,
                    requestAction: nil,
                    openTitle: "Open Settings",
                    openAction: model.openInputMonitoringSettings
                )

                HStack(spacing: 10) {
                    Button("Request All Permissions") {
                        model.requestAllPermissions()
                    }
                    .buttonStyle(PrimaryCapsuleButtonStyle())

                    Button("Reveal App in Finder") {
                        model.revealInstalledAppInFinder()
                    }
                    .buttonStyle(SecondaryCapsuleButtonStyle())

                    Button("Refresh Status") {
                        model.refreshPermissions()
                    }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                }
                .padding(.top, 4)
            }
        }
    }

    private var statusCard: some View {
        SettingsCard(
            title: "Status",
            subtitle: "Live monitor state and the latest screenshot, dictation, or paste action."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Monitor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.monitorStatusMessage)
                            .font(.headline)
                    }

                    Spacer()

                    StatusPill(
                        title: model.monitorRunning ? "Active" : "Stopped",
                        systemImage: model.monitorRunning ? "checkmark.circle.fill" : "xmark.circle",
                        tint: model.monitorRunning ? .green : .orange
                    )
                }
                .padding(14)
                .roundedSurface()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Last action")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.lastActionMessage)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .roundedSurface()

                Button("Test Screenshot Now") {
                    model.triggerManualScreenshot()
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())
            }
        }
    }

}

private struct ShortcutLegendItem: View {
    let systemImage: String
    let title: String
    let gesture: String
    let detail: String
    let tint: Color
    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(enabled ? tint : .secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(gesture)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((enabled ? tint : .secondary).opacity(0.14))
                    .clipShape(Capsule())
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((enabled ? tint : .secondary).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((enabled ? tint : .secondary).opacity(0.20), lineWidth: 1)
        )
        .opacity(enabled ? 1 : 0.78)
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool?
    let requestTitle: String?
    let requestAction: (() -> Void)?
    let openTitle: String
    let openAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if let isGranted {
                            StatusPill(
                                title: isGranted ? "Granted" : "Needs Access",
                                systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tint: isGranted ? .green : .orange
                            )
                        }
                    }

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                if let requestTitle, let requestAction {
                    Button(requestTitle, action: requestAction)
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                        .disabled(isGranted == true)
                }

                Button(openTitle, action: openAction)
                    .buttonStyle(SecondaryCapsuleButtonStyle())
            }
        }
        .padding(14)
        .roundedSurface()
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(18)
        .cardStyle()
    }
}

private struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.bold())
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.92 : 1))
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SecondaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isEnabled ? (pressed ? 0.10 : 0.06) : 0.03))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(isEnabled ? 0.08 : 0.04), lineWidth: 1)
            )
            .scaleEffect(pressed && isEnabled ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)
    }

    func roundedSurface() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}
