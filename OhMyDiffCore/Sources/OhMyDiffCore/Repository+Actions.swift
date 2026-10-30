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
    /// Plain git commits only to the checked-out branch.
    case notCheckedOut(String)
    case deletingCheckedOut(String)
    /// Plain git: a hunk to commit overlaps staged changes of the same file.
    case overlapsStaged(String)
    /// GitButler: the changes build on commits of this branch, so they go to a branch stacked on top of it.
    case dependsOn(String)

    public var description: String {
        switch self {
        case .unsupported(let action, let path): "\(action) is not available for \(path)."
        case .nothingSelected: "No changes were selected."
        case .invalidBranchName(let name): "\"\(name)\" is not a valid branch name."
        case .emptyMessage: "The commit message is empty."
        case .changeNotFound(let path): "\(path) changed since it was shown. Refresh and try again."
        case .notCheckedOut(let name): "\(name) is not checked out. Commit to the checked-out branch or a new one."
        case .deletingCheckedOut(let name): "\(name) is checked out. Switch to another branch before deleting it."
        case .dependsOn(let branch): "These changes build on commits in \(branch). Commit them to a branch stacked on top of it."
        case .overlapsStaged(let path): "The selected change of \(path) overlaps its staged changes. Commit or unstage those first."
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
        case (.git, .commit, .unstaged):
            return true
        case (.git, .commit, .staged), (.git, .commit, .untracked):
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

    /// Plain git: deletes local branches, e.g. ones whose upstream was deleted after merging. The checked-out
    /// branch is refused. Deleted commits stay recoverable through the reflog for a while.
    public func deleteBranches(_ names: [String]) async throws {
        guard kind == .git, !names.isEmpty else { return }
        if let current = try await currentBranch(), names.contains(current) { throw ChangeActionError.deletingCheckedOut(current) }
        // `-D`: squash-merged branches are not ancestors of their target, so `-d` would refuse them.
        _ = try await toolchain.git(["branch", "-D", "--"] + names, in: root)
    }

    /// GitButler: moves `branch` on top of `target`, so it builds on it in `target`'s stack.
    public func stack(_ branch: String, onto target: String) async throws {
        guard kind == .gitButler else { throw RepositoryError.notGitButler }
        _ = try await toolchain.but(["move", branch, "--above", target], in: root, timeout: .seconds(60))
    }

    /// GitButler: takes `branch` out of its stack into a stack of its own.
    public func unstack(_ branch: String) async throws {
        guard kind == .gitButler else { throw RepositoryError.notGitButler }
        _ = try await toolchain.but(["move", branch, "--unstack"], in: root, timeout: .seconds(60))
    }

    /// The checked-out branch; `nil` on a detached HEAD.
    public func currentBranch() async throws -> String? {
        let output = try await toolchain.git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root, allowedExitCodes: [0, 1])
        let name = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.exitCode == 0 && !name.isEmpty ? name : nil
    }

    /// Commits exactly `targets` to the checked-out branch, leaving everything else staged or not as it was.
    ///
    /// The commit is built in a temporary index that starts from HEAD and gets only the selected changes:
    /// staged files as staged, unstaged and untracked files as they are in the worktree, hunks applied on top
    /// of HEAD (or of the staged version when the whole staged file is selected too), so a file's other staged
    /// hunks stay out. `git commit` then runs with that index, so hooks still run, and the real index is
    /// brought in line for the committed paths afterwards, keeping staged hunks that were not committed.
    private func gitCommit(_ targets: [ChangeTarget], message: String) async throws {
        let index = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let temporary = ["GIT_INDEX_FILE": index.path]

        _ = try await toolchain.git(["read-tree"] + (try await hasHead() ? ["HEAD"] : ["--empty"]), in: root, environment: temporary)
        let (files, hunks) = Self.split(targets)

        // Staged files: the real index's entries, or none for staged deletions.
        let indexPaths = Array(Set(files.filter { $0.file.source == .staged }.flatMap(Self.paths))).sorted()
        if !indexPaths.isEmpty {
            _ = try await toolchain.git(["update-index", "--force-remove", "--"] + indexPaths, in: root, environment: temporary)
            let entries = try await toolchain.git(["ls-files", "--stage", "-z", "--"] + indexPaths, in: root)
            // NUL-terminated both ways, so names with newlines survive.
            if !entries.stdout.isEmpty {
                _ = try await toolchain.git(["update-index", "-z", "--index-info"], in: root, input: entries.stdout, environment: temporary)
            }
        }
        let fromWorktree = files.filter { $0.file.source != .staged }
        if !fromWorktree.isEmpty {
            _ = try await toolchain.git(["add", "-A", "--"] + fromWorktree.flatMap(Self.paths), in: root, environment: temporary)
        }
        for target in hunks {
            guard let hunk = target.hunk else { continue }
            // The hunk was read against the real index; `git apply` finds it at an offset in HEAD's version,
            // and refuses when it overlaps the file's staged changes.
            do {
                _ = try await toolchain.git(
                    ["apply", "--cached", "--whitespace=nowarn", "-"], in: root,
                    input: Data(Self.patch(path: target.file.path, hunk: hunk).utf8), environment: temporary)
            } catch let error as ProcessError {
                if !indexPaths.contains(target.file.path), try await isStaged(target.file.path) {
                    throw ChangeActionError.overlapsStaged(target.file.path)
                }
                throw error
            }
        }

        _ = try await toolchain.git(["commit", "--quiet", "--file=-"], in: root, input: Data(message.utf8), environment: temporary, timeout: .seconds(120))
        // The committed paths now match HEAD in the real index too, so they do not show as staged in reverse.
        // Paths committed only by hunk get those hunks in the real index instead, which keeps the rest staged.
        let filePaths = Set(files.flatMap(Self.paths))
        let hunkOnly = hunks.filter { !filePaths.contains($0.file.path) }
        var resetPaths = Set(targets.flatMap(Self.paths))
        for target in hunkOnly where (try? await apply(target, arguments: ["--cached"])) != nil {
            resetPaths.remove(target.file.path)
        }
        if !resetPaths.isEmpty {
            _ = try await toolchain.git(["reset", "--quiet", "--"] + resetPaths.sorted(), in: root)
        }
    }

    /// Whether the real index differs from HEAD for `path`.
    private func isStaged(_ path: String) async throws -> Bool {
        guard try await hasHead() else { return true }
        return try await toolchain.git(["diff", "--cached", "--quiet", "HEAD", "--", path], in: root, allowedExitCodes: [0, 1]).exitCode == 1
    }

    // MARK: - Both

    /// Commits files or hunks. GitButler: to `branch` with `but commit -b`, creating the branch if it does
    /// not exist, stacked on `anchor` when given; only the given changes are passed, by their CLI IDs. Throws
    /// `dependsOn` when the changes need such an anchor. Plain git: to the checked-out branch, or to a new
    /// branch `branch` switched to first; see `gitCommit`.
    public func commit(_ targets: [ChangeTarget], toBranch branch: String, stackedOn anchor: String? = nil, message: String) async throws {
        try check(.commit, targets)
        let branch = branch.trimmingCharacters(in: .whitespaces)
        guard try await isValidBranchName(branch) else { throw ChangeActionError.invalidBranchName(branch) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChangeActionError.emptyMessage }
        switch kind {
        case .gitButler:
            if let anchor {
                _ = try await toolchain.but(["branch", "new", branch, "--above", anchor], in: root, timeout: .seconds(60))
            }
            let ids = try await butIDs(for: targets)
            do {
                _ = try await toolchain.but(["commit", "-b", branch, "-m", message] + ids, in: root, timeout: .seconds(60))
            } catch let error as ProcessError {
                if case .nonZeroExit(_, _, let stderr) = error, let anchor = Self.dependencyAnchor(stderr) {
                    throw ChangeActionError.dependsOn(anchor)
                }
                throw error
            }
        case .git:
            if try await currentBranch() != branch {
                let exists = try await toolchain.git(
                    ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: root, allowedExitCodes: [0, 1]).exitCode == 0
                // Commits only go to the checked-out branch; another existing one would need a checkout.
                guard !exists else { throw ChangeActionError.notCheckedOut(branch) }
                _ = try await toolchain.git(["switch", "--quiet", "--create", branch], in: root)
            }
            try await gitCommit(targets, message: message)
        }
    }

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

    /// The branch `but commit` says the changes depend on, from its hint `but branch new <name> --above <branch>`
    /// (`--anchor` before 0.23), whose branch may be shell-quoted.
    static func dependencyAnchor(_ stderr: String) -> String? {
        guard let range = stderr.range(of: "--above ") ?? stderr.range(of: "--anchor ") else { return nil }
        let anchor = stderr[range.upperBound...].prefix { !$0.isWhitespace }
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return anchor.isEmpty ? nil : anchor
    }

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
        let old = quoted("a/" + path), new = quoted("b/" + path)
        return "diff --git \(old) \(new)\n--- \(old)\n+++ \(new)\n" + hunk.patch
    }

    /// `name` as git writes it in patch headers: C-quoted when it has quotes, backslashes or control
    /// characters, which would otherwise end or garble the header line.
    static func quoted(_ name: String) -> String {
        let escapes: [Unicode.Scalar: String] = ["\u{7}": "a", "\u{8}": "b", "\t": "t", "\n": "n", "\u{B}": "v", "\u{C}": "f", "\r": "r", "\"": "\"", "\\": "\\"]
        func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || scalar.value == 0x7F }
        guard name.unicodeScalars.contains(where: { escapes[$0] != nil || isControl($0) }) else { return name }
        var result = "\""
        for scalar in name.unicodeScalars {
            if let escape = escapes[scalar] {
                result += "\\" + escape
            } else if isControl(scalar) {
                result += "\\" + String(format: "%03o", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
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
