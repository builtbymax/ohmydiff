import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct UnifiedDiffParserTests {
    @Test func modifiedFileWithLineNumbers() throws {
        let diff = """
        diff --git a/src/main.swift b/src/main.swift
        index 1111111..2222222 100644
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -1,4 +1,5 @@ func main()
         one
        -two
        +TWO
        +two and a half
         three
         four

        """
        let files = UnifiedDiffParser.parse(diff)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.kind == .modified)
        #expect(file.oldPath == "src/main.swift")
        #expect(file.newPath == "src/main.swift")
        #expect(file.oldMode == "100644")
        #expect(!file.isModeChange)

        let hunk = try #require(file.hunks.first)
        #expect(hunk.oldStart == 1 && hunk.oldCount == 4 && hunk.newStart == 1 && hunk.newCount == 5)
        #expect(hunk.section == "func main()")
        #expect(hunk.lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context, .context])
        #expect(hunk.lines.map(\.oldLineNumber) == [1, 2, nil, nil, 3, 4])
        #expect(hunk.lines.map(\.newLineNumber) == [1, nil, 2, 3, 4, 5])
        #expect(file.additions == 2 && file.deletions == 1)
    }

    @Test func multipleFilesAndHunks() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -a
        +A
        @@ -10,2 +10,2 @@
         x
        -y
        +Y
        diff --git a/b.txt b/b.txt
        index 3..4 100644
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -b
        +B

        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
        #expect(files[0].hunks.count == 2)
        #expect(files[0].hunks[0].oldCount == 1 && files[0].hunks[0].newCount == 1)
        #expect(files[0].hunks[1].lines.map(\.newLineNumber) == [10, nil, 11])
    }

    @Test func addedAndDeletedFiles() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100755
        index 0000000..abc
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index abc..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye

        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].kind == .added)
        #expect(files[0].oldPath == nil && files[0].newPath == "new.txt")
        #expect(files[0].newMode == "100755")
        #expect(files[0].hunks[0].lines.map(\.newLineNumber) == [1, 2])
        #expect(files[1].kind == .deleted)
        #expect(files[1].oldPath == "old.txt" && files[1].newPath == nil)
        #expect(files[1].path == "old.txt")
    }

    @Test func pureRenameHasNoHunks() {
        let diff = """
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt

        """
        let file = UnifiedDiffParser.parse(diff)[0]
        #expect(file.kind == .renamed)
        #expect(file.oldPath == "old name.txt")
        #expect(file.newPath == "new name.txt")
        #expect(file.similarity == 100)
        #expect(file.hunks.isEmpty)
    }

    @Test func renameWithChangesAndCopy() {
        let diff = """
        diff --git a/a.swift b/b.swift
        similarity index 90%
        rename from a.swift
        rename to b.swift
        index 1..2 100644
        --- a/a.swift
        +++ b/b.swift
        @@ -1 +1 @@
        -x
        +y
        diff --git a/c.swift b/d.swift
        similarity index 75%
        copy from c.swift
        copy to d.swift

        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files[0].kind == .renamed && files[0].similarity == 90 && files[0].hunks.count == 1)
        #expect(files[1].kind == .copied && files[1].oldPath == "c.swift" && files[1].newPath == "d.swift")
    }

    @Test func binaryFiles() {
        let diff = """
        diff --git a/image.png b/image.png
        index 1..2 100644
        Binary files a/image.png and b/image.png differ
        diff --git a/blob.bin b/blob.bin
        new file mode 100644
        index 0000000..1234567
        GIT binary patch
        literal 4
        LcmZ?wWME_f00jU8

        literal 0
        HcmV?d00001

        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.isBinary })
        #expect(files[1].kind == .added)
        #expect(files.allSatisfy { $0.hunks.isEmpty })
    }

    @Test func modeChangeOnly() {
        let diff = """
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """
        let file = UnifiedDiffParser.parse(diff)[0]
        #expect(file.kind == .modified)
        #expect(file.oldMode == "100644" && file.newMode == "100755")
        #expect(file.isModeChange)
        #expect(file.path == "run.sh")
    }

    @Test func noNewlineAtEndOfFile() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file

        """
        let lines = UnifiedDiffParser.parse(diff)[0].hunks[0].lines
        #expect(lines.map(\.noNewlineAtEnd) == [false, true, true])
        #expect(lines.map(\.text) == ["keep", "old", "new"])
    }

    @Test func contentLinesThatLookLikeHeaders() {
        // Removing a line `-- x` and adding `++ y` produces `--- x` / `+++ y` inside the hunk.
        let diff = """
        diff --git a/notes.md b/notes.md
        index 1..2 100644
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1,2 @@
        --- x
        +++ y
         diff --git a/fake b/fake

        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].hunks[0].lines.map(\.text) == ["-- x", "++ y", "diff --git a/fake b/fake"])
    }

    @Test func quotedPathsAreUnescaped() {
        let diff = """
        diff --git "a/tab\\there.txt" "b/caf\\303\\251.txt"
        similarity index 100%
        rename from "tab\\there.txt"
        rename to "caf\\303\\251.txt"

        """
        let file = UnifiedDiffParser.parse(diff)[0]
        #expect(file.oldPath == "tab\there.txt")
        #expect(file.newPath == "café.txt")
    }

    @Test func gitHeaderWithSpacesAndBSlashInPath() {
        // Mode-only change: the header is the only source of the path.
        let diff = """
        diff --git a/dir b/x b/dir b/x
        old mode 100644
        new mode 100755

        """
        let file = UnifiedDiffParser.parse(diff)[0]
        #expect(file.oldPath == "dir b/x")
        #expect(file.newPath == "dir b/x")
    }

    @Test func carriageReturnsArePreserved() {
        let diff = "diff --git a/w.txt b/w.txt\nindex 1..2 100644\n--- a/w.txt\n+++ b/w.txt\n@@ -1 +1 @@\n-a\r\n+b\r\n"
        let lines = UnifiedDiffParser.parse(diff)[0].hunks[0].lines
        #expect(lines.map(\.text) == ["a\r", "b\r"])
    }

    @Test func emptyInput() {
        #expect(UnifiedDiffParser.parse("").isEmpty)
    }
}
