import SwiftUI

/// A file's Catppuccin icon from its name or extension, e.g. React's for `.tsx`; a plain page for the rest.
/// The icons and what picks them come from scripts/catppuccin-icons.py.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 14

    var body: some View {
        Image("FileIcons/\(Self.name(for: path))")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func name(for path: String) -> String {
        let fileName = (path as NSString).lastPathComponent.lowercased()
        if let icon = byName[fileName] { return icon }
        // The longest extension first, so `app.test.ts` gets the test icon before the TypeScript one.
        var rest = Substring(fileName)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if let icon = byExtension[String(rest)] { return icon }
        }
        return "_file"
    }
}
