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
    /// A selected segment or rail button on glass.
    static let glassSelection = dynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.09)
    /// Glass over code is tinted with the panel color so its labels stay readable.
    static let barGlass = Glass.regular.tint(dynamic(light: 0xFFFFFF, dark: 0x1E1E20).opacity(0.72))
    /// The logo's accent.
    static let logo = Color(red: 0.85, green: 0.95, blue: 0.23)

    static let addition = dynamic(light: 0x2F9E44, dark: 0x6BD08A)
    static let deletion = dynamic(light: 0xD9480F, dark: 0xFF7A66)

    static let railWidth: CGFloat = 60
    /// Gap between the window edge, the rail and the panel.
    static let inset: CGFloat = 8
    /// The window controls sit above the rail.
    static let titleBarHeight: CGFloat = 36
    /// Room below the diff for the floating hunk bar.
    static let hunkBarInset: CGFloat = 72

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
        })
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
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                }
                .buttonStyle(.hoverCapsule(isSelected: isSelected))
                .focusEffectDisabled()
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
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
