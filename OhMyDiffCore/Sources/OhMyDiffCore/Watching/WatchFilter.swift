/// Decides which file system events can change a project's state.
public struct WatchFilter: Sendable, Hashable {
    public enum Classification: Sendable, Hashable {
        /// HEAD, index, refs or GitButler state changed.
        case gitMetadata
        /// A worktree file changed; the path is relative to the root. Still subject to `.gitignore`.
        case worktree(String)
        case irrelevant
    }

    /// Worktree root, without a trailing slash.
    public let root: String
    /// Git dirs to watch: the worktree's git dir and, for linked worktrees, the common dir.
    public let gitDirectories: [String]

    public init(root: String, gitDirectories: [String]) {
        self.root = Self.normalize(root)
        self.gitDirectories = gitDirectories.map(Self.normalize)
    }

    /// Entries inside a git dir that affect status, branches or history.
    private static let relevantGitEntries: Set<String> = [
        "HEAD", "index", "packed-refs", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
    ]
    private static let relevantGitPrefixes = ["refs/", "gitbutler/", "rebase-merge/", "rebase-apply/", "worktrees/"]
    /// Transient files written by git and `but` itself (`but status` touches `gitbutler.write-lock`).
    private static let noiseSuffixes = [".lock", "write-lock", "-wal", "-shm", "-journal", ".tmp"]

    public func classify(_ path: String) -> Classification {
        let path = Self.normalize(path)
        for gitDirectory in gitDirectories {
            if let relative = Self.relative(path, to: gitDirectory) {
                return Self.isRelevantGitPath(relative) ? .gitMetadata : .irrelevant
            }
        }
        guard let relative = Self.relative(path, to: root), !relative.isEmpty else { return .irrelevant }
        // A `.git` that is not one of ours belongs to a nested repository or submodule.
        if relative == ".git" || relative.hasPrefix(".git/") || relative.contains("/.git/") || relative.hasSuffix("/.git") {
            return .irrelevant
        }
        return .worktree(relative)
    }

    static func isRelevantGitPath(_ relative: String) -> Bool {
        if noiseSuffixes.contains(where: relative.hasSuffix) { return false }
        // `worktrees/<name>/HEAD` etc. for linked worktrees, but not their logs.
        if relative.hasPrefix("worktrees/") {
            let entry = relative.split(separator: "/").dropFirst(2).joined(separator: "/")
            return relevantGitEntries.contains(entry) || entry.hasPrefix("refs/")
        }
        return relevantGitEntries.contains(relative) || relevantGitPrefixes.contains(where: relative.hasPrefix)
    }

    static func relative(_ path: String, to directory: String) -> String? {
        if path == directory { return "" }
        guard path.hasPrefix(directory + "/") else { return nil }
        return String(path.dropFirst(directory.count + 1))
    }

    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // FSEvents reports `/private/var/...` for `/var/...` and `/private/tmp` for `/tmp`.
        for alias in ["/var/", "/tmp/", "/etc/"] where path.hasPrefix(alias) {
            path = "/private" + path
        }
        if ["/var", "/tmp", "/etc"].contains(path) { path = "/private" + path }
        return path
    }
}
