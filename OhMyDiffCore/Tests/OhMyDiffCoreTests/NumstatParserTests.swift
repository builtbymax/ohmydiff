import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct NumstatParserTests {
    @Test func parsesCountsRenamesAndBinaries() {
        let records = [
            "3\t1\tsrc/a file.swift",
            "0\t0\t", "old/name.txt", "new/name.txt",
            "-\t-\timage.png",
            "12\t0\tREADME.md",
        ]
        let stats = NumstatParser.parse(Data((records.joined(separator: "\0") + "\0").utf8))

        #expect(stats == [
            "src/a file.swift": LineStats(additions: 3, deletions: 1),
            "new/name.txt": LineStats(additions: 0, deletions: 0),
            "README.md": LineStats(additions: 12, deletions: 0),
        ])
    }

    @Test func emptyOutputHasNoStats() {
        #expect(NumstatParser.parse(Data()).isEmpty)
    }
}
