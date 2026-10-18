import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ClaudePromptTests {
    private var diff: FileDiff {
        get throws {
            let text = """
            diff --git a/src/a.swift b/src/a.swift
            --- a/src/a.swift
            +++ b/src/a.swift
            @@ -10,10 +10,10 @@ func run()
             one
             two
             three
             four
            -five
            +FIVE
             six
             seven
             eight
             nine
             ten

            """
            return try #require(UnifiedDiffParser.parse(text).first)
        }
    }

    private let context = PromptContext(repositoryPath: "/repo", isGitButler: true, source: .uncommitted(group: "assigned to branch `fix`"))

    @Test func excerptKeepsContextAroundTheSelection() throws {
        // The deletion and addition of `five`.
        let hunks = ClaudePrompt.excerpt(of: try diff, positions: [DiffPosition(hunk: 0, line: 4), DiffPosition(hunk: 0, line: 5)])
        let hunk = try #require(hunks.first)
        #expect(hunk.lines.map(\.text) == ["two", "three", "four", "five", "FIVE", "six", "seven", "eight"])
        #expect(hunk.header == "@@ -11,7 +11,7 @@ func run()")
    }

    @Test func excerptOfAnAddedOnlySelectionAtTheStart() throws {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -0,0 +1,2 @@
        +a
        +b

        """
        let file = try #require(UnifiedDiffParser.parse(text).first)
        let hunk = try #require(ClaudePrompt.excerpt(of: file, positions: [DiffPosition(hunk: 0, line: 1)]).first)
        #expect(hunk.header == "@@ -0,0 +1,2 @@")
    }

    @Test func promptHasQuestionContextAndFencedDiff() throws {
        let prompt = ClaudePrompt.make(question: .review, context: context, diff: try diff, positions: [DiffPosition(hunk: 0, line: 5)])
        #expect(prompt.hasPrefix("Review this change for bugs"))
        #expect(prompt.contains("- Repository: `/repo` (GitButler workspace)"))
        #expect(prompt.contains("- Changes: uncommitted, assigned to branch `fix`"))
        #expect(prompt.contains("- File: `src/a.swift`"))
        #expect(prompt.contains("- Lines: 14 in the new file"))
        #expect(prompt.contains("```diff\n@@ -12,6 +12,6 @@ func run()\n three\n four\n-five\n+FIVE\n six\n"))
        #expect(prompt.contains("Read the surrounding code"))
    }

    @Test func contextOnlyPromptAndCommitMessage() throws {
        let commit = PromptContext(repositoryPath: "/repo", isGitButler: false, source: .commit(sha: "abcdef1234567890", message: "Fix it\n\nBecause."))
        let prompt = ClaudePrompt.make(question: .none, context: commit, diff: try diff, positions: [DiffPosition(hunk: 0, line: 4)])
        #expect(prompt.hasPrefix("- Repository: `/repo`\n"))
        #expect(prompt.contains("- Commit: `abcdef123456` Fix it"))
        #expect(prompt.contains("Commit message:\n\n> Fix it\n>\n> Because."))
        #expect(!prompt.contains("Read the surrounding code"))
    }

    @Test func fenceOutgrowsBackticksInTheCode() {
        #expect(ClaudePrompt.fenced("let s = \"```\"", language: "diff").hasPrefix("````diff\n"))
    }

    @Test func launcherScriptQuotesPathsAndPassesThePromptAsOneArgument() {
        let script = ClaudeCodeLauncher.script(root: "/my repo/it's", promptFile: "/tmp/p.md", provider: .claude, executable: "/opt/homebrew/bin/claude")
        #expect(script.contains("cd '/my repo/it'\\''s' || exit 1"))
        #expect(script.contains("prompt=$(cat '/tmp/p.md')"))
        #expect(script.contains("-l -c '\"$0\" \"$@\"' '/opt/homebrew/bin/claude' \"$prompt\""))
    }

    @Test func providersPassThePromptToAnInteractiveSession() {
        let gemini = ClaudeCodeLauncher.script(root: "/r", promptFile: "/tmp/p.md", provider: .gemini, executable: "/bin/gemini")
        #expect(gemini.contains("'/bin/gemini' '--prompt-interactive' \"$prompt\""))
        let opencode = ClaudeCodeLauncher.script(root: "/r", promptFile: "/tmp/p.md", provider: .opencode, executable: "/bin/opencode")
        #expect(opencode.contains("'/bin/opencode' '--prompt' \"$prompt\""))
    }

    @Test func dropsClaudeCodeSessionMarkers() {
        let environment = ClaudeCodeLauncher.sessionFree(["PATH": "/bin", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_API": "x"])
        #expect(environment == ["PATH": "/bin", "CLAUDE_API": "x"])
    }

    @Test func terminalsOpenTheScript() {
        #expect(TerminalApp.terminal.openArguments(script: "/s.command") == ["-b", "com.apple.Terminal", "/s.command"])
        #expect(TerminalApp.ghostty.openArguments(script: "/s.command").suffix(3) == ["-e", "/bin/sh", "/s.command"])
    }
}
