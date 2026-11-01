import Foundation
import OhMyDiffCore

enum DiffHighlighting {
    /// Highlights both sides of a file in the background; `contents` reads one side.
    @concurrent
    static func highlights(
        for diff: FileDiff, language: SyntaxLanguage, contents: @escaping @Sendable (Repository.FileSide) async -> Data?
    ) async -> SyntaxHighlights {
        let lines = diff.hunks.flatMap(\.lines)
        @Sendable func text(_ side: Repository.FileSide) async -> String? {
            await contents(side).flatMap { String(data: $0, encoding: .utf8) }
        }
        // Skip reading a side the diff does not show, e.g. the old side of an added file.
        async let old = lines.contains { $0.kind != .addition } ? text(.old) : nil
        async let new = lines.contains { $0.kind != .deletion } ? text(.new) : nil
        let (oldText, newText) = await (old, new)
        return SyntaxHighlighter.highlights(for: diff, language: language, old: oldText, new: newText)
    }

    /// `diff` expanded to the whole file, with syntax colors for every line; `nil` when the contents do not
    /// match the diff.
    @concurrent
    static func wholeFile(for diff: FileDiff, old: Data?, new: Data?) async -> (diff: FileDiff, highlights: SyntaxHighlights?)? {
        guard let expanded = diff.expandedToWholeFile(old: old, new: new) else { return nil }
        let highlights = SyntaxLanguage(path: diff.path).map { language in
            SyntaxHighlighter.highlights(
                for: expanded, language: language,
                old: old.flatMap { String(data: $0, encoding: .utf8) }, new: new.flatMap { String(data: $0, encoding: .utf8) })
        }
        return (expanded, highlights)
    }
}


/// Diffs expanded to the whole file, so Full file shows at once for a file seen lately.
@MainActor
enum WholeFileCache {
    private static var entries: [FileDiff: (diff: FileDiff, highlights: SyntaxHighlights?)] = [:]
    private static var order: [FileDiff] = []

    static func expansion(of diff: FileDiff) -> (diff: FileDiff, highlights: SyntaxHighlights?)? { entries[diff] }

    static func store(_ expansion: (diff: FileDiff, highlights: SyntaxHighlights?), for diff: FileDiff) {
        entries[diff] = expansion
        order.removeAll { $0 == diff }
        order.append(diff)
        while order.count > 20 { entries[order.removeFirst()] = nil }
    }
}
