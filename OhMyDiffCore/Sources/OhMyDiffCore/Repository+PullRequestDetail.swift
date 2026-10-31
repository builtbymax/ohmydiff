import Foundation

/// What the Branches page shows of a pull request beyond its status: each check, the description on GitHub,
/// and how many commits and files it has.
public struct PullRequestDetail: Sendable, Hashable {
    public struct Check: Sendable, Hashable, Identifiable {
        public enum State: Sendable, Hashable {
            case passed, failed, running, queued, skipped
        }

        public var name: String
        public var state: State
        public var startedAt: Date?
        public var completedAt: Date?

        public init(name: String, state: State, startedAt: Date? = nil, completedAt: Date? = nil) {
            self.name = name
            self.state = state
            self.startedAt = startedAt
            self.completedAt = completedAt
        }

        public var id: String { name }

        /// How long a finished check ran.
        public var duration: Duration? {
            guard let startedAt, let completedAt, completedAt >= startedAt else { return nil }
            return .seconds(completedAt.timeIntervalSince(startedAt))
        }
    }

    public var body: String
    public var author: String?
    public var commitCount: Int
    public var changedFiles: Int
    public var checks: [Check]
    /// Whether GitHub merges it by itself once the checks pass.
    public var autoMerge: Bool

    public init(body: String = "", author: String? = nil, commitCount: Int = 0, changedFiles: Int = 0, checks: [Check] = [], autoMerge: Bool = false) {
        self.body = body
        self.author = author
        self.commitCount = commitCount
        self.changedFiles = changedFiles
        self.checks = checks
        self.autoMerge = autoMerge
    }

    public var runningCheckCount: Int { checks.count { $0.state == .running || $0.state == .queued } }

    static let jsonFields = "body,author,commits,changedFiles,statusCheckRollup,autoMergeRequest"

    static func decode(_ data: Data) throws -> PullRequestDetail {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return PullRequestDetail() }
        let rollup = object["statusCheckRollup"] as? [[String: Any]] ?? []
        return PullRequestDetail(
            body: object["body"] as? String ?? "",
            author: (object["author"] as? [String: Any])?["login"] as? String,
            commitCount: (object["commits"] as? [Any])?.count ?? 0,
            changedFiles: object["changedFiles"] as? Int ?? 0,
            checks: rollup.map(check),
            autoMerge: !(object["autoMergeRequest"] is NSNull) && object["autoMergeRequest"] != nil)
    }

    /// A check run (`status`, `conclusion`) or a commit status (`state`), as `statusCheckRollup` lists them.
    private static func check(_ object: [String: Any]) -> Check {
        let name = (object["name"] as? String) ?? (object["context"] as? String) ?? "check"
        let date = { (key: String) in (object[key] as? String).flatMap { try? Date($0, strategy: .iso8601) } }
        let state: Check.State
        if let status = object["status"] as? String {
            switch status {
            case "COMPLETED":
                switch object["conclusion"] as? String ?? "" {
                case "SUCCESS", "NEUTRAL": state = .passed
                case "SKIPPED": state = .skipped
                default: state = .failed
                }
            case "IN_PROGRESS": state = .running
            default: state = .queued
            }
        } else {
            switch object["state"] as? String ?? "" {
            case "SUCCESS": state = .passed
            case "FAILURE", "ERROR": state = .failed
            case "PENDING": state = .running
            default: state = .queued
            }
        }
        // A commit status has no start; GitHub's year-one date stands for "not started".
        let started = date("startedAt").flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        let completed = date("completedAt").flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        return Check(name: name, state: state, startedAt: started, completedAt: completed)
    }
}

extension Repository {
    public func detail(of pullRequest: PullRequest) async throws -> PullRequestDetail {
        let output = try await toolchain.gh(
            ["pr", "view", String(pullRequest.number), "--json", PullRequestDetail.jsonFields], in: root, timeout: Self.remoteTimeout)
        return try PullRequestDetail.decode(output.stdout)
    }

    /// Replaces the pull request's description on GitHub.
    public func setDescription(_ body: String, of pullRequest: PullRequest) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-pr-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(body.utf8).write(to: file)
        _ = try await toolchain.gh(["pr", "edit", String(pullRequest.number), "--body-file", file.path], in: root, timeout: Self.remoteTimeout)
    }

    /// Merge when green: GitHub merges the pull request once its required checks pass. Turning it off cancels that.
    public func setAutoMerge(_ isOn: Bool, pullRequest: PullRequest, method: MergeMethod) async throws {
        let arguments = isOn ? ["--auto", "--\(method.rawValue)"] : ["--disable-auto"]
        _ = try await toolchain.gh(["pr", "merge", String(pullRequest.number)] + arguments, in: root, timeout: Self.remoteTimeout)
    }

    /// A new, empty branch: an applied GitButler branch of its own, or a plain git branch from the checked-out
    /// commit that is switched to, keeping uncommitted changes.
    public func createBranch(_ name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard try await isValidBranchName(name) else { throw ChangeActionError.invalidBranchName(name) }
        switch kind {
        case .gitButler: _ = try await toolchain.but(["branch", "new", name], in: root, timeout: .seconds(60))
        case .git: _ = try await toolchain.git(["switch", "--quiet", "--create", name], in: root)
        }
    }
}
