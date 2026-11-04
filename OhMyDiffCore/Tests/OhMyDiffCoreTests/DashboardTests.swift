import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct DashboardTests {
    @Test func groupsPathsIntoAreas() {
        #expect(Dashboard.area(of: "src/features/a/b.ts") == "src/features")
        #expect(Dashboard.area(of: "docs/a.md") == "docs")
        #expect(Dashboard.area(of: "README.md") == nil)
    }

    @Test func countsCommitsByDayPersonAndArea() throws {
        let now = try Date("2026-11-04T12:00:00Z", strategy: .iso8601)
        let since = Calendar.current.startOfDay(for: now.addingTimeInterval(-2 * 86_400))
        let log = Repository.parseDashboardLog("""
            \u{1e}a\0Ada\0ada@example.com\0\(now.formatted(.iso8601))\0feat: one

            src/app/a.ts
            src/app/b.ts
            README.md
            \u{1e}b\0Bob\0bob@example.com\0\(now.addingTimeInterval(-86_400).formatted(.iso8601))\0fix: two

            docs/x.md
            \u{1e}c\0Ada\0ADA@example.com\0\(now.addingTimeInterval(-86_400).formatted(.iso8601))\0chore: three
            """)
        var dashboard = Dashboard(days: 3, mainLine: "origin/main", commits: [], commitsPerDay: [], people: [], areas: [], releases: [], landed: [])
        dashboard.apply(log, since: since, now: now)

        #expect(dashboard.commits.map(\.summary) == ["feat: one", "fix: two", "chore: three"])
        #expect(dashboard.commitsPerDay == [0, 2, 1])
        #expect(dashboard.people.map(\.name) == ["Ada", "Bob"])
        #expect(dashboard.people.map(\.commits) == [2, 1])
        // One commit counts once per area, however many of its files are there.
        #expect(dashboard.areas.map(\.path) == ["docs", "src/app", nil])
        #expect(dashboard.areas.map(\.commits) == [1, 1, 1])
    }

    @Test func measuresLandedPullRequests() throws {
        let json = """
            [{"number":1,"title":"small","url":"https://github.com/o/r/pull/1","author":{"login":"ada"},
              "createdAt":"2026-11-01T10:00:00Z","mergedAt":"2026-11-01T12:00:00Z","additions":3,"deletions":1,"changedFiles":1},
             {"number":2,"title":"big","url":"https://github.com/o/r/pull/2","author":{"login":"bob"},
              "createdAt":"2026-11-02T10:00:00Z","mergedAt":"2026-11-03T10:00:00Z","additions":300,"deletions":20,"changedFiles":9},
             {"number":3,"title":"medium","url":"https://github.com/o/r/pull/3","author":{"login":"ada"},
              "createdAt":"2026-11-03T10:00:00Z","mergedAt":"2026-11-03T14:00:00Z","additions":30,"deletions":2,"changedFiles":3}]
            """
        let landed = try LandedPullRequest.decode(Data(json.utf8))
        #expect(landed.map(\.number) == [3, 2, 1])
        let dashboard = Dashboard(days: 30, mainLine: "origin/main", commits: [], commitsPerDay: [], people: [], areas: [], releases: [], landed: landed)
        #expect(dashboard.medianTimeToLand == TimeInterval(4 * 3600))
        #expect(dashboard.largest(2).map(\.number) == [2, 3])
    }

    @Test func readsTheMainLineAndReleases() async throws {
        let repo = try await TestRepo()
        try repo.write("src/app/a.ts", "a\n")
        try await repo.commitAll("one")
        try await repo.git("tag", "v1.0.0")
        try repo.write("docs/b.md", "b\n")
        try await repo.commitAll("two")
        try repo.write("c.txt", "c\n")
        try await repo.commitAll("three")
        try await repo.git("tag", "v1.1.0")
        let repository = try await repo.open()

        let dashboard = try await repository.dashboard()
        #expect(dashboard.mainLine == "main")
        #expect(dashboard.commits.count == 3)
        #expect(dashboard.commitsPerDay.last == 3)
        #expect(dashboard.people.map(\.commits) == [3])
        #expect(Set(dashboard.releases.map(\.name)) == ["v1.0.0", "v1.1.0"])
        #expect(dashboard.releases.first { $0.name == "v1.1.0" }?.commits.map { $0 == 2 } ?? true)
        #expect(dashboard.releaseCount() == 2)
    }
}
