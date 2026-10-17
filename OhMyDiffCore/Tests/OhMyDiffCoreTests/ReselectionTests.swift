import Testing
@testable import OhMyDiffCore

@Suite struct ReselectionTests {
    private func file(_ path: String, _ source: ChangeSource = .unstaged) -> ChangedFile {
        ChangedFile(path: path, kind: .modified, source: source)
    }

    private let before = [
        ChangeGroup(kind: .staged, title: "Staged", files: [ChangedFile(path: "a", kind: .modified, source: .staged)]),
        ChangeGroup(kind: .unstaged, title: "Unstaged", files: [
            ChangedFile(path: "b", kind: .modified, source: .unstaged),
            ChangedFile(path: "c", kind: .modified, source: .unstaged),
        ]),
    ]

    @Test func keepsFileThatIsStillListed() {
        let after = before + [ChangeGroup(kind: .untracked, title: "Untracked", files: [file("d", .untracked)])]
        #expect(after.reselecting("unstaged:c", previous: before) == "unstaged:c")
    }

    @Test func followsFileIntoAnotherGroup() {
        let after = [ChangeGroup(kind: .staged, title: "Staged", files: [file("a", .staged), file("b", .staged)])]
        #expect(after.reselecting("unstaged:b", previous: before) == "staged:b")
    }

    @Test func fallsBackToTheSamePosition() {
        let after = [ChangeGroup(kind: .unstaged, title: "Unstaged", files: [file("x"), file("y"), file("z")])]
        #expect(after.reselecting("unstaged:b", previous: before) == "unstaged:y")
        let shorter = [ChangeGroup(kind: .unstaged, title: "Unstaged", files: [file("x")])]
        #expect(shorter.reselecting("unstaged:c", previous: before) == "unstaged:x")
    }

    @Test func selectsFirstFileWhenNothingWasSelected() {
        #expect(before.reselecting(nil, previous: []) == "staged:a")
    }

    @Test func clearsSelectionWhenNothingChanged() {
        #expect([ChangeGroup]().reselecting("unstaged:b", previous: before) == nil)
        #expect([ChangeGroup]().reselecting(nil, previous: before) == nil)
    }
}
