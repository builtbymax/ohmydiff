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
}
