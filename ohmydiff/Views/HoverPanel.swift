import AppKit
import SwiftUI

extension View {
    /// A small glass label that appears after hovering for a moment, for icon-only buttons.
    /// Also sets the accessibility label, so no system tooltip is needed.
    func glassTooltip(_ text: String, edge: Edge = .bottom) -> some View {
        accessibilityLabel(text)
            .hoverPanel(edge: edge, delay: .milliseconds(450)) {
                Text(text)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .floatingSurface(in: .capsule)
            }
    }

    /// A glass card with details about a row, shown beside it after hovering for a moment.
    func hoverCard<Card: View>(edge: Edge = .trailing, @ViewBuilder _ card: @escaping () -> Card) -> some View {
        hoverPanel(edge: edge, delay: .milliseconds(650)) {
            card()
                .frame(width: HoverCardLayout.width, alignment: .leading)
                .padding(14)
                .floatingSurface(in: .rect(cornerRadius: 16))
        }
    }

    /// Shows `content` in a floating panel next to this view while it is hovered. The panel is its own
    /// window, so it is never clipped by scroll views, cards or the content panel.
    func hoverPanel<Content: View>(edge: Edge, delay: Duration, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        modifier(HoverPanelModifier(edge: edge, delay: delay, content: content))
    }
}

extension View {
    /// The background of tooltips and hover cards. They float in their own window, where glass has
    /// nothing to refract and turns gray, so they get a solid surface with a hairline edge instead.
    func floatingSurface<S: InsettableShape>(in shape: S) -> some View {
        background(Theme.floating, in: shape)
            .overlay(shape.strokeBorder(Theme.floatingEdge))
    }
}

enum HoverCardLayout {
    static let width: CGFloat = 300
}

private struct HoverPanelModifier<PanelContent: View>: ViewModifier {
    let edge: Edge
    let delay: Duration
    let content: () -> PanelContent

    @State private var owner = UUID()
    @State private var anchor = AnchorBox()
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(AnchorView(box: anchor))
            .onHover { isHovered = $0 }
            .task(id: isHovered) {
                guard isHovered else {
                    HoverPanelController.shared.hide(owner: owner)
                    return
                }
                // Moving from one hovered row to the next shows its panel right away, like system tooltips.
                try? await Task.sleep(for: HoverPanelController.shared.isWarm ? .milliseconds(60) : delay)
                guard !Task.isCancelled, let view = anchor.view else { return }
                HoverPanelController.shared.show(AnyView(self.content()), owner: owner, anchor: view, edge: edge)
            }
            .onDisappear { HoverPanelController.shared.hide(owner: owner) }
    }
}

/// The view a panel is placed next to.
private final class AnchorBox {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let box: AnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}

/// The one floating panel shared by all tooltips and hover cards; showing one replaces the other.
@MainActor
private final class HoverPanelController {
    static let shared = HoverPanelController()

    private let panel: NSPanel
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var owner: UUID?
    private var lastHidden = Date.distantPast
    private var monitor: Any?

    /// Room around the content for its shadow.
    private static let shadowInset: CGFloat = 24

    /// A panel was shown a moment ago.
    var isWarm: Bool { owner != nil || Date().timeIntervalSince(lastHidden) < 0.4 }

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The content draws its own soft shadow; the window shadow outlines it with a hard gray edge.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.contentView = hostingView
    }

    func show(_ content: AnyView, owner: UUID, anchor: NSView, edge: Edge) {
        // Only for the key window: the panel is a child window, and ordering it in raises its parent, which
        // would pull a background window in front of e.g. the Settings window a click just opened.
        guard let window = anchor.window, window.isVisible, window.isKeyWindow, let screen = window.screen ?? NSScreen.main
        else { return }
        self.owner = owner
        panel.appearance = window.effectiveAppearance
        let inset = Self.shadowInset
        hostingView.rootView = AnyView(content
            .shadow(color: Theme.overlayShadow, radius: 12, y: 4)
            .padding(inset))
        let fitting = hostingView.fittingSize
        let size = CGSize(width: fitting.width - inset * 2, height: fitting.height - inset * 2)
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let origin = Self.origin(for: size, next: anchorFrame, edge: edge, in: screen.visibleFrame)
        panel.setFrame(NSRect(x: origin.x - inset, y: origin.y - inset, width: fitting.width, height: fitting.height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        startMonitoring()
    }

    func hide(owner: UUID) {
        guard self.owner == owner else { return }
        hide()
    }

    private func hide() {
        guard owner != nil else { return }
        owner = nil
        lastHidden = .now
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }

    /// Clicking, scrolling or typing dismisses the panel, as the hovered view may move away under it.
    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    /// Outside `anchor` on `edge`, flipped to the other side when there is no room, and kept on screen.
    private static func origin(for size: CGSize, next anchor: NSRect, edge: Edge, in screen: NSRect) -> CGPoint {
        let gap: CGFloat = 8
        var origin: CGPoint
        switch edge {
        case .top, .bottom:
            let below = anchor.minY - gap - size.height
            let above = anchor.maxY + gap
            let y = edge == .bottom ? (below >= screen.minY ? below : above) : (above + size.height <= screen.maxY ? above : below)
            origin = CGPoint(x: anchor.midX - size.width / 2, y: y)
        case .leading, .trailing:
            let after = anchor.maxX + gap
            let before = anchor.minX - gap - size.width
            let x = edge == .trailing ? (after + size.width <= screen.maxX ? after : before) : (before >= screen.minX ? before : after)
            // Top-aligned with the anchor for cards, centered for small labels.
            let y = size.height > anchor.height * 2 ? anchor.maxY - size.height : anchor.midY - size.height / 2
            origin = CGPoint(x: x, y: y)
        }
        let margin: CGFloat = 6
        origin.x = origin.x.clamped(to: (screen.minX + margin)...max(screen.minX + margin, screen.maxX - size.width - margin))
        origin.y = origin.y.clamped(to: (screen.minY + margin)...max(screen.minY + margin, screen.maxY - size.height - margin))
        return origin
    }
}

/// A row of a hover card: a dimmed label and its value.
struct HoverCardField: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }
}
