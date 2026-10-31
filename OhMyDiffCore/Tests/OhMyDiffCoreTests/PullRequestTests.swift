import Foundation
import Testing
@testable import OhMyDiffCore

/// A repository whose toolchain finds a stub `gh` that logs its arguments and answers `pr list` from a file.
private struct StubbedGH {
    let repo: TestRepo
    let repository: Repository
    let log: URL
    let listResponse: URL

    init() async throws {
        repo = try await TestRepo()
        try await repo.addOrigin()
        let bin = repo.directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        log = repo.directory.appending(path: "gh.log")
        listResponse = repo.directory.appending(path: "gh-list.json")
        try Data("[]".utf8).write(to: listResponse)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        if [ "$1 $2" = "pr list" ]; then cat '\(listResponse.path)'; fi
        if [ "$1 $2" = "pr merge" ] && [ -f '\(log.path).stacked' ]; then
          echo "This pull request is part of a stack and must be merged using the asynchronous merge REST API." >&2; exit 1
        fi
        if [ "$1 $2" = "pr view" ]; then echo MERGED; fi
        if [ "$1 $2" = "pr create" ]; then
          for arg in "$@"; do case "$prev" in --body-file) cp "$arg" '\(log.path).body';; esac; prev="$arg"; done
        fi
        """
        let gh = bin.appending(path: "gh")
        try Data(script.utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        var environment = repo.toolchain.environment
        environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "")
        let toolchain = Toolchain(git: repo.toolchain.git, but: repo.toolchain.but, environment: environment)
        repository = Repository(root: repo.root, kind: .git, toolchain: toolchain)
    }

    func calls() throws -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

@Suite struct PullRequestTests {
    @Test func splitsTitleAndDescription() {
        #expect(Repository.pullRequestParts("# Add things\n\nBody line\n- item") == ("Add things", "Body line\n- item"))
        #expect(Repository.pullRequestParts("\n\nTitle: feat: x\nbody") == ("feat: x", "body"))
        #expect(Repository.pullRequestParts("Only a title") == ("Only a title", ""))
        #expect(Repository.pullRequestParts("") == ("", ""))
    }

    @Test func decodesPullRequests() throws {
        let json = #"[{"number": 12, "title": "feat: x", "url": "https://github.com/o/r/pull/12", "state": "OPEN", "isDraft": true, "baseRefName": "main"}]"#
        let pullRequest = try #require(try JSONDecoder().decode([PullRequest].self, from: Data(json.utf8)).first)
        #expect(pullRequest == PullRequest(number: 12, title: "feat: x", url: URL(string: "https://github.com/o/r/pull/12")!, state: .open, isDraft: true))
    }

    @Test func pushesAPlainBranchWithUpstream() async throws {
        let repo = try await TestRepo()
        try await repo.addOrigin()
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("f.txt", "f\n")
        try await repo.commitAll("feature")
        let repository = try await repo.open()

        try await repository.push(branch: "feature")
        #expect(try await repo.rev("origin/feature") == repo.rev("feature"))
        #expect(try await repo.git("rev-parse", "--abbrev-ref", "feature@{u}").hasPrefix("origin/feature"))
    }

    @Test func createsAPullRequestAgainstTheDefaultBranch() async throws {
        let stub = try await StubbedGH()
        try await stub.repo.git("switch", "-q", "-c", "feature")
        try stub.repo.write("f.txt", "f\n")
        try await stub.repo.commitAll("feature")
        try Data(#"[{"number": 3, "title": "Add f", "url": "https://github.com/o/r/pull/3", "state": "OPEN", "isDraft": false, "baseRefName": "main"}]"#.utf8)
            .write(to: stub.listResponse)

        let created = try await stub.repository.createPullRequest(branch: "feature", text: "# Add f\n\nAdds the f file.", isDraft: true)
        #expect(created?.number == 3)
        // Pushed first, so the pull request has a head to point at.
        #expect(try await stub.repo.rev("origin/feature") == stub.repo.rev("feature"))
        let create = try #require(try stub.calls().first { $0.hasPrefix("pr create") })
        #expect(create.contains("--head feature --title Add f"))
        #expect(create.contains("--base main"))
        #expect(create.hasSuffix("--draft"))
        #expect(try String(contentsOf: URL(fileURLWithPath: stub.log.path + ".body"), encoding: .utf8) == "Adds the f file.")
    }

    @Test func listsTheNewestPullRequestPerBranch() async throws {
        let stub = try await StubbedGH()
        try Data("""
        [{"number": 9, "title": "again", "url": "https://github.com/o/r/pull/9", "state": "OPEN", "isDraft": false, "baseRefName": "main", "headRefName": "a"},
         {"number": 4, "title": "first", "url": "https://github.com/o/r/pull/4", "state": "CLOSED", "isDraft": false, "baseRefName": "main", "headRefName": "a"},
         {"number": 5, "title": "b", "url": "https://github.com/o/r/pull/5", "state": "MERGED", "isDraft": false, "baseRefName": "main", "headRefName": "b"}]
        """.utf8).write(to: stub.listResponse)
        let pullRequests = try await stub.repository.pullRequests()
        #expect(pullRequests.mapValues(\.number) == ["a": 9, "b": 5])
    }

    @Test func decodesChecksConflictsAndReviews() throws {
        func status(_ json: String) throws -> PullRequestStatus { try PullRequestStatus.decode(Data(json.utf8)) }

        let running = try status("""
        {"mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": "REVIEW_REQUIRED", "statusCheckRollup": [
          {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"},
          {"__typename": "CheckRun", "name": "test", "status": "IN_PROGRESS", "conclusion": ""},
          {"__typename": "StatusContext", "context": "deploy", "state": "PENDING"}]}
        """)
        #expect(running == PullRequestStatus(checks: .pending(done: 1, total: 3), isMergeable: true, mergeState: "BLOCKED", review: .required))
        #expect(running.hasPendingChecks)

        let failed = try status("""
        {"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY", "reviewDecision": "", "statusCheckRollup": [
          {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"},
          {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR"},
          {"__typename": "CheckRun", "name": "test", "status": "QUEUED", "conclusion": ""}]}
        """)
        #expect(failed == PullRequestStatus(checks: .failed(names: ["lint", "ci/legacy"], total: 3), isMergeable: false, mergeState: "DIRTY"))

        let clean = try status(#"{"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED", "statusCheckRollup": [{"name": "a", "status": "COMPLETED", "conclusion": "SKIPPED"}]}"#)
        #expect(clean == PullRequestStatus(checks: .passed(total: 1), isMergeable: true, mergeState: "CLEAN", review: .approved))
        #expect(try status(#"{"mergeable": "UNKNOWN", "statusCheckRollup": []}"#) == PullRequestStatus())
    }

    @Test func readsTheStatusOfEveryOpenPullRequest() async throws {
        let stub = try await StubbedGH()
        try Data("""
        [{"number": 2, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "statusCheckRollup": [{"name": "t", "status": "IN_PROGRESS"}]},
         {"number": 3, "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY", "statusCheckRollup": []}]
        """.utf8).write(to: stub.listResponse)
        let statuses = try await stub.repository.openPullRequestStatuses()
        #expect(statuses[2]?.hasPendingChecks == true)
        #expect(statuses[3] == PullRequestStatus(isMergeable: false, mergeState: "DIRTY"))
        #expect(try stub.calls().last?.contains("--state open") == true)
    }

    @Test func changesDraftStateAndMerges() async throws {
        let stub = try await StubbedGH()
        let pullRequest = PullRequest(number: 7, title: "x", url: URL(string: "https://github.com/o/r/pull/7")!, state: .open, isDraft: true)
        try await stub.repository.setDraft(false, pullRequest: pullRequest)
        try await stub.repository.setDraft(true, pullRequest: pullRequest)
        try await stub.repository.merge(pullRequest, method: .squash)
        #expect(try stub.calls() == ["pr ready 7", "pr ready 7 --undo", "pr merge 7 --squash"])
    }

    @Test func mergesStackedPullRequestsAsynchronously() async throws {
        let stub = try await StubbedGH()
        try Data().write(to: URL(fileURLWithPath: stub.log.path + ".stacked"))
        let pullRequest = PullRequest(number: 8, title: "x", url: URL(string: "https://github.com/o/r/pull/8")!, state: .open)
        try await stub.repository.merge(pullRequest, method: .merge)
        #expect(try stub.calls() == [
            "pr merge 8 --merge",
            "api --method PUT repos/{owner}/{repo}/pulls/8/merge-async -f merge_method=merge",
            "pr view 8 --json state --jq .state",
        ])
    }

    @Test func describesGitHubErrorsWithoutCLIHints() {
        let conflict = GitHubError(stderr: """
        X Pull request builtbymax/repo#8 is not mergeable: the merge commit cannot be cleanly created.
        To have the pull request merged after all the requirements have been met, add the `--auto` flag.
        Run the following to resolve the merge conflicts locally:
          gh pr checkout 8 && git merge origin/main

        """)
        #expect(conflict.description == "Pull request builtbymax/repo#8 is not mergeable: the merge commit cannot be cleanly created.")
        #expect(GitHubError(stderr: "").description == "GitHub reported an error.")
    }

    @Test func readsNothingWithoutGH() async throws {
        let repo = try await TestRepo()
        var environment = repo.toolchain.environment
        environment["PATH"] = "/nonexistent"
        let repository = Repository(
            root: repo.root, kind: .git, toolchain: Toolchain(git: repo.toolchain.git, but: nil, environment: environment))
        #expect(!repository.canManagePullRequests)
        #expect(try await repository.pullRequest(forBranch: "main") == nil)
    }
}

@Suite struct PullRequestDetailTests {
    @Test func decodesChecksBodyAndAutoMerge() throws {
        let json = """
        {"body":"What\\n","author":{"login":"builtbymax"},"commits":[{},{},{}],"changedFiles":4,
         "autoMergeRequest":{"mergeMethod":"SQUASH"},
         "statusCheckRollup":[
          {"name":"core-tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-31T10:00:00Z","completedAt":"2026-10-31T10:01:52Z"},
          {"name":"lint","status":"COMPLETED","conclusion":"FAILURE"},
          {"name":"compat","status":"IN_PROGRESS","startedAt":"2026-10-31T10:00:00Z","completedAt":"0001-01-01T00:00:00Z"},
          {"name":"notarize","status":"QUEUED"},
          {"context":"ci/legacy","state":"PENDING"}
         ]}
        """
        let detail = try PullRequestDetail.decode(Data(json.utf8))
        #expect(detail.body == "What\n")
        #expect(detail.author == "builtbymax")
        #expect(detail.commitCount == 3)
        #expect(detail.changedFiles == 4)
        #expect(detail.autoMerge)
        #expect(detail.checks.map(\.state) == [.passed, .failed, .running, .queued, .running])
        #expect(detail.checks.map(\.name).last == "ci/legacy")
        #expect(detail.checks[0].duration == .seconds(112))
        #expect(detail.checks[2].completedAt == nil)
        #expect(detail.runningCheckCount == 3)
    }

    @Test func decodesMissingAutoMerge() throws {
        let detail = try PullRequestDetail.decode(Data(#"{"body":"","autoMergeRequest":null,"statusCheckRollup":[]}"#.utf8))
        #expect(!detail.autoMerge)
        #expect(detail.checks.isEmpty)
    }
}

@Suite struct InboxTests {
    @Test func decodesInboxPullRequests() throws {
        let json = """
        [{"number":151,"title":"Stream large diffs","url":"https://github.com/o/r/pull/151","state":"OPEN","isDraft":false,
          "baseRefName":"main","headRefName":"perf/stream","author":{"login":"lena-k"},
          "reviewRequests":[{"__typename":"User","login":"builtbymax"},{"__typename":"Team","name":"core"}],
          "reviewDecision":"REVIEW_REQUIRED","comments":[{"author":{"login":"jonas"},"body":"hm"}],
          "reviews":[{"author":{"login":"jonas"},"body":"","state":"COMMENTED"},{"author":{"login":"mia"},"body":"ok","state":"APPROVED"}],
          "updatedAt":"2026-10-31T10:00:00Z","mergedAt":null,"additions":412,"deletions":96,"changedFiles":6,
          "statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]},
         {"number":139,"title":"Release","url":"https://github.com/o/r/pull/139","state":"MERGED","isDraft":false,
          "baseRefName":"main","headRefName":"chore/release","author":{"login":"builtbymax"},"reviewRequests":[],
          "reviewDecision":"","comments":[],"reviews":[],"mergedAt":"2026-10-30T10:00:00Z","statusCheckRollup":[]},
         {"number":2,"title":"Closed","url":"https://github.com/o/r/pull/2","state":"CLOSED","author":{"login":"x"},"statusCheckRollup":[]}]
        """
        let inbox = try InboxPullRequest.decode(Data(json.utf8))
        #expect(inbox.count == 3)
        let first = inbox[0]
        #expect(first.author == "lena-k")
        #expect(first.reviewRequests == ["builtbymax", "core"])
        #expect(first.review == .required)
        #expect(first.commentCount == 2)
        #expect(first.participants == ["jonas", "mia"])
        #expect(first.checks == .passed(total: 1))
        #expect(first.additions == 412 && first.changedFiles == 6)
        #expect(inbox[1].state == .merged && inbox[1].mergedAt != nil && inbox[1].review == nil)
    }

    @Test func decodesFilesWithViewedState() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"id":"PR_1","files":{"nodes":[
          {"path":"a.swift","additions":3,"deletions":1,"changeType":"MODIFIED","viewerViewedState":"VIEWED"},
          {"path":"b.swift","additions":9,"deletions":0,"changeType":"ADDED","viewerViewedState":"UNVIEWED"}]}}}}}
        """
        let files = try PullRequestFiles.decode(Data(json.utf8))
        #expect(files.nodeID == "PR_1")
        #expect(files.files.map(\.isViewed) == [true, false])
        #expect(files.files.map(\.kind) == [.modified, .added])
    }
}
