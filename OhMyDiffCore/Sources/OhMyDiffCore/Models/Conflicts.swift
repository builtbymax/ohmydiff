import Foundation

/// GitButler's resolution mode, entered with `but resolve <commit>`: the commit is checked out with its conflicts
/// in the worktree until `but resolve finish` or `but resolve cancel`.
public struct ConflictResolution: Sendable, Hashable {
    /// Files that still hold conflict markers.
    public var conflictedFiles: [String]
    public var resolvedFiles: [String]

    public init(conflictedFiles: [String] = [], resolvedFiles: [String] = []) {
        self.conflictedFiles = conflictedFiles
        self.resolvedFiles = resolvedFiles
    }

    /// Every conflict is resolved, so `but resolve finish` can write the commit.
    public var isComplete: Bool { conflictedFiles.isEmpty }
}

/// One conflict in a file: the lines from `<<<<<<<` to `>>>>>>>`.
public struct ConflictRegion: Sendable, Hashable {
    /// The 1-based line of the `<<<<<<<` marker.
    public var line: Int
    public var text: String

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// A file with conflict markers, in the worktree or in a merge `git merge-tree` worked out.
public struct ConflictedFile: Sendable, Hashable, Identifiable {
    public var path: String
    public var regions: [ConflictRegion]

    public init(path: String, regions: [ConflictRegion]) {
        self.path = path
        self.regions = regions
    }

    public var id: String { path }
    /// Where an editor should open the file: its first conflict.
    public var firstLine: Int { regions.first?.line ?? 1 }
}

public enum ConflictMarkers {
    /// The conflicts in a file's text. A region missing its `>>>>>>>` runs to the end of the file.
    public static func regions(in text: String) -> [ConflictRegion] {
        var regions: [ConflictRegion] = []
        var current: (line: Int, lines: [Substring])?
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if current == nil, line.hasPrefix("<<<<<<<") {
                current = (index + 1, [line])
            } else if var open = current {
                open.lines.append(line)
                if line.hasPrefix(">>>>>>>") {
                    regions.append(ConflictRegion(line: open.line, text: open.lines.joined(separator: "\n")))
                    current = nil
                } else {
                    current = open
                }
            }
        }
        if let open = current {
            regions.append(ConflictRegion(line: open.line, text: open.lines.joined(separator: "\n")))
        }
        return regions
    }
}

/// Everything known about conflicts on a branch, for a prompt that asks a coding agent to resolve them.
public struct ConflictReport: Sendable, Hashable {
    public enum Situation: Sendable, Hashable {
        /// GitButler marked commits conflicted, e.g. when `but pull` rebased the branch.
        case conflictedCommits
        /// GitButler's resolution mode, with the conflicts in the worktree.
        case resolving
        /// Plain git: a merge, rebase, cherry-pick or revert stopped on conflicts, e.g. "rebase".
        case operation(String)
        /// A pull request conflicts with its base; nothing is conflicted locally.
        case pullRequest(number: Int, base: String)
    }

    public var situation: Situation
    public var repositoryPath: String
    public var isGitButler: Bool
    public var branch: String?
    /// What the branch is updated from or merged into, e.g. `origin/main`.
    public var target: String?
    /// The branch's own commits, newest first.
    public var commits: [CommitInfo]
    /// Commits on `target` the branch does not have, newest first.
    public var incoming: [CommitInfo]
    public var files: [ConflictedFile]
    /// GitButler: `but resolve conflicts` output, each conflict with its sides.
    public var details: String?

    public init(
        situation: Situation, repositoryPath: String, isGitButler: Bool, branch: String? = nil, target: String? = nil,
        commits: [CommitInfo] = [], incoming: [CommitInfo] = [], files: [ConflictedFile] = [], details: String? = nil
    ) {
        self.situation = situation
        self.repositoryPath = repositoryPath
        self.isGitButler = isGitButler
        self.branch = branch
        self.target = target
        self.commits = commits
        self.incoming = incoming
        self.files = files
        self.details = details
    }
}
