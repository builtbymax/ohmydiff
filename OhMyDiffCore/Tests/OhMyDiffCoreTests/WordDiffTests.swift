import Testing
@testable import OhMyDiffCore

@Suite struct WordDiffTests {
    private func hunk(_ lines: [(DiffLine.Kind, String)]) -> Hunk {
        Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 0, lines: lines.map {
            DiffLine(kind: $0.0, text: $0.1, oldLineNumber: nil, newLineNumber: nil)
        })
    }

    private func substrings(_ text: String, _ ranges: [Range<Int>]?) -> [String] {
        let characters = Array(text)
        return (ranges ?? []).map { String(characters[$0]) }
    }

    @Test func tokenizesWordsSpacesAndPunctuation() {
        #expect(WordDiff.tokenize("let x = foo(bar_1)").map(\.text) == ["let", " ", "x", " ", "=", " ", "foo", "(", "bar_1", ")"])
        #expect(WordDiff.tokenize("").isEmpty)
    }

    @Test func highlightsChangedWordsOfPairedLines() {
        let old = "let value = compute(a, b)"
        let new = "let result = compute(a, c)"
        let highlights = WordDiff.highlights(for: hunk([(.context, "x"), (.deletion, old), (.addition, new), (.context, "y")]))

        #expect(Set(highlights.keys) == [1, 2])
        #expect(substrings(old, highlights[1]) == ["value", "b"])
        #expect(substrings(new, highlights[2]) == ["result", "c"])
    }

    @Test func pairsRunsLineByLine() {
        let highlights = WordDiff.highlights(for: hunk([
            (.deletion, "one two"), (.deletion, "three four"),
            (.addition, "one 2"), (.addition, "three 4"), (.addition, "extra line"),
        ]))
        #expect(Set(highlights.keys) == [0, 1, 2, 3])
        #expect(substrings("one 2", highlights[2]) == ["2"])
    }

    @Test func skipsUnrelatedAndIdenticalLines() {
        #expect(WordDiff.highlights(for: hunk([(.deletion, "import Foundation"), (.addition, "return nil // nope")])).isEmpty)
        #expect(WordDiff.highlights(for: hunk([(.deletion, "same"), (.addition, "same")])).isEmpty)
        #expect(WordDiff.highlights(for: hunk([(.addition, "only added")])).isEmpty)
    }
}

@Suite struct DiffLayoutTests {
    private let diff = FileDiff(oldPath: "a", newPath: "a", kind: .modified, hunks: [
        Hunk(oldStart: 1, oldCount: 4, newStart: 1, newCount: 4, lines: [
            DiffLine(kind: .context, text: "c", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(kind: .deletion, text: "d1", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(kind: .deletion, text: "d2", oldLineNumber: 3, newLineNumber: nil),
            DiffLine(kind: .addition, text: "a1", oldLineNumber: nil, newLineNumber: 2, noNewlineAtEnd: true),
        ]),
    ])

    @Test func unifiedRowsIncludeHeadersAndNewlineMarkers() {
        #expect(DiffLayout.unified(diff) == [
            .hunkHeader(hunk: 0), .line(hunk: 0, line: 0), .line(hunk: 0, line: 1), .line(hunk: 0, line: 2),
            .line(hunk: 0, line: 3), .noNewlineAtEnd(hunk: 0, line: 3),
        ])
    }

    @Test func splitRowsPairDeletionsWithAdditions() {
        #expect(DiffLayout.split(diff) == [
            .hunkHeader(hunk: 0), .pair(hunk: 0, old: 0, new: 0), .pair(hunk: 0, old: 1, new: 3), .pair(hunk: 0, old: 2, new: nil),
        ])
    }
}
