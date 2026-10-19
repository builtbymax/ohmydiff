import Foundation

// Models for `but --json status`. The CLI's JSON is not a stable contract, so every field is
// decoded leniently: missing keys, nulls and unexpected types fall back to defaults instead of failing.

public struct ButStatus: Sendable, Hashable, Decodable {
    /// Uncommitted changes not assigned to any stack.
    public var unassignedChanges: [ButChange]
    public var stacks: [ButStack]
    public var mergeBase: ButCommit?
    public var upstreamState: ButUpstreamState?

    public init(unassignedChanges: [ButChange] = [], stacks: [ButStack] = [], mergeBase: ButCommit? = nil, upstreamState: ButUpstreamState? = nil) {
        self.unassignedChanges = unassignedChanges
        self.stacks = stacks
        self.mergeBase = mergeBase
        self.upstreamState = upstreamState
    }

    enum CodingKeys: String, CodingKey {
        case uncommittedChanges, stacks, mergeBase, upstreamState
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unassignedChanges = c.lossyArray(.uncommittedChanges)
        stacks = c.lossyArray(.stacks)
        mergeBase = c.lossy(.mergeBase)
        upstreamState = c.lossy(.upstreamState)
    }

    public static func decode(_ data: Data) throws -> ButStatus {
        try JSONDecoder().decode(ButStatus.self, from: data)
    }
}

public struct ButStack: Sendable, Hashable, Decodable, Identifiable {
    public var cliId: String
    public var assignedChanges: [ButChange]
    /// Branches from the top of the stack down to its base.
    public var branches: [ButBranch]

    public var id: String { cliId.isEmpty ? branches.map(\.name).joined(separator: "/") : cliId }

    enum CodingKeys: String, CodingKey {
        case cliId, assignedChanges, branches
    }

    public init(cliId: String = "", assignedChanges: [ButChange] = [], branches: [ButBranch] = []) {
        self.cliId = cliId
        self.assignedChanges = assignedChanges
        self.branches = branches
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cliId = c.lossy(.cliId) ?? ""
        assignedChanges = c.lossyArray(.assignedChanges)
        branches = c.lossyArray(.branches)
    }
}

public struct ButBranch: Sendable, Hashable, Decodable, Identifiable {
    public var cliId: String
    public var name: String
    /// Local commits, newest first.
    public var commits: [ButCommit]
    /// Commits on the remote branch that are not in the local one.
    public var upstreamCommits: [ButCommit]
    /// e.g. `completelyUnpushed`, `nothingToPush`, `unpushedCommits`, `integrated`.
    public var branchStatus: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case cliId, name, commits, upstreamCommits, branchStatus
    }

    public init(cliId: String = "", name: String, commits: [ButCommit] = [], upstreamCommits: [ButCommit] = [], branchStatus: String? = nil) {
        self.cliId = cliId
        self.name = name
        self.commits = commits
        self.upstreamCommits = upstreamCommits
        self.branchStatus = branchStatus
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cliId = c.lossy(.cliId) ?? ""
        name = c.lossy(.name) ?? ""
        commits = c.lossyArray(.commits)
        upstreamCommits = c.lossyArray(.upstreamCommits)
        branchStatus = c.lossy(.branchStatus)
    }
}

public struct ButCommit: Sendable, Hashable, Decodable, Identifiable {
    public var cliId: String
    public var changeId: String?
    public var commitId: String
    public var createdAt: Date?
    public var message: String
    public var authorName: String?
    public var authorEmail: String?
    public var conflicted: Bool
    /// Files touched by the commit; only present with `but status -f`.
    public var changes: [ButChange]?

    public var id: String { commitId }
    public var summary: String { message.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces) }

    enum CodingKeys: String, CodingKey {
        case cliId, changeId, commitId, createdAt, message, authorName, authorEmail, conflicted, changes
    }

    public init(
        cliId: String = "", changeId: String? = nil, commitId: String, createdAt: Date? = nil, message: String = "",
        authorName: String? = nil, authorEmail: String? = nil, conflicted: Bool = false, changes: [ButChange]? = nil
    ) {
        self.cliId = cliId
        self.changeId = changeId
        self.commitId = commitId
        self.createdAt = createdAt
        self.message = message
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.conflicted = conflicted
        self.changes = changes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cliId = c.lossy(.cliId) ?? ""
        changeId = c.lossy(.changeId)
        commitId = c.lossy(.commitId) ?? ""
        createdAt = (c.lossy(.createdAt) as String?).flatMap(ButDate.parse)
        message = c.lossy(.message) ?? ""
        authorName = c.lossy(.authorName)
        authorEmail = c.lossy(.authorEmail)
        conflicted = c.lossy(.conflicted) ?? false
        changes = (c.lossy(.changes) as [Lossy<ButChange>]?)?.compactMap(\.value)
    }
}

public struct ButChange: Sendable, Hashable, Decodable, Identifiable {
    public var cliId: String
    public var filePath: String
    /// Raw value such as `added`, `modified`, `deleted`, `renamed`.
    public var changeType: String

    public var id: String { filePath }

    public var kind: FileChangeKind {
        switch changeType.lowercased() {
        case "added", "addition": .added
        case "deleted", "deletion", "removed": .deleted
        case "modified", "modification": .modified
        case "renamed", "rename": .renamed
        case "copied": .copied
        case "typechanged", "typechange": .typeChanged
        case "conflicted": .conflicted
        default: .unknown
        }
    }

    enum CodingKeys: String, CodingKey {
        case cliId, filePath, changeType
    }

    public init(cliId: String = "", filePath: String, changeType: String) {
        self.cliId = cliId
        self.filePath = filePath
        self.changeType = changeType
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cliId = c.lossy(.cliId) ?? ""
        filePath = c.lossy(.filePath) ?? ""
        changeType = c.lossy(.changeType) ?? ""
    }
}

public struct ButUpstreamState: Sendable, Hashable, Decodable {
    /// Commits on the target branch not yet integrated into the workspace.
    public var behind: Int
    public var latestCommit: ButCommit?
    public var lastFetched: Date?

    enum CodingKeys: String, CodingKey {
        case behind, latestCommit, lastFetched
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        behind = c.lossy(.behind) ?? 0
        latestCommit = c.lossy(.latestCommit)
        lastFetched = (c.lossy(.lastFetched) as String?).flatMap(ButDate.parse)
    }
}

enum ButDate {
    static func parse(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601) { return date }
        return try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, returning `nil` for missing keys, nulls and type mismatches.
    func lossy<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(Lossy<T>.self, forKey: key))??.value
    }

    /// Decodes an array, dropping elements that fail to decode.
    func lossyArray<T: Decodable>(_ key: Key) -> [T] {
        guard let items = try? decodeIfPresent([Lossy<T>].self, forKey: key) else { return [] }
        return items.compactMap(\.value)
    }
}
