import Foundation

/// Release notes from the update feed, shaped for the update bar's small What's New card.
public enum ReleaseNotes {
    /// The introduction before the first heading, or all of the notes when they start with one. The full notes
    /// are one click away on the release page.
    ///
    /// Headings become bold lines and list items bullets, so an inline-only Markdown parse, which keeps line
    /// breaks but leaves block syntax alone, shows them as they read.
    public static func summary(_ markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let heading = lines.firstIndex(where: isHeading),
           lines[..<heading].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines = Array(lines[..<heading])
        }
        return lines.map(format).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHeading(_ line: String) -> Bool {
        headingText(line) != nil
    }

    /// `## Title` or `## Title ##`; a `#` without a space before it, as in `C#`, stays part of the title.
    private static func headingText(_ line: String) -> Substring? {
        line.wholeMatch(of: /\s{0,3}#{1,6}\s+(.+?)(?:\s+#+)?\s*/)?.output.1
    }

    private static func format(_ line: String) -> String {
        if let text = headingText(line) {
            return "**\(text)**"
        }
        if let match = line.wholeMatch(of: /(\s*)[-*+]\s+(.*)/) {
            return "\(match.output.1)• \(match.output.2)"
        }
        return line
    }
}
