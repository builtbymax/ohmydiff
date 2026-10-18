import AppKit
import OhMyDiffCore
import SwiftUI

/// A bundled syntax highlighting theme, with a light and a dark variant where the theme has one.
///
/// Themes only color the code: the diff keeps the app's background and addition and deletion tints, so
/// those stay readable under every theme.
enum CodeTheme: String, CaseIterable, Identifiable {
    case xcode, github, one, dracula, solarized, nord, catppuccin, tokyoNight

    static let `default` = CodeTheme.xcode

    var id: Self { self }

    /// The themes with a variant for the appearance.
    static func available(isDark: Bool) -> [CodeTheme] {
        allCases.filter { $0.palette(isDark: isDark) != nil }
    }

    /// The variant's own name, e.g. One Light or Catppuccin Mocha.
    func name(isDark: Bool) -> String {
        switch self {
        case .xcode: "Xcode"
        case .github: "GitHub"
        case .one: isDark ? "One Dark" : "One Light"
        case .dracula: "Dracula"
        case .solarized: isDark ? "Solarized Dark" : "Solarized Light"
        case .nord: "Nord"
        case .catppuccin: isDark ? "Catppuccin Mocha" : "Catppuccin Latte"
        case .tokyoNight: isDark ? "Tokyo Night" : "Tokyo Night Day"
        }
    }

