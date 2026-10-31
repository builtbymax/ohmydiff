import Foundation

/// A pull request in the Pull requests inbox: who opened it, who should review it, and how it stands.
public struct InboxPullRequest: Sendable, Hashable, Identifiable {
    public var number: Int
    public var title: String
    public var url: URL
    public var state: PullRequest.State
    public var isDraft: Bool
    public var baseRefName: String
    public var headRefName: String
    public var author: String
    /// Logins and team names asked to review.
    public var reviewRequests: [String]
    public var review: PullRequestStatus.Review?
    public var commentCount: Int
    /// People who commented or reviewed, first seen first, for the avatars.
    public var participants: [String]
    public var updatedAt: Date?
    public var mergedAt: Date?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var checks: PullRequestStatus.Checks

    public var id: Int { number }

    public init(
        number: Int, title: String, url: URL, state: PullRequest.State = .open, isDraft: Bool = false, baseRefName: String = "main",
        headRefName: String = "", author: String = "", reviewRequests: [String] = [], review: PullRequestStatus.Review? = nil,
        commentCount: Int = 0, participants: [String] = [], updatedAt: Date? = nil, mergedAt: Date? = nil, additions: Int = 0,
        deletions: Int = 0, changedFiles: Int = 0, checks: PullRequestStatus.Checks = .none
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.author = author
        self.reviewRequests = reviewRequests
        self.review = review
        self.commentCount = commentCount
        self.participants = participants
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.checks = checks
    }

    /// As the branches' own pull request type, for the actions that take one.
    public var pullRequest: PullRequest {
        PullRequest(number: number, title: title, url: url, state: state, isDraft: isDraft, baseRefName: baseRefName, headRefName: headRefName)
    }

    static let jsonFields = "number,title,url,state,isDraft,baseRefName,headRefName,author,reviewRequests,reviewDecision,comments,reviews,updatedAt,mergedAt,additions,deletions,changedFiles,statusCheckRollup"

