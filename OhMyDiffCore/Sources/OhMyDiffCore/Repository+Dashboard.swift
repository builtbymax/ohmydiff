import Foundation

/// What landed on the main line lately: commits by day, by person and by folder, the releases, and the pull
/// requests merged.
public struct Dashboard: Sendable, Hashable {
    /// The days looked back over, today included.
    public var days: Int
    /// The ref the commits are counted on, e.g. `origin/main`.
    public var mainLine: String
    /// The main line's commits in the window, newest first.
    public var commits: [CommitInfo]
    /// Commits per day, oldest first, one entry per day of the window.
    public var commitsPerDay: [Int]
    /// Who committed, most commits first.
    public var people: [Person]
    /// The folders the commits touched, most commits first.
    public var areas: [Area]
    /// The latest tags, newest first.
    public var releases: [Release]
    /// Pull requests merged in the window, newest first; empty without GitHub.
    public var landed: [LandedPullRequest]

    public struct Person: Sendable, Hashable, Identifiable {
        public var name: String
        public var email: String
        public var commits: Int
        public var id: String { email.isEmpty ? name : email.lowercased() }
    }

    /// A folder two levels deep at most, e.g. `src/features`, or `nil` for files at the top level.
    public struct Area: Sendable, Hashable, Identifiable {
        public var path: String?
        public var commits: Int
        public var id: String { path ?? "" }
    }

    public struct Release: Sendable, Hashable, Identifiable {
        public var name: String
        public var date: Date?
        /// Commits since the release before it; `nil` for the oldest one listed.
        public var commits: Int?
        public var id: String { name }
    }

    /// Commits in the last seven days.
    public var commitsLastWeek: Int { commitsPerDay.suffix(7).reduce(0, +) }

    /// Releases tagged in the window.
    public func releaseCount(now: Date = Date()) -> Int {
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        return releases.filter { ($0.date ?? .distantPast) >= start }.count
    }

    /// The median time from opening a pull request to merging it.
    public var medianTimeToLand: TimeInterval? {
        let durations = landed.compactMap { pullRequest in
            pullRequest.mergedAt.map { $0.timeIntervalSince(pullRequest.createdAt) }
        }.sorted()
        guard !durations.isEmpty else { return nil }
        let middle = durations.count / 2
        return durations.count.isMultiple(of: 2) ? (durations[middle - 1] + durations[middle]) / 2 : durations[middle]
    }

    /// The merged pull requests with the most changed lines.
    public func largest(_ count: Int = 5) -> [LandedPullRequest] {
        Array(landed.sorted { $0.additions + $0.deletions > $1.additions + $1.deletions }.prefix(count))
    }
}

/// A pull request merged into the repository.
public struct LandedPullRequest: Sendable, Hashable, Identifiable {
    public var number: Int
    public var title: String
    public var url: URL
    public var author: String
    public var createdAt: Date
    public var mergedAt: Date?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var id: Int { number }

    static let jsonFields = "number,title,url,author,createdAt,mergedAt,additions,deletions,changedFiles"

    static func decode(_ data: Data) throws -> [LandedPullRequest] {
        let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let date = { (value: Any?) in (value as? String).flatMap { try? Date($0, strategy: .iso8601) } }
        return objects.compactMap { object in
            guard let number = object["number"] as? Int, let url = (object["url"] as? String).flatMap(URL.init(string:)),
                  let createdAt = date(object["createdAt"])
            else { return nil }
            return LandedPullRequest(
                number: number, title: object["title"] as? String ?? "", url: url,
                author: (object["author"] as? [String: Any])?["login"] as? String ?? "", createdAt: createdAt,
                mergedAt: date(object["mergedAt"]), additions: object["additions"] as? Int ?? 0,
                deletions: object["deletions"] as? Int ?? 0, changedFiles: object["changedFiles"] as? Int ?? 0)
        }
        .sorted { ($0.mergedAt ?? $0.createdAt) > ($1.mergedAt ?? $1.createdAt) }
    }
}

