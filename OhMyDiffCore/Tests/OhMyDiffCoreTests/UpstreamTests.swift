import Foundation
import Testing
@testable import OhMyDiffCore

extension TestRepo {
    /// A bare `origin` with `main` pushed, for plain repositories (`TestRepo(gitButler: true)` has one already).
    func addOrigin() async throws {
        try write("README.md", "readme\n")
        try await commitAll("init")
        try await git("init", "-q", "--bare", remoteURL.path)
        try await git("remote", "add", "origin", remoteURL.path)
        try await git("push", "-q", "-u", "origin", "main")
    }

    var remoteURL: URL { directory.appending(path: "remote.git") }

    /// Runs git in a second clone of `origin`, e.g. to push commits as someone else would.
    @discardableResult
    func inClone(_ arguments: String...) async throws -> String {
        let clone = directory.appending(path: "clone")
        if !FileManager.default.fileExists(atPath: clone.path) {
            _ = try await toolchain.git(["clone", "-q", "-b", "main", remoteURL.path, clone.path], in: directory)
            _ = try await toolchain.git(["config", "user.name", "Other"], in: clone)
            _ = try await toolchain.git(["config", "user.email", "other@example.com"], in: clone)
            _ = try await toolchain.git(["config", "commit.gpgsign", "false"], in: clone)
        }
        return try await toolchain.git(arguments, in: clone).stdoutString
    }

    /// Commits a file in the clone and pushes it to `main`.
    func pushUpstream(_ path: String, _ contents: String, message: String) async throws {
        let clone = directory.appending(path: "clone")
        try await inClone("pull", "-q", "--ff-only")
        try Data(contents.utf8).write(to: clone.appending(path: path))
        try await inClone("add", "-A")
        try await inClone("commit", "-q", "-m", message)
        try await inClone("push", "-q", "origin", "main")
    }

    func rev(_ revision: String) async throws -> String {
        try await git("rev-parse", revision).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite struct GitUpstreamTests {
    @Test func reportsNothingWithoutUpstream() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("init")
        #expect(try await repo.open().gitUpstreamStatus() == nil)
    }

    @Test func fastForwardsTheCheckedOutBranch() async throws {
        let repo = try await TestRepo()
        try await repo.addOrigin()
        try await repo.pushUpstream("up.txt", "up\n", message: "upstream change")
        try repo.write("local.txt", "uncommitted\n")
        let repository = try await repo.open()

        let status = try #require(try await repository.fetchUpstream())
        #expect(status.target == "origin/main")
        #expect(status.incoming.map(\.summary) == ["upstream change"])
        #expect(status.branches == [BranchUpdate(name: "main", action: .fastForward)])

        let result = try await repository.updateFromUpstream()
        #expect(result.updated == ["main"])
        #expect(try await repo.rev("main") == repo.rev("origin/main"))
        // Uncommitted changes survive the update.
        #expect(FileManager.default.fileExists(atPath: repo.root.appending(path: "local.txt").path))
        #expect(try #require(try await repository.gitUpstreamStatus()).hasUpdates == false)
    }

    @Test func rebasesLocalCommitsOntoTheUpstream() async throws {
        let repo = try await TestRepo()
        try await repo.addOrigin()
        try await repo.pushUpstream("up.txt", "up\n", message: "upstream change")
        try repo.write("mine.txt", "mine\n")
        try await repo.commitAll("local change")
        let repository = try await repo.open()

        let status = try #require(try await repository.fetchUpstream())
        #expect(status.branches == [BranchUpdate(name: "main", action: .rebase)])

        let result = try await repository.updateFromUpstream()
        #expect(result.updated == ["main"])
        #expect(try await repo.rev("main~1") == repo.rev("origin/main"))
    }

    @Test func leavesAConflictingBranchAsItWas() async throws {
        let repo = try await TestRepo()
        try await repo.addOrigin()
        try await repo.pushUpstream("README.md", "theirs\n", message: "upstream readme")
        try repo.write("README.md", "mine\n")
        try await repo.commitAll("local readme")
        let before = try await repo.rev("main")
        let repository = try await repo.open()

        let status = try #require(try await repository.fetchUpstream())
        #expect(status.branches == [BranchUpdate(name: "main", action: .conflicts)])

        let result = try await repository.updateFromUpstream()
        #expect(result.conflicted == ["main"])
        #expect(try await repo.rev("main") == before)
    }

    @Test func fastForwardsOtherBranchesAndSkipsDivergedOnes() async throws {
        let repo = try await TestRepo()
        try await repo.addOrigin()
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("feature.txt", "f\n")
        try await repo.commitAll("feature")
        try await repo.git("push", "-q", "-u", "origin", "feature")
        try await repo.git("switch", "-q", "-c", "other", "main")
        try await repo.pushUpstream("up.txt", "up\n", message: "upstream change")
        // `feature` also gets a commit upstream, and a local one, so it has diverged.
        try await repo.inClone("fetch", "-q")
        try await repo.inClone("switch", "-q", "feature")
        try await repo.inClone("commit", "-q", "--allow-empty", "-m", "remote feature")
        try await repo.inClone("push", "-q", "origin", "feature")
        try await repo.inClone("switch", "-q", "main")
        try await repo.git("commit", "-q", "--allow-empty", "-m", "local feature")
        try await repo.git("switch", "-q", "--detach")
        try await repo.git("branch", "-q", "-f", "feature", "HEAD")
        try await repo.git("switch", "-q", "other")
        let repository = try await repo.open()

        let status = try #require(try await repository.fetchUpstream())
        #expect(Set(status.branches) == [
            BranchUpdate(name: "main", action: .fastForward),
            BranchUpdate(name: "feature", action: .diverged),
        ])

