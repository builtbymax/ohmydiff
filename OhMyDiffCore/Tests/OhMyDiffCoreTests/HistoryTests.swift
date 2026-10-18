import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct HistoryTests {
    @Test func parsesLogRecords() {
        let text = "abc123\0Ada\0ada@example.com\02026-10-18T10:00:00+02:00\0subject line\n\nbody text\n\u{1e}\n"
            + "def456\0Bob\0bob@example.com\02026-10-17T09:00:00Z\0only subject\n\u{1e}\n"
        let commits = Repository.parseLog(text)
        #expect(commits.map(\.sha) == ["abc123", "def456"])
        #expect(commits[0].summary == "subject line")
        #expect(commits[0].body == "body text")
        #expect(commits[0].authorName == "Ada" && commits[0].authorEmail == "ada@example.com")
        #expect(commits[0].date == Date(timeIntervalSince1970: 1_792_310_400))
        #expect(commits[1].body.isEmpty)
    }

    @Test func parsesTrackingInfo() {
        #expect(HistoryBranch.Status.tracking("[ahead 2, behind 1]", hasUpstream: true) == .tracking(ahead: 2, behind: 1))
        #expect(HistoryBranch.Status.tracking("[behind 3]", hasUpstream: true) == .tracking(ahead: 0, behind: 3))
        #expect(HistoryBranch.Status.tracking("", hasUpstream: true) == .upToDate)
        #expect(HistoryBranch.Status.tracking("[gone]", hasUpstream: true) == .upstreamGone)
        #expect(HistoryBranch.Status.tracking("", hasUpstream: false) == nil)
    }

    @Test func basesStackedBranchesOnTheBranchBelow() {
        let status = ButStatus(
            stacks: [ButStack(cliId: "s1", branches: [
                ButBranch(name: "top", commits: [ButCommit(commitId: "t2", message: "t2"), ButCommit(commitId: "t1", message: "t1", conflicted: true)],
                          branchStatus: "unpushedCommitsRequiringForce"),
                ButBranch(name: "empty"),
                ButBranch(name: "bottom", commits: [ButCommit(commitId: "b1", message: "b1")], branchStatus: "completelyUnpushed"),
            ])],
            mergeBase: ButCommit(commitId: "base", message: "base"))
        let branches = try! #require(Repository.butHistory(status).first).branches

        #expect(branches.map(\.name) == ["top", "empty", "bottom"])
        #expect(branches[0].base == "t1^" && branches[0].tip == "t2" && branches[0].baseName == "empty")
        #expect(branches[0].status == .requiresForce && branches[0].isConflicted)
        #expect(branches[1].base == nil && branches[1].tip == "b1")
        #expect(branches[2].base == "b1^" && branches[2].baseName == "the target branch" && branches[2].status == .unpushed)
    }

    @Test func listsGitBranchesAheadOfMain() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("init")
        try repo.write("a.txt", "one\nmain\n")
        try await repo.commitAll("main moves on")
        try await repo.git("checkout", "-q", "-b", "feature", "HEAD~1")
        try repo.write("b.txt", "feature\n")
        try await repo.commitAll("add b")
        try repo.write("b.txt", "feature\nmore\n")
        try await repo.commitAll("extend b")

        let repository = try await repo.open()
        let branches = try #require(try await repository.history().first).branches
        #expect(branches.map(\.name) == ["main", "feature"])

        // No upstream for main, so its recent history is listed without a whole diff.
        #expect(branches[0].commits.map(\.summary) == ["main moves on", "init"])
        #expect(branches[0].base == nil)

        let feature = branches[1]
        #expect(feature.isCurrent && feature.baseName == "main")
        #expect(feature.commits.map(\.summary) == ["extend b", "add b"])
        #expect(feature.commits[0].authorName == "Test" && feature.commits[0].date != nil)

        let base = try #require(feature.base)
        let whole = try await repository.diff(from: base, to: feature.tip)
        #expect(whole.map(\.path) == ["b.txt"])
        #expect(whole[0].hunks.flatMap(\.lines).map(\.text) == ["feature", "more"])

        #expect(try await repository.contents(at: feature.tip, path: "b.txt") == Data("feature\nmore\n".utf8))
        #expect(try await repository.contents(at: base, path: "b.txt") == nil)
    }
}

@Suite(.enabled(if: Toolchain.locate("but", in: Toolchain.mergedPath(nil, ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())) != nil, "requires the `but` CLI"))
struct GitButlerHistoryTests {
    @Test func listsStacksWithCommits() async throws {
        let repo = try await TestRepo(gitButler: true)
        try repo.write("one.txt", "one\n")
        try await repo.but("commit", "-b", "feature/one", "-m", "add one")
        try repo.write("one.txt", "one\nmore\n")
        try await repo.but("commit", "-b", "feature/one", "-m", "extend one")

        let repository = try await repo.open()
        let groups = try await repository.history()
        let branch = try #require(groups.flatMap(\.branches).first { $0.name == "feature/one" })
        #expect(branch.commits.map(\.summary) == ["extend one", "add one"])
        #expect(branch.status == .unpushed)

        let whole = try await repository.diff(from: try #require(branch.base), to: branch.tip)
        #expect(whole.map(\.path) == ["one.txt"])
        #expect(whole[0].kind == .added)
    }
}
