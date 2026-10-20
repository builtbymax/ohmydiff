import Foundation

extension Repository {
    /// Commits listed per plain-git branch at most.
    static let branchCommitLimit = 300
    /// git's empty tree, the base of a branch that starts at a root commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Branches with their own commits: GitButler's applied stacks, or the local branches of a plain repository.
    public func history() async throws -> [HistoryGroup] {
        switch kind {
        case .gitButler:
            async let target = butTarget()
            return Self.butHistory(try await butStatus(), target: await target)
        case .git: return [HistoryGroup(id: "branches", kind: .localBranches, branches: try await gitBranches())]
        }
    }

    /// Each branch of a stack is reviewed on its own: its whole diff starts below its oldest commit,
    /// which is the branch underneath it in the stack, or the target's merge base for the bottom branch.
    static func butHistory(_ status: ButStatus, target: String? = nil) -> [HistoryGroup] {
        status.stacks.map { stack in
            var branches: [HistoryBranch] = []
            // Bottom up, so each branch knows the tip of the one below it.
            var below: (name: String, tip: String)? = status.mergeBase.map { (target ?? "the target branch", $0.commitId) }
            for branch in stack.branches.reversed() {
                let commits = branch.commits.map { commit in
                    CommitInfo(
                        sha: commit.commitId, message: commit.message, authorName: commit.authorName ?? "",
                        authorEmail: commit.authorEmail ?? "", date: commit.createdAt, isConflicted: commit.conflicted)
                }
                let tip = commits.first?.sha ?? below?.tip ?? ""
                branches.append(HistoryBranch(
                    name: branch.name, status: HistoryBranch.Status(butStatus: branch.branchStatus), commits: commits,
                    base: commits.isEmpty ? nil : commits.last.map { "\($0.sha)^" },
                    tip: tip, baseName: below?.name))
                below = (branch.name, tip)
            }
            return HistoryGroup(id: stack.id, kind: .stack, branches: branches.reversed())
        }
    }

    /// Local branches. The default branch lists its commits ahead of its upstream; every other branch
    /// lists its commits ahead of the default branch, and its whole diff starts at their merge base.
    func gitBranches() async throws -> [HistoryBranch] {
        let format = ["%(refname:short)", "%(objectname)", "%(upstream:short)", "%(upstream:track)", "%(HEAD)"].joined(separator: "%00")
        let output = try await toolchain.git(["for-each-ref", "--format=\(format)", "refs/heads"], in: root)
        let refs = output.stdoutString.split(separator: "\n").map { $0.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) }
        let defaultBranch = await defaultBranch(local: refs.map { $0[0] })

