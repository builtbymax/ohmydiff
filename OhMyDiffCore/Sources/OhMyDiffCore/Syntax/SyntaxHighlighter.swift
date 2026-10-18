import Foundation
import Synchronization
import SwiftTreeSitter

/// A highlighted character range of one line; offsets count `Character`s, like `WordDiff` ranges.
public struct SyntaxSpan: Sendable, Hashable {
    public var range: Range<Int>
    public var token: SyntaxToken

    public init(range: Range<Int>, token: SyntaxToken) {
        self.range = range
        self.token = token
    }
}

/// Highlights of the lines a diff shows, keyed by 1-based line number in the old and new file.
public struct SyntaxHighlights: Sendable, Hashable {
    public var old: [Int: [SyntaxSpan]]
    public var new: [Int: [SyntaxSpan]]

    public init(old: [Int: [SyntaxSpan]] = [:], new: [Int: [SyntaxSpan]] = [:]) {
        self.old = old
        self.new = new
    }

    /// Spans for a diff line, taken from the file it belongs to; context lines prefer the new file.
    public func spans(for line: DiffLine) -> [SyntaxSpan]? {
        switch line.kind {
        case .deletion: line.oldLineNumber.flatMap { old[$0] }
        case .addition: line.newLineNumber.flatMap { new[$0] }
        case .context: line.newLineNumber.flatMap { new[$0] } ?? line.oldLineNumber.flatMap { old[$0] }
        }
    }
}

/// Syntax highlighting with tree-sitter.
///
/// Whole files are parsed, so constructs spanning lines (block comments, multi-line strings) are
/// colored correctly even where the diff only shows part of them; the colors are then cut into
/// per-line spans for the lines the diff shows.
public enum SyntaxHighlighter {
    /// Files longer than this (in UTF-16 units) are not highlighted.
    public static let maximumLength = 4 << 20

    /// Highlights the old and new contents of `diff`'s file. Lines whose text differs from the
    /// diff's (e.g. other line endings) are left out, so colors never land on the wrong characters.
    public static func highlights(for diff: FileDiff, language: SyntaxLanguage, old: String?, new: String?) -> SyntaxHighlights {
        var oldLines: [Int: String] = [:]
        var newLines: [Int: String] = [:]
        for hunk in diff.hunks {
            for line in hunk.lines {
                if line.kind != .addition, let number = line.oldLineNumber { oldLines[number] = line.text }
                if line.kind != .deletion, let number = line.newLineNumber { newLines[number] = line.text }
            }
        }
        return SyntaxHighlights(
            old: old.map { highlight($0, language: language, lines: oldLines) } ?? [:],
            new: new.map { highlight($0, language: language, lines: newLines) } ?? [:])
    }

    /// Highlights `text` and returns the spans of the requested lines (1-based number → expected text);
    /// `nil` requests every line.
    public static func highlight(_ text: String, language: SyntaxLanguage, lines wanted: [Int: String]? = nil) -> [Int: [SyntaxSpan]] {
        let utf16 = Array(text.utf16)
        guard utf16.count <= maximumLength, let query = query(for: language) else { return [:] }

        let parser = Parser()
        guard (try? parser.setLanguage(language.tsLanguage)) != nil,
              let tree = parser.parse(text)
        else { return [:] }

        let tokens = paint(query.execute(in: tree).resolve(with: Predicate.Context(string: text)), length: utf16.count)
        return spans(text: text, utf16: utf16, tokens: tokens, lines: wanted)
    }

    /// One token per UTF-16 unit. Outer captures are painted first so nested ones win; for the same
    /// node, the later pattern wins. Captures without a color are skipped, so a catch-all such as
    /// `(identifier) @variable` does not erase a more specific color.
    static func paint<Matches: Sequence<QueryMatch>>(_ matches: Matches, length: Int) -> [UInt8] {
        var paints: [Paint] = []
        for match in matches {
            for capture in match.captures {
                guard let name = capture.name, let token = SyntaxToken(captureName: name) else { continue }
                paints.append(Paint(range: capture.range, pattern: capture.patternIndex, token: token))
            }
        }
        paints.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.pattern < $1.pattern
        }

