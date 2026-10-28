import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ButContractTests {
    private func violations(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> [String] {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(ButStatusTests.sample.utf8)) as? [String: Any])
        edit(&object)
        return ButContract.violations(in: try JSONSerialization.data(withJSONObject: object))
    }

    /// Edits the first branch of the first stack.
    private func editBranch(_ object: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        var stacks = object["stacks"] as! [[String: Any]]
        var branches = stacks[0]["branches"] as! [[String: Any]]
        edit(&branches[0])
        stacks[0]["branches"] = branches
        object["stacks"] = stacks
    }

    @Test func capturedOutputConforms() throws {
        #expect(try violations().isEmpty)
        // New fields are fine.
        #expect(try violations { $0["somethingNew"] = [1, 2] }.isEmpty)
        #expect(try violations { $0["upstreamState"] = NSNull() }.isEmpty)
    }

    @Test func reportsRenamedAndRetypedFields() throws {
        #expect(try violations { $0["unassignedChanges"] = $0.removeValue(forKey: "uncommittedChanges") }
            == ["uncommittedChanges: missing"])
        #expect(try violations { $0["stacks"] = [:] as [String: Any] } == ["stacks: expected an array"])
        #expect(try violations { $0["mergeBase"] = NSNull() } == ["mergeBase: expected an object"])
        #expect(try violations { $0["upstreamState"] = ["behind": "2"] } == ["upstreamState.behind: expected a number"])

        let commit = try violations { object in
            editBranch(&object) { branch in
                var commits = branch["commits"] as! [[String: Any]]
                commits[0]["id"] = commits[0].removeValue(forKey: "commitId")
                commits[0]["conflicted"] = "no"
                commits[0]["createdAt"] = "yesterday"
                branch["commits"] = commits
            }
        }
        #expect(commit == [
            "stacks[].branches[].commits[].commitId: missing",
            "stacks[].branches[].commits[].createdAt: unparseable date \"yesterday\"",
            "stacks[].branches[].commits[].conflicted: expected a boolean or null",
        ])
    }

    @Test func reportsUnknownValuesOnce() throws {
        let found = try violations { object in
            object["uncommittedChanges"] = [
                ["cliId": "a", "filePath": "a", "changeType": "moved"],
                ["cliId": "b", "filePath": "b", "changeType": "moved"],
            ]
            editBranch(&object) { $0["branchStatus"] = "pending" }
        }
        #expect(found == [
            "uncommittedChanges[].changeType: unknown value \"moved\"",
            "stacks[].branches[].branchStatus: unknown value \"pending\"",
        ])
        #expect(ButContract.violations(in: Data("not json".utf8)) == ["$: not valid JSON"])
        #expect(ButContract.violations(in: Data("[]".utf8)) == ["$: expected an object"])
    }
}

@Suite struct ButCompatibilityTests {
    @Test func parsesAndOrdersVersions() throws {
        #expect(ButVersion("but 0.22.3") == ButVersion([0, 22, 3]))
        #expect(ButVersion("0.23.0-nightly.4")?.description == "0.23.0")
        #expect(ButVersion("but") == nil)
        let versions = ["0.22.10", "0.22.3", "1.0", "0.9.9"].compactMap(ButVersion.init).sorted()
        #expect(versions.map(\.description) == ["0.9.9", "0.22.3", "0.22.10", "1.0"])
        #expect(ButVersion("1.0") == ButVersion("1.0.0"))
    }

