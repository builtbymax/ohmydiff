import AppKit
import SwiftUI

/// A plain button that shows a soft fill on hover, a stronger one while pressed, and stays filled when selected.
struct HoverButtonStyle<S: Shape>: ButtonStyle {
    var shape: S
    var isSelected = false
    var selectedFill: Color = Theme.glassSelection

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, shape: shape, isSelected: isSelected, selectedFill: selectedFill)
    }
}

extension ButtonStyle where Self == HoverButtonStyle<RoundedRectangle> {
    /// Icon and text buttons on glass.
    static func hover(cornerRadius: CGFloat = 10, isSelected: Bool = false) -> Self {
        HoverButtonStyle(shape: RoundedRectangle(cornerRadius: cornerRadius), isSelected: isSelected)
    }

    /// List rows on solid surfaces.
    static func row(isSelected: Bool) -> Self {
        HoverButtonStyle(shape: RoundedRectangle(cornerRadius: 8), isSelected: isSelected, selectedFill: Theme.selectedRow)
    }
}

extension ButtonStyle where Self == HoverButtonStyle<Capsule> {
    static func hoverCapsule(isSelected: Bool = false) -> Self {
        HoverButtonStyle(shape: Capsule(), isSelected: isSelected)
    }
}

private struct HoverButtonBody<S: Shape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: S
    let isSelected: Bool
    let selectedFill: Color

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .background { shape.fill(fill) }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { isHovered = $0 && isEnabled }
            .animation(.snappy(duration: 0.16), value: isHovered)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }

    private var fill: Color {
        if configuration.isPressed { return Color.primary.opacity(0.14) }
        if isSelected { return selectedFill }
        return isHovered ? Color.primary.opacity(0.07) : .clear
    }
}

extension View {
    /// A small translucent label that appears after hovering for a moment, for icon-only buttons.
    /// Also sets the accessibility label, so no system tooltip is needed.
    func glassTooltip(_ text: String, edge: Edge = .bottom) -> some View {
        modifier(GlassTooltip(text: text, edge: edge))
    }
}

private struct GlassTooltip: ViewModifier {
    let text: String
    let edge: Edge

    @State private var isHovered = false
    @State private var isShown = false
    @State private var anchorSize = CGSize.zero
    @State private var tipSize = CGSize.zero

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(text)
            .onHover { isHovered = $0 }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { anchorSize = $0 }
            .task(id: isHovered) {
                guard isHovered else {
                    isShown = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { isShown = true }
            }
            .overlay {
                if isShown {
                    Text(text)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .glassEffect(Theme.barGlass, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
                        .offset(offset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.18), value: isShown)
    }

    /// From the anchor's center to just outside its chosen edge.
    private var offset: CGSize {
        let gap: CGFloat = 8
        switch edge {
        case .top: return CGSize(width: 0, height: -(anchorSize.height + tipSize.height) / 2 - gap)
        case .bottom: return CGSize(width: 0, height: (anchorSize.height + tipSize.height) / 2 + gap)
        case .leading: return CGSize(width: -(anchorSize.width + tipSize.width) / 2 - gap, height: 0)
        case .trailing: return CGSize(width: (anchorSize.width + tipSize.width) / 2 + gap, height: 0)
        }
    }
}

extension View {
    /// Arrow keys, Return and Escape for a palette while it is shown, even when its search field has focus.
    func paletteKeys(up: @escaping () -> Void, down: @escaping () -> Void, choose: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        modifier(PaletteKeys(handlers: .init(up: up, down: down, choose: choose, dismiss: dismiss)))
    }
}

private struct PaletteKeys: ViewModifier {
    struct Handlers {
        var up: () -> Void
        var down: () -> Void
        var choose: () -> Void
        var dismiss: () -> Void
    }

    let handlers: Handlers
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                    switch event.keyCode {
                    case 126: handlers.up()
                    case 125: handlers.down()
                    case 36, 76: handlers.choose()
                    case 53: handlers.dismiss()
                    default: return event
                    }
                    return nil
                }
            }
            .onDisappear {
                monitor.map(NSEvent.removeMonitor)
                monitor = nil
            }
    }
}
