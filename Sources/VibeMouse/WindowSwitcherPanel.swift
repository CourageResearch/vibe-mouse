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
            height = min(max(240, screenSize.height - 64), 72 + CGFloat(rows) * 204)
        } else {
            columns = 1
            width = min(maxWidth, max(330, CGFloat(windowCount) * 244 + 36))
            height = 257
        }
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
    var scope: WindowSwitchScope = .currentApplication
    var layout = WindowSwitcherLayout(scope: .currentApplication, windowCount: 1,
                                     screenSize: CGSize(width: 1200, height: 800))
}

@MainActor
protocol WindowSwitcherPresentation {
    func show(model: WindowSwitcherViewModel)
    func hide()
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
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: WindowSwitcherView(model: model).frame(width: width, height: height))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil) }
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
                .onAppear { reader.scrollTo(model.selectedIndex, anchor: .center) }
                .onChange(of: model.selectedIndex) { index in reader.scrollTo(index, anchor: .center) }
            }
        }
        .padding(18)
        .background(SwitcherMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var windowCards: some View {
        ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
            windowCard(window, selected: index == model.selectedIndex).id(index)
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(window.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    if model.scope == .allApplications {
                        Text(window.appName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: 232)
        .background(RoundedRectangle(cornerRadius: 15).fill(.white.opacity(selected ? 0.16 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(
            selected ? Color.accentColor : .clear, lineWidth: 3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.scope == .allApplications ? "\(window.appName): \(window.title)" : window.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
