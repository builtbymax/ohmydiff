import Foundation

/// What a fetch found on the remote: the commits the workspace lacks and what updating does to each branch.
public struct UpstreamStatus: Sendable, Hashable {
    /// The branch everything is updated from, e.g. `origin/main`.
    public var target: String
    /// Commits on the remote the workspace does not have yet, newest first.
    public var incoming: [CommitInfo]
    /// Branches an update changes; unaffected branches are left out.
    public var branches: [BranchUpdate]
    /// GitButler: uncommitted changes would conflict with the incoming commits.
    public var hasWorktreeConflicts: Bool

    public init(target: String, incoming: [CommitInfo] = [], branches: [BranchUpdate] = [], hasWorktreeConflicts: Bool = false) {
        self.target = target
        self.incoming = incoming
        self.branches = branches
        self.hasWorktreeConflicts = hasWorktreeConflicts
    }

    /// Whether an update would change anything.
    public var hasUpdates: Bool { !incoming.isEmpty || !branches.isEmpty }
}

/// What updating from the remote does to one branch.
public struct BranchUpdate: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        /// Its commits are replayed onto the new base.
        case rebase
        /// It only lacks remote commits and moves forward to them.
        case fastForward
        /// It was merged upstream: it becomes part of the new base and is removed.
        case integrated
        /// Rebasing it conflicts. GitButler marks the commits conflicted; plain git leaves the branch as is.
        case conflicts
        /// Plain git: it and its upstream both have new commits, so it is left as is.
        case diverged
    }

    public var name: String
    public var action: Action

    public init(name: String, action: Action) {
        self.name = name
        self.action = action
    }

    public var id: String { name }
}

/// What an update did.
public struct UpstreamUpdateResult: Sendable, Hashable {
    public var updated: [String] = []
    /// Branches removed because they are part of the target now.
    public var integrated: [String] = []
    /// GitButler: branches whose commits are now marked conflicted; plain git: branches that could not be rebased.
    public var conflicted: [String] = []

    public init(updated: [String] = [], integrated: [String] = [], conflicted: [String] = []) {
        self.updated = updated
        self.integrated = integrated
        self.conflicted = conflicted
    }
}
