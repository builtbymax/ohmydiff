import Foundation

/// A pull request on GitHub, as `gh` reports it.
public struct PullRequest: Sendable, Hashable, Decodable, Identifiable {
    public enum State: String, Sendable, Hashable, Decodable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    public var number: Int
    public var title: String
    public var url: URL
    public var state: State
    public var isDraft: Bool
    public var baseRefName: String
    /// The branch the pull request comes from.
    public var headRefName: String?

    public init(
        number: Int, title: String, url: URL, state: State, isDraft: Bool = false, baseRefName: String = "main", headRefName: String? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.baseRefName = baseRefName
        self.headRefName = headRefName
    }

    public var id: Int { number }

    static let jsonFields = "number,title,url,state,isDraft,baseRefName,headRefName"
}

public enum MergeMethod: String, Sendable, CaseIterable {
    case squash, merge, rebase

    public var title: String {
        switch self {
        case .squash: "Squash and Merge"
        case .merge: "Create a Merge Commit"
        case .rebase: "Rebase and Merge"
        }
    }
}

/// Pushing branches and their pull requests. GitButler branches go through `but push` and `but pr`, which
/// keep stacks intact; plain branches through `git push` and `gh pr create`. Reading and changing an existing
/// pull request uses `gh` for both.
extension Repository {
    /// Whether `gh` is installed, which reading and changing pull requests needs.
    public var canManagePullRequests: Bool { toolchain.gh != nil }

    /// The newest pull request whose head is `branch`, in any state; `nil` when there is none or `gh` is missing.
    public func pullRequest(forBranch branch: String) async throws -> PullRequest? {
        guard canManagePullRequests else { return nil }
        let output = try await toolchain.gh(
            ["pr", "list", "--head", branch, "--state", "all", "--limit", "1", "--json", PullRequest.jsonFields],
            in: root, timeout: Self.remoteTimeout)
        return try JSONDecoder().decode([PullRequest].self, from: output.stdout).first
    }

    /// The newest pull request of every branch, by branch name, in one `gh` call; empty without `gh`.
    public func pullRequests() async throws -> [String: PullRequest] {
        guard canManagePullRequests else { return [:] }
        let output = try await toolchain.gh(
            ["pr", "list", "--state", "all", "--limit", "200", "--json", PullRequest.jsonFields], in: root, timeout: Self.remoteTimeout)
        var byBranch: [String: PullRequest] = [:]
        // `gh` lists the newest first, so the first one per branch wins.
        for pullRequest in try JSONDecoder().decode([PullRequest].self, from: output.stdout) {
            guard let head = pullRequest.headRefName, byBranch[head] == nil else { continue }
            byBranch[head] = pullRequest
        }
        return byBranch
    }

    /// Pushes a branch, setting its upstream. GitButler pushes the branches below it in its stack too and
    /// force-pushes rewritten history; plain git force-pushes only with `force`, and then with a lease.
    public func push(branch: String, force: Bool = false) async throws {
        switch kind {
        case .gitButler:
            _ = try await toolchain.but(["push", branch], in: root, timeout: Self.remoteTimeout)
        case .git:
            let remote = try await pushRemote()
            _ = try await toolchain.git(
                ["push", "--quiet", "--set-upstream"] + (force ? ["--force-with-lease"] : []) + [remote, branch],
                in: root, timeout: Self.remoteTimeout)
        }
    }

    /// Pushes the branch and opens a pull request for it; the first line of `text` is the title, the rest
    /// the description.
    public func createPullRequest(branch: String, text: String, isDraft: Bool) async throws -> PullRequest? {
        let (title, body) = Self.pullRequestParts(text)
        let file = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-pr-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }

        switch kind {
        case .gitButler:
            try Data((title + "\n\n" + body).utf8).write(to: file)
            _ = try await toolchain.but(
                ["pr", "new", branch, "-F", file.path] + (isDraft ? ["--draft"] : []), in: root, timeout: Self.remoteTimeout)
        case .git:
            try await push(branch: branch)
            try Data(body.utf8).write(to: file)
            var arguments = ["pr", "create", "--head", branch, "--title", title, "--body-file", file.path]
            if let base = await pullRequestBase(for: branch) { arguments += ["--base", base] }
            if isDraft { arguments.append("--draft") }
            _ = try await toolchain.gh(arguments, in: root, timeout: Self.remoteTimeout)
        }
        return try? await pullRequest(forBranch: branch)
    }

    public func setDraft(_ isDraft: Bool, pullRequest: PullRequest) async throws {
        _ = try await toolchain.gh(
            ["pr", "ready", String(pullRequest.number)] + (isDraft ? ["--undo"] : []), in: root, timeout: Self.remoteTimeout)
    }

    /// Merges on the forge; the local branches catch up with the next update from the upstream.
    public func merge(_ pullRequest: PullRequest, method: MergeMethod) async throws {
        _ = try await toolchain.gh(
            ["pr", "merge", String(pullRequest.number), "--\(method.rawValue)"], in: root, timeout: Self.remoteTimeout)
    }

    /// A drafted text as a title and a description: the first non-empty line, without a Markdown heading
    /// marker or a `Title:` label, and everything below it.
    static func pullRequestParts(_ text: String) -> (title: String, body: String) {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard !lines.isEmpty else { return ("", "") }
        var title = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        while title.hasPrefix("#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return (title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `origin`, or the only remote.
    private func pushRemote() async throws -> String {
        let remotes = try await toolchain.git(["remote"], in: root).stdoutString.split(separator: "\n").map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first ?? "origin"
    }

    /// The default branch, unless that is the branch itself.
    private func pullRequestBase(for branch: String) async -> String? {
        guard let names = try? await toolchain.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: root)
            .stdoutString.split(separator: "\n").map(String.init),
            let base = await defaultBranch(local: names), base != branch
        else { return nil }
        return base
    }
}
