import AppKit
import OhMyDiffCore
import SwiftUI

/// The Opus palette: graphite in dark mode, paper in light mode. Chrome stays neutral; colour only
/// appears where git has meaning: green added, red removed, amber waiting, violet merged, blue AI and info.
enum Theme {
    // MARK: Surfaces

    /// The window behind the sidebar and the content panel.
    static let sidebar = dynamic(light: 0xF0F0EE, dark: 0x121213)
    /// The content panel and the diff.
    static let canvas = dynamic(light: 0xF7F7F6, dark: 0x0E0E0F)
    /// Cards, the commit composer, inline AI cards.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x161617)
    /// Popovers, menus, the selected segment.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let hover = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0x0A / 255, darkAlpha: 0x0A / 255)
    static let selected = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0x10 / 255, darkAlpha: 0x12 / 255)
    /// The primary button and the project avatar.
    static let inverse = dynamic(light: 0x1A1A1B, dark: 0xEDEDEB)
    /// Floating bars over the diff, e.g. the hunk bar.
    static let glass = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E, lightAlpha: 0.9, darkAlpha: 0.9)

    // MARK: Text and lines

    static let textPrimary = dynamic(light: 0x19191A, dark: 0xECECEA)
    static let textSecondary = dynamic(light: 0x5E5E5B, dark: 0xA3A3A0)
    static let textTertiary = dynamic(light: 0x93938F, dark: 0x6B6B69)
    static let textInverse = dynamic(light: 0xF7F7F6, dark: 0x121213)
    static let lineSubtle = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0x0D / 255, darkAlpha: 0x0D / 255)
    static let line = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0x17 / 255, darkAlpha: 0x17 / 255)
    static let lineStrong = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0x26 / 255, darkAlpha: 0x26 / 255)

    // MARK: Diff

    static let addFgColor = dynamicNSColor(light: 0x2F7A47, dark: 0x8CC79B)
    static let delFgColor = dynamicNSColor(light: 0xB4483B, dark: 0xE39A8F)
    static let addBgColor = dynamicNSColor(light: 0x2E8C50, dark: 0x54AA6E, lightAlpha: 0x14 / 255, darkAlpha: 0x17 / 255)
    static let delBgColor = dynamicNSColor(light: 0xC84637, dark: 0xE0685A, lightAlpha: 0x14 / 255, darkAlpha: 0x17 / 255)
    static let addBgStrongColor = dynamicNSColor(light: 0x2E8C50, dark: 0x54AA6E, lightAlpha: 0.18, darkAlpha: 0x38 / 255)
    static let delBgStrongColor = dynamicNSColor(light: 0xC84637, dark: 0xE0685A, lightAlpha: 0.18, darkAlpha: 0x38 / 255)
    static let hunkBgColor = dynamicNSColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.02, darkAlpha: 0x08 / 255)

    /// AppKit versions of the tokens the diff table draws with.
    static let canvasColor = dynamicNSColor(light: 0xF7F7F6, dark: 0x0E0E0F)
    static let textPrimaryColor = dynamicNSColor(light: 0x19191A, dark: 0xECECEA)
    static let textSecondaryColor = dynamicNSColor(light: 0x5E5E5B, dark: 0xA3A3A0)
    static let textTertiaryColor = dynamicNSColor(light: 0x93938F, dark: 0x6B6B69)
    static let hoverColor = dynamicNSColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0x0A / 255, darkAlpha: 0x0A / 255)
    static let lineSubtleColor = dynamicNSColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0x0D / 255, darkAlpha: 0x0D / 255)
    static let diffSelectionColor = dynamicNSColor(light: 0x2F68B0, dark: 0x8FB4E3, lightAlpha: 0.12, darkAlpha: 0.16)

    static let addFg = Color(nsColor: addFgColor)
    static let delFg = Color(nsColor: delFgColor)
    static let addBg = Color(nsColor: addBgColor)
    static let delBg = Color(nsColor: delBgColor)
    static let hunkBg = Color(nsColor: hunkBgColor)

    // MARK: State

    static let okFg = dynamic(light: 0x2F7A47, dark: 0x8CC79B)
    static let warnFg = dynamic(light: 0x9A6B12, dark: 0xD8B36A)
    static let mergedFg = dynamic(light: 0x6A55C3, dark: 0xB4A5E6)
    static let infoFg = dynamic(light: 0x2F68B0, dark: 0x8FB4E3)
    static let okBg = dynamic(light: 0x2F7A47, dark: 0x8CC79B, lightAlpha: 0x14 / 255, darkAlpha: 0x1F / 255)
    static let warnBg = dynamic(light: 0x9A6B12, dark: 0xD8B36A, lightAlpha: 0x14 / 255, darkAlpha: 0x1F / 255)
    static let mergedBg = dynamic(light: 0x6A55C3, dark: 0xB4A5E6, lightAlpha: 0x14 / 255, darkAlpha: 0x1F / 255)
    static let infoBg = dynamic(light: 0x2F68B0, dark: 0x8FB4E3, lightAlpha: 0x14 / 255, darkAlpha: 0x1F / 255)

    /// The shadow below popovers and floating bars.
    static let overlayShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0.28)

    // MARK: Metrics

    static let sidebarWidth: CGFloat = 248
    /// Gap between the content panel and the window edge.
    static let inset: CGFloat = 9
    /// Room below the diff for the floating hunk bar.
    static let hunkBarInset: CGFloat = 72

    // MARK: Motion

    /// Row and button hover fills.
    static let hoverAnimation = Animation.easeOut(duration: 0.08)
    /// Menus, the project switcher and popovers: a fade and a scale from 0.98.
    static let popoverAnimation = Animation.easeOut(duration: 0.14)
    /// The ⌘K launcher: a fade and a 6 pt rise.
    static let launcherAnimation = Animation.easeOut(duration: 0.16)
    /// Scrolling the diff to a hunk.
    static let hunkJumpAnimation = Animation.easeOut(duration: 0.18)
    /// The selected pill of segmented controls and tabs, sliding under the pointer.
    static let magneticSpring = Animation.interpolatingSpring(stiffness: 500, damping: 40)

    // MARK: Helpers

    /// A file's change kind: modified amber, added green, deleted red, renamed blue.
    static func changeColor(_ kind: FileChangeKind) -> Color {
        switch kind {
        case .added, .untracked: addFg
        case .modified: warnFg
        case .deleted, .conflicted: delFg
        case .renamed, .copied: infoFg
        case .typeChanged: mergedFg
        case .unknown: textTertiary
        }
    }

    /// A stable colour for a name, e.g. for author avatars; muted so it does not compete with git colours.
    static func nameColor(_ name: String) -> Color {
        let palette: [Color] = [textSecondary, infoFg, mergedFg, okFg, warnFg]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    /// A project's Pantone colour, used for workspace monograms.
    static func projectColor(_ color: ProjectColor) -> Color {
        Color(
            red: Double((color.hex >> 16) & 0xFF) / 255,
            green: Double((color.hex >> 8) & 0xFF) / 255,
            blue: Double(color.hex & 0xFF) / 255)
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

/// The Opus type scale in SF Pro and SF Mono.
extension Font {
    /// Settings page titles.
    static let settingsTitle = Font.system(size: 22, weight: .semibold)
    /// Panel titles, e.g. a pull request's title.
    static let panelTitle = Font.system(size: 17, weight: .semibold)
    /// The project and branch names in the sidebar.
    static let projectName = Font.system(size: 13.5, weight: .medium)
    /// Rows, nav items, body text.
    static let row = Font.system(size: 13)
    /// Buttons, tabs, inputs.
    static let control = Font.system(size: 12.5)
    /// Folders, secondary details.
    static let detail = Font.system(size: 12)
    /// Section labels, counts, timestamps.
    static let sectionLabel = Font.system(size: 11.5, weight: .medium)
    static let caption11 = Font.system(size: 11.5)
    /// Chips and key caps.
    static let chip = Font.system(size: 11, weight: .medium)
    /// The change kind letter of a file.
    static let statusLetter = Font.system(size: 10.5, weight: .semibold)

    static func code(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A raised card with a hairline edge: groups, inline AI answers, settings sections.
struct Card<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            content
        }
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

/// Text segments with one pill that is drawn to the hovered segment and springs back to the selected one
/// when the pointer leaves.
struct MagneticSegments<Value: Hashable, Pill: View>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var systemImages: [Value: String] = [:]
    /// A count after a segment's title, e.g. a workspace's projects.
    var counts: [Value: String] = [:]
    /// Segments share the width, e.g. workspace tabs; otherwise each hugs its title.
    var isEqualWidth = false
    var disabled: Set<Value> = []
    let font: Font
    let horizontalPadding: CGFloat
    let height: CGFloat
    @ViewBuilder var pill: Pill

    @Namespace private var namespace
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isDisabled = disabled.contains(option.value)
                let isSelected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 5) {
                        if let image = systemImages[option.value] {
                            Image(systemName: image)
                                .font(.system(size: 12))
                                .frame(width: 14, height: 14)
                        }
                        // One weight for all, so the segments keep their width as the selection moves.
                        Text(option.title).font(font.weight(.medium))
                        if let count = counts[option.value] {
                            Text(count)
                                .font(.caption11)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, horizontalPadding)
                    .frame(maxWidth: isEqualWidth ? .infinity : nil)
                    .frame(height: height)
                    .contentShape(.rect)
                    .matchedGeometryEffect(id: option.value, in: namespace)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1)
                .onHover { if $0, !isDisabled { hovered = option.value } }
            }
        }
        .background {
            pill.matchedGeometryEffect(id: hovered ?? selection, in: namespace, isSource: false)
        }
        .onHover { if !$0 { hovered = nil } }
        .animation(Theme.magneticSpring, value: hovered)
        .animation(Theme.magneticSpring, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .focusEffectDisabled()
    }
}