    @Test func probesOnlyUntestedReleases() throws {
        let broken = Data(#"{"stacks": []}"#.utf8)
        let knownGood = ButVersion([0, 22, 3])
        #expect(ButCompatibility.check(status: broken, version: ButVersion([0, 22, 3]), knownGood: knownGood) == nil)
        #expect(ButCompatibility.check(status: broken, version: ButVersion([0, 21]), knownGood: knownGood) == nil)

        let issue = try #require(ButCompatibility.check(status: broken, version: ButVersion([0, 23, 0]), knownGood: knownGood))
        #expect(issue.violations == ["uncommittedChanges: missing", "mergeBase: missing"])
        #expect(issue.description == "GitButler 0.23.0 is not yet supported, showing plain git view")

        let fine = Data(ButStatusTests.sample.utf8)
        #expect(ButCompatibility.check(status: fine, version: ButVersion([0, 23, 0]), knownGood: knownGood) == nil)
        #expect(ButCompatibility.check(status: broken, version: nil, knownGood: knownGood) != nil)
        #expect(ButCompatibility.check(status: broken, version: knownGood, knownGood: nil) != nil)
    }

    @Test func flagsAnyOtherRelease() throws {
        let knownGood = ButVersion([0, 22, 3])
        #expect(ButCompatibility.mismatch(version: ButVersion([0, 22, 3]), knownGood: knownGood) == nil)
        #expect(ButCompatibility.mismatch(version: ButVersion([0, 22, 3, 0]), knownGood: knownGood) == nil)
        #expect(ButCompatibility.mismatch(version: ButVersion([0, 23, 1]), knownGood: nil) == nil)

        let newer = try #require(ButCompatibility.mismatch(version: ButVersion([0, 23, 1]), knownGood: knownGood))
        #expect(newer == ButVersionMismatch(installed: ButVersion([0, 23, 1]), tested: knownGood))
        #expect(newer.description == "GitButler 0.23.1 is untested, some features may not work until ohmydiff supports it")
        #expect(ButCompatibility.mismatch(version: ButVersion([0, 21]), knownGood: knownGood) != nil)
        #expect(ButCompatibility.mismatch(version: nil, knownGood: knownGood)?.installed == nil)
    }

    @Test func bundlesKnownGoodVersion() {
        #expect(ButCompatibility.knownGood != nil)
    }
}

/// Runs against whatever `but` is installed, in a workspace with every shape ohmydiff decodes. CI
/// runs this daily against the latest release; `OHMYDIFF_REQUIRE_BUT=1` makes a missing `but` fail
/// instead of skipping, and `OHMYDIFF_COMPAT_REPORT` names a file that receives the findings.
@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["OHMYDIFF_REQUIRE_BUT"] == "1"
        || Toolchain.locate("but", in: Toolchain.mergedPath(nil, ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())) != nil,
    "requires the `but` CLI"))
struct ButLiveContractTests {
    @Test func latestButMatchesContract() async throws {
        let repo = try await TestRepo(gitButler: true)
        let version = await ButCompatibility.version(of: repo.toolchain)

        // Two stacks, one of them two branches deep.
        try repo.write("one.txt", "one\n")
        try await repo.but("commit", "-b", "feature/one", "-m", "add one")
        try await repo.but("branch", "new", "feature/three", "--above", "feature/one")
        try repo.write("three.txt", "three\n")
        try await repo.but("commit", "-b", "feature/three", "-m", "add three")
        try repo.write("README.md", "readme\nfrom the branch\n")
        try await repo.but("commit", "-b", "feature/two", "-m", "edit readme")
        try await repo.but("push", "feature/three")

        // An upstream edit to the same line conflicts feature/two's commit once pulled.
        let upstream = repo.directory.appending(path: "upstream", directoryHint: .isDirectory)
        _ = try await repo.toolchain.git(["clone", "-q", "-b", "main", repo.directory.appending(path: "remote.git").path, upstream.path], in: repo.directory)
        try Data("readme\nfrom upstream\n".utf8).write(to: upstream.appending(path: "README.md"))
        for arguments in [["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-am", "upstream"], ["push", "-q", "origin", "main"]] {
            _ = try await repo.toolchain.git(arguments, in: upstream)
        }
        let upstreamHead = try await repo.toolchain.git(["rev-parse", "HEAD"], in: upstream).stdoutString.trimmingCharacters(in: .newlines)
        try await repo.but("pull")

        try repo.write("loose.txt", "unassigned\n")
        try repo.write("one.txt", "one\nedited\n")

        let withFiles = Data(try await repo.but("--json", "status", "-f").utf8)
        let plain = Data(try await repo.but("--json", "status").utf8)
        var violations = ButContract.violations(in: withFiles)
        violations += ButContract.violations(in: plain).filter { !violations.contains($0) }
        try writeReport(version: version, violations: violations)
        #expect(violations.isEmpty, "but \(version?.description ?? "?") breaks the contract: \(violations.joined(separator: "; "))")

        // The lenient decoder must still see what the workspace holds.
        let status = try ButStatus.decode(withFiles)
        #expect(Set(status.unassignedChanges.map(\.filePath)) == ["loose.txt", "one.txt"])
        #expect(Set(status.stacks.map { $0.branches.map(\.name) }) == [["feature/two"], ["feature/three", "feature/one"]])
        let branches = Dictionary(uniqueKeysWithValues: status.stacks.flatMap(\.branches).map { ($0.name, $0) })
        #expect(branches["feature/two"]?.commits.map(\.conflicted) == [true])
        #expect(branches["feature/two"]?.branchStatus == "completelyUnpushed")
        #expect(branches["feature/three"]?.branchStatus != "completelyUnpushed")
        #expect(branches["feature/three"]?.commits.first?.changes?.map(\.filePath) == ["three.txt"])
        #expect(status.stacks.flatMap(\.branches).allSatisfy { HistoryBranch.Status(butStatus: $0.branchStatus) != nil })
        #expect(status.mergeBase?.commitId == upstreamHead)

        // Hunk actions find their CLI IDs in `but --json diff`.
        let hunks = try ButDiff.decode(Data(try await repo.but("--json", "diff").utf8))
        #expect(Set(hunks.map(\.path)) == ["loose.txt", "one.txt"])
        #expect(hunks.allSatisfy { !$0.id.isEmpty && $0.newStart > 0 })

        let repository = try await repo.open()
        #expect(repository.kind == .gitButler)
        #expect(repository.butIncompatibility == nil)
        #expect(repository.butVersionMismatch == ButCompatibility.mismatch(version: version))

        // A conflicted commit is read through its checked-out tree, not GitButler's conflict bookkeeping.
        let conflicted = try #require(branches["feature/two"]?.commits.first?.commitId)
        let paths = try await repository.diff(commit: conflicted).map(\.path)
            + (try await repository.diff(from: "\(conflicted)^", to: conflicted)).map(\.path)
        #expect(!paths.contains { $0.hasPrefix(".") })
        #expect(try await repository.contents(at: conflicted, path: "README.md") != nil)
    }

