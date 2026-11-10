import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ConflictMarkerTests {
    @Test func findsEachConflictWithItsLine() {
        let text = "a\n<<<<<<< ours\nMAIN\n=======\nFEAT\n>>>>>>> theirs\nb\n<<<<<<< ours\nx\n"
        let regions = ConflictMarkers.regions(in: text)
        #expect(regions.map(\.line) == [2, 8])
        #expect(regions.first?.text == "<<<<<<< ours\nMAIN\n=======\nFEAT\n>>>>>>> theirs")
        // The unterminated region runs to the end.
        #expect(regions.last?.text == "<<<<<<< ours\nx\n")
    }

    @Test func resolutionModeStatusDecodes() throws {
        let json = #"{"conflicted_files":["f.txt"],"resolved_files":["g.txt"],"conflicted_count":1,"all_resolved":false}"#
        let status = try ButStatus.decode(Data(json.utf8))
        #expect(status.resolution == ConflictResolution(conflictedFiles: ["f.txt"], resolvedFiles: ["g.txt"]))
        #expect(ButContract.violations(in: Data(json.utf8)).isEmpty)
        #expect(try ButStatus.decode(Data(#"{"stacks":[]}"#.utf8)).resolution == nil)
    }

    @Test func promptCarriesTheContextAndTheNextSteps() {
        let report = ConflictReport(
            situation: .operation("rebase"), repositoryPath: "/repo", isGitButler: false, branch: "feat", target: "origin/main",
            commits: [CommitInfo(sha: "aaaaaaaaaa", message: "feat change")], incoming: [CommitInfo(sha: "bbbbbbbbbb", message: "main change")],
            files: [ConflictedFile(path: "f.txt", regions: [ConflictRegion(line: 2, text: "<<<<<<< ours\nMAIN\n=======\nFEAT\n>>>>>>> theirs")])])
        let prompt = ClaudePrompt.resolveConflicts(report)
        #expect(prompt.hasPrefix("Resolve the merge conflicts on `feat`."))
        #expect(prompt.contains("- Target: `origin/main`"))
        #expect(prompt.contains("a git rebase stopped on conflicts"))
        #expect(prompt.contains("- `aaaaaaa` feat change"))
        #expect(prompt.contains("Commits on `origin/main` the branch does not have, newest first:\n\n- `bbbbbbb` main change"))
        #expect(prompt.contains("`f.txt`\n\nLine 2:\n\n```\n<<<<<<< ours"))
        #expect(prompt.contains("`git rebase --continue`"))
        #expect(prompt.contains("Do not push."))
    }

    @Test func mergeCommandLineQuotesEveryPath() {
        let line = EditorCommand.mergeCommandLine(
            template: EditorPreset.cursor.mergeTemplate!, file: "/r/a b.txt", ours: "/t/ours", theirs: "/t/theirs", base: "/t/base")
        #expect(line == "cursor --merge '/t/ours' '/t/theirs' '/t/base' '/r/a b.txt'")
        #expect(EditorPreset.zed.mergeTemplate == nil)
    }
}

@Suite struct GitConflictTests {
    /// `main` and `feat` both change the second line of `f.txt`.
    private func divergedRepo() async throws -> TestRepo {
        let repo = try await TestRepo()
        try repo.write("f.txt", "a\nb\nc\n")
        try await repo.commitAll("init")
        try await repo.git("checkout", "-q", "-b", "feat")
        try repo.write("f.txt", "a\nFEAT\nc\n")
        try await repo.commitAll("feat change")
        try await repo.git("checkout", "-q", "main")
        try repo.write("f.txt", "a\nMAIN\nc\n")
        try await repo.commitAll("main change")
        return repo
    }

    @Test func reportsAMergeStoppedOnConflicts() async throws {
        let repo = try await divergedRepo()
        _ = try? await repo.git("merge", "feat")
        let repository = try await repo.open()

        let report = try await repository.conflictReport(branch: nil, target: nil)
        #expect(report.situation == .operation("merge"))
        #expect(report.files.map(\.path) == ["f.txt"])
        #expect(report.files.first?.firstLine == 2)

        let sides = try #require(try await repository.mergeSides(of: "f.txt"))
        #expect(try String(contentsOf: sides.ours, encoding: .utf8) == "a\nMAIN\nc\n")
        #expect(try String(contentsOf: sides.theirs, encoding: .utf8) == "a\nFEAT\nc\n")
        #expect(try String(contentsOf: sides.base, encoding: .utf8) == "a\nb\nc\n")
        #expect(try await repository.mergeSides(of: "missing.txt") == nil)
    }

    @Test func reportsAPullRequestsConflictsWithoutTouchingTheWorktree() async throws {
        let repo = try await divergedRepo()
        let repository = try await repo.open()
        let branch = HistoryBranch(name: "feat", commits: try await repository.log(["main..feat"]), tip: try await repo.rev("feat"))

        let report = try await repository.conflictReport(branch: branch, target: nil, pullRequest: (number: 7, base: "main"))
        #expect(report.situation == .pullRequest(number: 7, base: "main"))
        #expect(report.target == "main")
        #expect(report.incoming.map(\.summary) == ["main change"])
        #expect(report.files.map(\.path) == ["f.txt"])
        #expect(report.files.first?.regions.first?.text.contains("MAIN") == true)
        #expect(try await repository.worktreeConflicts().isEmpty)
    }
}

@Suite(.enabled(if: Toolchain.locate("but", in: Toolchain.mergedPath(nil, ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())) != nil, "requires the `but` CLI"))
struct ButConflictTests {
    @Test func resolvesAConflictedCommitInResolutionMode() async throws {
        let repo = try await TestRepo(gitButler: true)
        try repo.write("README.md", "feat\n")
        try await repo.but("commit", "-b", "feat", "-m", "feat change")
        try await repo.pushUpstream("README.md", "main\n", message: "main change")
        // A second branch keeps the workspace from checking out `feat` alone, which `but resolve` refuses.
        try repo.write("other.txt", "other\n")
        try await repo.but("commit", "-b", "other", "-m", "other change")
        var repository = try await repo.open()
        _ = try await repository.fetchUpstream()
        _ = try await repository.updateFromUpstream()

        let branches = try await repository.history().flatMap(\.branches)
        let branch = try #require(branches.first { $0.name == "feat" })
        #expect(branch.isConflicted)
        let report = try await repository.conflictReport(branch: branch, target: "origin/main")
        #expect(report.situation == .conflictedCommits)
        #expect(report.details?.contains("README.md") == true)

        let commit = try #require(branch.commits.last { $0.isConflicted })
        try await repository.enterResolution(commit.sha)
        repository = try await repo.open()
        let changes = try await repository.changes()
        #expect(changes.resolution?.conflictedFiles == ["README.md"])
        #expect(changes.groups.first?.kind == .conflicted)
        let resolving = try await repository.conflictReport(branch: nil, target: nil, isResolving: true)
        #expect(resolving.files.map(\.path) == ["README.md"])

        try repo.write("README.md", "main and feat\n")
        try await repository.finishResolution()
        #expect(try await repository.changes().resolution == nil)
        let after = try await repository.history().flatMap(\.branches)
        let resolved = try #require(after.first { $0.name == "feat" })
        #expect(!resolved.isConflicted)
    }
}
