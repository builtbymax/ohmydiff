import Foundation

/// A commit in the History log: its parents for the graph, and the branches and tags pointing at it.
public struct LogCommit: Sendable, Hashable, Identifiable {
    public var commit: CommitInfo
    public var parents: [String]
    /// Local branches pointing at the commit, e.g. `main`.
    public var branches: [String]
    /// Tags pointing at the commit, e.g. `v1.3.2`.
    public var tags: [String]
    /// Whether a remote branch contains the commit.
    public var isPushed: Bool
    /// Whether the checked-out branch contains the commit, so a revert applies to it.
    public var isOnHead: Bool

    public init(
        commit: CommitInfo, parents: [String] = [], branches: [String] = [], tags: [String] = [], isPushed: Bool = false,
        isOnHead: Bool = true
    ) {
        self.commit = commit
        self.parents = parents
        self.branches = branches
        self.tags = tags
        self.isPushed = isPushed
        self.isOnHead = isOnHead
    }

    public var id: String { commit.sha }
    public var isMerge: Bool { parents.count > 1 }
}

extension Repository {
    /// Commits the History log lists at most.
    public static let logLimit = 400

    /// Commits reachable from `revisions`, newest first in date order, with their parents and refs. With no
    /// revisions: every local branch, or for GitButler the workspace. GitButler's own workspace commit and
    /// refs are left out. With `paths`, only commits that touch them.
    public func commitLog(_ revisions: [String] = [], paths: [String] = [], limit: Int = Repository.logLimit) async throws -> [LogCommit] {
        let sources = revisions.isEmpty ? (kind == .gitButler ? ["HEAD"] : ["--branches", "HEAD"]) : revisions
        let format = "%H%x00%P%x00%D%x00%an%x00%ae%x00%aI%x00%B%x1e"
        let output = try await toolchain.git(
            ["log", "--date-order", "--decorate=short", "--format=\(format)", "-n", String(limit)] + sources + ["--"] + paths, in: root)
        var commits = Self.parseCommitLog(output.stdoutString)
        // Asks for the unpushed commits rather than the pushed ones, so old pushed commits outside any window count too.
        let unpushed = try? await toolchain.git(["rev-list", "-n", String(limit)] + sources + ["--not", "--remotes", "--"] + paths, in: root)
        let unpushedSHAs = Set((unpushed?.stdoutString ?? "").split(separator: "\n").map(String.init))
        let onHead = try? await toolchain.git(["rev-list", "-n", String(limit * 2), "HEAD", "--"] + paths, in: root)
        let onHeadSHAs = onHead.map { Set($0.stdoutString.split(separator: "\n").map(String.init)) }
        for index in commits.indices {
            let sha = commits[index].commit.sha
            commits[index].isPushed = unpushed == nil || !unpushedSHAs.contains(sha)
            commits[index].isOnHead = onHeadSHAs?.contains(sha) ?? true
        }
        return commits
    }

    static func parseCommitLog(_ text: String) -> [LogCommit] {
        text.split(separator: "\u{1e}").compactMap { record -> LogCommit? in
            let fields = record.drop { $0 == "\n" }.split(separator: "\0", maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count == 7, !fields[0].isEmpty else { return nil }
            let message = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
            let refs = fields[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var branches: [String] = []
            var tags: [String] = []
            for ref in refs where !ref.isEmpty {
                if ref.hasPrefix("tag: ") {
                    tags.append(String(ref.dropFirst(5)))
                } else {
                    let name = ref.hasPrefix("HEAD -> ") ? String(ref.dropFirst(8)) : ref
                    // Remote branches show as pushed state instead; GitButler's refs are bookkeeping.
                    guard name != "HEAD", !name.contains("/") || !Self.isRemoteRef(name), !name.hasPrefix("gitbutler/") else { continue }
                    branches.append(name)
                }
            }
            // GitButler's merge of the applied stacks is not a commit anyone made.
            let subject = message.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            if subject == "GitButler Workspace Commit" { return nil }
            return LogCommit(
                commit: CommitInfo(
                    sha: String(fields[0]), message: message, authorName: String(fields[3]), authorEmail: String(fields[4]),
                    date: try? Date(String(fields[5]), strategy: .iso8601)),
                parents: fields[1].split(separator: " ").map(String.init),
                branches: branches, tags: tags)
        }
    }

    /// `origin/main`, `upstream/x`: refs under a remote, as `%D` prints them.
    static func isRemoteRef(_ name: String) -> Bool {
        let first = name.prefix { $0 != "/" }
        return ["origin", "upstream"].contains(first) || name.hasPrefix("refs/remotes/")
    }

    /// A git config value, e.g. `user.email`; `nil` when unset.
    public func toolchainGitConfig(_ key: String) async throws -> String? {
        let output = try await toolchain.git(["config", "--get", key], in: root, allowedExitCodes: [0, 1])
        let value = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The default branch's local name, e.g. `main`: `origin/HEAD`'s branch, else `main` or `master`.
    public func defaultBranchName() async -> String? {
        if let output = try? await toolchain.git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root, allowedExitCodes: [0, 1]) {
            let name = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = name.firstIndex(of: "/"), !name.isEmpty { return String(name[name.index(after: slash)...]) }
        }
        for candidate in ["main", "master"] {
            if let output = try? await toolchain.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"], in: root, allowedExitCodes: [0, 1]),
               output.exitCode == 0 {
                return candidate
            }
        }
        return nil
    }

    /// The checked-out commit.
    public func headSHA() async -> String? {
        let output = try? await toolchain.git(["rev-parse", "--verify", "--quiet", "HEAD"], in: root, allowedExitCodes: [0, 1])
        let sha = output?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sha.isEmpty ? nil : sha
    }

    // MARK: Undoing commits

    /// GitButler: reverts the last operation in the oplog, e.g. a commit or discard, with `but undo`.
    public func undoLastOperation() async throws {
        guard kind == .gitButler else { throw UncommitError.notLastCommit }
        _ = try await toolchain.but(["undo"], in: root, timeout: .seconds(60))
    }

    /// Plain git: a new commit that undoes `sha`, on the checked-out branch.
    public func revert(_ sha: String) async throws {
        _ = try await toolchain.git(["revert", "--no-edit", sha], in: root, timeout: .seconds(60))
    }

    /// Takes a commit apart, keeping its changes uncommitted: `but uncommit` in GitButler, a soft reset of the
    /// last commit in plain git.
    public func uncommit(_ sha: String) async throws {
        if kind == .gitButler {
            _ = try await toolchain.but(["uncommit", sha], in: root, timeout: .seconds(60))
        } else {
            let head = try await toolchain.git(["rev-parse", "HEAD"], in: root).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == sha else { throw UncommitError.notLastCommit }
            _ = try await toolchain.git(["reset", "--soft", "HEAD^"], in: root)
        }
    }
}

public enum UncommitError: Error, Sendable, CustomStringConvertible {
    case notLastCommit

    public var description: String {
        switch self {
        case .notLastCommit: "Only the last commit of the checked-out branch can be uncommitted."
        }
    }
}
