import SwiftUI

struct VibingMouseBadge: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.95),
                            Color.orange.opacity(0.12),
                            Color.accentColor.opacity(0.16),
                        ],
                        center: .topLeading,
                        startRadius: 1,
                        endRadius: size
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.14),
                            .clear,
                            Color.orange.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VibingMouseLogo()
                .padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.08), lineWidth: 1)
                .blur(radius: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: size * 0.14, x: 0, y: size * 0.05)
        .accessibilityHidden(true)
    }
}

struct VibingMouseLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVibing = false
    @State private var startedAnimation = false

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let sway = reduceMotion ? 0.0 : (isVibing ? 4.0 : -4.0)
            let bob = reduceMotion ? 0.0 : (isVibing ? -s * 0.02 : s * 0.01)
            let noteLift = reduceMotion ? 0.0 : (isVibing ? -s * 0.025 : s * 0.01)

            ZStack {
                vibeDecorations(size: s, noteLift: noteLift)

                ZStack {
                    MouseTail(size: s)
                        .offset(x: s * 0.15, y: s * 0.12)

                    Ellipse()
                        .fill(Color(red: 0.80, green: 0.82, blue: 0.86))
                        .frame(width: s * 0.38, height: s * 0.43)
                        .offset(y: s * 0.18)

                    Ellipse()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: s * 0.24, height: s * 0.28)
                        .offset(y: s * 0.20)

                    Circle()
                        .fill(Color(red: 0.82, green: 0.84, blue: 0.88))
                        .frame(width: s * 0.41, height: s * 0.41)
                        .offset(y: s * 0.00)

                    Circle()
                        .fill(Color(red: 0.77, green: 0.79, blue: 0.84))
                        .frame(width: s * 0.145, height: s * 0.145)
                        .offset(x: -s * 0.15, y: -s * 0.18)

                    Circle()
                        .fill(Color(red: 0.77, green: 0.79, blue: 0.84))
                        .frame(width: s * 0.145, height: s * 0.145)
                        .offset(x: s * 0.15, y: -s * 0.18)

                    Circle()
                        .fill(Color(red: 0.98, green: 0.84, blue: 0.84))
                        .frame(width: s * 0.082, height: s * 0.082)
                        .offset(x: -s * 0.15, y: -s * 0.18)

                    Circle()
                        .fill(Color(red: 0.98, green: 0.84, blue: 0.84))
                        .frame(width: s * 0.082, height: s * 0.082)
                        .offset(x: s * 0.15, y: -s * 0.18)

                    Ellipse()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: s * 0.14, height: s * 0.10)
                        .offset(y: s * 0.05)

                    MouseWhiskers(size: s)
                        .offset(y: s * 0.05)

                    Circle()
                        .fill(Color(red: 0.95, green: 0.63, blue: 0.67))
                        .frame(width: s * 0.04, height: s * 0.04)
                        .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                        .offset(y: s * 0.045)

                    MouseSunglasses(size: s, tilt: sway)
                        .offset(y: -s * 0.01)

                    MouseBowTie(size: s)
                        .offset(y: s * 0.15)

                    Capsule()
                        .fill(Color(red: 0.78, green: 0.80, blue: 0.84))
                        .frame(width: s * 0.12, height: s * 0.035)
                        .rotationEffect(.degrees(-25))
                        .offset(x: -s * 0.10, y: s * 0.13)

                    Capsule()
                        .fill(Color(red: 0.78, green: 0.80, blue: 0.84))
                        .frame(width: s * 0.12, height: s * 0.035)
                        .rotationEffect(.degrees(22))
                        .offset(x: s * 0.10, y: s * 0.15)

                    MouseCocktail(size: s)
                        .offset(x: -s * 0.14, y: s * 0.17)

                    Ellipse()
                        .fill(Color(red: 0.96, green: 0.79, blue: 0.80))
                        .frame(width: s * 0.055, height: s * 0.025)
                        .rotationEffect(.degrees(-20))
                        .offset(x: -s * 0.07, y: s * 0.37)

                    Ellipse()
                        .fill(Color(red: 0.96, green: 0.79, blue: 0.80))
                        .frame(width: s * 0.055, height: s * 0.025)
                        .rotationEffect(.degrees(20))
                        .offset(x: s * 0.07, y: s * 0.37)
                }
                .offset(y: bob)
                .rotationEffect(.degrees(sway), anchor: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            guard !startedAnimation else { return }
            startedAnimation = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isVibing = true
            }
        }
    }

    @ViewBuilder
    private func vibeDecorations(size s: CGFloat, noteLift: CGFloat) -> some View {
        let noteSpin = reduceMotion ? 0.0 : (isVibing ? 18.0 : -8.0)
        let sparkleSpin = reduceMotion ? 0.0 : (isVibing ? -12.0 : 10.0)

        Image(systemName: "music.note")
            .font(.system(size: s * 0.13, weight: .black))
            .foregroundStyle(Color.accentColor.opacity(0.85))
            .rotationEffect(.degrees(noteSpin))
            .offset(x: -s * 0.22, y: -s * 0.20 + noteLift)

        Image(systemName: "music.note")
            .font(.system(size: s * 0.095, weight: .bold))
            .foregroundStyle(Color.orange.opacity(0.8))
            .rotationEffect(.degrees(-noteSpin * 0.7))
            .offset(x: s * 0.23, y: -s * 0.26 - noteLift * 0.4)

        Image(systemName: "sparkles")
            .font(.system(size: s * 0.10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.75))
            .rotationEffect(.degrees(sparkleSpin))
            .offset(x: s * 0.24, y: -s * 0.06)
    }
}