    /// Token colors as sRGB hex; tokens left out stay in the plain text color. `nil` when the theme has no
    /// variant for the appearance.
    func palette(isDark: Bool) -> [SyntaxToken: UInt32]? {
        switch (self, isDark) {
        case (.xcode, false):
            [.keyword: 0x9B2393, .string: 0xC41A16, .comment: 0x5D6C79, .number: 0x1C00CF, .constant: 0x326D74, .type: 0x0B4F79,
             .function: 0x326D74, .property: 0x3900A0, .attribute: 0x815F03, .tag: 0x9B2393, .escape: 0x815F03, .heading: 0x0B4F79,
             .link: 0x0E0EFF]
        case (.xcode, true):
            [.keyword: 0xFC5FA3, .string: 0xFC6A5D, .comment: 0x7F8C98, .number: 0xD0BF69, .constant: 0x67B7A4, .type: 0x5DD8FF,
             .function: 0x67B7A4, .property: 0xA167E6, .attribute: 0xBF8555, .tag: 0xFC5FA3, .escape: 0xBF8555, .heading: 0x5DD8FF,
             .link: 0x6699FF]
        case (.github, false):
            [.keyword: 0xCF222E, .string: 0x0A3069, .comment: 0x6E7781, .number: 0x0550AE, .constant: 0x0550AE, .type: 0x953800,
             .function: 0x8250DF, .property: 0x0550AE, .attribute: 0x0550AE, .tag: 0x116329, .escape: 0x116329, .heading: 0x0550AE,
             .link: 0x0A3069]
        case (.github, true):
            [.keyword: 0xFF7B72, .string: 0xA5D6FF, .comment: 0x8B949E, .number: 0x79C0FF, .constant: 0x79C0FF, .type: 0xFFA657,
             .function: 0xD2A8FF, .property: 0x79C0FF, .attribute: 0x79C0FF, .tag: 0x7EE787, .escape: 0x7EE787, .heading: 0x79C0FF,
             .link: 0xA5D6FF]
        case (.one, false):
            [.keyword: 0xA626A4, .string: 0x50A14F, .comment: 0xA0A1A7, .number: 0x986801, .constant: 0x986801, .type: 0xC18401,
             .function: 0x4078F2, .property: 0xE45649, .attribute: 0x986801, .tag: 0xE45649, .escape: 0x0184BC, .heading: 0xE45649,
             .link: 0x4078F2]
        case (.one, true):
            [.keyword: 0xC678DD, .string: 0x98C379, .comment: 0x7F848E, .number: 0xD19A66, .constant: 0xD19A66, .type: 0xE5C07B,
             .function: 0x61AFEF, .property: 0xE06C75, .attribute: 0xD19A66, .tag: 0xE06C75, .escape: 0x56B6C2, .heading: 0xE06C75,
             .link: 0x61AFEF]
        case (.dracula, false):
            nil
        case (.dracula, true):
            [.keyword: 0xFF79C6, .string: 0xF1FA8C, .comment: 0x6272A4, .number: 0xBD93F9, .constant: 0xBD93F9, .type: 0x8BE9FD,
             .function: 0x50FA7B, .attribute: 0x50FA7B, .tag: 0xFF79C6, .escape: 0xFF79C6, .heading: 0xBD93F9, .link: 0x8BE9FD]
        case (.solarized, _):
            [.keyword: 0x859900, .string: 0x2AA198, .comment: isDark ? 0x6F8288 : 0x93A1A1, .number: 0xD33682, .constant: 0xCB4B16,
             .type: 0xB58900, .function: 0x268BD2, .property: 0x6C71C4, .attribute: 0xB58900, .tag: 0x268BD2, .escape: 0xDC322F,
             .heading: 0xCB4B16, .link: 0x6C71C4]
        case (.nord, false):
            nil
        case (.nord, true):
            [.keyword: 0x81A1C1, .string: 0xA3BE8C, .comment: 0x616E88, .number: 0xB48EAD, .constant: 0xB48EAD, .type: 0x8FBCBB,
             .function: 0x88C0D0, .attribute: 0x8FBCBB, .tag: 0x81A1C1, .escape: 0xEBCB8B, .heading: 0x88C0D0, .link: 0x81A1C1]
        case (.catppuccin, false):
            [.keyword: 0x8839EF, .string: 0x40A02B, .comment: 0x7C7F93, .number: 0xFE640B, .constant: 0xFE640B, .type: 0xDF8E1D,
             .function: 0x1E66F5, .property: 0x7287FD, .attribute: 0xDF8E1D, .tag: 0x1E66F5, .escape: 0xEA76CB, .heading: 0xD20F39,
             .link: 0x209FB5]
        case (.catppuccin, true):
            [.keyword: 0xCBA6F7, .string: 0xA6E3A1, .comment: 0x9399B2, .number: 0xFAB387, .constant: 0xFAB387, .type: 0xF9E2AF,
             .function: 0x89B4FA, .property: 0xB4BEFE, .attribute: 0xF9E2AF, .tag: 0x89B4FA, .escape: 0xF5C2E7, .heading: 0xF38BA8,
             .link: 0x74C7EC]
        case (.tokyoNight, false):
            [.keyword: 0x9854F1, .string: 0x587539, .comment: 0x848CB5, .number: 0xB15C00, .constant: 0xB15C00, .type: 0x007197,
             .function: 0x2E7DE9, .property: 0x387068, .attribute: 0x8C6C3E, .tag: 0xF52A65, .escape: 0x006A83, .heading: 0x2E7DE9,
             .link: 0x387068]
        case (.tokyoNight, true):
            [.keyword: 0xBB9AF7, .string: 0x9ECE6A, .comment: 0x737AA2, .number: 0xFF9E64, .constant: 0xFF9E64, .type: 0x2AC3DE,
             .function: 0x7AA2F7, .property: 0x73DACA, .attribute: 0xE0AF68, .tag: 0xF7768E, .escape: 0x89DDFF, .heading: 0x7AA2F7,
             .link: 0x73DACA]
        }
    }

    /// A saved pick, falling back to the default when it has no variant for the appearance.
    static func resolved(_ rawValue: String?, isDark: Bool) -> CodeTheme {
        guard let theme = rawValue.flatMap(CodeTheme.init(rawValue:)), theme.palette(isDark: isDark) != nil else { return .default }
        return theme
    }

    static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// The token colors of the themes picked for light and dark appearance, switching with the appearance.
struct SyntaxTheme: Equatable {
    let light: CodeTheme
    let dark: CodeTheme
    private let colors: [SyntaxToken: NSColor]

    init(light: CodeTheme = .default, dark: CodeTheme = .default) {
        self.light = light
        self.dark = dark
        let lightPalette = light.palette(isDark: false) ?? [:]
        let darkPalette = dark.palette(isDark: true) ?? [:]
        var colors: [SyntaxToken: NSColor] = [:]
        for token in SyntaxToken.allCases {
            let lightColor = lightPalette[token].map(CodeTheme.rgb) ?? .labelColor
            let darkColor = darkPalette[token].map(CodeTheme.rgb) ?? .labelColor
            colors[token] = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
            }
        }
        self.colors = colors
    }

    func color(for token: SyntaxToken) -> NSColor { colors[token] ?? .labelColor }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.light == rhs.light && lhs.dark == rhs.dark }
}
