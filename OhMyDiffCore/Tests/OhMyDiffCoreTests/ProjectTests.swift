import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ProjectStoreTests {
    @Test func roundTripsProjects() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(fileURL: directory.appending(path: "nested/projects.json"))

        #expect(try store.load().isEmpty)

        let projects = [
            Project(path: "/Users/me/code/app"),
            Project(path: "/Users/me/code/lib", displayName: "Library", kind: .gitButler),
        ]
        try store.save(projects)
        let loaded = try store.load()
        #expect(loaded == projects)
        #expect(loaded[0].displayName == "app")

        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"kind\" : \"gitButler\""))
        #expect(json.contains("\"path\" : \"/Users/me/code/lib\""))
    }

    @Test func detectsMissingFolder() {
        #expect(Project(path: NSTemporaryDirectory()).exists)
        #expect(!Project(path: "/nonexistent/ohmydiff/\(UUID().uuidString)").exists)
    }
}

@Suite struct FuzzyMatcherTests {
    @Test func matchesSubsequencesCaseInsensitively() {
        #expect(FuzzyMatcher.match("omd", in: "OhMyDiff") != nil)
        #expect(FuzzyMatcher.match("OMD", in: "ohmydiff") != nil)
        #expect(FuzzyMatcher.match("dmo", in: "ohmydiff") == nil)
        #expect(FuzzyMatcher.match("toolong", in: "tool") == nil)
        #expect(FuzzyMatcher.match("", in: "anything")?.score == 0)
        #expect(FuzzyMatcher.match("oh my", in: "ohmydiff") != nil)
    }

    @Test func prefersWordStartsAndPrefixes() throws {
        let match = try #require(FuzzyMatcher.match("md", in: "ohMyDiff"))
        #expect(match.indices == [2, 4])

        let ranked = FuzzyMatcher.rank(["halftime", "family", "ohmydiff", "wonders"], query: "fa") { $0 }
        #expect(ranked.first?.item == "family")

        let byPrefix = FuzzyMatcher.rank(["my-diff-tool", "diff"], query: "diff") { $0 }
        #expect(byPrefix.map(\.item) == ["diff", "my-diff-tool"])
    }

    @Test func keepsOrderForTiesAndDropsNonMatches() {
        let ranked = FuzzyMatcher.rank(["b", "a", "c"], query: "") { $0 }
        #expect(ranked.map(\.item) == ["b", "a", "c"])
        #expect(FuzzyMatcher.rank(["abc", "xyz"], query: "q") { $0 }.isEmpty)
    }

    @Test func backtracksFromWordStartWhenNeeded() throws {
        // Jumping to the word start `B` for "b" would leave no room for the trailing "x".
        let match = try #require(FuzzyMatcher.match("bx", in: "abx-B"))
        #expect(match.indices == [1, 2])
    }
}

@Suite struct WatchFilterTests {
    private let filter = WatchFilter(root: "/repo/", gitDirectories: ["/repo/.git"])

    @Test func classifiesGitMetadata() {
        for path in ["/repo/.git/HEAD", "/repo/.git/index", "/repo/.git/refs/heads/main", "/repo/.git/packed-refs",
                     "/repo/.git/gitbutler/virtual_branches.toml", "/repo/.git/gitbutler/but.sqlite",
                     "/repo/.git/rebase-merge/done"] {
            #expect(filter.classify(path) == .gitMetadata, "\(path)")
        }
    }

    @Test func ignoresGitNoise() {
        for path in ["/repo/.git/objects/ab/cdef", "/repo/.git/logs/HEAD", "/repo/.git/index.lock",
                     "/repo/.git/gitbutler/gitbutler.write-lock", "/repo/.git/gitbutler/but.sqlite-wal",
                     "/repo/.git/gitbutler/but.sqlite-shm", "/repo/.git/FETCH_HEAD", "/repo/.git",
                     "/repo/.git/refs/heads/main.lock"] {
            #expect(filter.classify(path) == .irrelevant, "\(path)")
        }
    }

