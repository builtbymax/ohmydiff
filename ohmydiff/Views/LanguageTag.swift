import SwiftUI

/// A file's language from its name or extension, with GitHub's color for it.
struct FileLanguage: Equatable {
    let name: String
    let color: Color

    /// `nil` for files without an extension or a well-known name.
    init?(path: String) {
        let fileName = (path as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let known = Self.byName[fileName.lowercased()] ?? Self.byExtension[ext] {
            (name, color) = (known.name, Self.color(known.hex))
        } else if !ext.isEmpty, ext.count <= 6 {
            (name, color) = (ext.uppercased(), .secondary)
        } else {
            return nil
        }
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private static let byName: [String: (name: String, hex: UInt32)] = [
        "dockerfile": ("Dockerfile", 0x384D54),
        "makefile": ("Makefile", 0x427819),
        "gemfile": ("Ruby", 0x701516),
        "podfile": ("Ruby", 0x701516),
        ".gitignore": ("Git Ignore", 0xF44D27),
        ".gitattributes": ("Git Attributes", 0xF44D27),
        ".env": ("Env", 0xE5D559),
    ]

    private static let byExtension: [String: (name: String, hex: UInt32)] = [
        "swift": ("Swift", 0xF05138),
        "ts": ("TypeScript", 0x3178C6), "mts": ("TypeScript", 0x3178C6), "cts": ("TypeScript", 0x3178C6),
        "tsx": ("TSX", 0x3178C6),
        "js": ("JavaScript", 0xF1E05A), "mjs": ("JavaScript", 0xF1E05A), "cjs": ("JavaScript", 0xF1E05A),
        "jsx": ("JSX", 0xF1E05A),
        "py": ("Python", 0x3572A5),
        "go": ("Go", 0x00ADD8),
        "rs": ("Rust", 0xDEA584),
        "rb": ("Ruby", 0x701516),
        "java": ("Java", 0xB07219),
        "kt": ("Kotlin", 0xA97BFF), "kts": ("Kotlin", 0xA97BFF),
        "c": ("C", 0x555555), "h": ("C Header", 0x555555),
        "cpp": ("C++", 0xF34B7D), "cc": ("C++", 0xF34B7D), "hpp": ("C++", 0xF34B7D),
        "m": ("Objective-C", 0x438EFF), "mm": ("Objective-C++", 0x6866FB),
        "cs": ("C#", 0x178600),
        "php": ("PHP", 0x4F5D95),
        "dart": ("Dart", 0x00B4AB),
        "lua": ("Lua", 0x000080),
        "ex": ("Elixir", 0x6E4A7E), "exs": ("Elixir", 0x6E4A7E),
        "zig": ("Zig", 0xEC915C),
        "vue": ("Vue", 0x41B883),
        "svelte": ("Svelte", 0xFF3E00),
        "html": ("HTML", 0xE34C26), "htm": ("HTML", 0xE34C26),
        "css": ("CSS", 0x663399),
        "scss": ("SCSS", 0xC6538C), "sass": ("Sass", 0xA53B70), "less": ("Less", 0x1D365D),
        "json": ("JSON", 0x292929), "jsonc": ("JSON", 0x292929),
        "yaml": ("YAML", 0xCB171E), "yml": ("YAML", 0xCB171E),
        "toml": ("TOML", 0x9C4221),
        "xml": ("XML", 0x0060AC), "plist": ("Property List", 0x0060AC),
        "md": ("Markdown", 0x083FA1), "mdx": ("MDX", 0xFCB32C),
        "sh": ("Shell", 0x89E051), "bash": ("Shell", 0x89E051), "zsh": ("Shell", 0x89E051), "fish": ("Fish", 0x4AAE47),
        "sql": ("SQL", 0xE38C00),
        "graphql": ("GraphQL", 0xE10098), "gql": ("GraphQL", 0xE10098),
        "proto": ("Protobuf", 0x3D7BBE),
        "txt": ("Text", 0x8E8E93),
        "csv": ("CSV", 0x237346),
        "svg": ("SVG", 0xFF9900),
        "png": ("PNG", 0xA259FF), "jpg": ("JPEG", 0xA259FF), "jpeg": ("JPEG", 0xA259FF), "gif": ("GIF", 0xA259FF),
        "lock": ("Lockfile", 0x8E8E93),
    ]
}

/// A colored dot and the language name, e.g. `● TypeScript`.
struct LanguageTag: View {
    let language: FileLanguage

    init?(path: String) {
        guard let language = FileLanguage(path: path) else { return nil }
        self.language = language
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(language.color)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text(language.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .fixedSize()
    }
}