private struct MouseSunglasses: View {
    let size: CGFloat
    let tilt: Double

    var body: some View {
        HStack(spacing: size * 0.012) {
            RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .frame(width: size * 0.13, height: size * 0.065)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                )

            Capsule()
                .fill(Color.black.opacity(0.82))
                .frame(width: size * 0.035, height: size * 0.012)

            RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .frame(width: size * 0.13, height: size * 0.065)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                )
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.black.opacity(0.82))
                .frame(width: size * 0.045, height: size * 0.012)
                .offset(x: -size * 0.13, y: -size * 0.005)
                .rotationEffect(.degrees(-20))
        }
        .overlay(alignment: .trailing) {
            Capsule()
                .fill(Color.black.opacity(0.82))
                .frame(width: size * 0.045, height: size * 0.012)
                .offset(x: size * 0.13, y: -size * 0.005)
                .rotationEffect(.degrees(20))
        }
        .rotationEffect(.degrees(tilt * 0.4 - 6))
    }
}

private struct MouseBowTie: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.004) {
            RoundedRectangle(cornerRadius: size * 0.022, style: .continuous)
                .fill(Color(red: 0.98, green: 0.77, blue: 0.82))
                .frame(width: size * 0.12, height: size * 0.07)
                .rotationEffect(.degrees(-24))

            RoundedRectangle(cornerRadius: size * 0.022, style: .continuous)
                .fill(Color(red: 0.98, green: 0.77, blue: 0.82))
                .frame(width: size * 0.12, height: size * 0.07)
                .rotationEffect(.degrees(24))
        }
        .overlay {
            Circle()
                .fill(Color(red: 0.96, green: 0.67, blue: 0.76))
                .frame(width: size * 0.045, height: size * 0.045)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.6))
        }
        .shadow(color: Color.red.opacity(0.08), radius: size * 0.01, x: 0, y: 0)
    }
}

