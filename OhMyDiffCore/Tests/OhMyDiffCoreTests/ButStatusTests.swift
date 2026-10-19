import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ButStatusTests {
    /// Captured from `but 0.22.3 --json status -f`.
    static let sample = """
    {
      "uncommittedChanges": [
        { "cliId": "kl", "filePath": "c.txt", "changeType": "added" },
        { "cliId": "qs", "filePath": "d.txt", "changeType": "renamed" }
      ],
      "stacks": [
        {
          "cliId": "i0",
          "assignedChanges": [],
          "branches": [
            {
              "cliId": "at",
              "name": "feature/x",
              "commits": [
                {
                  "cliId": "ynt",
                  "changeId": "yntuumlmktzlqwkxopzvvqnqryxptwsn",
                  "commitId": "ec875f67f661f426ffd1a922a3811b51473db649",
                  "createdAt": "2026-10-17T21:35:02+00:00",
                  "message": "edit a\\n\\nbody",
                  "authorName": "t",
                  "authorEmail": "t@t",
                  "conflicted": false,
                  "reviewId": null,
                  "changes": [{ "cliId": "y:n", "filePath": "a.txt", "changeType": "modified" }]
                }
              ],
              "upstreamCommits": [],
              "branchStatus": "completelyUnpushed",
              "reviewId": null,
              "ci": null
            }
          ]
        }
      ],
      "mergeBase": {
        "cliId": "",
        "commitId": "06d2c0237d237b0bddf1ee83ba7969388b3c1a32",
        "createdAt": "2026-10-17T21:34:57+00:00",
        "message": "init\\n",
        "authorName": "t",
        "authorEmail": "t@t",
        "conflicted": null,
        "reviewId": null,
        "changes": null
      },
      "upstreamState": {
        "behind": 2,
        "latestCommit": null,
        "lastFetched": "2026-10-17T21:34:57.368+00:00"
      }
    }
    """

    @Test func decodesCapturedOutput() throws {
        let status = try ButStatus.decode(Data(Self.sample.utf8))
        #expect(status.unassignedChanges.map(\.filePath) == ["c.txt", "d.txt"])
        #expect(status.unassignedChanges.map(\.kind) == [.added, .renamed])

        let branch = try #require(status.stacks.first?.branches.first)
        #expect(status.stacks.first?.id == "feature/x")
        #expect(branch.name == "feature/x")
        #expect(branch.branchStatus == "completelyUnpushed")

        let commit = try #require(branch.commits.first)
        #expect(commit.commitId == "ec875f67f661f426ffd1a922a3811b51473db649")
        #expect(commit.summary == "edit a")
        #expect(commit.createdAt != nil)
        #expect(commit.changes?.map(\.filePath) == ["a.txt"])

        #expect(status.mergeBase?.conflicted == false)
        #expect(status.mergeBase?.changes == nil)
        #expect(status.upstreamState?.behind == 2)
        #expect(status.upstreamState?.lastFetched != nil)
    }

    @Test func toleratesMissingAndMistypedFields() throws {
        let json = """
        {
          "stacks": [
            {
              "branches": [
                { "name": "a", "commits": [{ "commitId": "abc", "conflicted": "yes", "createdAt": 5 }, 42] },
                { "commits": null }
              ],
              "assignedChanges": [{ "filePath": "x", "changeType": "somethingNew" }]
            },
            "garbage"
          ],
          "mergeBase": "not an object",
          "futureField": { "nested": true }
        }
        """
        let status = try ButStatus.decode(Data(json.utf8))
        #expect(status.unassignedChanges.isEmpty)
        #expect(status.stacks.count == 1)
        #expect(status.mergeBase == nil)

        let stack = status.stacks[0]
        #expect(stack.branches.map(\.name) == ["a", ""])
        #expect(stack.branches[0].commits.count == 1)
        #expect(stack.branches[0].commits[0].conflicted == false)
        #expect(stack.branches[0].commits[0].createdAt == nil)
        #expect(stack.assignedChanges[0].kind == .unknown)
    }

    @Test func groupsForGitButler() throws {
        let status = try ButStatus.decode(Data(Self.sample.utf8))
        let renamed = StatusEntry(kind: .renamed, path: "d.txt", originalPath: "b.txt", indexStatus: "R")
        let groups = Repository.butChangeGroups(status, gitStatus: [renamed])

        #expect(groups.map(\.kind) == [.unassigned, .stack(id: "feature/x", branches: ["feature/x"])])
        #expect(groups[1].title == "feature/x")
        let files = groups[0].files
        #expect(files.map(\.path) == ["c.txt", "d.txt"])
        #expect(files.allSatisfy { $0.source == .workspace })
        #expect(files[1].previousPath == "b.txt")
    }

    @Test func rejectsNonJSON() {
        #expect(throws: (any Error).self) { try ButStatus.decode(Data("Error: nope".utf8)) }
    }
}