/// The Opus segmented control: a soft track with the selected segment raised on it, e.g. Split | Unified.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var systemImages: [Value: String] = [:]
    var disabled: Set<Value> = []

    var body: some View {
        MagneticSegments(
            selection: $selection, options: options, systemImages: systemImages, disabled: disabled,
            font: .detail, horizontalPadding: 8, height: 24
        ) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.raised)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
        }
        .padding(2)
        .background(Theme.hover, in: .rect(cornerRadius: 9))
        .fixedSize()
    }
}

/// `+3 −1` in SF Mono and the diff colours; zero deletions are kept so the pair lines up in lists.
struct LineStatsLabel: View {
    let stats: LineStats
    var font: Font = .code(11)

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(stats.additions)").foregroundStyle(Theme.addFg)
            Text("−\(stats.deletions)").foregroundStyle(Theme.delFg)
        }
        .font(font)
        .monospacedDigit()
        .fixedSize()
    }
}

extension View {
    /// Menus, the project switcher and other popovers: raised, a strong hairline and a two-step shadow.
    func popoverSurface<S: InsettableShape>(in shape: S) -> some View {
        background(Theme.raised, in: shape)
            .overlay(shape.strokeBorder(Theme.lineStrong))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 2)
            .shadow(color: .black.opacity(0.32), radius: 12, y: 16)
    }

    /// Bars that float over the diff, e.g. the hunk bar: translucent, blurred, with a soft drop shadow.
    func floatingBar<S: InsettableShape>(in shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
            .background(Theme.glass, in: shape)
            .overlay(shape.strokeBorder(Theme.line))
            .shadow(color: Theme.overlayShadow, radius: 7.5, y: 10)
    }

    /// Popover entrance: a fade and a scale from 0.98.
    func popoverTransition(anchor: UnitPoint = .top) -> some View {
        transition(.opacity.combined(with: .scale(scale: 0.98, anchor: anchor)))
    }
}
