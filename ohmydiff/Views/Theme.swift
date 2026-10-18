import AppKit
import OhMyDiffCore
import SwiftUI

/// Colors and metrics of the window chrome: a tinted backdrop, a glass rail and toolbar floating
/// over a solid content panel with card-style groups.
enum Theme {
    /// Window background behind the rail and the content panel.
    static let backdrop = dynamic(light: 0xECECEE, dark: 0x161618)
    /// The content panel; the diff itself uses the text background.
    static let panel = Color(nsColor: .textBackgroundColor)
    /// The change list column inside the panel.
    static let column = dynamic(light: 0xF7F7F8, dark: 0x1C1C1E)
    /// A group or hunk card around its white rows.
    static let card = dynamic(light: 0xEFEFF1, dark: 0x2A2A2D)
    static let cardRow = dynamic(light: 0xFFFFFF, dark: 0x1E1E20)
    static let selectedRow = dynamic(light: 0xF0F0F2, dark: 0x343438)
    static let hairline = Color.primary.opacity(0.07)
    /// A selected segment or rail button on glass.
    static let glassSelection = dynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.09)
    /// The logo's accent.
    static let logo = Color(red: 0.85, green: 0.95, blue: 0.23)

    static let addition = dynamic(light: 0x2F9E44, dark: 0x6BD08A)
    static let deletion = dynamic(light: 0xD9480F, dark: 0xFF7A66)

    /// The rail sits under the window controls, which macOS places about 9 pt from the corner.
    static let railWidth: CGFloat = 66
    static let inset: CGFloat = 5
    /// Room above content for the floating toolbar.
    static let toolbarInset: CGFloat = 64
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

/// Soft color washes behind the glass rail, so the glass has something to refract.
struct Backdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.backdrop
            blob(Theme.logo, width: 380, height: 420, x: -140, y: -60, opacity: 0.75)
            blob(Color(red: 0.5, green: 0.72, blue: 1), width: 360, height: 420, x: -120, y: 420, opacity: 0.55)
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Ellipse()
            .fill(color.opacity(colorScheme == .dark ? opacity * 0.45 : opacity))
            .frame(width: width, height: height)
            .blur(radius: 110)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: x, y: y)
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
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.glassSelection)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
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
