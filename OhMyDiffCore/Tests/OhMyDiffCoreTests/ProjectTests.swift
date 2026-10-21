import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ProjectStoreTests {
    @Test func roundTripsProjects() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(fileURL: directory.appending(path: "nested/projects.json"))

        #expect(try store.load() == ProjectList())

        let workspace = Workspace(name: "Work", color: .greenery)
        let list = ProjectList(projects: [
            Project(path: "/Users/me/code/app", workspaceID: workspace.id, lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            Project(path: "/Users/me/code/lib", displayName: "Library", kind: .gitButler, workspaceID: workspace.id),
        ], workspaces: [workspace])
        try store.save(list)
        let loaded = try store.load()
        #expect(loaded == list)
        #expect(loaded.projects[0].displayName == "app")

        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"kind\" : \"gitButler\""))
        #expect(json.contains("\"path\" : \"/Users/me/code/lib\""))
        #expect(json.contains("\"version\" : 2"))
    }

    @Test func movesVersionOneListsIntoOneWorkspace() throws {
        let json = """
        {"version": 1, "projects": [
          {"id": "\(UUID())", "path": "/a", "displayName": "a", "kind": "git"},
          {"id": "\(UUID())", "path": "/b", "displayName": "b", "kind": "git"}
        ]}
        """
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(fileURL: directory.appending(path: "projects.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)

        var list = try store.load()
        #expect(list.workspaces.isEmpty)
        let changed = list.assignWorkspaces()
        #expect(changed)
        #expect(list.workspaces.map(\.name) == [Workspace.defaultName])
        #expect(list.projects.allSatisfy { $0.workspaceID == list.workspaces[0].id })
        let changedAgain = list.assignWorkspaces()
        #expect(!changedAgain)
    }

    @Test func movesProjectsOfUnknownWorkspacesIntoTheFirst() {
        let first = Workspace(name: "One", color: .emerald)
        let second = Workspace(name: "Two", color: .mimosa)
        var list = ProjectList(projects: [
            Project(path: "/a", workspaceID: second.id),
            Project(path: "/b", workspaceID: UUID()),
        ], workspaces: [first, second])
        let changed = list.assignWorkspaces()
        #expect(changed)
        #expect(list.projects.map(\.workspaceID) == [second.id, first.id])
    }

    @Test func listsAWorkspaceMostRecentlyOpenedFirst() {
        let workspace = UUID()
        let projects = [
            Project(path: "/never", workspaceID: workspace),
            Project(path: "/old", workspaceID: workspace, lastOpenedAt: Date(timeIntervalSince1970: 100)),
            Project(path: "/elsewhere", workspaceID: UUID(), lastOpenedAt: Date(timeIntervalSince1970: 300)),
            Project(path: "/new", workspaceID: workspace, lastOpenedAt: Date(timeIntervalSince1970: 200)),
            Project(path: "/never-either", workspaceID: workspace),
        ]
        #expect(projects.inWorkspace(workspace).map(\.path) == ["/new", "/old", "/never", "/never-either"])
    }

    @Test func decodesListsWithoutOrWithUnknownColors() throws {
        let id = UUID()
        let json = """
        {"version": 1, "projects": [
          {"id": "\(id)", "path": "/a", "displayName": "a", "kind": "git"},
          {"id": "\(UUID())", "path": "/b", "displayName": "b", "kind": "git", "color": "notAColor"},
          {"id": "\(UUID())", "path": "/c", "displayName": "c", "kind": "git", "color": "greenery"}
        ]}
        """
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(fileURL: directory.appending(path: "projects.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load().projects
        #expect(loaded.map(\.color) == [nil, nil, .greenery])
        #expect(loaded[0].id == id)
    }

    @Test func detectsMissingFolder() {
        #expect(Project(path: NSTemporaryDirectory()).exists)
        #expect(!Project(path: "/nonexistent/ohmydiff/\(UUID().uuidString)").exists)
    }

    @Test func findsTheProjectContainingAFolderWithoutGit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-containing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "app")
        for folder in ["app/.git", "app/Sources/Views", "app/vendor/lib/.git", "other"] {
            try FileManager.default.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        let project = Project(path: root.resolvingSymlinksInPath().path)

        // `root` is under /var, a symlink to the project's /private/var.
        #expect(Project.containing(root, in: [project]) == project)
        #expect(Project.containing(root.appending(path: "Sources/Views"), in: [project]) == project)
        #expect(Project.containing(URL(fileURLWithPath: root.path + "/Sources/../Sources"), in: [project]) == project)
        // A repository nested inside the project is another one.
        #expect(Project.containing(root.appending(path: "vendor/lib"), in: [project]) == nil)
        #expect(Project.containing(directory.appending(path: "other"), in: [project]) == nil)
        #expect(Project.containing(URL(fileURLWithPath: "/"), in: [project]) == nil)
    }
}

@Suite struct ProjectColorTests {
    @Test func avoidsColorsInUse() {
        var generator = SystemRandomNumberGenerator()
        let taken = Array(ProjectColor.allCases.dropLast())
        for _ in 0..<20 {
            #expect(ProjectColor.pick(avoiding: taken, using: &generator) == ProjectColor.allCases.last)
        }
    }

    @Test func reusesTheLeastUsedOnceAllAreTaken() {
        var generator = SystemRandomNumberGenerator()
        let taken = ProjectColor.allCases + ProjectColor.allCases.filter { $0 != .emerald }
        #expect(ProjectColor.pick(avoiding: taken, using: &generator) == .emerald)
    }

    @Test func assignsDistinctColorsToProjectsWithout() {
        var projects = (0..<ProjectColor.allCases.count).map { Project(path: "/p\($0)") }
        projects[0].color = .mimosa
        let changed = projects.assignMissingColors()
        #expect(changed)
        #expect(Set(projects.compactMap(\.color)).count == ProjectColor.allCases.count)
        #expect(projects[0].color == .mimosa)
        let changedAgain = projects.assignMissingColors()
        #expect(!changedAgain)
    }

    @Test func namesAndContrast() {
        #expect(ProjectColor.classicBlue.name == "Classic Blue")
        #expect(ProjectColor.tangerineTango.name == "Tangerine Tango")
        #expect(ProjectColor.illuminating.isLight)
        #expect(!ProjectColor.classicBlue.isLight)
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