        var tokens = [UInt8](repeating: 0, count: length)
        for paint in paints {
            let lower = max(paint.range.location, 0)
            let upper = min(paint.range.location + paint.range.length, length)
            guard lower < upper else { continue }
            for index in lower..<upper { tokens[index] = paint.token.rawValue }
        }
        return tokens
    }

    private struct Paint {
        var range: NSRange
        var pattern: Int
        var token: SyntaxToken
    }

    /// Cuts the painted file into per-line spans with `Character` offsets.
    private static func spans(text: String, utf16: [UInt16], tokens: [UInt8], lines wanted: [Int: String]?) -> [Int: [SyntaxSpan]] {
        var result: [Int: [SyntaxSpan]] = [:]
        var lineNumber = 1
        var lineStart = 0
        var index = text.startIndex

        while index <= text.endIndex {
            // Split on `\n` only, like the diff parser, so `\r` stays part of the line.
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[index..<lineEnd]
            let lineLength = line.utf16.count

            let isWanted = wanted.map { $0[lineNumber].map { line == $0 } ?? false } ?? true
            if isWanted {
                let spans = lineSpans(line, tokens: tokens, offset: lineStart)
                if !spans.isEmpty { result[lineNumber] = spans }
            }

            guard lineEnd < text.endIndex else { break }
            lineStart += lineLength + 1
            lineNumber += 1
            index = text.index(after: lineEnd)
        }
        return result
    }

    private static func lineSpans(_ line: Substring, tokens: [UInt8], offset: Int) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var utf16Offset = offset
        var characterOffset = 0
        for character in line {
            let raw = utf16Offset < tokens.count ? tokens[utf16Offset] : 0
            if let token = SyntaxToken(rawValue: raw) {
                if let last = spans.last, last.token == token, last.range.upperBound == characterOffset {
                    spans[spans.count - 1].range = last.range.lowerBound..<characterOffset + 1
                } else {
                    spans.append(SyntaxSpan(range: characterOffset..<characterOffset + 1, token: token))
                }
            }
            utf16Offset += character.utf16.count
            characterOffset += 1
        }
        return spans
    }

    // MARK: Queries

    private static let queries = Mutex<[SyntaxLanguage: Query?]>([:])

    /// The compiled highlight query of `language`, loaded once from the grammar's resource bundle.
    static func query(for language: SyntaxLanguage) -> Query? {
        if let cached = queries.withLock({ $0[language] }) { return cached }
        let query = loadQuery(for: language)
        queries.withLock { $0[language] = query }
        return query
    }

    private static func loadQuery(for language: SyntaxLanguage) -> Query? {
        var source = Data()
        for (bundle, file) in language.querySources {
            guard let url = queriesDirectory(bundle)?.appending(path: file), let data = try? Data(contentsOf: url) else {
                return nil
            }
            source.append(data)
            source.append(0x0A)
        }
        return try? Query(language: Language(language.tsLanguage), data: source)
    }

    private final class BundleMarker {}

    /// Package resource bundles sit in the app's resources, or next to the test bundle in `swift test`.
    private static func queriesDirectory(_ bundleName: String) -> URL? {
        let codeBundle = Bundle(for: BundleMarker.self)
        let containers = [codeBundle.resourceURL, codeBundle.bundleURL.deletingLastPathComponent(), Bundle.main.resourceURL]
        for container in containers.compactMap(\.self) {
            let bundle = container.appending(path: "\(bundleName).bundle", directoryHint: .isDirectory)
            for path in ["Contents/Resources/queries", "queries"] {
                let directory = bundle.appending(path: path, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: directory.path) { return directory }
            }
        }
        return nil
    }
}
