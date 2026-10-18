import Foundation

/// One commit in History mode.
public struct CommitInfo: Sendable, Hashable, Identifiable {
    public var sha: String
    /// Full commit message, subject and body.
    public var message: String
    public var authorName: String
    public var authorEmail: String
    public var date: Date?
    public var isConflicted: Bool

    public init(sha: String, message: String, authorName: String = "", authorEmail: String = "", date: Date? = nil, isConflicted: Bool = false) {
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.isConflicted = isConflicted
    }

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var summary: String { message.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces) }

    /// The message after the subject line, without surrounding blank lines.
    public var body: String {
        guard let newline = message.firstIndex(of: "\n") else { return "" }
        return message[newline...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A branch whose commits can be reviewed one by one and as a whole.
public struct HistoryBranch: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        /// Never pushed.
        case unpushed
        /// Has commits the remote branch lacks.
        case unpushedCommits
        /// The local history was rewritten, so pushing needs `--force`.
        case requiresForce
        case upToDate
        /// Already merged into the target.
        case integrated
        /// Plain git: tracking information from `git for-each-ref`.
        case tracking(ahead: Int, behind: Int)
        /// Plain git: the upstream branch was deleted.
        case upstreamGone
    }

    public var name: String
    public var status: Status?
    /// Commits only this branch has, newest first.
    public var commits: [CommitInfo]
    /// The revision the whole-branch diff starts from; `nil` when there is nothing to compare against.
    public var base: String?
    /// The branch tip.
    public var tip: String
    /// What `base` is, for display (e.g. `main` or `feature/one`).
    public var baseName: String?
    /// Plain git: the checked-out branch.
    public var isCurrent: Bool

    public init(
        name: String, status: Status? = nil, commits: [CommitInfo] = [], base: String? = nil, tip: String,
        baseName: String? = nil, isCurrent: Bool = false
    ) {
        self.name = name
        self.status = status
        self.commits = commits
        self.base = base
        self.tip = tip
        self.baseName = baseName
        self.isCurrent = isCurrent
    }

    public var id: String { name }
    public var isConflicted: Bool { commits.contains(where: \.isConflicted) }
}

/// A titled list of branches: a GitButler stack (top branch first) or a repository's local branches.
public struct HistoryGroup: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case stack
        case localBranches
    }

    public var id: String
    public var kind: Kind
    public var branches: [HistoryBranch]

    public init(id: String, kind: Kind, branches: [HistoryBranch]) {
        self.id = id
        self.kind = kind
        self.branches = branches
    }
}

extension HistoryBranch.Status {
    /// Maps `branchStatus` from `but --json status`.
    init?(butStatus: String?) {
        switch butStatus {
        case "completelyUnpushed": self = .unpushed
        case "unpushedCommits": self = .unpushedCommits
        case "unpushedCommitsRequiringForce": self = .requiresForce
        case "nothingToPush": self = .upToDate
        case "integrated": self = .integrated
        default: return nil
        }
    }

    /// Parses `%(upstream:track)`, e.g. `[ahead 2, behind 1]` or `[gone]`; `nil` without an upstream.
    static func tracking(_ value: String, hasUpstream: Bool) -> Self? {
        guard hasUpstream else { return nil }
        if value == "[gone]" { return .upstreamGone }
        func count(_ word: String) -> Int {
            guard let range = value.range(of: "\(word) ") else { return 0 }
            return Int(value[range.upperBound...].prefix(while: \.isNumber)) ?? 0
        }
        let ahead = count("ahead")
        let behind = count("behind")
        return ahead == 0 && behind == 0 ? .upToDate : .tracking(ahead: ahead, behind: behind)
    }
}