    @Test func unsupportedReleaseFallsBackToGit() async throws {
        let repo = try await TestRepo(gitButler: true)
        // A future `but` whose status output dropped fields ohmydiff relies on.
        let fake = repo.directory.appending(path: "but")
        try Data("""
            #!/bin/sh
            case "$*" in
                *--version*) echo "but 99.0.0" ;;
                *) echo '{"stacks": [{"cliId": "a", "branches": [{"title": "feature/x"}]}]}' ;;
            esac
            """.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let toolchain = Toolchain(git: repo.toolchain.git, but: fake, environment: repo.toolchain.environment)

        let repository = try await Repository.open(repo.root, toolchain: toolchain)
        #expect(repository.kind == .git)
        let incompatibility = try #require(repository.butIncompatibility)
        #expect(incompatibility.version == ButVersion([99, 0, 0]))
        #expect(incompatibility.violations.contains("stacks[].branches[].name: missing"))
        #expect(repository.butVersionMismatch == nil)
    }

    @Test func untestedReleaseKeepsGitButlerView() async throws {
        let repo = try await TestRepo(gitButler: true)
        // A future `but` whose status output still conforms.
        let fake = repo.directory.appending(path: "but")
        let status = repo.directory.appending(path: "status.json")
        try Data(ButStatusTests.sample.utf8).write(to: status)
        try Data("""
            #!/bin/sh
            case "$*" in
                *--version*) echo "but 99.0.0" ;;
                *) cat '\(status.path)' ;;
            esac
            """.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let toolchain = Toolchain(git: repo.toolchain.git, but: fake, environment: repo.toolchain.environment)

        let repository = try await Repository.open(repo.root, toolchain: toolchain)
        #expect(repository.kind == .gitButler)
        #expect(repository.butIncompatibility == nil)
        #expect(repository.butVersionMismatch?.installed == ButVersion([99, 0, 0]))
    }

    private func writeReport(version: ButVersion?, violations: [String]) throws {
        guard let path = ProcessInfo.processInfo.environment["OHMYDIFF_COMPAT_REPORT"], !path.isEmpty else { return }
        let report: [String: Any] = ["version": version?.description ?? "unknown", "violations": violations]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
