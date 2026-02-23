import AppKit
import SwiftUI

struct MenuPanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mouse Chord Shot")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("Left + Right click for screenshot")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Enable mouse chord screenshot")
                            .font(.subheadline.weight(.semibold))
                        Text(model.isEnabled ? "Listening globally for the chord trigger." : "Chord listener is disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                }
                .padding(12)
                .panelSurface()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Status", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(model.monitorStatusMessage)
                        .font(.subheadline.weight(.semibold))

                    if !model.accessibilityTrusted || !model.screenRecordingGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Permissions are managed in Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()
                        .overlay(Color.primary.opacity(0.08))

                    HStack(alignment: .top, spacing: 8) {
                        Text("Last action")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .leading)

                        Text(model.lastActionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .panelSurface()

                HStack(spacing: 8) {
                    Button("Test Screenshot") {
                        model.triggerManualScreenshot()
                    }
                    .buttonStyle(PanelPrimaryButtonStyle())

                    Button("Settings…") {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        openWindow(id: "settings")
                    }
                    .buttonStyle(PanelSecondaryButtonStyle())
                }

                HStack(spacing: 8) {
                    if !model.accessibilityTrusted || !model.screenRecordingGranted {
                        Button("Settings → Permissions") {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            openWindow(id: "settings")
                        }
                        .buttonStyle(PanelSecondaryButtonStyle())
                    }

                    Spacer(minLength: 0)

                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(PanelSecondaryButtonStyle())
                }
            }
            .padding(14)
        }
        .frame(width: 392)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.isEnabled },
            set: { model.isEnabled = $0 }
        )
    }
}

private struct MiniPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct PanelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.92 : 1))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PanelSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.10 : 0.06) : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isEnabled ? 0.08 : 0.04), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    func panelSurface() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}
