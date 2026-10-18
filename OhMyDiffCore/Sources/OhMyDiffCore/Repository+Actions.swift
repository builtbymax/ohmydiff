import Foundation

/// A change an action applies to: a whole uncommitted file, or one hunk of its diff.
public struct ChangeTarget: Sendable, Hashable {
    public var file: ChangedFile
    /// One hunk of `file`'s current diff; `nil` for the whole file.
    public var hunk: Hunk?

    public init(file: ChangedFile, hunk: Hunk? = nil) {
        self.file = file
        self.hunk = hunk
    }
}

/// The few write actions ohmydiff offers. Each touches only the changes it is given.
public enum ChangeAction: Sendable, Hashable, CaseIterable {
    /// Plain git: add to the index.
    case stage
    /// Plain git: remove from the index, keeping the worktree.
    case unstage
    /// GitButler: commit to a branch the user picked.
    case commit
    /// Throw the change away: untracked files go to the Trash, GitButler discards are in the oplog.
    case discard
}

public enum ChangeActionError: Error, Sendable, CustomStringConvertible {
    case unsupported(ChangeAction, String)
    case nothingSelected
    case invalidBranchName(String)
    case emptyMessage
    /// The change is no longer in `but`'s view of the workspace, e.g. it changed since the diff loaded.
    case changeNotFound(String)

    public var description: String {
        switch self {
        case .unsupported(let action, let path): "\(action) is not available for \(path)."
        case .nothingSelected: "No changes were selected."
        case .invalidBranchName(let name): "\"\(name)\" is not a valid branch name."
        case .emptyMessage: "The commit message is empty."
        case .changeNotFound(let path): "\(path) changed since it was shown. Refresh and try again."
        }
    }
}

extension Repository {
    /// Whether `action` applies to `target` in this repository.
    public func supports(_ action: ChangeAction, on target: ChangeTarget) -> Bool {
        let file = target.file
        // Hunks are only offered for plain edits, where a one-hunk patch applies cleanly.
        if target.hunk != nil, file.kind != .modified { return false }
        switch (kind, action, file.source) {
        case (.git, .stage, .unstaged), (.git, .unstage, .staged), (.git, .discard, .unstaged):
            return true
        case (.git, .stage, .untracked), (.git, .discard, .untracked):
            return target.hunk == nil
        case (.gitButler, .commit, .workspace), (.gitButler, .discard, .workspace):
            return true
        default:
            return false
        }
    }

    // MARK: - Plain git

    /// Adds files or hunks to the index.
    public func stage(_ targets: [ChangeTarget]) async throws {
        try check(.stage, targets)
        let (files, hunks) = Self.split(targets)
        if !files.isEmpty {
            // `-A` also records deletions.
            _ = try await toolchain.git(["add", "-A", "--"] + files.flatMap(Self.paths), in: root)
        }
        for target in hunks { try await apply(target, arguments: ["--cached"]) }
    }

    /// Removes files or hunks from the index; the worktree keeps them.
    public func unstage(_ targets: [ChangeTarget]) async throws {
        try check(.unstage, targets)
        let (files, hunks) = Self.split(targets)
        if !files.isEmpty {
            let paths = files.flatMap(Self.paths)
            if try await hasHead() {
                _ = try await toolchain.git(["restore", "--staged", "--"] + paths, in: root)
            } else {
                // Before the first commit there is nothing to restore from.
                _ = try await toolchain.git(["rm", "--cached", "-r", "-q", "--"] + paths, in: root)
            }
        }
        for target in hunks { try await apply(target, arguments: ["--cached", "--reverse"]) }
    }

    // MARK: - GitButler

    /// Commits files or hunks to `branch` with `but commit -b`, creating the branch if it does not exist.
    /// Only the given changes are passed, by their CLI IDs, so nothing else lands in the commit.
    public func commit(_ targets: [ChangeTarget], toBranch branch: String, message: String) async throws {
        try check(.commit, targets)
        let branch = branch.trimmingCharacters(in: .whitespaces)
        guard try await isValidBranchName(branch) else { throw ChangeActionError.invalidBranchName(branch) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChangeActionError.emptyMessage }
        let ids = try await butIDs(for: targets)
        _ = try await toolchain.but(["commit", "-b", branch, "-m", message] + ids, in: root, timeout: .seconds(60))
    }

    // MARK: - Both

