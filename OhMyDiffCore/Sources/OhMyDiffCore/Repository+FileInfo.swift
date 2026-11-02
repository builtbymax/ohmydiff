import Foundation

/// A commit that last changed some lines of a file, from `git blame`.
public struct BlameCommit: Sendable, Hashable, Identifiable {
    public var commit: CommitInfo
    /// How many of the asked-about lines it last changed.
    public var lineCount: Int

    public init(commit: CommitInfo, lineCount: Int) {
        self.commit = commit
        self.lineCount = lineCount
    }

    public var id: String { commit.sha }
}

/// The latest commits that touched a file, and how many there are in all.
public struct FileHistory: Sendable, Hashable {
    public var commits: [LogCommit]
    public var count: Int

    public init(commits: [LogCommit], count: Int) {
        self.commits = commits
        self.count = count
    }
}

extension Repository {
    /// The newest `limit` commits on HEAD that touched `path`, and how many did.
    public func fileHistory(of path: String, limit: Int = 4) async throws -> FileHistory {
        async let commits = commitLog(["HEAD"], paths: [path], limit: limit)
        let count = try await toolchain.git(["rev-list", "--count", "HEAD", "--", path], in: root, allowedExitCodes: [0, 128])
        return FileHistory(commits: try await commits, count: Int(count.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    /// The commits that last changed `lines` of `path` at HEAD, newest first; empty when HEAD has no such file.
    public func blame(_ path: String, lines: ClosedRange<Int>) async throws -> [BlameCommit] {
        let output = try await toolchain.git(
            ["blame", "--porcelain", "-L", "\(lines.lowerBound),\(lines.upperBound)", "HEAD", "--", path], in: root,
            allowedExitCodes: [0, 128])
        guard output.exitCode == 0 else { return [] }
        return Self.parseBlame(output.stdoutString)
    }

    /// `git blame --porcelain`: a `<sha> <old> <new> [<count>]` header per line, the commit's fields the first
    /// time it appears, then the line itself after a tab.
    static func parseBlame(_ text: String) -> [BlameCommit] {
        var order: [String] = []
        var fields: [String: [String: String]] = [:]
        var counts: [String: Int] = [:]
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                if let current { counts[current, default: 0] += 1 }
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first.map(String.init) else { continue }
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                current = key
                if fields[key] == nil {
                    fields[key] = [:]
                    order.append(key)
                }
            } else if let current, parts.count == 2 {
                fields[current]?[key] = String(parts[1])
            }
        }
        return order
            // Lines not committed yet blame to the zero SHA.
            .filter { !$0.allSatisfy { $0 == "0" } }
            .map { sha in
                let values = fields[sha] ?? [:]
                let date = values["author-time"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                let email = values["author-mail"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) } ?? ""
                return BlameCommit(
                    commit: CommitInfo(sha: sha, message: values["summary"] ?? "", authorName: values["author"] ?? "", authorEmail: email, date: date),
                    lineCount: counts[sha] ?? 0)
            }
            .sorted { ($0.commit.date ?? .distantPast) > ($1.commit.date ?? .distantPast) }
    }
}
