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

    public init(root: URL, kind: RepositoryKind, toolchain: Toolchain) {
        self.root = root
        self.kind = kind
        self.toolchain = toolchain
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
        let kind = await detectKind(root: root, toolchain: toolchain)
        return Repository(root: root, kind: kind, toolchain: toolchain)
    }

    /// GitButler when `<git-common-dir>/gitbutler` exists and `but --json status` succeeds; plain git otherwise.
    public static func detectKind(root: URL, toolchain: Toolchain) async -> RepositoryKind {
        guard toolchain.but != nil,
              let output = try? await toolchain.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
        else { return .git }

        let commonDir = URL(fileURLWithPath: output.stdoutString.trimmingCharacters(in: .newlines), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: commonDir.appending(path: "gitbutler").path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .git }

        guard (try? await toolchain.but(["--json", "status"], in: root)) != nil else { return .git }
        return .gitButler
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
        let groups = switch kind {
        case .git:
            Self.gitChangeGroups(try await gitStatus())
        case .gitButler:
            Self.butChangeGroups(try await butStatus(), gitStatus: try await gitStatus())
        }
        return try await addingStats(to: groups)
    }

    /// Fills in each file's line counts with one `--numstat` run per diff the groups draw from.
    private func addingStats(to groups: [ChangeGroup]) async throws -> [ChangeGroup] {
        var stats: [ChangeSource: [String: LineStats]] = [:]
        for source in Set(groups.flatMap { $0.files.map(\.source) }) {
            let base: [String]
            switch source {
            case .staged: base = ["diff", "--cached"]
            case .unstaged: base = ["diff"]
            case .workspace: base = ["diff", "HEAD"]
            case .untracked, .conflicted: continue
            }
            let output = try await toolchain.git(base + Self.diffOptions + ["--numstat", "-z"], in: root)
            stats[source] = NumstatParser.parse(output.stdout)
        }

        return groups.map { group in
            var group = group
            for index in group.files.indices {
                let file = group.files[index]
                // Untracked files are absent from every diff against the index or HEAD.
                group.files[index].stats = stats[file.source]?[file.path]
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
        let input = Data(paths.joined(separator: "\0").utf8 + [0])
        // Exits 0 when something matched and 1 when nothing did.
        let output = try await toolchain.git(
            ["check-ignore", "-z", "--stdin"], in: root, allowedExitCodes: [0, 1], input: input)
        return Set(output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    // MARK: - Diffs

    private static let diffOptions = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-M"]

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
            // HEAD is the GitButler workspace commit, so this covers every applied branch.
            arguments = ["diff", "HEAD"] + Self.diffOptions + ["--"] + paths
        }

        let output = try await toolchain.git(arguments, in: root)
        if let parsed = UnifiedDiffParser.parse(output.stdout).first(where: { $0.newPath == file.path || $0.oldPath == file.path }) {
            return parsed
        }
        if file.source == .workspace, try await isUntracked(file.path) {
            return try await untrackedDiff(file.path)
        }
        return nil
    }

    /// The parsed diff a commit introduces relative to its first parent (or the empty tree for a root commit).
    public func diff(commit: String) async throws -> [FileDiff] {
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
        // `cat-file -s` fails with 128 when the object does not exist, e.g. for an added file.
        let sizeOutput = try await toolchain.git(["cat-file", "-s", blob], in: root, allowedExitCodes: [0, 128])
        guard sizeOutput.exitCode == 0,
              let size = Int(sizeOutput.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)), size <= limit
        else { return nil }
        return try await toolchain.git(["cat-file", "blob", blob], in: root).stdout
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
