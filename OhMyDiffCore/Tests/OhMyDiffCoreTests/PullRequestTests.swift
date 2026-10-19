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

    @Test func changesDraftStateAndMerges() async throws {
        let stub = try await StubbedGH()
        let pullRequest = PullRequest(number: 7, title: "x", url: URL(string: "https://github.com/o/r/pull/7")!, state: .open, isDraft: true)
        try await stub.repository.setDraft(false, pullRequest: pullRequest)
        try await stub.repository.setDraft(true, pullRequest: pullRequest)
        try await stub.repository.merge(pullRequest, method: .squash)
        #expect(try stub.calls() == ["pr ready 7", "pr ready 7 --undo", "pr merge 7 --squash"])
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
