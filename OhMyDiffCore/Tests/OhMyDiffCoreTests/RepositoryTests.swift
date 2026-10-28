import Foundation
import Testing
@testable import OhMyDiffCore

/// A throwaway repository in a temp dir with its own `HOME`, so neither the user's git config
/// nor GitButler's global project list is read or touched.
final class TestRepo {
    let directory: URL
    let root: URL
    let toolchain: Toolchain

    init(gitButler: Bool = false) async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ohmydiff-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        root = directory.appending(path: "repo", directoryHint: .isDirectory)
        let home = directory.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let discovered = try await Toolchain.discover()
        var environment = discovered.environment
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appending(path: ".config").path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        toolchain = Toolchain(git: discovered.git, but: discovered.but, environment: environment)

        try await git("init", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try await git("config", "commit.gpgsign", "false")

        if gitButler {
            // `but setup` wants an initial commit and a remote target.
            try write("README.md", "readme\n")
            try await git("add", "-A")
            try await git("commit", "-q", "-m", "init")
            let remote = directory.appending(path: "remote.git")
            try await git("init", "-q", "--bare", remote.path)
            try await git("remote", "add", "origin", remote.path)
            // The upstream is where `but push` pushes to since 0.23.
            try await git("push", "-q", "-u", "origin", "main")
            // A no-op since 0.23, where using `but` in a repository sets up its workspace.
            try await but("setup")
            try await but("status")
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func git(_ arguments: String...) async throws -> String {
        try await toolchain.git(arguments, in: root).stdoutString
    }

    @discardableResult
    func but(_ arguments: String...) async throws -> String {
        try await toolchain.but(arguments, in: root, timeout: .seconds(60)).stdoutString
    }

    func write(_ path: String, _ contents: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: path))
    }

    func commitAll(_ message: String) async throws {
        try await git("add", "-A")
        try await git("commit", "-q", "-m", message)
    }

    func open() async throws -> Repository {
        try await Repository.open(root, toolchain: toolchain)
    }
}

@Suite struct GitRepositoryTests {
    @Test func opensFromSubdirectoryAsPlainGit() async throws {
        let repo = try await TestRepo()
        try repo.write("sub/dir/file.txt", "x\n")
        let repository = try await Repository.open(repo.root.appending(path: "sub/dir"), toolchain: repo.toolchain)
        #expect(repository.kind == .git)
        #expect(repository.root.standardizedFileURL.path == repo.root.standardizedFileURL.path)
    }

    @Test func rejectsNonRepository() async throws {
        let repo = try await TestRepo()
        let outside = repo.directory.appending(path: "home")
        await #expect {
            try await Repository.open(outside, toolchain: repo.toolchain)
        } throws: { error in
            if case RepositoryError.notARepository = error { true } else { false }
        }
    }

    @Test func groupsAndDiffsUncommittedChanges() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        try repo.write("rename-me.txt", "same content\nacross\nlines\n")
        try repo.write("delete-me.txt", "bye\n")
        try await repo.commitAll("init")

        try repo.write("a.txt", "one\nTWO\nthree\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "one\nTWO\nthree\nfour")
        try await repo.git("mv", "rename-me.txt", "renamed.txt")
        try repo.remove("delete-me.txt")
        try repo.write("new dir/untracked.txt", "fresh\n")

        let repository = try await repo.open()
        let groups = try await repository.changeGroups()
        #expect(groups.map(\.kind) == [.staged, .unstaged, .untracked])

        let staged = groups[0].files
        #expect(Set(staged.map(\.path)) == ["a.txt", "renamed.txt"])
        let rename = try #require(staged.first { $0.path == "renamed.txt" })
        #expect(rename.kind == .renamed && rename.previousPath == "rename-me.txt")
        #expect(Set(groups[1].files.map(\.path)) == ["a.txt", "delete-me.txt"])
        #expect(groups[2].files.map(\.path) == ["new dir/untracked.txt"])

        #expect(staged.first { $0.path == "a.txt" }?.stats == LineStats(additions: 1, deletions: 1))
        #expect(groups[1].files.first { $0.path == "a.txt" }?.stats == LineStats(additions: 1, deletions: 0))
        #expect(groups[1].files.first { $0.path == "delete-me.txt" }?.stats == LineStats(additions: 0, deletions: 1))
        #expect(rename.stats == LineStats(additions: 0, deletions: 0))
        #expect(groups[2].files[0].stats == LineStats(additions: 1, deletions: 0))

        // Staged a.txt: only the TWO change.
        let stagedA = try #require(try await repository.diff(for: staged.first { $0.path == "a.txt" }!))
        #expect(stagedA.hunks.flatMap(\.lines).filter { $0.kind != .context }.map(\.text) == ["two", "TWO"])

        // Unstaged a.txt: the appended line without a trailing newline.
        let unstagedA = try #require(try await repository.diff(for: groups[1].files.first { $0.path == "a.txt" }!))
        let added = try #require(unstagedA.hunks.last?.lines.last)
        #expect(added.kind == .addition && added.text == "four" && added.noNewlineAtEnd && added.newLineNumber == 4)

        let renameDiff = try #require(try await repository.diff(for: rename))
        #expect(renameDiff.kind == .renamed && renameDiff.oldPath == "rename-me.txt" && renameDiff.similarity == 100)

        let deleted = try #require(try await repository.diff(for: groups[1].files.first { $0.path == "delete-me.txt" }!))
        #expect(deleted.kind == .deleted)

        let stagedFile = try #require(staged.first { $0.path == "a.txt" })
        let unstagedFile = try #require(groups[1].files.first { $0.path == "a.txt" })
        #expect(try await repository.contents(of: stagedFile, side: .old) == Data("one\ntwo\nthree\n".utf8))
        #expect(try await repository.contents(of: stagedFile, side: .new) == Data("one\nTWO\nthree\n".utf8))
        #expect(try await repository.contents(of: unstagedFile, side: .new) == Data("one\nTWO\nthree\nfour".utf8))
        #expect(try await repository.contents(of: rename, side: .old) == Data("same content\nacross\nlines\n".utf8))
        #expect(try await repository.contents(of: groups[2].files[0], side: .old) == nil)
        #expect(try await repository.contents(of: groups[1].files.first { $0.path == "delete-me.txt" }!, side: .new) == nil)

        let untracked = try #require(try await repository.diff(for: groups[2].files[0]))
        #expect(untracked.kind == .added && untracked.newPath == "new dir/untracked.txt")
        #expect(untracked.hunks.first?.lines.map(\.text) == ["fresh"])
    }

    @Test func diffsCommitsIncludingRoot() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "a\n")
        try repo.write("tool.sh", "echo\n")
        try await repo.commitAll("root")
        let rootSha = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)

        try repo.write("a.txt", "a\nb\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appending(path: "tool.sh").path)
        try await repo.git("mv", "a.txt", "b.txt")
        try repo.write("bin.dat", "\u{0}\u{1}\u{2}binary")
        try await repo.commitAll("second")

        let repository = try await repo.open()
        let rootFiles = try await repository.diff(commit: rootSha)
        #expect(rootFiles.map(\.path) == ["a.txt", "tool.sh"])
        #expect(rootFiles.allSatisfy { $0.kind == .added })

        let files = try await repository.diff(commit: "HEAD")
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(byPath["b.txt"]?.kind == .renamed)
        #expect(byPath["b.txt"]?.oldPath == "a.txt")
        #expect(byPath["bin.dat"]?.isBinary == true)
        #expect(byPath["tool.sh"]?.isModeChange == true)
        #expect(byPath["tool.sh"]?.newMode == "100755")
    }

    @Test func untouchedFileHasNoDiff() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("init")
        let repository = try await repo.open()
        let diff = try await repository.diff(for: ChangedFile(path: "a.txt", kind: .modified, source: .unstaged))
        #expect(diff == nil)
    }
}