    /// Throws away files or hunks. Plain git restores tracked files from the index and moves untracked
    /// ones to the Trash; GitButler runs `but discard`, which `but undo` can revert.
    public func discard(_ targets: [ChangeTarget]) async throws {
        try await discard(targets) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    func discard(_ targets: [ChangeTarget], trash: (URL) throws -> Void) async throws {
        try check(.discard, targets)
        switch kind {
        case .gitButler:
            // `but discard` needs all IDs of one kind: files or hunks.
            let (files, hunks) = Self.split(targets)
            for group in [files, hunks] where !group.isEmpty {
                _ = try await toolchain.but(["discard"] + (try await butIDs(for: group)), in: root, timeout: .seconds(60))
            }
        case .git:
            let (files, hunks) = Self.split(targets)
            let tracked = files.filter { $0.file.source == .unstaged }
            if !tracked.isEmpty {
                _ = try await toolchain.git(["restore", "--worktree", "--"] + tracked.flatMap(Self.paths), in: root)
            }
            for target in files where target.file.source == .untracked {
                try trash(root.appending(path: target.file.path))
            }
            for target in hunks { try await apply(target, arguments: ["--reverse"]) }
        }
    }

    // MARK: - Helpers

    private func check(_ action: ChangeAction, _ targets: [ChangeTarget]) throws {
        guard !targets.isEmpty else { throw ChangeActionError.nothingSelected }
        if let target = targets.first(where: { !supports(action, on: $0) }) {
            throw ChangeActionError.unsupported(action, target.file.path)
        }
    }

    private static func split(_ targets: [ChangeTarget]) -> (files: [ChangeTarget], hunks: [ChangeTarget]) {
        (targets.filter { $0.hunk == nil }, targets.filter { $0.hunk != nil })
    }

    private static func paths(_ target: ChangeTarget) -> [String] {
        [target.file.path] + (target.file.previousPath.map { [$0] } ?? [])
    }

    private func hasHead() async throws -> Bool {
        try await toolchain.git(["rev-parse", "--verify", "-q", "HEAD"], in: root, allowedExitCodes: [0, 1]).exitCode == 0
    }

    private func isValidBranchName(_ name: String) async throws -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return try await toolchain.git(["check-ref-format", "--branch", name], in: root, allowedExitCodes: [0, 1, 128]).exitCode == 0
    }

    /// Applies a one-hunk patch to the index (`--cached`) or worktree. `git apply` refuses when the
    /// file changed since the diff was read, so a stale hunk never lands in the wrong place.
    private func apply(_ target: ChangeTarget, arguments: [String]) async throws {
        guard let hunk = target.hunk else { return }
        let patch = Self.patch(path: target.file.path, hunk: hunk)
        _ = try await toolchain.git(["apply", "--whitespace=nowarn"] + arguments + ["-"], in: root, input: Data(patch.utf8))
    }

    static func patch(path: String, hunk: Hunk) -> String {
        "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n" + hunk.patch
    }

    /// The `but` CLI IDs of files (from `but --json status`) or hunks (from `but --json diff`, matched by
    /// their start lines). Read right before the mutation, since the IDs are only valid for one snapshot.
    private func butIDs(for targets: [ChangeTarget]) async throws -> [String] {
        var ids: [String] = []
        let files = targets.filter { $0.hunk == nil }
        if !files.isEmpty {
            let status = try await butStatus()
            let known = Dictionary(
                (status.unassignedChanges + status.stacks.flatMap(\.assignedChanges)).map { ($0.filePath, $0.cliId) },
                uniquingKeysWith: { first, _ in first })
            for target in files {
                guard let id = known[target.file.path], !id.isEmpty else { throw ChangeActionError.changeNotFound(target.file.path) }
                ids.append(id)
            }
        }
        let hunks = targets.filter { $0.hunk != nil }
        if !hunks.isEmpty {
            let changes = try ButDiff.decode(try await toolchain.but(["--json", "diff"], in: root).stdout)
            for target in hunks {
                guard let hunk = target.hunk,
                      let id = changes.first(where: {
                          $0.path == target.file.path && $0.oldStart == hunk.oldStart && $0.newStart == hunk.newStart
                              && $0.oldLines == hunk.oldCount && $0.newLines == hunk.newCount
                      })?.id
                else { throw ChangeActionError.changeNotFound(target.file.path) }
                ids.append(id)
            }
        }
        guard !ids.isEmpty else { throw ChangeActionError.nothingSelected }
        return ids
    }
}

/// The hunks of `but --json diff`, one entry per hunk with its CLI ID.
struct ButDiff {
    struct Hunk: Hashable {
        var id: String
        var path: String
        var oldStart: Int
        var oldLines: Int
        var newStart: Int
        var newLines: Int
    }

    static func decode(_ data: Data) throws -> [Hunk] {
        struct Output: Decodable {
            struct Change: Decodable {
                struct Diff: Decodable {
                    struct Hunk: Decodable { var oldStart: Int; var oldLines: Int; var newStart: Int; var newLines: Int }
                    var hunks: [Hunk]?
                }
                var id: String
                var path: String
                var diff: Diff?
            }
            var changes: [Change]
        }
        return try JSONDecoder().decode(Output.self, from: data).changes.flatMap { change in
            (change.diff?.hunks ?? []).map {
                Hunk(id: change.id, path: change.path, oldStart: $0.oldStart, oldLines: $0.oldLines, newStart: $0.newStart, newLines: $0.newLines)
            }
        }
    }
}
