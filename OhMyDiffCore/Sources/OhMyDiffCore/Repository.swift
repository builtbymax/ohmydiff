import Foundation

public enum RepositoryKind: Sendable, Hashable {
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
        switch kind {
        case .git:
            Self.gitChangeGroups(try await gitStatus())
        case .gitButler:
            Self.butChangeGroups(try await butStatus(), gitStatus: try await gitStatus())
        }
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