@Suite(.enabled(if: Toolchain.locate("but", in: Toolchain.mergedPath(nil, ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())) != nil, "requires the `but` CLI"))
struct GitButlerRepositoryTests {
    @Test func detectsWorkspaceAndReadsChanges() async throws {
        let repo = try await TestRepo(gitButler: true)
        let repository = try await repo.open()
        #expect(repository.kind == .gitButler)

        try repo.write("feature.txt", "one\n")
        try await repo.but("commit", "-b", "feature/one", "-m", "add feature")
        let headCommit = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)

        try repo.write("feature.txt", "one\ntwo\n")
        try repo.write("README.md", "readme\nmore\n")
        try repo.write("brand new.txt", "new\n")

        let status = try await repository.butStatus(includeFiles: true)
        let branch = try #require(status.stacks.flatMap(\.branches).first { $0.name == "feature/one" })
        let commit = try #require(branch.commits.first)
        #expect(commit.summary == "add feature")
        #expect(commit.changes?.map(\.filePath) == ["feature.txt"])

        let groups = try await repository.changeGroups()
        #expect(groups.first?.kind == .unassigned)
        #expect(groups.contains { if case .stack(_, let branches) = $0.kind { branches == ["feature/one"] } else { false } })
        let unassigned = try #require(groups.first).files
        #expect(Set(unassigned.map(\.path)) == ["feature.txt", "README.md", "brand new.txt"])
        #expect(unassigned.allSatisfy { $0.source == .workspace })
        #expect(unassigned.first { $0.path == "feature.txt" }?.stats == LineStats(additions: 1, deletions: 0))
        #expect(unassigned.first { $0.path == "brand new.txt" }?.stats == LineStats(additions: 1, deletions: 0))

        // Workspace diffs are against the workspace commit, so the branch's committed line is context.
        let feature = try #require(try await repository.diff(for: unassigned.first { $0.path == "feature.txt" }!))
        #expect(feature.hunks.flatMap(\.lines).map(\.kind) == [.context, .addition])
        #expect(feature.hunks.flatMap(\.lines).map(\.text) == ["one", "two"])

        let untracked = try #require(try await repository.diff(for: unassigned.first { $0.path == "brand new.txt" }!))
        #expect(untracked.kind == .added && untracked.hunks.first?.lines.map(\.text) == ["new"])

        let commitFiles = try await repository.diff(commit: commit.commitId)
        #expect(commitFiles.map(\.path) == ["feature.txt"])
        #expect(commitFiles.first?.kind == .added)
        // HEAD is the workspace commit, or since 0.23 the only applied branch itself; either holds the commit.
        let ancestry = try await repo.toolchain.git(
            ["merge-base", "--is-ancestor", commit.commitId, headCommit], in: repo.root, allowedExitCodes: [0, 1])
        #expect(ancestry.exitCode == 0)
    }

    @Test func plainRepoWithButInstalledIsGit() async throws {
        let repo = try await TestRepo()
        let kind = try await repo.open().kind
        #expect(kind == .git)
    }
}
