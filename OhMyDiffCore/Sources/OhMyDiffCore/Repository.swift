import Foundation

public enum RepositoryKind: String, Sendable, Hashable, Codable {
    case git
    case gitButler
}

public enum RepositoryError: Error, Sendable, CustomStringConvertible {
    case notARepository(String)
    case notGitButler

    public var description: String {
        switch self {
        case .notARepository(let path): "\(path) is not inside a git repository"
        case .notGitButler: "the repository is not a GitButler workspace"
        }
    }
}

/// Read-only access to a project: its kind, uncommitted change groups and parsed diffs.
public struct Repository: Sendable {
    /// The worktree root.
    public let root: URL
    public let kind: RepositoryKind
    public let toolchain: Toolchain
    /// Set when the folder is a GitButler workspace but the installed `but` is not supported, so
    /// `kind` fell back to plain git.
    public let butIncompatibility: ButIncompatibility?
    /// Set when the folder is a GitButler workspace shown as one, but the installed `but` is not the
    /// release ohmydiff was tested against.
    public let butVersionMismatch: ButVersionMismatch?

    public init(
        root: URL, kind: RepositoryKind, toolchain: Toolchain,
        butIncompatibility: ButIncompatibility? = nil, butVersionMismatch: ButVersionMismatch? = nil
    ) {
        self.root = root
        self.kind = kind
        self.toolchain = toolchain
        self.butIncompatibility = butIncompatibility
        self.butVersionMismatch = butVersionMismatch
    }

    /// Resolves the repository containing `path` and detects whether it is a GitButler workspace.
    public static func open(_ path: URL, toolchain: Toolchain) async throws -> Repository {
        let root: URL
        do {
            let output = try await toolchain.git(["rev-parse", "--show-toplevel"], in: path)
            root = URL(fileURLWithPath: output.stdoutString.trimmingCharacters(in: .newlines), isDirectory: true)
        } catch let error as ProcessError {
            if case .nonZeroExit = error { throw RepositoryError.notARepository(path.path) }
            throw error
        }
        let detected = await detectKind(root: root, toolchain: toolchain)
        return Repository(
            root: root, kind: detected.kind, toolchain: toolchain,
            butIncompatibility: detected.incompatibility, butVersionMismatch: detected.mismatch)
    }

    /// GitButler when `<git-common-dir>/gitbutler` exists and `but --json status` succeeds; plain git otherwise.
    /// A `but` release newer than the known-good one must also pass `ButContract`, or the workspace is
    /// shown as plain git with the reason. A GitButler workspace on any release but the known-good one
    /// gets a `mismatch`.
    public static func detectKind(root: URL, toolchain: Toolchain) async
        -> (kind: RepositoryKind, incompatibility: ButIncompatibility?, mismatch: ButVersionMismatch?)
    {
        guard toolchain.but != nil,
              let output = try? await toolchain.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
        else { return (.git, nil, nil) }

        let commonDir = URL(fileURLWithPath: output.stdoutString.trimmingCharacters(in: .newlines), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: commonDir.appending(path: "gitbutler").path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return (.git, nil, nil) }

        guard let status = try? await toolchain.but(["--json", "status"], in: root) else { return (.git, nil, nil) }
        let version = await ButCompatibility.version(of: toolchain)
        if let incompatibility = ButCompatibility.check(status: status.stdout, version: version) {
            return (.git, incompatibility, nil)
        }
        return (.gitButler, nil, ButCompatibility.mismatch(version: version))
    }

    // MARK: - Status

    /// Parsed `git status --porcelain=v2`, including every untracked file.
    public func gitStatus() async throws -> [StatusEntry] {
        let output = try await toolchain.git(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: root)
        return PorcelainStatusParser.parse(output.stdout)
    }

    /// Parsed `but --json status`; `includeFiles` adds each commit's changed files.
    public func butStatus(includeFiles: Bool = false) async throws -> ButStatus {
        guard kind == .gitButler else { throw RepositoryError.notGitButler }
        let output = try await toolchain.but(["--json", "status"] + (includeFiles ? ["-f"] : []), in: root)
        return try ButStatus.decode(output.stdout)
    }

    /// Uncommitted changes grouped the way the project's kind presents them.
    public func changeGroups() async throws -> [ChangeGroup] {
        let groups: [ChangeGroup]
        switch kind {
        case .git:
            groups = Self.gitChangeGroups(try await gitStatus())
        case .gitButler:
            // Independent reads; `but status` is the slow one, so `git status` runs alongside it.
            async let butStatus = butStatus()
            async let gitStatus = gitStatus()
            let status = try await gitStatus
            groups = try await addingWorktreeRenames(to: Self.butChangeGroups(try await butStatus, gitStatus: status), gitStatus: status)
        }
        return try await addingStats(to: groups)
    }

