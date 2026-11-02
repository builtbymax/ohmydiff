import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct FileInfoTests {
    @Test func parsesPorcelainBlame() {
        let old = String(repeating: "a", count: 40)
        let new = String(repeating: "b", count: 40)
        let text = """
            \(old) 1 1 1
            author Ada
            author-mail <ada@example.com>
            author-time 1792310400
            summary First line
            filename a.txt
            \tone
            \(new) 2 2 2
            author Bob
            author-mail <bob@example.com>
            author-time 1792396800
            summary Second
            filename a.txt
            \ttwo
            \(new) 3 3
            \tthree
            \(String(repeating: "0", count: 40)) 4 4 1
            author Not Committed Yet
            summary Version of a.txt from a.txt
            \tfour

            """
        let commits = Repository.parseBlame(text)
        #expect(commits.map(\.id) == [new, old])
        #expect(commits[0].commit.summary == "Second" && commits[0].lineCount == 2)
        #expect(commits[1].commit.authorName == "Ada" && commits[1].commit.authorEmail == "ada@example.com")
        #expect(commits[1].commit.date == Date(timeIntervalSince1970: 1_792_310_400))
    }

    @Test func listsFileHistoryAndBlame() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("add a")
        try repo.write("b.txt", "other\n")
        try await repo.commitAll("add b")
        try repo.write("a.txt", "one\nTWO\n")
        try await repo.commitAll("shout two")

        let repository = try await repo.open()
        let history = try await repository.fileHistory(of: "a.txt", limit: 1)
        #expect(history.count == 2)
        #expect(history.commits.map(\.commit.summary) == ["shout two"])
        #expect(history.commits.first?.isPushed == false)

        let blame = try await repository.blame("a.txt", lines: 1...2)
        #expect(blame.map(\.commit.summary).sorted() == ["add a", "shout two"])
        #expect(try await repository.blame("new.txt", lines: 1...1).isEmpty)
    }
}
