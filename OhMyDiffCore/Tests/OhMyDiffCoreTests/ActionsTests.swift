import Foundation
import Testing
@testable import OhMyDiffCore

private let twentyLines = (1...20).map { "line \($0)\n" }.joined()

private func edited(_ replacements: [Int: String]) -> String {
    (1...20).map { "\(replacements[$0] ?? "line \($0)")\n" }.joined()
}

extension TestRepo {
    func file(_ path: String, in group: ChangeGroup.Kind, of repository: Repository) async throws -> ChangedFile {
        let groups = try await repository.changeGroups()
        return try #require(groups.first { $0.kind == group }?.files.first { $0.path == path })
    }

    func paths(in group: ChangeGroup.Kind, of repository: Repository) async throws -> [String] {
        try await repository.changeGroups().first { $0.kind == group }?.files.map(\.path) ?? []
    }
}

@Suite struct GitActionTests {
    @Test func stagesAndUnstagesFiles() async throws {
        let repo = try await TestRepo()
        let repository = try await repo.open()
        // Before the first commit, unstaging has no HEAD to restore from.
        try repo.write("new file.txt", "new\n")
        try await repository.stage([ChangeTarget(file: repo.file("new file.txt", in: .untracked, of: repository))])
        #expect(try await repo.paths(in: .staged, of: repository) == ["new file.txt"])
        try await repository.unstage([ChangeTarget(file: repo.file("new file.txt", in: .staged, of: repository))])
        #expect(try await repo.paths(in: .untracked, of: repository) == ["new file.txt"])

        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "init")
        try FileManager.default.removeItem(at: repo.root.appending(path: "new file.txt"))
        try await repository.stage([ChangeTarget(file: repo.file("new file.txt", in: .unstaged, of: repository))])
        let staged = try await repo.file("new file.txt", in: .staged, of: repository)
        #expect(staged.kind == .deleted)
        try await repository.unstage([ChangeTarget(file: staged)])
        #expect(try await repo.paths(in: .staged, of: repository).isEmpty)
    }

    @Test func stagesUnstagesAndDiscardsHunks() async throws {
        let repo = try await TestRepo()
        try repo.write("my notes.txt", twentyLines)
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "init")
        try repo.write("my notes.txt", edited([1: "first", 20: "last"]))
        let repository = try await repo.open()

        let unstaged = try await repo.file("my notes.txt", in: .unstaged, of: repository)
        let diff = try #require(try await repository.diff(for: unstaged))
        #expect(diff.hunks.count == 2)
        try await repository.stage([ChangeTarget(file: unstaged, hunk: diff.hunks[1])])

        let stagedFile = try await repo.file("my notes.txt", in: .staged, of: repository)
        let stagedDiff = try #require(try await repository.diff(for: stagedFile))
        #expect(stagedDiff.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text) == ["last"])
        let remaining = try #require(try await repository.diff(for: unstaged))
        #expect(remaining.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text) == ["first"])

        try await repository.unstage([ChangeTarget(file: stagedFile, hunk: stagedDiff.hunks[0])])
        #expect(try await repo.paths(in: .staged, of: repository).isEmpty)

        // Discard the first hunk only.
        let both = try #require(try await repository.diff(for: unstaged))
        try await repository.discard([ChangeTarget(file: unstaged, hunk: both.hunks[0])])
        #expect(try String(contentsOf: repo.root.appending(path: "my notes.txt"), encoding: .utf8) == edited([20: "last"]))
    }

    @Test func refusesStaleHunks() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", twentyLines)
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "init")
        try repo.write("a.txt", edited([10: "ten"]))
        let repository = try await repo.open()
        let file = try await repo.file("a.txt", in: .unstaged, of: repository)
        let diff = try #require(try await repository.diff(for: file))

        // The file changes again after the diff was shown.
        try repo.write("a.txt", edited([9: "nine", 10: "TEN"]))
        await #expect(throws: ProcessError.self) {
            try await repository.discard([ChangeTarget(file: file, hunk: diff.hunks[0])])
        }
        #expect(try String(contentsOf: repo.root.appending(path: "a.txt"), encoding: .utf8) == edited([9: "nine", 10: "TEN"]))
    }

    @Test func discardsFiles() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "a\n")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "init")
        try repo.write("a.txt", "changed\n")
        try repo.write("scratch.txt", "x\n")
        let repository = try await repo.open()

        var trashed: [String] = []
        try await repository.discard([
            ChangeTarget(file: repo.file("a.txt", in: .unstaged, of: repository)),
            ChangeTarget(file: repo.file("scratch.txt", in: .untracked, of: repository)),
        ]) { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        #expect(trashed == ["scratch.txt"])
        #expect(try String(contentsOf: repo.root.appending(path: "a.txt"), encoding: .utf8) == "a\n")
        #expect(try await repository.changeGroups().isEmpty)
    }

    @Test func offersOnlySafeActions() throws {
        let repository = Repository(root: URL(fileURLWithPath: "/r"), kind: .git, toolchain: Toolchain(git: URL(fileURLWithPath: "/g"), but: nil, environment: [:]))
        let hunk = Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)
        let unstaged = ChangedFile(path: "a", kind: .modified, source: .unstaged)
        let untracked = ChangedFile(path: "b", kind: .untracked, source: .untracked)
        let staged = ChangedFile(path: "c", kind: .added, source: .staged)

        #expect(ChangeAction.allCases.filter { repository.supports($0, on: ChangeTarget(file: unstaged)) } == [.stage, .commit, .discard])
        #expect(ChangeAction.allCases.filter { repository.supports($0, on: ChangeTarget(file: unstaged, hunk: hunk)) } == [.stage, .commit, .discard])
        #expect(ChangeAction.allCases.filter { repository.supports($0, on: ChangeTarget(file: untracked)) } == [.stage, .commit, .discard])
        #expect(ChangeAction.allCases.filter { repository.supports($0, on: ChangeTarget(file: staged)) } == [.unstage, .commit])
        // Hunks of added files would need a full new-file patch.
        #expect(!repository.supports(.unstage, on: ChangeTarget(file: staged, hunk: hunk)))
        #expect(!repository.supports(.commit, on: ChangeTarget(file: staged, hunk: hunk)))
    }

    @Test func buildsOneHunkPatches() {
        let hunk = Hunk(oldStart: 3, oldCount: 2, newStart: 3, newCount: 2, section: "func x()", lines: [
            DiffLine(kind: .context, text: "keep\r", oldLineNumber: 3, newLineNumber: 3),
            DiffLine(kind: .deletion, text: "old", oldLineNumber: 4, newLineNumber: nil, noNewlineAtEnd: true),
            DiffLine(kind: .addition, text: "new", oldLineNumber: nil, newLineNumber: 4, noNewlineAtEnd: true),
        ])
        #expect(Repository.patch(path: "dir/my file.txt", hunk: hunk) == """
            diff --git a/dir/my file.txt b/dir/my file.txt
            --- a/dir/my file.txt
            +++ b/dir/my file.txt
            @@ -3,2 +3,2 @@ func x()
             keep\r
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file

            """)
    }
}

@Suite struct GitCommitTests {
    private func setUp() async throws -> TestRepo {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
        try repo.write("b.txt", "b\n")
        try await repo.commitAll("init")
        return repo
    }

    private func committedFiles(_ repo: TestRepo) async throws -> [String] {
        try await repo.git("show", "--name-only", "--format=", "HEAD").split(separator: "\n").map(String.init).sorted()
    }

    @Test func commitsStagedFilesAndLeavesOtherStagedChanges() async throws {
        let repo = try await setUp()
        try repo.write("a.txt", "changed\n")
        try repo.write("b.txt", "changed b\n")
        try await repo.git("add", "a.txt", "b.txt")
        let repository = try await repo.open()

        try await repository.commit([ChangeTarget(file: repo.file("a.txt", in: .staged, of: repository))], toBranch: "main", message: "change a")
        #expect(try await committedFiles(repo) == ["a.txt"])
        #expect(try await repo.git("log", "-1", "--format=%s") == "change a\n")
        // b.txt is still staged, a.txt is clean.
        #expect(try await repo.paths(in: .staged, of: repository) == ["b.txt"])
        #expect(try await repo.paths(in: .unstaged, of: repository).isEmpty)
    }

    @Test func commitsUnstagedAndUntrackedFilesDirectly() async throws {
        let repo = try await setUp()
        try repo.write("b.txt", "changed b\n")
        try repo.write("new.txt", "new\n")
        try repo.write("other.txt", "untouched\n")
        let repository = try await repo.open()

        try await repository.commit([
            ChangeTarget(file: repo.file("b.txt", in: .unstaged, of: repository)),
            ChangeTarget(file: repo.file("new.txt", in: .untracked, of: repository)),
        ], toBranch: "main", message: "b and new")
        #expect(try await committedFiles(repo) == ["b.txt", "new.txt"])
        #expect(try await repository.changeGroups().map(\.kind) == [.untracked])
        #expect(try await repo.paths(in: .untracked, of: repository) == ["other.txt"])
    }

    @Test func commitsOneHunk() async throws {
        let repo = try await setUp()
        try repo.write("a.txt", "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n")
        let repository = try await repo.open()
        let file = try await repo.file("a.txt", in: .unstaged, of: repository)
        let diff = try #require(try await repository.diff(for: file))
        #expect(diff.hunks.count == 2)

        try await repository.commit([ChangeTarget(file: file, hunk: diff.hunks[0])], toBranch: "main", message: "first line")
        #expect(try await repo.git("show", "HEAD:a.txt").hasPrefix("ONE\ntwo"))
        #expect(try await repo.git("show", "HEAD:a.txt").hasSuffix("nine\nten\n"))
        // The other hunk is still an unstaged change, not a staged reversal.
        #expect(try await repo.paths(in: .staged, of: repository).isEmpty)
        let rest = try #require(try await repository.diff(for: repo.file("a.txt", in: .unstaged, of: repository)))
        #expect(rest.hunks.count == 1 && rest.hunks[0].newStart > 5)
    }

    @Test func commitsOneHunkButNotTheFilesStagedHunks() async throws {
        let repo = try await setUp()
        try repo.write("a.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nSTAGED\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "UNSTAGED\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nSTAGED\n")
        let repository = try await repo.open()
        let file = try await repo.file("a.txt", in: .unstaged, of: repository)
        let diff = try #require(try await repository.diff(for: file))
        #expect(diff.hunks.count == 1)

        try await repository.commit([ChangeTarget(file: file, hunk: diff.hunks[0])], toBranch: "main", message: "first line")
        #expect(try await repo.git("show", "HEAD:a.txt") == "UNSTAGED\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
        // The staged hunk is still staged, and nothing is left unstaged.
        #expect(try await repo.git("diff", "--cached", "--unified=0", "--", "a.txt").contains("+STAGED"))
        #expect(try await repo.paths(in: .unstaged, of: repository).isEmpty)
    }

    @Test func refusesAHunkOverlappingStagedChanges() async throws {
        let repo = try await setUp()
        try repo.write("a.txt", "STAGED\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "STAGED\nUNSTAGED\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
        let repository = try await repo.open()
        let file = try await repo.file("a.txt", in: .unstaged, of: repository)
        let diff = try #require(try await repository.diff(for: file))

        await #expect(throws: ChangeActionError.self) {
            try await repository.commit([ChangeTarget(file: file, hunk: diff.hunks[0])], toBranch: "main", message: "x")
        }
        #expect(try await repo.git("log", "-1", "--format=%s") == "init\n")
    }

    @Test func ignoresTheUsersDiffContextConfig() async throws {
        let repo = try await setUp()
        try await repo.git("config", "diff.context", "5")
        try await repo.git("config", "diff.interHunkContext", "10")
        try repo.write("a.txt", "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n")
        let repository = try await repo.open()
        let diff = try #require(try await repository.diff(for: repo.file("a.txt", in: .unstaged, of: repository)))
        // Three lines of context and no merging, like `but diff`.
        #expect(diff.hunks.map(\.oldCount) == [4, 4])
    }

    @Test func commitsToANewBranchButNotAnotherExistingOne() async throws {
        let repo = try await setUp()
        try await repo.git("branch", "other")
        try repo.write("b.txt", "changed b\n")
        let repository = try await repo.open()
        let target = ChangeTarget(file: try await repo.file("b.txt", in: .unstaged, of: repository))

        await #expect(throws: ChangeActionError.self) {
            try await repository.commit([target], toBranch: "other", message: "x")
        }
        try await repository.commit([target], toBranch: "feature/b", message: "b on a branch")
        #expect(try await repository.currentBranch() == "feature/b")
        #expect(try await repo.git("log", "-1", "--format=%s", "feature/b") == "b on a branch\n")
        #expect(try await repo.git("log", "-1", "--format=%s", "main") == "init\n")
    }

    @Test func deletesBranchesButNotTheCheckedOutOne() async throws {
        let repo = try await setUp()
        try await repo.git("switch", "-q", "-c", "squashed")
        try repo.write("b.txt", "squashed\n")
        try await repo.commitAll("not on main")
        try await repo.git("switch", "-q", "main")
        try await repo.git("branch", "merged")
        let repository = try await repo.open()

        await #expect(throws: ChangeActionError.self) { try await repository.deleteBranches(["merged", "main"]) }
        try await repository.deleteBranches(["merged", "squashed"])
        #expect(try await repo.git("branch", "--format=%(refname:short)") == "main\n")
    }

    @Test func runsCommitHooks() async throws {
        let repo = try await setUp()
        let hook = repo.root.appending(path: ".git/hooks/commit-msg")
        try Data("#!/bin/sh\necho 'rejected by hook' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try repo.write("b.txt", "changed b\n")
        let repository = try await repo.open()

        await #expect(throws: ProcessError.self) {
            try await repository.commit([ChangeTarget(file: repo.file("b.txt", in: .unstaged, of: repository))], toBranch: "main", message: "x")
        }
        #expect(try await repo.git("log", "-1", "--format=%s") == "init\n")
        #expect(try await repo.paths(in: .unstaged, of: repository) == ["b.txt"])
    }
}

@Suite(.enabled(if: Toolchain.locate("but", in: Toolchain.mergedPath(nil, ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())) != nil, "requires the `but` CLI"))
struct GitButlerActionTests {
    @Test func stacksDependentChangesOnTheirBranch() async throws {
        let repo = try await TestRepo(gitButler: true)
        try repo.write("notes.txt", twentyLines)
        try await repo.but("commit", "-b", "feature/base", "-m", "add notes")
        try repo.write("notes.txt", edited([2: "edited"]))
        let repository = try await repo.open()
        let target = ChangeTarget(file: try await repo.file("notes.txt", in: .unassigned, of: repository))

        do {
            try await repository.commit([target], toBranch: "feature/next", message: "edit notes")
            Issue.record("committing changes that depend on feature/base should fail")
        } catch ChangeActionError.dependsOn(let anchor) {
            #expect(anchor == "feature/base")
        }
        try await repository.commit([target], toBranch: "feature/next", stackedOn: "feature/base", message: "edit notes")
        let stack = try #require(try await repository.butStatus().stacks.first { $0.branches.contains { $0.name == "feature/next" } })
        #expect(stack.branches.map(\.name) == ["feature/next", "feature/base"])
    }

    @Test func showsUnstagedMovesAsRenames() async throws {
        let repo = try await TestRepo(gitButler: true)
        try repo.write("notes.txt", twentyLines)
        try await repo.but("commit", "-b", "feature/base", "-m", "add notes")
        try repo.remove("notes.txt")
        try repo.write("moved.txt", edited([20: "last"]))
        let repository = try await repo.open()

        let file = try await repo.file("moved.txt", in: .unassigned, of: repository)
        #expect(file.kind == .renamed && file.previousPath == "notes.txt")
        #expect(file.stats == LineStats(additions: 1, deletions: 1))
        let diff = try #require(try await repository.diff(for: file))
        #expect(diff.kind == .renamed && diff.oldPath == "notes.txt" && diff.hunks.count == 1)
    }

    @Test func commitsAndDiscardsOnlyTheGivenChanges() async throws {
        let repo = try await TestRepo(gitButler: true)
        try repo.write("notes.txt", twentyLines)
        try await repo.but("commit", "-b", "feature/base", "-m", "add notes")
        let repository = try await repo.open()

        try repo.write("a.txt", "a\n")
        try repo.write("b.txt", "b\n")
        try repo.write("notes.txt", edited([1: "first", 20: "last"]))

        // One file to a new branch.
        try await repository.commit([ChangeTarget(file: repo.file("a.txt", in: .unassigned, of: repository))], toBranch: "feature/a", message: "add a")
        // One hunk to an existing branch.
        let notes = try await repo.file("notes.txt", in: .unassigned, of: repository)
        let diff = try #require(try await repository.diff(for: notes))
        #expect(diff.hunks.count == 2)
        try await repository.commit([ChangeTarget(file: notes, hunk: diff.hunks[1])], toBranch: "feature/base", message: "edit end")

        let status = try await repository.butStatus(includeFiles: true)
        let branches = Dictionary(uniqueKeysWithValues: status.stacks.flatMap(\.branches).map { ($0.name, $0) })
        #expect(branches["feature/a"]?.commits.first?.changes?.map(\.filePath) == ["a.txt"])
        #expect(branches["feature/base"]?.commits.map(\.summary) == ["edit end", "add notes"])
        #expect(Set(status.unassignedChanges.map(\.filePath)) == ["b.txt", "notes.txt"])
        let left = try #require(try await repository.diff(for: notes))
        #expect(left.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text) == ["first"])

        try await repository.discard([ChangeTarget(file: notes, hunk: left.hunks[0])])
        try await repository.discard([ChangeTarget(file: repo.file("b.txt", in: .unassigned, of: repository))])
        #expect(try await repo.paths(in: .unassigned, of: repository).isEmpty)

        // Discards go through `but`, so they can be undone.
        try await repo.but("undo")
        #expect(try await repo.paths(in: .unassigned, of: repository) == ["b.txt"])

        await #expect(throws: ChangeActionError.self) {
            try await repository.commit([ChangeTarget(file: repo.file("b.txt", in: .unassigned, of: repository))], toBranch: "bad..name", message: "x")
        }
        await #expect(throws: ChangeActionError.self) {
            try await repository.commit([], toBranch: "feature/a", message: "x")
        }
    }

    @Test func stacksAndUnstacksBranches() async throws {
        let repo = try await TestRepo(gitButler: true)
        try repo.write("a.txt", "a\n")
        try await repo.but("commit", "-b", "feature/a", "-m", "add a")
        try repo.write("b.txt", "b\n")
        try await repo.but("commit", "-b", "feature/b", "-m", "add b")
        let repository = try await repo.open()
        #expect(try await repository.butStatus().stacks.count == 2)

        try await repository.stack("feature/b", onto: "feature/a")
        let stacked = try await repository.butStatus().stacks
        #expect(stacked.map { $0.branches.map(\.name) } == [["feature/b", "feature/a"]])

        try await repository.unstack("feature/b")
        #expect(try await repository.butStatus().stacks.map { $0.branches.map(\.name) }.sorted { $0[0] < $1[0] } == [["feature/a"], ["feature/b"]])
    }
}