private struct MouseWhiskers: View {
    let size: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.39, y: size * 0.49))
            path.addLine(to: CGPoint(x: size * 0.27, y: size * 0.46))
            path.move(to: CGPoint(x: size * 0.39, y: size * 0.51))
            path.addLine(to: CGPoint(x: size * 0.26, y: size * 0.52))
            path.move(to: CGPoint(x: size * 0.39, y: size * 0.53))
            path.addLine(to: CGPoint(x: size * 0.28, y: size * 0.57))

            path.move(to: CGPoint(x: size * 0.61, y: size * 0.49))
            path.addLine(to: CGPoint(x: size * 0.73, y: size * 0.46))
            path.move(to: CGPoint(x: size * 0.61, y: size * 0.51))
            path.addLine(to: CGPoint(x: size * 0.74, y: size * 0.52))
            path.move(to: CGPoint(x: size * 0.61, y: size * 0.53))
            path.addLine(to: CGPoint(x: size * 0.72, y: size * 0.57))
        }
        .stroke(Color.white.opacity(0.80), lineWidth: max(0.8, size * 0.012))
        .shadow(color: .black.opacity(0.08), radius: 0.5, x: 0, y: 0)
    }
}

private struct MouseTail: View {
    let size: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.52, y: size * 0.58))
            path.addCurve(
                to: CGPoint(x: size * 0.80, y: size * 0.42),
                control1: CGPoint(x: size * 0.66, y: size * 0.68),
                control2: CGPoint(x: size * 0.78, y: size * 0.60)
            )
            path.addCurve(
                to: CGPoint(x: size * 0.90, y: size * 0.56),
                control1: CGPoint(x: size * 0.86, y: size * 0.33),
                control2: CGPoint(x: size * 0.96, y: size * 0.46)
            )
        }
        .stroke(Color(red: 0.93, green: 0.74, blue: 0.78), style: StrokeStyle(lineWidth: max(1.1, size * 0.018), lineCap: .round, lineJoin: .round))
        .opacity(0.8)
    }
}

private struct MouseCocktail: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Path { path in
                let w = size * 0.12
                let h = size * 0.14
                let origin = CGPoint(x: -w / 2, y: -h / 2)

                path.move(to: CGPoint(x: origin.x + w * 0.16, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x + w * 0.84, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x + w * 0.68, y: origin.y + h))
                path.addLine(to: CGPoint(x: origin.x + w * 0.32, y: origin.y + h))
                path.closeSubpath()
            }
            .fill(Color.white.opacity(0.20))

            Path { path in
                let w = size * 0.10
                let h = size * 0.09
                let origin = CGPoint(x: -w / 2, y: -h / 2 + size * 0.01)

                path.move(to: CGPoint(x: origin.x + w * 0.16, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x + w * 0.84, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x + w * 0.66, y: origin.y + h))
                path.addLine(to: CGPoint(x: origin.x + w * 0.34, y: origin.y + h))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.99, green: 0.82, blue: 0.45),
                        Color(red: 0.93, green: 0.53, blue: 0.18),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Path { path in
                let w = size * 0.12
                let h = size * 0.14
                let origin = CGPoint(x: -w / 2, y: -h / 2)

                path.move(to: CGPoint(x: origin.x + w * 0.16, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x + w * 0.84, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x + w * 0.68, y: origin.y + h))
                path.addLine(to: CGPoint(x: origin.x + w * 0.32, y: origin.y + h))
                path.closeSubpath()
            }
            .stroke(Color.white.opacity(0.75), lineWidth: 0.8)

            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: max(0.9, size * 0.014), height: size * 0.07)
                .offset(y: size * 0.10)

            Capsule()
                .fill(Color.white.opacity(0.78))
                .frame(width: size * 0.07, height: max(0.9, size * 0.014))
                .offset(y: size * 0.14)

            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: size * 0.016, height: size * 0.016)
                .offset(x: -size * 0.018, y: -size * 0.01)

            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: size * 0.014, height: size * 0.014)
                .offset(x: size * 0.016, y: size * 0.005)
        }
        .rotationEffect(.degrees(-6))
    }
}