    @Test func classifiesWorktreePaths() {
        #expect(filter.classify("/repo/src/main.swift") == .worktree("src/main.swift"))
        #expect(filter.classify("/repo/sub/.git/HEAD") == .irrelevant)
        #expect(filter.classify("/repo") == .irrelevant)
        #expect(filter.classify("/repository/file") == .irrelevant)
        #expect(filter.classify("/elsewhere/file") == .irrelevant)
    }

    @Test func handlesLinkedWorktreesAndPrivateAliases() {
        let linked = WatchFilter(root: "/tmp/wt", gitDirectories: ["/tmp/main/.git/worktrees/wt", "/tmp/main/.git"])
        #expect(linked.classify("/private/tmp/main/.git/worktrees/wt/HEAD") == .gitMetadata)
        #expect(linked.classify("/private/tmp/main/.git/worktrees/wt/logs/HEAD") == .irrelevant)
        #expect(linked.classify("/private/tmp/main/.git/refs/heads/x") == .gitMetadata)
        #expect(linked.classify("/private/tmp/wt/a.txt") == .worktree("a.txt"))
    }
}

@Suite struct FileWatcherTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ohmydiff-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory.appending(path: ".git/objects"), withIntermediateDirectories: true)
        return directory
    }

    /// Returns the next batch, or `nil` after `timeout`.
    private func nextBatch(_ watcher: FileWatcher, timeout: Duration = .seconds(3)) async -> WatchBatch? {
        await withTaskGroup(of: WatchBatch?.self) { group in
            group.addTask {
                var iterator = watcher.batches.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func reportsDebouncedWorktreeAndGitChanges() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = FileWatcher(filter: WatchFilter(root: directory.path, gitDirectories: [directory.appending(path: ".git").path]))
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // Several writes in quick succession arrive as one batch.
        try Data("a".utf8).write(to: directory.appending(path: "a.txt"))
        try Data("b".utf8).write(to: directory.appending(path: "b.txt"))
        try Data("noise".utf8).write(to: directory.appending(path: ".git/objects/blob"))
        try Data("ref".utf8).write(to: directory.appending(path: ".git/HEAD"))

        let batch = try #require(await nextBatch(watcher))
        #expect(batch.worktreePaths.isSuperset(of: ["a.txt", "b.txt"]))
        #expect(batch.gitMetadataChanged)
        #expect(!batch.worktreePaths.contains { $0.hasPrefix(".git") })
    }

    @Test func ignoresObjectNoise() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = FileWatcher(filter: WatchFilter(root: directory.path, gitDirectories: [directory.appending(path: ".git").path]))
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try Data("noise".utf8).write(to: directory.appending(path: ".git/objects/blob"))
        try Data("lock".utf8).write(to: directory.appending(path: ".git/index.lock"))
        #expect(await nextBatch(watcher, timeout: .milliseconds(800)) == nil)
    }

    @Test func reportsRootRemoval() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = FileWatcher(filter: WatchFilter(root: directory.path, gitDirectories: [directory.appending(path: ".git").path]))
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let moved = directory.deletingLastPathComponent().appending(path: directory.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }

        let batch = try #require(await nextBatch(watcher))
        #expect(batch.rootChanged)
    }
}

@Suite struct IgnoredPathTests {
    @Test func filtersGitignoredPaths() async throws {
        let repo = try await TestRepo()
        try repo.write(".gitignore", "build/\n*.log\n")
        try repo.write("tracked.log", "x\n")
        try await repo.git("add", "-f", ".gitignore", "tracked.log")
        let repository = try await repo.open()

        let ignored = try await repository.ignoredPaths(["build/out.o", "src/a.swift", "debug.log", "tracked.log", "dir with space/x.log"])
        #expect(ignored == ["build/out.o", "debug.log", "dir with space/x.log"])
        #expect(try await repository.ignoredPaths([]).isEmpty)
    }

    @Test func reportsGitDirectories() async throws {
        let repo = try await TestRepo()
        let repository = try await repo.open()
        let directories = try await repository.gitDirectories()
        #expect(directories.gitDir.standardizedFileURL == repo.root.appending(path: ".git").standardizedFileURL)
        #expect(directories.commonDir.standardizedFileURL == directories.gitDir.standardizedFileURL)
    }
}
