import Foundation

extension Repository {
    // MARK: GitButler resolution mode

    /// Checks out a conflicted commit with its conflicts in the worktree, with `but resolve <commit>`.
    public func enterResolution(_ commit: String) async throws {
        guard kind == .gitButler else { throw RepositoryError.notGitButler }
        _ = try await toolchain.but(["resolve", commit], in: root, timeout: .seconds(60))
    }

    /// Writes the resolved commit and returns to the workspace, with `but resolve finish`.
    public func finishResolution() async throws {
        guard kind == .gitButler else { throw RepositoryError.notGitButler }
        _ = try await toolchain.but(["resolve", "finish"], in: root, timeout: .seconds(60))
    }

    /// Leaves the commit conflicted and returns to the workspace, with `but resolve cancel`.
    public func cancelResolution() async throws {
        guard kind == .gitButler else { throw RepositoryError.notGitButler }
        _ = try await toolchain.but(["resolve", "cancel"], in: root, timeout: .seconds(60))
    }

    // MARK: Conflicts

    /// The worktree's unmerged files with their conflicts, e.g. during a merge, a rebase or GitButler's resolution
    /// mode. Files without markers left, e.g. already edited, come without regions.
    public func worktreeConflicts() async throws -> [ConflictedFile] {
        let output = try await toolchain.git(["diff", "--name-only", "--diff-filter=U", "-z"], in: root)
        let paths = Array(Set(output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })).sorted()
        return paths.map { path in
            let url = root.appending(path: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let text = size <= Self.conflictFileLimit ? (try? String(contentsOf: url, encoding: .utf8)) : nil
            return ConflictedFile(path: path, regions: text.map(ConflictMarkers.regions(in:)) ?? [])
        }
    }

    /// An unmerged file's sides from the index, written to temporary files for an editor's merge view: ours
    /// (stage 2), theirs (stage 3) and their common ancestor (stage 1). A side the file lacks, e.g. the ancestor of
    /// a file both sides added, is an empty file. `nil` when the file is not unmerged.
    public func mergeSides(of path: String) async throws -> (ours: URL, theirs: URL, base: URL)? {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ohmydiff-merge/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: path).lastPathComponent
        var sides: [URL] = []
        var found = false
        for (stage, label) in [(2, "ours"), (3, "theirs"), (1, "base")] {
            let data = try await blob(":\(stage):\(path)", limit: Self.conflictFileLimit)
            found = found || data != nil
            // The side's name first, so the editor's tabs tell them apart; the extension keeps highlighting.
            let url = directory.appending(path: "\(label).\(name)")
            try (data ?? Data()).write(to: url)
            sides.append(url)
        }
        guard found else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return (sides[0], sides[1], sides[2])
    }

    /// Plain git: what stopped on conflicts, e.g. "rebase"; `nil` when nothing is in progress.
    public func operationInProgress() async -> String? {
        guard let gitDir = try? await gitDirectories().gitDir else { return nil }
        let markers = [
            ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
            ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"),
        ]
        return markers.first { FileManager.default.fileExists(atPath: gitDir.appending(path: $0.0).path) }?.1
    }

    /// The files that conflict when `tip` is merged into `target`, with the conflicts `git merge-tree` writes,
    /// without touching the worktree.
    func mergeConflicts(target: String, tip: String) async throws -> [ConflictedFile] {
        // Exits with 1 when there are conflicts: the merged tree, then the conflicted paths.
        let output = try await toolchain.git(
            ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", target, tip], in: root, allowedExitCodes: [0, 1])
        guard output.exitCode == 1 else { return [] }
        let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard let tree = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines), !tree.isEmpty else { return [] }
        var seen: Set<String> = []
        var files: [ConflictedFile] = []
        for path in fields.dropFirst() where !path.isEmpty && seen.insert(path).inserted {
            let text = try await blob("\(tree):\(path)", limit: Self.conflictFileLimit).map { String(decoding: $0, as: UTF8.self) }
            files.append(ConflictedFile(path: path, regions: text.map(ConflictMarkers.regions(in:)) ?? []))
        }
        return files
    }

    /// What there is to know about `branch`'s conflicts: conflicts in the worktree first, then GitButler's
    /// conflicted commits, then those of merging the branch into its pull request's base.
    public func conflictReport(
        branch: HistoryBranch?, target: String?, pullRequest: (number: Int, base: String)? = nil, isResolving: Bool = false
    ) async throws -> ConflictReport {
        var report = ConflictReport(
            situation: .conflictedCommits, repositoryPath: root.path, isGitButler: kind == .gitButler,
            branch: branch?.name, target: target, commits: branch?.commits ?? [])

        if let pullRequest, report.target == nil {
            report.target = await firstCommit(of: ["origin/\(pullRequest.base)", pullRequest.base]) ?? pullRequest.base
        }
        if let branch, let target = report.target {
            report.incoming = (try? await log(["\(branch.tip)..\(target)"])) ?? []
        }

        let worktree = try await worktreeConflicts()
        if isResolving {
            report.situation = .resolving
            report.files = worktree
        } else if !worktree.isEmpty, kind == .git {
            report.situation = .operation(await operationInProgress() ?? "merge")
            report.files = worktree
        } else if kind == .gitButler, let branch, branch.isConflicted {
            report.situation = .conflictedCommits
            report.details = try? await toolchain.but(["resolve", "conflicts", branch.name], in: root).stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let pullRequest {
            report.situation = .pullRequest(number: pullRequest.number, base: pullRequest.base)
            if let branch, let target = report.target {
                report.files = (try? await mergeConflicts(target: target, tip: branch.tip)) ?? []
            }
        }
        return report
    }

    /// The first of `revisions` that names a commit, as given.
    private func firstCommit(of revisions: [String]) async -> String? {
        for revision in revisions where (try? await resolveCommit(revision)) != nil { return revision }
        return nil
    }

    /// Only files up to this size are read for their conflicts.
    static let conflictFileLimit = 2 << 20
}
