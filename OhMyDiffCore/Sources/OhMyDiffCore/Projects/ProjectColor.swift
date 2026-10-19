import Foundation

/// A project's color, from Pantone's Colors of the Year. New projects get one at random, preferring
/// colors no other project uses yet.
public enum ProjectColor: String, Sendable, CaseIterable, Codable {
    case classicBlue
    case livingCoral
    case ultraViolet
    case greenery
    case vivaMagenta
    case veryPeri
    case illuminating
    case peachFuzz
    case mochaMousse
    case emerald
    case tangerineTango
    case turquoise
    case honeysuckle
    case mimosa
    case blueIris
    case chiliPepper
    case marsala
    case serenity

    /// The Pantone color as `0xRRGGBB`.
    public var hex: UInt32 {
        switch self {
        case .classicBlue: 0x0F4C81
        case .livingCoral: 0xFF6F61
        case .ultraViolet: 0x5F4B8B
        case .greenery: 0x88B04B
        case .vivaMagenta: 0xBB2649
        case .veryPeri: 0x6667AB
        case .illuminating: 0xF5DF4D
        case .peachFuzz: 0xFFBE98
        case .mochaMousse: 0xA47864
        case .emerald: 0x009473
        case .tangerineTango: 0xDD4124
        case .turquoise: 0x45B5AA
        case .honeysuckle: 0xD94F70
        case .mimosa: 0xF0C05A
        case .blueIris: 0x5A5B9F
        case .chiliPepper: 0x9B1B30
        case .marsala: 0x955251
        case .serenity: 0x92A8D1
        }
    }

    /// The Pantone name, e.g. `Classic Blue`.
    public var name: String {
        rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name.append(" ") }
            name.append(character)
        }.capitalized
    }

    /// Whether dark text reads better on this color than white text.
    public var isLight: Bool {
        let channels = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { Double($0) / 255 }
        let luminance = 0.299 * channels[0] + 0.587 * channels[1] + 0.114 * channels[2]
        return luminance > 0.6
    }

    /// A random color that none of `taken` uses, or one of the least used once every color is taken.
    public static func pick(avoiding taken: [ProjectColor], using generator: inout some RandomNumberGenerator) -> ProjectColor {
        let counts = Dictionary(taken.map { ($0, 1) }, uniquingKeysWith: +)
        let fewest = allCases.map { counts[$0, default: 0] }.min() ?? 0
        let candidates = allCases.filter { counts[$0, default: 0] == fewest }
        return candidates.randomElement(using: &generator)!
    }

    public static func pick(avoiding taken: [ProjectColor]) -> ProjectColor {
        var generator = SystemRandomNumberGenerator()
        return pick(avoiding: taken, using: &generator)
    }
}

extension [Project] {
    /// Gives every project without a color one that the others do not use yet; `true` when any changed.
    @discardableResult
    public mutating func assignMissingColors() -> Bool {
        var changed = false
        for index in indices where self[index].color == nil {
            self[index].color = ProjectColor.pick(avoiding: compactMap(\.color))
            changed = true
        }
        return changed
    }
}
