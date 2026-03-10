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
            Text("Auto Arena")
                .font(.system(size: 30, weight: .semibold, design: .rounded))

            Text("A prediction market for machine learning experiments.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("The real bottleneck in ML research is not a shortage of ideas. It is deciding which ideas deserve compute.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .cardStyle()
    }

    private var workflowCard: some View {
        AboutCard(
            title: "How It Works",
            subtitle: "Auto Arena turns experiment selection into a market that resolves on real training results."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                WorkflowRow(step: "1", text: "Multiple AI models continuously propose training modifications.")
                WorkflowRow(step: "2", text: "Each proposal enters a market where participants estimate probability of success.")
                WorkflowRow(step: "3", text: "Proposals are ranked by market confidence, and the top one runs first.")
                WorkflowRow(step: "4", text: "A five-minute training job runs on real hardware, and the outcome resolves the market.")
            }
        }
    }

    private var valueCard: some View {
        AboutCard(
            title: "Why It Matters",
            subtitle: "Spend compute where signal is highest."
        ) {
            Text("Auto Arena replaces static decision queues with continuous price discovery, so teams can cheaply identify which ideas are worth testing before spending large amounts of compute.")
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
