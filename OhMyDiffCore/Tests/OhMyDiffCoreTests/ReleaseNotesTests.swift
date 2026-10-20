import Testing
@testable import OhMyDiffCore

@Suite struct ReleaseNotesTests {
    @Test func keepsTheIntroductionBeforeTheFirstHeading() {
        let notes = """
        ohmydiff now **updates itself**.

        ## Highlights

        - Self-update
        """
        #expect(ReleaseNotes.summary(notes) == "ohmydiff now **updates itself**.")
    }

    @Test func formatsHeadingsAndListsWithoutAnIntroduction() {
        let notes = """
        ## Fixes ##

        - Keeps `C#` files highlighted
          * nested item
        + plus item
        """
        #expect(ReleaseNotes.summary(notes) == """
        **Fixes**

        • Keeps `C#` files highlighted
          • nested item
        • plus item
        """)
    }

    @Test func leavesPlainTextAlone() {
        #expect(ReleaseNotes.summary("  Fixes a crash.\r\n**Bold** and *italic*\n\n") == "Fixes a crash.\n**Bold** and *italic*")
        #expect(ReleaseNotes.summary("## C#") == "**C#**")
        #expect(ReleaseNotes.summary("#hashtag") == "#hashtag")
    }
}