        let featureBefore = try await repo.rev("feature")
        let result = try await repository.updateFromUpstream()
        #expect(result.updated == ["main"])
        #expect(try await repo.rev("main") == repo.rev("origin/main"))
        #expect(try await repo.rev("feature") == featureBefore)
    }

    @Test func removesBranchesMergedAndDeletedUpstream() async throws {
        let repo = try await TestRepo()
        try await repo.addOrigin()
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("feature.txt", "f\n")
        try await repo.commitAll("feature")
        try await repo.git("push", "-q", "-u", "origin", "feature")
        try await repo.git("switch", "-q", "main")
        try await repo.inClone("fetch", "-q")
        try await repo.inClone("merge", "-q", "--ff-only", "origin/feature")
        try await repo.inClone("push", "-q", "origin", "main", ":feature")
        let repository = try await repo.open()

        let status = try #require(try await repository.fetchUpstream())
        #expect(Set(status.branches) == [
            BranchUpdate(name: "main", action: .fastForward),
            BranchUpdate(name: "feature", action: .integrated),
        ])

        let result = try await repository.updateFromUpstream()
        #expect(result.integrated == ["feature"])
        let branches = try await repo.git("branch", "--format=%(refname:short)")
        #expect(!branches.contains("feature"))
    }
}

@Suite struct ButPullDecodingTests {
    @Test func decodesCheck() throws {
        let json = """
        {"baseBranch": {"name": "origin/main", "remoteName": "origin"},
         "upstreamCommits": {"count": 2, "commits": [
            {"id": "82baf5b", "description": "edit readme\\n", "authorName": "O"},
            {"id": "9cd8e29", "description": "feat a", "authorName": "T"}]},
         "branchStatuses": [
            {"name": "feat/c", "status": "conflicted", "rebasable": true},
            {"name": "feat/b", "status": "updatable", "rebasable": null},
            {"name": "feat/a", "status": "integrated", "rebasable": null},
            {"name": "", "status": "updatable"}],
         "upToDate": false, "hasWorktreeConflicts": true}
        """
        let status = try JSONDecoder().decode(ButPullCheck.self, from: Data(json.utf8)).upstreamStatus
        #expect(status.target == "origin/main")
        #expect(status.incoming.map(\.summary) == ["edit readme", "feat a"])
        #expect(status.incoming.first?.authorName == "O")
        #expect(status.branches == [
            BranchUpdate(name: "feat/c", action: .conflicts),
            BranchUpdate(name: "feat/b", action: .rebase),
            BranchUpdate(name: "feat/a", action: .integrated),
        ])
        #expect(status.hasWorktreeConflicts)
    }

    @Test func decodesUpToDateCheckAndResult() throws {
        let check = try JSONDecoder().decode(ButPullCheck.self, from: Data(#"{"baseBranch": {"name": "origin/main"}, "upstreamCommits": {"count": 0, "commits": []}, "branchStatuses": []}"#.utf8))
        #expect(!check.upstreamStatus.hasUpdates)

        let json = #"{"status": "completed_with_conflicts", "branchesToUpdate": [{"name": "feat/c", "status": "conflicted_rebasable"}, {"name": "feat/b", "status": "updatable"}, {"name": "feat/a", "status": "integrated"}]}"#
        let result = try JSONDecoder().decode(ButPullResult.self, from: Data(json.utf8)).result
        #expect(result == UpstreamUpdateResult(updated: ["feat/b"], integrated: ["feat/a"], conflicted: ["feat/c"]))
    }
}

@Suite(.enabled(if: Toolchain.locate("but", in: Toolchain.mergedPath(nil, ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())) != nil, "requires the `but` CLI"))
struct ButUpstreamTests {
    @Test func checksAndPullsUpstreamCommits() async throws {
        let repo = try await TestRepo(gitButler: true)
        try repo.write("b.txt", "b\n")
        try await repo.but("commit", "-b", "feat/b", "-m", "feat b")
        try await repo.pushUpstream("up.txt", "up\n", message: "upstream change")
        let repository = try await repo.open()

        let status = try #require(try await repository.fetchUpstream())
        #expect(status.target == "origin/main")
        #expect(status.incoming.map(\.summary) == ["upstream change"])
        #expect(status.branches == [BranchUpdate(name: "feat/b", action: .rebase)])

        let result = try await repository.updateFromUpstream()
        #expect(result.updated == ["feat/b"])
        #expect(try #require(try await repository.fetchUpstream()).incoming.isEmpty)
    }
}