        var branches: [HistoryBranch] = []
        for fields in refs where fields.count == 5 {
            let (name, tip, upstream, track) = (fields[0], fields[1], fields[2], fields[3])
            let compare: (ref: String, name: String)? = if name == defaultBranch || defaultBranch == nil {
                upstream.isEmpty ? nil : (upstream, upstream)
            } else {
                (defaultBranch!, defaultBranch!)
            }

            var commits: [CommitInfo]
            var base: String?
            if let compare {
                commits = try await log(["\(compare.ref)..\(tip)"])
                base = try await mergeBase(compare.ref, tip)
            } else {
                // Nothing to compare against: show recent history; the whole diff is unavailable.
                commits = try await log([tip])
            }
            if base == nil, compare != nil, let oldest = commits.last, commits.count < Self.branchCommitLimit {
                // Unrelated histories: fall back to the parent of the oldest listed commit.
                base = try await parent(of: oldest.sha)
            }
            // A branch without upstream was never pushed, unless it is the main line of a local-only repository.
            let status: HistoryBranch.Status? = upstream.isEmpty
                ? (name == defaultBranch ? nil : .unpushed)
                : .tracking(track, hasUpstream: true)
            branches.append(HistoryBranch(
                name: name, status: status, commits: commits,
                base: base, tip: tip, baseName: compare?.name, isCurrent: fields[4] == "*", isDefault: name == defaultBranch))
        }
        // The default branch first, then the checked-out one, then alphabetical as git lists them.
        return branches.sorted { lhs, rhs in
            func rank(_ branch: HistoryBranch) -> Int { branch.name == defaultBranch ? 0 : branch.isCurrent ? 1 : 2 }
            return rank(lhs) < rank(rhs)
        }
    }

    /// `origin/HEAD`'s local counterpart, else `main` or `master` when they exist.
    func defaultBranch(local: [String]) async -> String? {
        if let output = try? await toolchain.git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root),
           case let remote = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
           let slash = remote.firstIndex(of: "/") {
            let name = String(remote[remote.index(after: slash)...])
            if local.contains(name) { return name }
        }
        return ["main", "master"].first(where: local.contains)
    }

    private func mergeBase(_ a: String, _ b: String) async throws -> String? {
        // Exits with 1 when the histories are unrelated.
        let output = try await toolchain.git(["merge-base", a, b], in: root, allowedExitCodes: [0, 1])
        let sha = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private func parent(of sha: String) async throws -> String {
        let output = try await toolchain.git(["rev-parse", "--verify", "--quiet", "\(sha)^"], in: root, allowedExitCodes: [0, 1])
        let parent = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return parent.isEmpty ? Self.emptyTree : parent
    }

    /// Commits for a revision range, newest first, using NUL-separated fields and RS-separated records.
    func log(_ revisions: [String]) async throws -> [CommitInfo] {
        let format = "%H%x00%an%x00%ae%x00%aI%x00%B%x1e"
        let output = try await toolchain.git(
            ["log", "--format=\(format)", "-n", String(Self.branchCommitLimit)] + revisions + ["--"], in: root)
        return Self.parseLog(output.stdoutString)
    }

    static func parseLog(_ text: String) -> [CommitInfo] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: "\0", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, !fields[0].isEmpty else { return nil }
            return CommitInfo(
                sha: String(fields[0]),
                message: fields[4].trimmingCharacters(in: .whitespacesAndNewlines),
                authorName: String(fields[1]), authorEmail: String(fields[2]),
                date: try? Date(String(fields[3]), strategy: .iso8601))
        }
    }

    /// GitButler: the target branch, e.g. `origin/main`; `nil` when `but` does not say.
    func butTarget() async -> String? {
        struct Target: Decodable { var branch: String? }
        guard let output = try? await toolchain.but(["--json", "config", "target"], in: root),
              let branch = (try? JSONDecoder().decode(Target.self, from: output.stdout))?.branch, !branch.isEmpty
        else { return nil }
        return branch
    }

    // MARK: Diffs between revisions

    /// The diff from `base` to `tip`, e.g. a whole branch.
    public func diff(from base: String, to tip: String) async throws -> [FileDiff] {
        let (base, tip) = (try await tree(of: base), try await tree(of: tip))
        let output = try await toolchain.git(["diff"] + Self.diffOptions + [base, tip, "--"], in: root)
        return UnifiedDiffParser.parse(output.stdout)
    }

    /// The tree-ish to read for `revision`. GitButler stores a conflicted commit's sides (`.conflict-base-0`,
    /// `.conflict-side-0`, …) in its tree next to `.auto-resolution`, the tree it checks out; that subtree
    /// stands in for the commit, so the bookkeeping does not show as added files.
    func tree(of revision: String) async throws -> String {
        guard kind == .gitButler else { return revision }
        let marker = try await toolchain.git(["cat-file", "-e", "\(revision):.conflict-files"], in: root, allowedExitCodes: [0, 1, 128])
        return marker.exitCode == 0 ? "\(revision):.auto-resolution" : revision
    }

    /// The full SHA of the commit `revision` names, e.g. an abbreviated SHA; `nil` when there is none.
    public func resolveCommit(_ revision: String) async throws -> String? {
        guard !revision.hasPrefix("-") else { return nil }
        let output = try await toolchain.git(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"], in: root, allowedExitCodes: [0, 1, 128])
        let sha = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.exitCode == 0 && !sha.isEmpty ? sha : nil
    }

    /// A file's contents at `revision`, or `nil` when it does not exist there or is larger than `limit` bytes.
    public func contents(at revision: String, path: String, limit: Int = 16 << 20) async throws -> Data? {
        let tree = try await tree(of: revision)
        return try await blob(tree == revision ? "\(revision):\(path)" : "\(tree)/\(path)", limit: limit)
    }
}
