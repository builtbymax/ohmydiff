import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct WholeFileDiffTests {
    private let old = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
    private let new = (1...12).map { $0 == 3 ? "line three" : $0 == 10 ? "line ten" : "line \($0)" }.joined(separator: "\n") + "\n"

    /// Two hunks with one line of context each, as `git diff -U1` prints them for `old` → `new`.
    private var diff: FileDiff {
        get throws {
            let text = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -2,3 +2,3 @@ first
             line 2
            -line 3
            +line three
             line 4
            @@ -9,3 +9,3 @@ second
             line 9
            -line 10
            +line ten
             line 11

            """
            return try #require(UnifiedDiffParser.parse(text).first)
        }
    }

    @Test func fillsUnchangedLinesAroundAndBetweenHunks() throws {
        let expanded = try #require(try diff.expandedToWholeFile(old: Data(old.utf8), new: Data(new.utf8)))

        #expect(expanded.hunks.count == 2)
        #expect(expanded.hunks.map(\.section) == ["first", "second"])
        let lines = expanded.hunks.flatMap(\.lines)
        #expect(lines.filter { $0.kind != .deletion }.map(\.text) == new.split(separator: "\n").map(String.init))
        #expect(lines.compactMap(\.oldLineNumber) == Array(1...12))
        #expect(lines.compactMap(\.newLineNumber) == Array(1...12))
        #expect(expanded.additions == 2 && expanded.deletions == 2)

        let first = expanded.hunks[0]
        #expect((first.oldStart, first.oldCount, first.newStart, first.newCount) == (1, 4, 1, 4))
        let second = expanded.hunks[1]
        #expect((second.oldStart, second.oldCount, second.newStart, second.newCount) == (5, 8, 5, 8))
    }

    @Test func marksMissingFinalNewlineOnTheLastFilledLine() throws {
        let expanded = try #require(try diff.expandedToWholeFile(
            old: Data(old.dropLast().utf8), new: Data(new.dropLast().utf8)))
        let last = try #require(expanded.hunks.last?.lines.last)
        #expect(last.text == "line 12")
        #expect(last.noNewlineAtEnd)
    }

    @Test func readsUnchangedLinesFromTheOldSideOfDeletedFiles() throws {
        let text = """
        diff --git a/f.txt b/f.txt
        deleted file mode 100644
        --- a/f.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -a
        -b

        """
        let file = try #require(UnifiedDiffParser.parse(text).first)
        let expanded = try #require(file.expandedToWholeFile(old: Data("a\nb\n".utf8), new: nil))
        #expect(expanded == file)
    }

    @Test func rejectsContentsThatDoNotMatchTheDiff() throws {
        let edited = new.replacingOccurrences(of: "line 4", with: "line four")
        #expect(try diff.expandedToWholeFile(old: Data(old.utf8), new: Data(edited.utf8)) == nil)
        #expect(try diff.expandedToWholeFile(old: Data(old.utf8), new: Data("line 1\n".utf8)) == nil)
        #expect(try diff.expandedToWholeFile(old: nil, new: nil) == nil)
    }

    @Test func keepsCarriageReturnsAsLineContent() throws {
        let text = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -2 +2 @@
        -b\r
        +B\r

        """
        let file = try #require(UnifiedDiffParser.parse(text).first)
        let expanded = try #require(file.expandedToWholeFile(old: Data("a\r\nb\r\nc\r\n".utf8), new: Data("a\r\nB\r\nc\r\n".utf8)))
        #expect(expanded.hunks[0].lines.map(\.text) == ["a\r", "b\r", "B\r", "c\r"])
    }
}
