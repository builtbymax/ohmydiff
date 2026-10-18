import AppKit
import OhMyDiffCore
import SwiftUI

/// Colors and metrics of the window chrome: a translucent window, a glass rail and toolbar floating
/// over a solid content panel with card-style groups.
enum Theme {
    /// The content panel; the diff itself uses the text background.
    static let panel = Color(nsColor: .textBackgroundColor)
    /// The file list column inside the panel.
    static let column = dynamic(light: 0xF7F7F8, dark: 0x1C1C1E)
    /// A group or hunk card around its white rows.
    static let card = dynamic(light: 0xEFEFF1, dark: 0x2A2A2D)
    static let cardRow = dynamic(light: 0xFFFFFF, dark: 0x1E1E20)
    static let selectedRow = dynamic(light: 0xE8E8EB, dark: 0x3A3A3F)
    static let hairline = Color.primary.opacity(0.07)
    /// Shell commands in Settings.
    static let terminal = dynamic(light: 0xF4F4F6, dark: 0x161618)
    /// A selected segment or rail button on glass.
    static let glassSelection = dynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.09)
    /// Glass over code is tinted with the panel color so its labels stay readable; nearly white in light
    /// mode, where a thinner tint lets the content below turn it gray.
    static let barGlass = Glass.regular.tint(dynamic(light: 0xFFFFFF, dark: 0x1E1E20, lightAlpha: 0.9, darkAlpha: 0.72))
    /// Tooltips and hover cards.
    static let floating = dynamic(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let floatingEdge = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.1)
    /// The shadow below floating glass: soft and faint in light mode.
    static let overlayShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.08, darkAlpha: 0.3)
    /// The lime of the logo, darkened enough to read on white.
    static let logoText = dynamic(light: 0x5E7D00, dark: 0xD9F23B)
    /// The logo's accent.
    static let logo = Color(red: 0.85, green: 0.95, blue: 0.23)

    /// Soft, pastel diff colors: text for counts and markers, tints for line and word backgrounds.
    static let additionColor = dynamicNSColor(light: 0x3A9A5E, dark: 0x9FE0B5)
    static let deletionColor = dynamicNSColor(light: 0xC8615F, dark: 0xF5A8A4)
    static let additionLineTint = dynamicNSColor(light: 0x8FD9A8, dark: 0x86D6A4, lightAlpha: 0.22, darkAlpha: 0.13)
    static let deletionLineTint = dynamicNSColor(light: 0xF4A5A5, dark: 0xF09292, lightAlpha: 0.24, darkAlpha: 0.13)
    static let additionWordTint = dynamicNSColor(light: 0x7BCF98, dark: 0x86D6A4, lightAlpha: 0.45, darkAlpha: 0.28)
    static let deletionWordTint = dynamicNSColor(light: 0xF09090, dark: 0xF09292, lightAlpha: 0.45, darkAlpha: 0.28)

    static let addition = Color(nsColor: additionColor)
    static let deletion = Color(nsColor: deletionColor)

    static let railWidth: CGFloat = 60
    /// Gap between the window edge, the rail and the panel.
    static let inset: CGFloat = 8
    /// The window controls sit above the rail.
    static let titleBarHeight: CGFloat = 36
    /// Room below the diff for the floating hunk bar.
    static let hunkBarInset: CGFloat = 72

    /// A stable color for a name, e.g. for project monograms and author avatars.
    static func nameColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNSColor(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

/// Makes the window translucent, so the desktop shows through around the content panel.
struct WindowTranslucency: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TranslucentView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private final class TranslucentView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}

/// A rounded card with a header strip and a solid body, used for change groups and hunks.
struct Card<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            content
                .background(Theme.cardRow, in: .rect(cornerRadius: 11))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        }
        .padding(3)
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }
}

/// A capsule segmented control on glass, e.g. Changes / History.
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        MagneticSegments(selection: $selection, options: options, font: .callout, horizontalPadding: 13, height: 30,
                         hoverFill: Color.primary.opacity(0.06)) {
            Capsule().fill(Theme.glassSelection)
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Text segments whose selection pill and hover highlight glide from one segment to the next.
struct MagneticSegments<Value: Hashable, Pill: View>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var disabled: Set<Value> = []
    let font: Font
    let horizontalPadding: CGFloat
    let height: CGFloat
    let hoverFill: Color
    @ViewBuilder var pill: Pill

    @Namespace private var namespace
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                let isDisabled = disabled.contains(option.value)
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(font.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, horizontalPadding)
                        .frame(height: height)
                        .background {
                            if isSelected { pill.matchedGeometryEffect(id: "selection", in: namespace) }
                        }
                        .background {
                            if hovered == option.value {
                                Capsule().fill(hoverFill).matchedGeometryEffect(id: "hover", in: namespace)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1)
                // Only entering sets it, and leaving the whole control clears it, so the highlight
                // moves between neighbors instead of fading out and in.
                .onHover { if $0, !isDisabled { hovered = option.value } }
            }
        }
        .onHover { if !$0 { hovered = nil } }
        .animation(.snappy(duration: 0.28), value: selection)
        .animation(.snappy(duration: 0.22), value: hovered)
        .focusEffectDisabled()
    }
}

/// `+3 −1` in the theme's diff colors; zero counts are left out.
struct LineStatsLabel: View {
    let stats: LineStats
    var font: Font = .caption.monospacedDigit()

    var body: some View {
        HStack(spacing: 5) {
            if stats.additions > 0 || stats.deletions == 0 {
                Text("+\(stats.additions)").foregroundStyle(Theme.addition)
            }
            if stats.deletions > 0 {
                Text("−\(stats.deletions)").foregroundStyle(Theme.deletion)
            }
        }
        .font(font.monospaced())
    }
}
