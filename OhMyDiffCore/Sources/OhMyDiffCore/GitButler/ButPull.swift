import Foundation

// Models for `but pull --check --json` and `but pull --json`, decoded as leniently as `ButStatus`.

struct ButPullCheck: Sendable, Decodable {
    struct BaseBranch: Sendable, Decodable {
        var name: String

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lossy(.name) ?? "origin"
        }

        enum CodingKeys: String, CodingKey { case name }
    }

    struct Commits: Sendable, Decodable {
        var commits: [Commit]

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            commits = c.lossyArray(.commits)
        }

        enum CodingKeys: String, CodingKey { case commits }
    }

    struct Commit: Sendable, Decodable {
        var id: String
        var description: String
        var authorName: String

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lossy(.id) ?? ""
            description = c.lossy(.description) ?? ""
            authorName = c.lossy(.authorName) ?? ""
        }

        enum CodingKeys: String, CodingKey { case id, description, authorName }
    }

    struct Branch: Sendable, Decodable {
        var name: String
        /// `updatable`, `integrated`, `conflicted`, …
        var status: String

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lossy(.name) ?? ""
            status = c.lossy(.status) ?? ""
        }

        enum CodingKeys: String, CodingKey { case name, status }
    }

    var baseBranch: BaseBranch?
    var upstreamCommits: Commits?
    var branchStatuses: [Branch]
    var hasWorktreeConflicts: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseBranch = c.lossy(.baseBranch)
        upstreamCommits = c.lossy(.upstreamCommits)
        branchStatuses = c.lossyArray(.branchStatuses)
        hasWorktreeConflicts = c.lossy(.hasWorktreeConflicts) ?? false
    }

    enum CodingKeys: String, CodingKey { case baseBranch, upstreamCommits, branchStatuses, hasWorktreeConflicts }

    var upstreamStatus: UpstreamStatus {
        UpstreamStatus(
            target: baseBranch?.name ?? "origin",
            incoming: (upstreamCommits?.commits ?? []).filter { !$0.id.isEmpty }.map {
                CommitInfo(sha: $0.id, message: $0.description.trimmingCharacters(in: .whitespacesAndNewlines), authorName: $0.authorName)
            },
            branches: branchStatuses.filter { !$0.name.isEmpty }.map { BranchUpdate(name: $0.name, action: Self.action($0.status)) },
            hasWorktreeConflicts: hasWorktreeConflicts)
    }

    static func action(_ status: String) -> BranchUpdate.Action {
        switch status {
        case "integrated": .integrated
        case let status where status.hasPrefix("conflicted"): .conflicts
        default: .rebase
        }
    }
}

struct ButPullResult: Sendable, Decodable {
    struct Branch: Sendable, Decodable {
        var name: String
        var status: String

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lossy(.name) ?? ""
            status = c.lossy(.status) ?? ""
        }

        enum CodingKeys: String, CodingKey { case name, status }
    }

    var branchesToUpdate: [Branch]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        branchesToUpdate = c.lossyArray(.branchesToUpdate)
    }

    enum CodingKeys: String, CodingKey { case branchesToUpdate }

    var result: UpstreamUpdateResult {
        var result = UpstreamUpdateResult()
        for branch in branchesToUpdate where !branch.name.isEmpty {
            switch ButPullCheck.action(branch.status) {
            case .integrated: result.integrated.append(branch.name)
            case .conflicts: result.conflicted.append(branch.name)
            default: result.updated.append(branch.name)
            }
        }
        return result
    }
}
