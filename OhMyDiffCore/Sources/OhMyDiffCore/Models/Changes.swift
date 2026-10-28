/// Which diff an uncommitted file belongs to, which decides how its patch is produced.
public enum ChangeSource: Sendable, Hashable {
    /// Index vs. HEAD (plain git).
    case staged
    /// Worktree vs. index (plain git).
    case unstaged
    /// Not tracked by git.
    case untracked
    /// Unmerged path during a merge or rebase.
    case conflicted
    /// Worktree vs. HEAD: the GitButler workspace commit, or the only applied branch.
    case workspace
}

/// Added and removed line counts of one file.
public struct LineStats: Sendable, Hashable {
    public var additions: Int
    public var deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }
}

/// An uncommitted file as listed in a change group.
public struct ChangedFile: Sendable, Hashable, Identifiable {
    public var path: String
    /// Source path when the file was renamed or copied.
    public var previousPath: String?
    public var kind: FileChangeKind
    public var source: ChangeSource
    /// Line counts; `nil` for binary files or when they could not be determined.
    public var stats: LineStats?

    public init(path: String, previousPath: String? = nil, kind: FileChangeKind, source: ChangeSource, stats: LineStats? = nil) {
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.source = source
        self.stats = stats
    }

    public var id: String { "\(source):\(path)" }
}

/// A titled list of uncommitted files: staged/unstaged/untracked in plain git, unassigned and per-stack in GitButler.
public struct ChangeGroup: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case staged
        case unstaged
        case untracked
        case conflicted
        case unassigned
        /// Changes assigned to a GitButler stack; `branches` lists its branch names from the top down.
        case stack(id: String, branches: [String])
    }

    public var kind: Kind
    public var title: String
    public var files: [ChangedFile]

    public init(kind: Kind, title: String, files: [ChangedFile]) {
        self.kind = kind
        self.title = title
        self.files = files
    }

    public var id: String {
        switch kind {
        case .staged: "staged"
        case .unstaged: "unstaged"
        case .untracked: "untracked"
        case .conflicted: "conflicted"
        case .unassigned: "unassigned"
        case .stack(let id, _): "stack:\(id)"
        }
    }
}

extension Array where Element == ChangeGroup {
    /// Every file across the groups, in display order.
    public var allFiles: [ChangedFile] { flatMap(\.files) }

    /// The file to select after a refresh replaced `previous` with these groups.
    ///
    /// Keeps the same file when it is still listed, follows it to another group (e.g. after staging),
    /// and otherwise selects the file now at its old position. Selects the first file when nothing was selected.
    public func reselecting(_ id: ChangedFile.ID?, previous: [ChangeGroup]) -> ChangedFile.ID? {
        let files = allFiles
        guard let id else { return files.first?.id }
        if files.contains(where: { $0.id == id }) { return id }

        let oldFiles = previous.allFiles
        guard let oldIndex = oldFiles.firstIndex(where: { $0.id == id }) else { return files.first?.id }
        if let moved = files.first(where: { $0.path == oldFiles[oldIndex].path }) { return moved.id }
        return files.isEmpty ? nil : files[Swift.min(oldIndex, files.count - 1)].id
    }
}
