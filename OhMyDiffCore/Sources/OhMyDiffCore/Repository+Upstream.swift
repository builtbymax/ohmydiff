import Foundation

extension Repository {
    /// Fetching and updating talk to the remote, so they get longer than local commands.
    static let remoteTimeout: Duration = .seconds(120)

    /// Fetches from the remote and returns what an update would bring in; `nil` for a plain repository
    /// without any tracked branch.
    ///
    /// GitButler: `but pull --check`. Plain git: `git fetch --all --prune`, then each local branch is
    /// compared with its upstream.
    public func fetchUpstream() async throws -> UpstreamStatus? {
        switch kind {
        case .gitButler:
            let output = try await toolchain.but(["pull", "--check", "--json"], in: root, timeout: Self.remoteTimeout)
            return try JSONDecoder().decode(ButPullCheck.self, from: output.stdout).upstreamStatus
        case .git:
            _ = try await toolchain.git(["fetch", "--all", "--prune", "--quiet"], in: root, timeout: Self.remoteTimeout)
            return try await gitUpstreamStatus()
        }
    }

    /// Updates the workspace from the fetched remote.
    ///
    /// GitButler: `but pull`, which rebases the applied branches and removes integrated ones; conflicting
    /// commits are marked conflicted and `but undo` reverts it. Plain git: branches that only lack remote
    /// commits move forward, the checked-out branch is rebased onto its upstream (with its uncommitted
    /// changes stashed meanwhile), and branches whose upstream is gone after being merged are deleted.
    /// A rebase that conflicts is aborted, leaving the branch as it was.
    public func updateFromUpstream() async throws -> UpstreamUpdateResult {
        switch kind {
        case .gitButler:
            let output = try await toolchain.but(["pull", "--json"], in: root, timeout: Self.remoteTimeout)
            return (try? JSONDecoder().decode(ButPullResult.self, from: output.stdout).result) ?? UpstreamUpdateResult()
        case .git:
            return try await gitUpdate()
        }
    }

    // MARK: - Plain git

    private struct TrackedBranch {
        var name: String
        var tip: String
        var upstream: String
        var ahead: Int
        var behind: Int
        var isGone: Bool
        var isCurrent: Bool
    }

    private func trackedBranches() async throws -> [TrackedBranch] {
        let format = ["%(refname:short)", "%(objectname)", "%(upstream:short)", "%(upstream:track)", "%(HEAD)"].joined(separator: "%00")
        let output = try await toolchain.git(["for-each-ref", "--format=\(format)", "refs/heads"], in: root)
        return output.stdoutString.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, !fields[2].isEmpty else { return nil }
            let status = HistoryBranch.Status.tracking(fields[3], hasUpstream: true)
            var (ahead, behind) = (0, 0)
            if case .tracking(let a, let b) = status { (ahead, behind) = (a, b) }
            return TrackedBranch(
                name: fields[0], tip: fields[1], upstream: fields[2], ahead: ahead, behind: behind,
                isGone: status == .upstreamGone, isCurrent: fields[4] == "*")
        }
    }

    func gitUpstreamStatus() async throws -> UpstreamStatus? {
        let branches = try await trackedBranches()
        let names = try await toolchain.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: root)
            .stdoutString.split(separator: "\n").map(String.init)
        let defaultName = await defaultBranch(local: names)
        let current = branches.first(where: \.isCurrent)
        // The default branch's upstream, else the checked-out branch's.
        guard let targetBranch = branches.first(where: { $0.name == defaultName && !$0.isGone }) ?? current.flatMap({ $0.isGone ? nil : $0 })
        else { return nil }
        let target = targetBranch.upstream

        // What the default branch lacks, plus what the checked-out branch lacks from its own upstream.
        var incoming = try await log(["\(targetBranch.name)..\(target)"])
        if let current, !current.isGone, current.upstream != target {
            let known = Set(incoming.map(\.sha))
            incoming += try await log(["\(current.name)..\(current.upstream)"]).filter { !known.contains($0.sha) }
        }

        var updates: [BranchUpdate] = []
        for branch in branches {
            if branch.isGone {
                // Merged upstream and deleted there: the local copy is no longer needed.
                if !branch.isCurrent, try await isAncestor(branch.tip, of: target) {
                    updates.append(BranchUpdate(name: branch.name, action: .integrated))
                }
                continue
            }
            guard branch.behind > 0 else { continue }
            if branch.ahead == 0 {
                updates.append(BranchUpdate(name: branch.name, action: .fastForward))
            } else if branch.isCurrent {
                let clean = try await mergesCleanly(branch.tip, branch.upstream)
                updates.append(BranchUpdate(name: branch.name, action: clean ? .rebase : .conflicts))
            } else {
                updates.append(BranchUpdate(name: branch.name, action: .diverged))
            }
        }
        return UpstreamStatus(target: target, incoming: incoming, branches: updates)
    }

    private func gitUpdate() async throws -> UpstreamUpdateResult {
        // Decided again from the current state, in case something changed since the preview.
        guard let status = try await gitUpstreamStatus() else { return UpstreamUpdateResult() }
        let branches = Dictionary(try await trackedBranches().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result = UpstreamUpdateResult()

        for update in status.branches {
            guard let branch = branches[update.name] else { continue }
            switch update.action {
            case .fastForward where branch.isCurrent, .rebase:
                do {
                    _ = try await toolchain.git(["rebase", "--autostash", branch.upstream], in: root, timeout: Self.remoteTimeout)
                    result.updated.append(branch.name)
                } catch {
                    // Leave the branch exactly as it was.
                    _ = try? await toolchain.git(["rebase", "--abort"], in: root)
                    result.conflicted.append(branch.name)
                }
            case .fastForward:
                // Fetching from the repository itself refuses anything but a fast-forward.
                _ = try await toolchain.git(["fetch", "--quiet", ".", "refs/remotes/\(branch.upstream):refs/heads/\(branch.name)"], in: root)
                result.updated.append(branch.name)
            case .integrated:
                _ = try await toolchain.git(["branch", "-D", branch.name], in: root)
                result.integrated.append(branch.name)
            case .conflicts:
                result.conflicted.append(branch.name)
            case .diverged:
                continue
            }
        }
        return result
    }

    private func isAncestor(_ commit: String, of revision: String) async throws -> Bool {
        let output = try await toolchain.git(["merge-base", "--is-ancestor", commit, revision], in: root, allowedExitCodes: [0, 1])
        return output.exitCode == 0
    }

    /// Whether `a` and `b` combine without conflicts, without touching the worktree.
    private func mergesCleanly(_ a: String, _ b: String) async throws -> Bool {
        // Exits with 1 when there are conflicts.
        let output = try await toolchain.git(["merge-tree", "--write-tree", "--quiet", a, b], in: root, allowedExitCodes: [0, 1])
        return output.exitCode == 0
    }
}
