import SwiftUI

struct AboutView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    workflowCard
                    valueCard
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vibe Mouse")
                .font(.system(size: 30, weight: .semibold, design: .rounded))

            Text("A small macOS utility for mouse and keyboard shortcuts.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("It keeps Windows-style muscle memory available on macOS without reaching for awkward key combinations.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .cardStyle()
    }

    private var workflowCard: some View {
        AboutCard(
            title: "How It Works",
            subtitle: "Vibe Mouse listens for a small set of global shortcuts and translates them into focused desktop actions."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                WorkflowRow(step: "1", text: "Left+Right or Caps Lock starts an interactive screenshot and copies the result to the clipboard.")
                WorkflowRow(step: "2", text: "Palm Ctrl shortcuts map common Windows commands to the matching macOS Command shortcuts.")
                WorkflowRow(step: "3", text: "Ctrl+Alt+Arrow snaps the focused window or moves it between neighboring monitors.")
                WorkflowRow(step: "4", text: "Center click toggles Windows-style auto-scroll; Escape or left click stops it.")
            }
        }
    }

    private var valueCard: some View {
        AboutCard(
            title: "Why It Matters",
            subtitle: "Less finger travel, fewer mode switches."
        ) {
            Text("The app is intentionally narrow: screenshots, window movement, auto-scroll, and keyboard remaps for a Windows-style external keyboard on macOS.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WorkflowRow: View {
    let step: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(step)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(Circle())

            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AboutCard<Content: View>: View {
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
}
