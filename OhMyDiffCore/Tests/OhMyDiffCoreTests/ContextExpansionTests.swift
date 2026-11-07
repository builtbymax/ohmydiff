import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ContextExpansionTests {
    private let old = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
    private let new = (1...30).map { $0 == 5 ? "line five" : $0 == 20 ? "line twenty" : "line \($0)" }.joined(separator: "\n") + "\n"

    /// Two hunks with one line of context each, as `git diff -U1` prints them for `old` → `new`.
    private var diff: FileDiff {
        get throws {
            let text = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -4,3 +4,3 @@
             line 4
            -line 5
            +line five
             line 6
            @@ -19,3 +19,3 @@
             line 19
            -line 20
            +line twenty
             line 21

            """
            return try #require(UnifiedDiffParser.parse(text).first)
        }
    }

    private var whole: FileDiff {
        get throws { try #require(try diff.expandedToWholeFile(old: Data(old.utf8), new: Data(new.utf8))) }
    }

    @Test func countsTheUnchangedLinesOfEachGap() throws {
        let diff = try diff
        #expect(diff.unchangedLinesAbove == [3, 12])
        #expect(diff.unchangedLinesBelow(in: try whole) == 9)
    }

    @Test func showsNothingMoreWithoutAnExpansion() throws {
        #expect(try diff.revealing(ContextExpansion(), from: whole) == diff)
    }

    @Test func growsAGapFromEitherSide() throws {
        var expansion = ContextExpansion()
        expansion.expand(gap: 1, .down, by: 2)
        expansion.expand(gap: 1, .up, by: 3)
        let revealed = try #require(try diff.revealing(expansion, from: whole))

        #expect(revealed.hunks.count == 2)
        #expect(revealed.hunks[0].lines.compactMap(\.newLineNumber) == Array(4...8))
        #expect(revealed.hunks[1].lines.compactMap(\.newLineNumber) == Array(16...21))
        let first = revealed.hunks[0]
        #expect((first.oldStart, first.oldCount, first.newStart, first.newCount) == (4, 5, 4, 5))
        let second = revealed.hunks[1]
        #expect((second.oldStart, second.oldCount, second.newStart, second.newCount) == (16, 6, 16, 6))
        #expect(revealed.unchangedLinesAbove == [3, 7])
        #expect(revealed.unchangedLinesBelow(in: try whole) == 9)
    }

    @Test func growsTheGapsAboveTheFirstAndBelowTheLastHunk() throws {
        var expansion = ContextExpansion()
        expansion.expand(gap: 0, .up, by: 2)
        expansion.expand(gap: 2, .down, by: 4)
        let revealed = try #require(try diff.revealing(expansion, from: whole))

        #expect(revealed.hunks[0].lines.first?.newLineNumber == 2)
        #expect(revealed.hunks[0].oldStart == 2)
        #expect(revealed.hunks[1].lines.last?.newLineNumber == 25)
        #expect(revealed.unchangedLinesAbove == [1, 12])
        #expect(revealed.unchangedLinesBelow(in: try whole) == 5)
    }

    @Test func showsAWholeGapAndStopsAtItsEnds() throws {
        var expansion = ContextExpansion()
        expansion.expand(gap: 1, .all, by: 0)
        expansion.expand(gap: 1, .down, by: 5)
        expansion.expand(gap: 2, .down, by: 100)
        let revealed = try #require(try diff.revealing(expansion, from: whole))

        let lines = revealed.hunks.flatMap(\.lines)
        #expect(lines.compactMap(\.newLineNumber) == Array(4...30))
        #expect(revealed.unchangedLinesAbove == [3, 0])
        #expect(revealed.unchangedLinesBelow(in: try whole) == 0)
    }

    @Test func matchesTheWholeFileWhenEveryGapIsShown() throws {
        var expansion = ContextExpansion()
        for gap in 0...2 { expansion.expand(gap: gap, .all, by: 0) }
        #expect(try diff.revealing(expansion, from: whole) == whole)
    }

    @Test func rejectsADiffOfAnotherFile() throws {
        let other = FileDiff(oldPath: "f.txt", newPath: "f.txt", kind: .modified)
        #expect(try diff.revealing(ContextExpansion(), from: other) == nil)
    }
}
