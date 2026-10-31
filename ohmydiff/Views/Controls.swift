import AppKit
import SwiftUI

/// A plain button that shows a soft fill on hover and stays filled when selected.
struct HoverButtonStyle<S: Shape>: ButtonStyle {
    var shape: S
    var isSelected = false
    var selectedFill: Color = Theme.selected
    /// The colour of the hover and pressed fills, e.g. red for destructive rows.
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, shape: shape, isSelected: isSelected, selectedFill: selectedFill, tint: tint)
    }
}

extension ButtonStyle where Self == HoverButtonStyle<RoundedRectangle> {
    /// Icon and text buttons in bars and menus.
    static func hover(cornerRadius: CGFloat = 8, isSelected: Bool = false, tint: Color? = nil) -> Self {
        HoverButtonStyle(
            shape: RoundedRectangle(cornerRadius: cornerRadius), isSelected: isSelected,
            selectedFill: tint.map { $0.opacity(0.12) } ?? Theme.selected, tint: tint)
    }

    /// List rows.
    static func row(isSelected: Bool) -> Self {
        HoverButtonStyle(shape: RoundedRectangle(cornerRadius: 7), isSelected: isSelected, selectedFill: Theme.selected)
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
    let tint: Color?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .background { shape.fill(fill) }
            .contentShape(shape)
            .onHover { isHovered = $0 && isEnabled }
            .animation(Theme.hoverAnimation, value: isHovered)
    }

    private var fill: Color {
        if configuration.isPressed { return tint.map { $0.opacity(0.16) } ?? Theme.selected }
        if isSelected { return selectedFill }
        guard isHovered else { return .clear }
        return tint.map { $0.opacity(0.1) } ?? Theme.hover
    }
}

/// The 28 pt ghost icon button: a 16 pt symbol, `bg/hover` on hover.
struct IconButton: View {
    let title: String
    let systemImage: String
    var size: CGFloat = 28
    var isSelected = false
    var tooltipEdge: Edge = .bottom
    let action: () -> Void

    init(_ title: String, systemImage: String, size: CGFloat = 28, isSelected: Bool = false, tooltipEdge: Edge = .bottom, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.isSelected = isSelected
        self.tooltipEdge = tooltipEdge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size >= 28 ? 14 : 13))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: size, height: size)
        }
        .buttonStyle(.hover(cornerRadius: 8, isSelected: isSelected))
        .focusEffectDisabled()
        .glassTooltip(title, edge: tooltipEdge)
    }
}

/// A small pill for a status, the repository mode (git/but), an AI provider or a scope.
struct Chip: View {
    enum Tone { case neutral, ok, warn, merged, info, danger }

    let title: String
    var systemImage: String?
    var tone = Tone.neutral
    /// Neutral chips read primary instead of secondary, e.g. a branch picked as a commit target.
    var isEmphasized = false

    init(_ title: String, systemImage: String? = nil, tone: Tone = .neutral, isEmphasized: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.isEmphasized = isEmphasized
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .medium))
                    .frame(width: 12, height: 12)
            }
            Text(title)
                .font(.chip)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.leading, systemImage == nil ? 7 : 6)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(background, in: .capsule)
        .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .neutral: isEmphasized ? Theme.textPrimary : Theme.textSecondary
        case .ok: Theme.okFg
        case .warn: Theme.warnFg
        case .merged: Theme.mergedFg
        case .info: Theme.infoFg
        case .danger: Theme.delFg
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Theme.hover
        case .ok: Theme.okBg
        case .warn: Theme.warnBg
        case .merged: Theme.mergedBg
        case .info: Theme.infoBg
        case .danger: Theme.delBg
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

    /// The handlers of the latest render, read by the monitor; they capture the items as shown then.
    private final class Box {
        var handlers: Handlers?
    }

    let handlers: Handlers
    @State private var box = Box()
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        box.handlers = handlers
        return content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [box] event in
                    guard let handlers = box.handlers,
                          event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
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

/// A handle on a column's trailing edge; drag it to resize the column. A thin line shows on hover and
/// while dragging.
struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .frame(width: 9)
            .overlay {
                Rectangle()
                    .fill(startWidth != nil ? Theme.lineStrong : Theme.line)
                    .frame(width: 2)
                    .opacity(isHovered || startWidth != nil ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(.easeOut(duration: 0.15), value: startWidth != nil)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
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
            // Full height, also beside a bar inset at the top of the column.
            .ignoresSafeArea(edges: .vertical)
    }
}

/// The Opus button: 28 pt tall, 8 pt corners. `normal` is a soft fill with a hairline, `prominent` the
/// inverse fill for the one primary action, `ghost` text only, `destructive` red.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, ghost, destructive }

    var kind = Kind.normal
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind = .normal, height: CGFloat = 28) -> Self {
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
            .font(.control.weight(.medium))
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(minHeight: height)
            .background(fill, in: .rect(cornerRadius: 8))
            .overlay {
                if kind == .normal {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line)
                }
            }
            .contentShape(.rect(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 && isEnabled }
            .animation(Theme.hoverAnimation, value: isHovered)
    }

    private var foreground: Color {
        switch kind {
        case .normal: Theme.textPrimary
        case .prominent: Theme.textInverse
        case .ghost: isHovered ? Theme.textPrimary : Theme.textSecondary
        case .destructive: Theme.delFg
        }
    }

    private var fill: Color {
        let boost = (isHovered ? 1.0 : 0) + (configuration.isPressed ? 1 : 0)
        switch kind {
        case .normal: return isHovered || configuration.isPressed ? Theme.selected : Theme.hover
        case .prominent: return Theme.inverse.opacity(1 - 0.08 * boost)
        case .ghost: return boost > 0 ? Theme.hover : .clear
        case .destructive: return Theme.delBg.opacity(1 + 0.6 * boost)
        }
    }
}

/// A 14 pt icon close to the title.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12))
            configuration.title
        }
    }
}

/// A keyboard hint, e.g. `⌘K`, in menus, tooltips, buttons and the launcher.
struct KeyCap: View {
    let text: String
    /// On an inverse button the cap has no fill and takes the button's text colour at 60%.
    var onInverse = false

    init(_ text: String, onInverse: Bool = false) {
        self.text = text
        self.onInverse = onInverse
    }

    var body: some View {
        Text(text)
            .font(.chip)
            .foregroundStyle(onInverse ? Theme.textInverse : Theme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 18)
            .background(onInverse ? Color.clear : Theme.hover, in: .rect(cornerRadius: 5))
            .overlay {
                if !onInverse { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line) }
            }
            .opacity(onInverse ? 0.6 : 1)
            .fixedSize()
    }
}

/// A placeholder for an empty or failed pane in the app's own style: the icon on a small card tile,
/// a compact title and caption, and pill actions.
struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, systemImage: String, description: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.hover, in: .circle)
                .overlay(Circle().strokeBorder(Theme.line))
                .padding(.bottom, 12)
            Text(title)
                .font(.row.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            if let description {
                Text(description)
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 6)
            }
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) { actions }
                    .buttonStyle(.pill())
                    .padding(.top, 14)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
