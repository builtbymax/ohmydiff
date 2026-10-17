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
    /// Worktree vs. the GitButler workspace commit (HEAD).
    case workspace
}

/// An uncommitted file as listed in a change group.
public struct ChangedFile: Sendable, Hashable, Identifiable {
    public var path: String
    /// Source path when the file was renamed or copied.
    public var previousPath: String?
    public var kind: FileChangeKind
    public var source: ChangeSource

    public init(path: String, previousPath: String? = nil, kind: FileChangeKind, source: ChangeSource) {
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.source = source
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
