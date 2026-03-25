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

    private var forwardButtonDictationBinding: Binding<Bool> {
        Binding(
            get: { model.forwardButtonDictationEnabled },
            set: { model.forwardButtonDictationEnabled = $0 }
        )
    }

    private var screenshotPasteStartsDictationBinding: Binding<Bool> {
        Binding(
            get: { model.screenshotPasteStartsDictationEnabled },
            set: { model.screenshotPasteStartsDictationEnabled = $0 }
        )
    }

    private var dictationBackendBinding: Binding<AppModel.DictationBackend> {
        Binding(
            get: { model.dictationBackend },
            set: { model.dictationBackend = $0 }
        )
    }

    private var whisperModelPresetBinding: Binding<WhisperDictationService.ModelPreset> {
        Binding(
            get: { model.whisperModelPreset },
            set: { model.whisperModelPreset = $0 }
        )
    }

    private var whisperExecutablePathBinding: Binding<String> {
        Binding(
            get: { model.whisperExecutablePath },
            set: { model.whisperExecutablePath = $0 }
        )
    }

    private var whisperModelDirectoryPathBinding: Binding<String> {
        Binding(
            get: { model.whisperModelDirectoryPath },
            set: { model.whisperModelDirectoryPath = $0 }
        )
    }

    private var whisperMicrophoneSelectionBinding: Binding<String> {
        Binding(
            get: { model.whisperMicrophoneSelectionID },
            set: { model.whisperMicrophoneSelectionID = $0 }
        )
    }

    private var whisperDebugRecordingsBinding: Binding<Bool> {
        Binding(
            get: { model.whisperDebugRecordingsEnabled },
            set: { model.whisperDebugRecordingsEnabled = $0 }
        )
    }

    private var capsLockScreenshotBinding: Binding<Bool> {
        Binding(
            get: { model.capsLockScreenshotEnabled },
            set: { model.capsLockScreenshotEnabled = $0 }
        )
    }

    private var reverseScrollingBinding: Binding<Bool> {
        Binding(
            get: { model.reverseScrollingEnabled },
            set: { model.reverseScrollingEnabled = $0 }
        )
    }

    private var mouseScrollSpeedBinding: Binding<Double> {
        Binding(
            get: { model.mouseScrollSpeed },
            set: { model.mouseScrollSpeed = $0 }
        )
    }

    private var scrollEventLoggingBinding: Binding<Bool> {
        Binding(
            get: { model.scrollEventLoggingEnabled },
            set: { model.scrollEventLoggingEnabled = $0 }
        )
    }

    private var captureLegendGesture: String {
        return model.capsLockScreenshotEnabled
            ? "Caps Lock or Left + Right"
            : "Left + Right"
    }

    private var captureLegendDetail: String {
        "Take screenshot, then click to paste"
    }

    private var pasteLegendGesture: String {
        "Next Click"
    }

    private var pasteLegendDetail: String {
        model.screenshotPasteStartsDictationActive
            ? "After a screenshot, click the target field to paste it and begin dictation. The following left click stops dictation."
            : "After a screenshot, click the target field to paste it."
    }

    private var dictationLegendGesture: String {
        "Forward Button"
    }

    private var dictationLegendDetail: String {
        guard model.forwardButtonDictationEnabled else { return "Enable in Behavior" }
        if model.isAppleDictationBackendSelected {
            return "Toggle macOS Dictation (\(model.dictationShortcutLabel)); sends Return when Dictation stops."
        }
        return "Toggle whisper.cpp recording. Press once to start, press again to transcribe and paste."
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VibingMouseBadge(size: 52, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Vibe Mouse")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))

                    Text("Version \(settingsVersionTag)")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(Capsule())
                }

                Text(
                    model.screenshotPasteStartsDictationActive
                        ? "Global shortcuts: \(keyboardCaptureSummary) capture, click the target field to paste and start dictation, then click once more to stop."
                        : "Global shortcuts: \(keyboardCaptureSummary) capture, click the target field to paste, and use Forward for Dictation when you want it."
                )
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
                                gesture: captureLegendGesture,
                                detail: captureLegendDetail,
                                tint: .blue
                            )
                            ShortcutLegendItem(
                                systemImage: "doc.on.clipboard",
                                title: "Paste",
                                gesture: pasteLegendGesture,
                                detail: pasteLegendDetail,
                                tint: .green
                            )
                            ShortcutLegendItem(
                                systemImage: "mic.fill",
                                title: "Dictate",
                                gesture: dictationLegendGesture,
                                detail: dictationLegendDetail,
                                tint: model.forwardButtonDictationEnabled ? .orange : .gray,
                                enabled: model.forwardButtonDictationEnabled
                            )
                        }

                        VStack(spacing: 10) {
                            ShortcutLegendItem(
                                systemImage: "camera.viewfinder",
                                title: "Capture",
                                gesture: captureLegendGesture,
                                detail: captureLegendDetail,
                                tint: .blue
                            )
                            ShortcutLegendItem(
                                systemImage: "doc.on.clipboard",
                                title: "Paste",
                                gesture: pasteLegendGesture,
                                detail: pasteLegendDetail,
                                tint: .green
                            )
                            ShortcutLegendItem(
                                systemImage: "mic.fill",
                                title: "Dictate",
                                gesture: dictationLegendGesture,
                                detail: dictationLegendDetail,
                                tint: model.forwardButtonDictationEnabled ? .orange : .gray,
                                enabled: model.forwardButtonDictationEnabled
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
                        Text(
                            model.screenshotPasteStartsDictationActive
                                ? "When enabled, the app listens globally for screenshot capture (\(screenshotListeningLegend)), click-to-paste after capture, and optional dictation auto-start with stop-on-next-click."
                                : "When enabled, the app listens globally for screenshot capture (\(screenshotListeningLegend)), click-to-paste after capture, and optional Forward-button Dictation."
                        )
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
                        Text("Use Caps Lock for screenshot")
                            .font(.headline)
                        Text(
                            model.capsLockScreenshotEnabled
                                ? "Overrides Caps Lock while mouse shortcuts are enabled. Press Caps Lock to start screenshot capture to clipboard."
                                : "Caps Lock keeps normal behavior. Screenshot capture stays on left+right."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: capsLockScreenshotBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(14)
                .roundedSurface()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reverse scroll direction (Windows style)")
                            .font(.headline)
                        Text(
                            model.reverseScrollingEnabled
                                ? "Scroll direction is inverted globally while mouse shortcuts are enabled."
                                : "Use macOS natural scrolling direction."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: reverseScrollingBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(14)
                .roundedSurface()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Mouse scroll speed")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(model.mouseScrollSpeed.rounded()))")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                    }

                    Slider(value: mouseScrollSpeedBinding, in: 4...36, step: 1)
                        .tint(.accentColor)

                    HStack {
                        Text("Slower")
                        Spacer()
                        Text("Applies to mouse wheel only")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Faster")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
                .roundedSurface()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Forward-button Dictation")
                            .font(.headline)
                        Text(
                            model.isAppleDictationBackendSelected
                                ? "Use the Forward side mouse button to send \(model.dictationShortcutLabel). Set the same shortcut in macOS Keyboard > Dictation. When Dictation stops, Return is sent automatically."
                                : "Use the Forward side mouse button to start/stop whisper.cpp recording. On stop, audio is transcribed and pasted."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: forwardButtonDictationBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(14)
                .roundedSurface()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start dictation after screenshot paste")
                            .font(.headline)
                        Text(
                            model.forwardButtonDictationEnabled
                                ? (
                                    model.screenshotPasteStartsDictationEnabled
                                        ? "After a screenshot, the next click pastes it and starts dictation. The following left click stops dictation."
                                        : "Screenshots stay quiet. Turn this on only when you want the paste click to start dictation too."
                                )
                                : "Screenshots stay quiet. Turn on Forward-button Dictation first if you want screenshot paste to optionally start dictation."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: screenshotPasteStartsDictationBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(14)
                .roundedSurface()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Dictation Engine")
                        .font(.headline)

                    Picker("Engine", selection: dictationBackendBinding) {
                        ForEach(AppModel.DictationBackend.allCases) { backend in
                            Text(backend.displayName)
                                .tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.isAppleDictationBackendSelected {
                        Text("Apple mode uses macOS Dictation via \(model.dictationShortcutLabel).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.isWhisperBackendSelected {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Whisper model")
                                    .font(.subheadline.weight(.semibold))
                                Picker("Whisper model", selection: whisperModelPresetBinding) {
                                    ForEach(WhisperDictationService.ModelPreset.allCases) { preset in
                                        Text(preset.displayName).tag(preset)
                                    }
                                }
                                .pickerStyle(.menu)
                                Text("Expected model file: \(model.whisperModelFileName)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Whisper microphone")
                                    .font(.subheadline.weight(.semibold))
                                Picker("Whisper microphone", selection: whisperMicrophoneSelectionBinding) {
                                    ForEach(model.whisperMicrophoneOptions) { option in
                                        Text(option.displayName).tag(option.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                Text("Selected: \(model.whisperSelectedMicrophoneSummary)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("Built-in mic is recommended when your output is on Bluetooth so the start cue does not get swallowed by route switching.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("whisper executable path (optional)")
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    "Auto-detect whisper-cli from Homebrew paths",
                                    text: whisperExecutablePathBinding
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model directory")
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    WhisperDictationService.defaultModelDirectoryPath,
                                    text: whisperModelDirectoryPathBinding
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))

                                HStack(spacing: 10) {
                                    Button("Open Model Directory") {
                                        model.openWhisperModelDirectoryInFinder()
                                    }
                                    .buttonStyle(SecondaryCapsuleButtonStyle())
                                }
                            }

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Keep debug recordings")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Saves each captured whisper recording as a WAV file for debugging.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: whisperDebugRecordingsBinding)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.whisperDebugRecordingsPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                Button("Open Debug Recordings") {
                                    model.openWhisperDebugRecordingsInFinder()
                                }
                                .buttonStyle(SecondaryCapsuleButtonStyle())
                            }
                        }
                    }
                }
                .padding(14)
                .roundedSurface()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Log scroll events (debug)")
                                .font(.headline)
                            Text("Writes per-event scroll fields to a local file so you can share diagnostics.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: scrollEventLoggingBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Text(model.scrollEventLogPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button("Open Log in Finder") {
                            model.openScrollEventLogInFinder()
                        }
                        .buttonStyle(SecondaryCapsuleButtonStyle())

                        Button("Clear Log") {
                            model.clearScrollEventLog()
                        }
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                    }
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
            }
        }
    }

    private var keyboardCaptureSummary: String {
        model.capsLockScreenshotEnabled ? "Caps Lock + Left/Right" : "Left/Right"
    }

    private var settingsVersionTag: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let shortVersion, let buildVersion {
            return "\(shortVersion) (\(buildVersion))"
        }
        if let shortVersion {
            return shortVersion
        }
        if let buildVersion {
            return "build \(buildVersion)"
        }
        return "dev"
    }

    private var screenshotListeningLegend: String {
        model.capsLockScreenshotEnabled ? "Caps Lock or left+right" : "left+right"
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
            subtitle: "Live monitor state and the latest screenshot, paste, or Dictation action."
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
