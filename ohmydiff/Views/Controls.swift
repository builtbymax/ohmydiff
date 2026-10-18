import AppKit
import SwiftUI

/// A plain button that shows a soft fill on hover, a stronger one while pressed, and stays filled when selected.
struct HoverButtonStyle<S: Shape>: ButtonStyle {
    var shape: S
    var isSelected = false
    var selectedFill: Color = Theme.glassSelection
    /// The color of the hover and pressed fills, e.g. red for destructive rows.
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, shape: shape, isSelected: isSelected, selectedFill: selectedFill, tint: tint)
    }
}

extension ButtonStyle where Self == HoverButtonStyle<RoundedRectangle> {
    /// Icon and text buttons on glass.
    static func hover(cornerRadius: CGFloat = 10, isSelected: Bool = false, tint: Color = .primary) -> Self {
        HoverButtonStyle(
            shape: RoundedRectangle(cornerRadius: cornerRadius), isSelected: isSelected,
            selectedFill: tint == .primary ? Theme.glassSelection : tint.opacity(0.12), tint: tint)
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
    let tint: Color

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
        if configuration.isPressed { return tint.opacity(0.14) }
        if isSelected { return selectedFill }
        return isHovered ? tint.opacity(tint == .primary ? 0.07 : 0.1) : .clear
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

/// An invisible handle on a column's trailing edge; drag it to resize the column.
struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 9)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = (start + value.translation.width).clamped(to: range)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .offset(x: 4.5)
    }
}

/// A capsule button in the app's own style: a soft fill that deepens on hover, the lime logo color
/// for the main action, red for destructive ones.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, destructive }

    var kind = Kind.normal
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind = .normal, height: CGFloat = 30) -> Self {
        PillButtonStyle(kind: kind, height: height)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let height: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.callout.weight(.medium))
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background(fill, in: .capsule)
            .overlay {
                // A flat lime fill needs no edge; the others get a hairline so they hold their shape on glass.
                if kind != .prominent { Capsule().strokeBorder(Theme.hairline) }
            }
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { isHovered = $0 && isEnabled }
            .animation(.snappy(duration: 0.15), value: isHovered)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .normal: .primary
        case .prominent: .black
        case .destructive: Theme.deletion
        }
    }

    private var fill: Color {
        let boost = (isHovered ? 1.0 : 0) + (configuration.isPressed ? 1 : 0)
        switch kind {
        case .normal: return Color.primary.opacity(0.06 + 0.05 * boost)
        case .prominent: return Theme.logo.mix(with: .black, by: 0.06 * boost)
        case .destructive: return Theme.deletion.opacity(0.12 + 0.08 * boost)
        }
    }
}

/// Icon and title close together, with the icon a touch smaller.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// A keyboard shortcut as a small key cap, e.g. `⌘K`.
struct KeyCap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
            .fixedSize()
    }
}