    static func decode(_ data: Data) throws -> [InboxPullRequest] {
        let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return objects.compactMap { object in
            guard let number = object["number"] as? Int, let url = (object["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let date = { (key: String) in (object[key] as? String).flatMap { try? Date($0, strategy: .iso8601) } }
            let login = { (value: Any?) in ((value as? [String: Any])?["login"] as? String) }
            let requests = (object["reviewRequests"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String ?? $0["name"] as? String }
            let comments = object["comments"] as? [[String: Any]] ?? []
            let reviews = object["reviews"] as? [[String: Any]] ?? []
            var participants: [String] = []
            for login in (comments + reviews).compactMap({ login($0["author"]) }) where !participants.contains(login) {
                participants.append(login)
            }
            return InboxPullRequest(
                number: number, title: object["title"] as? String ?? "", url: url,
                state: (object["state"] as? String).flatMap(PullRequest.State.init(rawValue:)) ?? .open,
                isDraft: object["isDraft"] as? Bool ?? false, baseRefName: object["baseRefName"] as? String ?? "main",
                headRefName: object["headRefName"] as? String ?? "", author: login(object["author"]) ?? "",
                reviewRequests: requests, review: (object["reviewDecision"] as? String).flatMap(PullRequestStatus.Review.init(rawValue:)),
                commentCount: comments.count + reviews.filter { !(($0["body"] as? String) ?? "").isEmpty }.count,
                participants: participants, updatedAt: date("updatedAt"), mergedAt: date("mergedAt"),
                additions: object["additions"] as? Int ?? 0, deletions: object["deletions"] as? Int ?? 0,
                changedFiles: object["changedFiles"] as? Int ?? 0, checks: PullRequestStatus(object).checks)
        }
    }
}

/// A file of a pull request with whether the user marked it viewed on GitHub.
public struct PullRequestFile: Sendable, Hashable, Identifiable {
    public var path: String
    public var additions: Int
    public var deletions: Int
    public var kind: FileChangeKind
    public var isViewed: Bool

    public var id: String { path }

    public init(path: String, additions: Int = 0, deletions: Int = 0, kind: FileChangeKind = .modified, isViewed: Bool = false) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.kind = kind
        self.isViewed = isViewed
    }
}

/// The files of a pull request and the node ID that marking them viewed needs.
public struct PullRequestFiles: Sendable, Hashable {
    public var nodeID: String
    public var files: [PullRequestFile]

    static func decode(_ data: Data) throws -> PullRequestFiles {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pullRequest = ((object?["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] ?? [:]
        let nodes = (pullRequest["files"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return PullRequestFiles(
            nodeID: pullRequest["id"] as? String ?? "",
            files: nodes.compactMap { node in
                guard let path = node["path"] as? String else { return nil }
                let kind: FileChangeKind = switch node["changeType"] as? String {
                case "ADDED": .added
                case "DELETED": .deleted
                case "RENAMED": .renamed
                case "COPIED": .copied
                default: .modified
                }
                return PullRequestFile(
                    path: path, additions: node["additions"] as? Int ?? 0, deletions: node["deletions"] as? Int ?? 0, kind: kind,
                    isViewed: node["viewerViewedState"] as? String == "VIEWED")
            })
    }
}

/// What a review submits: a comment, or a request for changes.
public enum ReviewVerdict: Sendable {
    case comment
    case requestChanges
    case approve
}

extension Repository {
    /// The signed-in GitHub user's login.
    public func gitHubViewer() async -> String? {
        guard canManagePullRequests,
              let output = try? await toolchain.gh(["api", "user", "--jq", ".login"], in: root, timeout: Self.remoteTimeout)
        else { return nil }
        let login = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }

    /// Open pull requests, and the ones merged lately, newest activity first. Asked for apart, so merged ones
    /// never push older open ones out of the limit.
    public func inbox(limit: Int = 100, mergedLimit: Int = 20) async throws -> [InboxPullRequest] {
        guard canManagePullRequests else { return [] }
        func list(_ state: String, _ limit: Int) async throws -> [InboxPullRequest] {
            let output = try await toolchain.gh(
                ["pr", "list", "--state", state, "--limit", String(limit), "--json", InboxPullRequest.jsonFields], in: root,
                timeout: Self.remoteTimeout)
            return try InboxPullRequest.decode(output.stdout)
        }
        let open = try await list("open", limit)
        let merged = (try? await list("merged", mergedLimit)) ?? []
        return (open + merged).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// A pull request's files with their viewed state, from GitHub's GraphQL API.
    public func files(of number: Int) async throws -> PullRequestFiles {
        let query = """
        query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id \
        files(first:100){nodes{path additions deletions changeType viewerViewedState}}}}}
        """
        let output = try await toolchain.gh(
            ["api", "graphql", "-f", "query=\(query)", "-F", "owner={owner}", "-F", "name={repo}", "-F", "number=\(number)"],
            in: root, timeout: Self.remoteTimeout)
        return try PullRequestFiles.decode(output.stdout)
    }

    /// Marks a file viewed on GitHub, or unmarks it.
    public func setViewed(_ isViewed: Bool, path: String, pullRequestNodeID: String) async throws {
        let mutation = isViewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        let query = "mutation($id:ID!,$path:String!){\(mutation)(input:{pullRequestId:$id,path:$path}){clientMutationId}}"
        _ = try await toolchain.gh(
            ["api", "graphql", "-f", "query=\(query)", "-f", "id=\(pullRequestNodeID)", "-f", "path=\(path)"], in: root, timeout: Self.remoteTimeout)
    }

    /// The pull request's whole diff, as GitHub computes it, without fetching its branch.
    public func diff(ofPullRequest number: Int) async throws -> [FileDiff] {
        let output = try await toolchain.gh(["pr", "diff", String(number), "--color", "never"], in: root, timeout: Self.remoteTimeout)
        return UnifiedDiffParser.parse(output.stdout)
    }

    /// Comments on a pull request, or submits a review asking for changes or approving it.
    public func review(_ number: Int, verdict: ReviewVerdict, body: String) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-review-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(body.utf8).write(to: file)
        let arguments: [String] = switch verdict {
        case .comment: ["pr", "comment", String(number), "--body-file", file.path]
        case .requestChanges: ["pr", "review", String(number), "--request-changes", "--body-file", file.path]
        case .approve: ["pr", "review", String(number), "--approve"] + (body.isEmpty ? [] : ["--body-file", file.path])
        }
        _ = try await toolchain.gh(arguments, in: root, timeout: Self.remoteTimeout)
    }
}