extension Repository {
    /// The main line's last `days` days; the remote's copy of the default branch when there is one.
    public func dashboard(days: Int = 30, now: Date = Date()) async throws -> Dashboard {
        let mainLine = await mainLineRef()
        let since = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(days - 1) * 86_400))
        var dashboard = Dashboard(days: days, mainLine: mainLine ?? "HEAD", commits: [], commitsPerDay: [], people: [], areas: [], releases: [], landed: [])
        if let mainLine {
            let output = try await toolchain.git(
                ["log", "--since=\(since.formatted(.iso8601))", "--format=\u{1e}%H%x00%an%x00%ae%x00%aI%x00%s", "--name-only", mainLine, "--"],
                in: root)
            dashboard.apply(Self.parseDashboardLog(output.stdoutString), since: since, now: now)
        }
        dashboard.releases = try await releases()
        if canManagePullRequests {
            let day = since.formatted(.iso8601.year().month().day())
            let output = try? await toolchain.gh(
                ["pr", "list", "--state", "merged", "--search", "merged:>=\(day)", "--limit", "200", "--json", LandedPullRequest.jsonFields],
                in: root, timeout: Self.remoteTimeout)
            dashboard.landed = (output.flatMap { try? LandedPullRequest.decode($0.stdout) }) ?? []
        }
        return dashboard
    }

    /// `origin/<default>` when it exists, else the local default branch, else HEAD.
    private func mainLineRef() async -> String? {
        let name = await defaultBranchName()
        for candidate in [name.map { "refs/remotes/origin/\($0)" }, name.map { "refs/heads/\($0)" }, "HEAD"].compactMap(\.self) {
            if let output = try? await toolchain.git(["rev-parse", "--verify", "--quiet", candidate], in: root, allowedExitCodes: [0, 1]),
               output.exitCode == 0 {
                return candidate.replacingOccurrences(of: "refs/remotes/", with: "").replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        return nil
    }

    /// The newest tags with the commits each added since the one before.
    private func releases(limit: Int = 8) async throws -> [Dashboard.Release] {
        let output = try await toolchain.git(
            ["for-each-ref", "--sort=-creatordate", "--count=\(limit + 1)", "--format=%(refname:short)%00%(creatordate:iso-strict)", "refs/tags"],
            in: root)
        let tags = output.stdoutString.split(separator: "\n").map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            return (name: String(fields[0]), date: fields.count > 1 ? try? Date(String(fields[1]), strategy: .iso8601) : nil)
        }
        var releases: [Dashboard.Release] = []
        for (index, tag) in tags.prefix(limit).enumerated() {
            var commits: Int?
            if tags.indices.contains(index + 1),
               let count = try? await toolchain.git(["rev-list", "--count", "\(tags[index + 1].name)..\(tag.name)"], in: root) {
                commits = Int(count.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            releases.append(Dashboard.Release(name: tag.name, date: tag.date, commits: commits))
        }
        return releases
    }

    /// One record per commit: its fields, then the paths it touched.
    static func parseDashboardLog(_ text: String) -> [(commit: CommitInfo, paths: [String])] {
        text.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\0", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            let commit = CommitInfo(
                sha: fields[0], message: fields[4], authorName: fields[1], authorEmail: fields[2], date: try? Date(fields[3], strategy: .iso8601))
            return (commit, lines.dropFirst().map(String.init))
        }
    }
}

extension Dashboard {
    /// Folds the parsed log into the per-day, per-person and per-folder counts.
    mutating func apply(_ log: [(commit: CommitInfo, paths: [String])], since: Date, now: Date) {
        let calendar = Calendar.current
        commits = log.map(\.commit)
        commitsPerDay = Array(repeating: 0, count: days)
        var people: [String: Person] = [:]
        var areas: [String?: Int] = [:]
        for (commit, paths) in log {
            if let date = commit.date {
                let day = calendar.dateComponents([.day], from: since, to: calendar.startOfDay(for: date)).day ?? -1
                if commitsPerDay.indices.contains(day) { commitsPerDay[day] += 1 }
            }
            let person = Person(name: commit.authorName, email: commit.authorEmail, commits: 0)
            people[person.id, default: person].commits += 1
            for area in Set(paths.map(Self.area)) { areas[area, default: 0] += 1 }
        }
        self.people = people.values.sorted { ($0.commits, $1.name) > ($1.commits, $0.name) }
        // On a tie, named folders come before the top level, then by name.
        self.areas = areas.map { Area(path: $0.key, commits: $0.value) }.sorted { a, b in
            if a.commits != b.commits { return a.commits > b.commits }
            if (a.path == nil) != (b.path == nil) { return b.path == nil }
            return a.id < b.id
        }
    }

    /// `src/features/a/b.ts` → `src/features`, `docs/a.md` → `docs`, `README.md` → `nil`.
    static func area(of path: String) -> String? {
        let folders = path.split(separator: "/").dropLast()
        return folders.isEmpty ? nil : folders.prefix(2).joined(separator: "/")
    }
}