    /// GitButler: fills in the source path and line counts of files moved but not staged, which `but` reports as
    /// renamed without a source, and git only as a deletion plus an untracked file.
    private func addingWorktreeRenames(to groups: [ChangeGroup], gitStatus: [StatusEntry]) async throws -> [ChangeGroup] {
        let moved = groups.flatMap(\.files).filter { $0.kind == .renamed && $0.previousPath == nil }.map(\.path)
        let deleted = gitStatus.filter { $0.kind == .ordinary && ($0.worktreeStatus == "D" || $0.indexStatus == "D") }.map(\.path)
        guard !moved.isEmpty, !deleted.isEmpty else { return groups }

        let paths = moved + deleted
        let names = try await worktreeDiff(["-M", "--name-status", "-z"], paths: paths)
        let tokens = names.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var sources: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            // `R<score>` and `C<score>` are followed by the old and new paths, everything else by one path.
            if tokens[index].hasPrefix("R") || tokens[index].hasPrefix("C"), index + 2 < tokens.count {
                sources[tokens[index + 2]] = tokens[index + 1]
                index += 3
            } else {
                index += 2
            }
        }
        let stats = NumstatParser.parse(try await worktreeDiff(Self.diffOptions + ["--numstat", "-z"], paths: paths))

        return groups.map { group in
            var group = group
            for index in group.files.indices where group.files[index].previousPath == nil {
                let path = group.files[index].path
                guard let source = sources[path] else { continue }
                group.files[index].previousPath = source
                group.files[index].stats = stats[path]
            }
            return group
        }
    }

    /// `git diff --cached HEAD` against a temporary index that holds HEAD plus the worktree state of `paths`, as if they
    /// were added, so git pairs a deleted and an untracked file as a rename. The real index is not touched.
    func worktreeDiff(_ options: [String], paths: [String]) async throws -> Data {
        let index = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let temporary = ["GIT_INDEX_FILE": index.path]
        _ = try await toolchain.git(["read-tree", "HEAD"], in: root, environment: temporary)
        _ = try await toolchain.git(["add", "-A", "--"] + paths, in: root, environment: temporary)
        return try await toolchain.git(["diff", "--cached", "HEAD"] + options + ["--"] + paths, in: root, environment: temporary).stdout
    }

    /// Fills in each file's line counts with one `--numstat` run per diff the groups draw from.
    private func addingStats(to groups: [ChangeGroup]) async throws -> [ChangeGroup] {
        // The `--numstat` runs are independent, so they run at once.
        let stats = try await withThrowingTaskGroup(of: (ChangeSource, [String: LineStats]).self) { tasks in
            for source in Set(groups.flatMap { $0.files.map(\.source) }) {
                let base: [String]
                switch source {
                case .staged: base = ["diff", "--cached"]
                case .unstaged: base = ["diff"]
                case .workspace: base = ["diff", "HEAD"]
                case .untracked, .conflicted: continue
                }
                tasks.addTask {
                    let output = try await toolchain.git(base + Self.diffOptions + ["--numstat", "-z"], in: root)
                    return (source, NumstatParser.parse(output.stdout))
                }
            }
            var stats: [ChangeSource: [String: LineStats]] = [:]
            for try await (source, parsed) in tasks { stats[source] = parsed }
            return stats
        }

        return groups.map { group in
            var group = group
            for index in group.files.indices {
                let file = group.files[index]
                // Untracked files are absent from every diff against the index or HEAD; unstaged GitButler moves
                // already have theirs.
                group.files[index].stats = stats[file.source]?[file.path] ?? file.stats
                    ?? (file.kind == .untracked || file.kind == .added ? Self.addedLineStats(root.appending(path: file.path)) : nil)
            }
            return group
        }
    }

    /// Only files up to this size are read to count the lines of untracked files.
    private static let lineCountLimit = 8 << 20

    /// Counts a new file's lines; `nil` for binary, unreadable or very large files.
    static func addedLineStats(_ url: URL) -> LineStats? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= lineCountLimit,
              let data = try? Data(contentsOf: url)
        else { return nil }
        // Same heuristic as git: a NUL byte in the first 8000 bytes marks the file as binary.
        guard !data.prefix(8000).contains(0) else { return nil }
        var lines = data.count { $0 == UInt8(ascii: "\n") }
        if let last = data.last, last != UInt8(ascii: "\n") { lines += 1 }
        return LineStats(additions: lines, deletions: 0)
    }

    static func gitChangeGroups(_ entries: [StatusEntry]) -> [ChangeGroup] {
        var staged: [ChangedFile] = []
        var unstaged: [ChangedFile] = []
        var untracked: [ChangedFile] = []
        var conflicted: [ChangedFile] = []

        for entry in entries {
            switch entry.kind {
            case .untracked:
                untracked.append(ChangedFile(path: entry.path, kind: .untracked, source: .untracked))
            case .unmerged:
                conflicted.append(ChangedFile(path: entry.path, kind: .conflicted, source: .conflicted))
            case .ignored:
                continue
            case .ordinary, .renamed, .copied:
                if entry.isStaged {
                    staged.append(ChangedFile(
                        path: entry.path, previousPath: entry.originalPath,
                        kind: StatusEntry.changeKind(for: entry.indexStatus), source: .staged))
                }
                if entry.isUnstaged {
                    unstaged.append(ChangedFile(
                        path: entry.path, kind: StatusEntry.changeKind(for: entry.worktreeStatus), source: .unstaged))
                }
            }
        }

        return [
            ChangeGroup(kind: .conflicted, title: "Conflicted", files: conflicted),
            ChangeGroup(kind: .staged, title: "Staged", files: staged),
            ChangeGroup(kind: .unstaged, title: "Unstaged", files: unstaged),
            ChangeGroup(kind: .untracked, title: "Untracked", files: untracked),
        ].filter { !$0.files.isEmpty }
    }

    static func butChangeGroups(_ status: ButStatus, gitStatus: [StatusEntry]) -> [ChangeGroup] {
        // `but` reports renames without their source path; take it from git when the index knows it.
        let origins = Dictionary(
            gitStatus.compactMap { entry in entry.originalPath.map { (entry.path, $0) } },
            uniquingKeysWith: { first, _ in first })

        func files(_ changes: [ButChange]) -> [ChangedFile] {
            changes.map { change in
                ChangedFile(
                    path: change.filePath, previousPath: origins[change.filePath],
                    kind: change.kind, source: .workspace)
            }
        }

        var groups = [ChangeGroup(kind: .unassigned, title: "Unassigned", files: files(status.unassignedChanges))]
        for stack in status.stacks {
            let branches = stack.branches.map(\.name)
            groups.append(ChangeGroup(
                kind: .stack(id: stack.id, branches: branches),
                title: branches.first ?? stack.id,
                files: files(stack.assignedChanges)))
        }
        return groups
    }

    // MARK: - Metadata

    /// The worktree's git dir and the shared common dir; they differ for linked worktrees.
    public func gitDirectories() async throws -> (gitDir: URL, commonDir: URL) {
        let output = try await toolchain.git(
            ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: root)
        let lines = output.stdoutString.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { throw RepositoryError.notARepository(root.path) }
        return (URL(fileURLWithPath: lines[0], isDirectory: true), URL(fileURLWithPath: lines[1], isDirectory: true))
    }

    /// The subset of worktree-relative `paths` that `.gitignore` rules exclude (tracked files never count as ignored).
    public func ignoredPaths(_ paths: [String]) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        // `check-ignore` refuses literal pathspecs; the `./` prefix keeps a leading `:` from reading as magic
        // instead. It only tests each path itself, so globs in names match nothing else.
        let input = Data(paths.map { "./" + $0 }.joined(separator: "\0").utf8 + [0])
        // Exits 0 when something matched and 1 when nothing did.
        let output = try await toolchain.git(
            ["check-ignore", "-z", "--stdin"], in: root, allowedExitCodes: [0, 1], input: input,
            environment: ["GIT_LITERAL_PATHSPECS": "0"])
        return Set(output.stdout.split(separator: 0).map { String(decoding: $0.dropFirst(2), as: UTF8.self) })
    }

    // MARK: - Diffs

    /// Context is pinned, so `diff.context` / `diff.interHunkContext` in the user's config cannot make hunks differ
    /// from the ones `but` reports, which GitButler hunk actions are matched against.
    static let diffOptions = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-M", "-U3", "--inter-hunk-context=0"]

    /// The parsed diff of one uncommitted file, or `nil` if it no longer differs.
    public func diff(for file: ChangedFile) async throws -> FileDiff? {
        let paths = [file.path] + (file.previousPath.map { [$0] } ?? [])
        let arguments: [String]
        switch file.source {
        case .staged:
            arguments = ["diff", "--cached"] + Self.diffOptions + ["--"] + paths
        case .unstaged, .conflicted:
            arguments = ["diff"] + Self.diffOptions + ["--"] + paths
        case .untracked:
            return try await untrackedDiff(file.path)
        case .workspace:
            // HEAD is the GitButler workspace commit, or since 0.23 the tip of the only applied branch,
            // so this covers every applied branch.
            arguments = ["diff", "HEAD"] + Self.diffOptions + ["--"] + paths
        }

        // A move GitButler left unstaged: the new path is untracked, so plain `git diff HEAD` only sees the deletion.
        var isUnstagedMove = false
        if file.source == .workspace, file.previousPath != nil { isUnstagedMove = try await isUntracked(file.path) }
        let output = isUnstagedMove
            ? try await worktreeDiff(Self.diffOptions, paths: paths)
            : try await toolchain.git(arguments, in: root).stdout
        if let parsed = UnifiedDiffParser.parse(output).first(where: { $0.newPath == file.path || $0.oldPath == file.path }) {
            return parsed
        }
        if file.source == .workspace, try await isUntracked(file.path) {
            return try await untrackedDiff(file.path)
        }
        return nil
    }

    /// The parsed diff a commit introduces relative to its first parent (or the empty tree for a root commit).
    public func diff(commit: String) async throws -> [FileDiff] {
        let tree = try await tree(of: commit)
        if tree != commit {
            // A conflicted GitButler commit: its checked-out tree against its parent's.
            return try await diff(from: "\(commit)^", to: commit)
        }
        let arguments = ["diff-tree", "-p", "-r", "--root", "--no-commit-id", "-m", "--first-parent"]
            + Self.diffOptions + [commit]
        let output = try await toolchain.git(arguments, in: root)
        return UnifiedDiffParser.parse(output.stdout)
    }

    public enum FileSide: Sendable {
        /// Before the change: HEAD for staged and workspace changes, the index for unstaged ones.
        case old
        /// After the change: the index for staged changes, the worktree otherwise.
        case new
    }

    /// The full contents of one side of an uncommitted change, or `nil` when that side does not exist
    /// (e.g. the old side of an added file) or is larger than `limit` bytes.
    public func contents(of file: ChangedFile, side: FileSide, limit: Int = 16 << 20) async throws -> Data? {
        let blob: String?
        switch (file.source, side) {
        case (.staged, .old), (.workspace, .old):
            blob = "HEAD:" + (file.previousPath ?? file.path)
        case (.unstaged, .old), (.conflicted, .old), (.staged, .new):
            blob = ":" + file.path
        case (.untracked, .old):
            return nil
        case (.unstaged, .new), (.conflicted, .new), (.untracked, .new), (.workspace, .new):
            blob = nil
        }

        guard let blob else {
            let url = root.appending(path: file.path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { return nil }
            return try? Data(contentsOf: url)
        }
        return try await self.blob(blob, limit: limit)
    }

    /// The object `spec` names (e.g. `HEAD:path`), or `nil` when it does not exist or is larger than `limit` bytes.
    func blob(_ spec: String, limit: Int) async throws -> Data? {
        // `cat-file -s` fails with 128 when the object does not exist, e.g. for an added file.
        let sizeOutput = try await toolchain.git(["cat-file", "-s", spec], in: root, allowedExitCodes: [0, 128])
        guard sizeOutput.exitCode == 0,
              let size = Int(sizeOutput.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)), size <= limit
        else { return nil }
        return try await toolchain.git(["cat-file", "blob", spec], in: root).stdout
    }

    private func isUntracked(_ path: String) async throws -> Bool {
        let output = try await toolchain.git(["ls-files", "--others", "--exclude-standard", "-z", "--", path], in: root)
        return !output.stdout.isEmpty
    }

    private func untrackedDiff(_ path: String) async throws -> FileDiff? {
        // `--no-index` exits with 1 when the files differ.
        let output = try await toolchain.git(
            ["diff", "--no-index"] + Self.diffOptions + ["--", "/dev/null", path],
            in: root, allowedExitCodes: [0, 1])
        guard var file = UnifiedDiffParser.parse(output.stdout).first else { return nil }
        file.kind = .added
        file.oldPath = nil
        file.newPath = path
        return file
    }
}
