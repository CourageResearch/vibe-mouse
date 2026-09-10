import AppKit
import SwiftUI

struct WindowSwitcherLayout {
    let width: CGFloat
    let height: CGFloat
    let columns: Int

    init(scope: WindowSwitchScope, windowCount: Int, screenSize: CGSize) {
        let maxWidth = max(280, screenSize.width - 48)
        if scope == .allApplications {
            columns = max(1, min(4, windowCount, Int((maxWidth - 36) / 244)))
            width = min(maxWidth, max(330, CGFloat(columns) * 244 + 36))
            let rows = min(3, max(1, (windowCount + columns - 1) / columns))
            height = min(max(240, screenSize.height - 64), 72 + CGFloat(rows) * 196)
        } else {
            columns = 1
            width = min(maxWidth, max(330, CGFloat(windowCount) * 244 + 36))
            height = 257
        }
    }
}

struct WindowSwitcherHitRegions: Equatable {
    var viewport: CGRect = .zero
    var cards: [UUID: CGRect] = [:]

    func target(at point: CGPoint) -> WindowSwitcherPointerTarget {
        guard viewport.contains(point), let card = cards.first(where: { $0.value.contains(point) }) else {
            return .background
        }
        return .window(card.key)
    }
}

private struct WindowSwitcherHitRegionsKey: PreferenceKey {
    static let defaultValue = WindowSwitcherHitRegions()

    static func reduce(value: inout WindowSwitcherHitRegions, nextValue: () -> WindowSwitcherHitRegions) {
        let next = nextValue()
        if !next.viewport.isEmpty { value.viewport = next.viewport }
        value.cards.merge(next.cards, uniquingKeysWith: { _, new in new })
    }
}

@MainActor
final class WindowSwitcherViewModel: ObservableObject {
    @Published var windows: [SwitchableWindow] = []
    @Published var selectedIndex = 0
    @Published var previews: [UUID: NSImage] = [:]
    var appName = "App"
    var appIcon: NSImage?
    var appIcons: [pid_t: NSImage] = [:]
    var onChooseWindow: ((UUID) -> Void)?
    var hitRegions = WindowSwitcherHitRegions()
    var scope: WindowSwitchScope = .currentApplication
    var layout = WindowSwitcherLayout(scope: .currentApplication, windowCount: 1,
                                     screenSize: CGSize(width: 1200, height: 800))
}

@MainActor
protocol WindowSwitcherPresentation {
    func show(model: WindowSwitcherViewModel)
    func hide()
    func pointerTarget(at point: CGPoint) -> WindowSwitcherPointerTarget?
}

private final class WindowSwitcherHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class WindowSwitcherPanel: WindowSwitcherPresentation {
    private var panel: NSPanel?

    func show(model: WindowSwitcherViewModel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = model.layout.width
        let height = model.layout.height
        let frame = NSRect(x: available.midX - width / 2, y: available.midY - height / 2,
                           width: width, height: height)
        let panel = self.panel ?? NSPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.contentView = WindowSwitcherHostingView(rootView: AnyView(
            WindowSwitcherView(model: model).frame(width: width, height: height)))
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model
    }

    func hide() { panel?.orderOut(nil) }

    private weak var model: WindowSwitcherViewModel?

    func pointerTarget(at point: CGPoint) -> WindowSwitcherPointerTarget? {
        guard let panel, panel.isVisible, let model else { return nil }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return Self.pointerTarget(at: point, panelFrame: panel.frame, screenTop: screenTop, regions: model.hitRegions)
    }

    static func pointerTarget(at point: CGPoint, panelFrame: CGRect, screenTop: CGFloat,
                              regions: WindowSwitcherHitRegions) -> WindowSwitcherPointerTarget? {
        // CG events and SwiftUI use top-left coordinates; AppKit window frames
        // use bottom-left coordinates relative to the primary display.
        let origin = CGPoint(x: panelFrame.minX, y: screenTop - panelFrame.maxY)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard CGRect(origin: .zero, size: panelFrame.size).contains(local) else { return nil }
        return regions.target(at: local)
    }
}

private struct SwitcherMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WindowSwitcherView: View {
    @ObservedObject var model: WindowSwitcherViewModel
    @State private var hoveredWindow: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let icon = model.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else if model.scope == .allApplications {
                    Image(systemName: "rectangle.grid.2x2").font(.system(size: 17)).frame(width: 22, height: 22)
                }
                Text(model.appName).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(model.selectedIndex + 1) of \(model.windows.count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            ScrollViewReader { reader in
                Group {
                    if model.scope == .allApplications {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(232), spacing: 12),
                                                     count: model.layout.columns), spacing: 12) {
                                windowCards
                            }.padding(3)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) { windowCards }.padding(3)
                        }
                    }
                }
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: WindowSwitcherHitRegionsKey.self,
                        value: WindowSwitcherHitRegions(viewport: geometry.frame(in: .named("windowSwitcher"))))
                })
                .onAppear { reader.scrollTo(model.selectedIndex, anchor: .center) }
                .onChange(of: model.selectedIndex) { index in reader.scrollTo(index, anchor: .center) }
            }
        }
        .padding(18)
        .background(SwitcherMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .coordinateSpace(name: "windowSwitcher")
        .onPreferenceChange(WindowSwitcherHitRegionsKey.self) { model.hitRegions = $0 }
    }

    private var windowCards: some View {
        ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
            Button { model.onChooseWindow?(window.id) } label: {
                windowCard(window, selected: index == model.selectedIndex)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredWindow = window.id }
                else if hoveredWindow == window.id { hoveredWindow = nil }
            }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: WindowSwitcherHitRegionsKey.self,
                    value: WindowSwitcherHitRegions(cards: [window.id: geometry.frame(in: .named("windowSwitcher"))]))
            })
            .id(index)
        }
    }

    private func windowCard(_ window: SwitchableWindow, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.22))
                if let preview = model.previews[window.id] {
                    Image(nsImage: preview).resizable().scaledToFit().padding(3)
                } else {
                    VStack(spacing: 6) {
                        if let icon = model.appIcons[window.processIdentifier] ?? model.appIcon {
                            Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                        }
                        Text(window.minimized ? "Minimized" : "Window preview")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 7) {
                if model.scope == .allApplications, let icon = model.appIcons[window.processIdentifier] {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Text(window.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: 232)
        .background(RoundedRectangle(cornerRadius: 15)
            .fill(.white.opacity(selected ? 0.16 : hoveredWindow == window.id ? 0.10 : 0.04)))
        .contentShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(
            selected ? Color.accentColor : .clear, lineWidth: 3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.scope == .allApplications ? "\(window.appName): \(window.title)" : window.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
