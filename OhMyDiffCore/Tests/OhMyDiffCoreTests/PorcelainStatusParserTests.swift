import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct PorcelainStatusParserTests {
    private let hash = String(repeating: "a", count: 40)

    @Test func parsesAllRecordKinds() {
        let records = [
            "# branch.oid \(hash)",
            "1 M. N... 100644 100644 100644 \(hash) \(hash) staged.txt",
            "1 .M N... 100644 100644 100644 \(hash) \(hash) dir/with space.txt",
            "1 MM N... 100644 100644 100644 \(hash) \(hash) both.txt",
            "2 R. N... 100644 100644 100644 \(hash) \(hash) R87 new.txt",
            "old.txt",
            "2 C. N... 100644 100644 100644 \(hash) \(hash) C100 copy.txt",
            "orig.txt",
            "u UU N... 100644 100644 100644 100644 \(hash) \(hash) \(hash) conflict.txt",
            "? untracked file.txt",
            "! ignored.log",
        ]
        let data = Data((records.joined(separator: "\0") + "\0").utf8)
        let entries = PorcelainStatusParser.parse(data)

        #expect(entries.map(\.path) == [
            "staged.txt", "dir/with space.txt", "both.txt", "new.txt", "copy.txt",
            "conflict.txt", "untracked file.txt", "ignored.log",
        ])
        #expect(entries[0].isStaged && !entries[0].isUnstaged)
        #expect(!entries[1].isStaged && entries[1].isUnstaged)
        #expect(entries[2].isStaged && entries[2].isUnstaged)
        #expect(entries[3].kind == .renamed && entries[3].originalPath == "old.txt" && entries[3].similarity == 87)
        #expect(entries[4].kind == .copied && entries[4].originalPath == "orig.txt")
        #expect(entries[5].kind == .unmerged && !entries[5].isStaged)
        #expect(entries[6].kind == .untracked)
        #expect(entries[7].kind == .ignored)
    }

    @Test func groupsForPlainGit() {
        let entries = [
            StatusEntry(kind: .ordinary, path: "both.txt", indexStatus: "M", worktreeStatus: "M"),
            StatusEntry(kind: .renamed, path: "new.txt", originalPath: "old.txt", indexStatus: "R", similarity: 100),
            StatusEntry(kind: .ordinary, path: "gone.txt", worktreeStatus: "D"),
            StatusEntry(kind: .untracked, path: "u.txt", indexStatus: "?", worktreeStatus: "?"),
            StatusEntry(kind: .unmerged, path: "c.txt", indexStatus: "U", worktreeStatus: "U"),
        ]
        let groups = Repository.gitChangeGroups(entries)
        #expect(groups.map(\.kind) == [.conflicted, .staged, .unstaged, .untracked])

        let staged = groups[1].files
        #expect(staged.map(\.path) == ["both.txt", "new.txt"])
        #expect(staged[1].kind == .renamed && staged[1].previousPath == "old.txt")
        #expect(groups[2].files.map(\.path) == ["both.txt", "gone.txt"])
        #expect(groups[2].files[1].kind == .deleted)
        #expect(groups[3].files[0].source == .untracked)
    }

    @Test func emptyStatus() {
        #expect(PorcelainStatusParser.parse(Data()).isEmpty)
        #expect(Repository.gitChangeGroups([]).isEmpty)
    }
}
