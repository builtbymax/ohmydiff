import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ReviewTests {
    /// `a.swift`: line 10 unchanged, old 11 removed, new 11 and 12 added, line 13 unchanged.
    private let diff = FileDiff(
        oldPath: "a.swift", newPath: "a.swift", kind: .modified,
        hunks: [Hunk(oldStart: 10, oldCount: 3, newStart: 10, newCount: 4, lines: [
            DiffLine(kind: .context, text: "let a = 1", oldLineNumber: 10, newLineNumber: 10),
            DiffLine(kind: .deletion, text: "let b = 2", oldLineNumber: 11, newLineNumber: nil),
            DiffLine(kind: .addition, text: "let b = 3", oldLineNumber: nil, newLineNumber: 11),
            DiffLine(kind: .addition, text: "let c = b / 0", oldLineNumber: nil, newLineNumber: 12),
            DiffLine(kind: .context, text: "print(c)", oldLineNumber: 12, newLineNumber: 13),
        ])])

    @Test func numbersEveryLineAsInTheFile() {
        let text = ReviewPrompt.numberedDiff([diff]).text
        #expect(text.contains("File: a.swift"))
        #expect(text.contains("10|  let a = 1"))
        #expect(text.contains("-11| -let b = 2"))
        #expect(text.contains("12| +let c = b / 0"))
        #expect(text.contains("13|  print(c)"))
    }

    @Test func leavesOutWholeFilesPastTheLimit() {
        let long = DiffLine(kind: .addition, text: String(repeating: "x", count: PromptTemplate.diffCharacterLimit), oldLineNumber: nil, newLineNumber: 1)
        var big = diff
        big.newPath = "big.swift"
        big.oldPath = "big.swift"
        big.hunks = [Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1, lines: [long])]
        let (text, isCut) = ReviewPrompt.numberedDiff([diff, big])
        #expect(isCut)
        #expect(text.contains("File: a.swift"))
        #expect(!text.contains("File: big.swift"))
        #expect(ReviewPrompt.make(diffs: [diff], description: "").isCut == false)
    }

    @Test func readsTheFindingsObject() throws {
        let answer = #"{"findings":[{"file":"a.swift","line":12,"side":"new","severity":"high","message":"Divides by zero.","suggestion":"Check b first."}]}"#
        let findings = try ReviewPrompt.findings(in: answer)
        #expect(findings.count == 1)
        #expect(findings[0].path == "a.swift")
        #expect(findings[0].line == 12)
        #expect(findings[0].side == .new)
        #expect(findings[0].severity == .high)
        #expect(findings[0].suggestion == "Check b first.")
        #expect(findings[0].origin == .task)
    }

    @Test func toleratesProseFencesAndLooseFields() throws {
        let answer = """
            Here is the review:
            ```json
            [{"path":"./a.swift","line":11,"side":"OLD","severity":"nit","message":" Removed value. "},
             {"file":"a.swift","message":"no line"},
             {"file":"","line":3,"message":"no file"}]
            ```
            """
        let findings = try ReviewPrompt.findings(in: answer)
        #expect(findings.count == 1)
        #expect(findings[0].path == "a.swift")
        #expect(findings[0].side == .old)
        #expect(findings[0].severity == .low)
        #expect(findings[0].message == "Removed value.")
        #expect(findings[0].suggestion.isEmpty)
    }

    @Test func emptyFindingsAreFineAndGarbageIsAnError() throws {
        #expect(try ReviewPrompt.findings(in: #"{"findings":[]}"#).isEmpty)
        #expect(throws: ReviewPrompt.ParseError.self) { try ReviewPrompt.findings(in: "Looks good to me!") }
    }

    @Test func anchorsFindingsToTheirLineOnly() {
        func finding(_ line: Int, _ side: ReviewSide = .new, path: String = "a.swift") -> ReviewFinding {
            ReviewFinding(path: path, line: line, side: side, severity: .medium, message: "m")
        }
        #expect(finding(12).position(in: diff) == DiffPosition(hunk: 0, line: 3))
        #expect(finding(10).position(in: diff) == DiffPosition(hunk: 0, line: 0))
        // Old line 11 is the removed one, not an unchanged line.
        #expect(finding(11, .old).position(in: diff) == DiffPosition(hunk: 0, line: 1))
        #expect(finding(12, .old).position(in: diff) == DiffPosition(hunk: 0, line: 4))
        #expect(finding(40).position(in: diff) == nil)
        #expect(finding(12, path: "b.swift").position(in: diff) == nil)
    }

    @Test func readsClaudesStructuredOutput() {
        let output = #"{"type":"result","result":"{\"findings\":[]}","structured_output":{"findings":[{"file":"a"}]}}"#
        #expect(Suggester.structuredOutput(fromClaude: output) == #"{"findings":[{"file":"a"}]}"#)
        #expect(Suggester.structuredOutput(fromClaude: #"{"result":"plain"}"#) == "plain")
        #expect(Suggester.structuredOutput(fromClaude: "not json") == "not json")
    }

    @Test func readsClaudesErrors() {
        #expect(Suggester.claudeError(#"{"is_error":true,"result":"Not logged in · Please run /login"}"#) == "Not logged in · Please run /login")
        #expect(Suggester.claudeError(#"{"is_error":true,"result":"","errors":["boom"]}"#) == "boom")
        #expect(Suggester.claudeError(#"{"is_error":true,"subtype":"error_max_structured_output_retries"}"#) == "error max structured output retries")
        #expect(Suggester.claudeError("plain text") == nil)
    }

    @Test func holdsClaudeAndCodexToTheSchema() {
        let claude = AIProvider.claude.completionArguments(prompt: "p", model: "", answerFile: "/a", schema: ("{}", "/s.json"))
        #expect(claude.contains("--json-schema"))
        #expect(claude[claude.firstIndex(of: "--output-format")! + 1] == "json")
        #expect(claude.last == "p")
        let codex = AIProvider.codex.completionArguments(prompt: "p", model: "", answerFile: "/a", schema: ("{}", "/s.json"))
        #expect(codex[codex.firstIndex(of: "--output-schema")! + 1] == "/s.json")
        #expect(AIProvider.gemini.completionArguments(prompt: "p", model: "", answerFile: "/a", schema: ("{}", "/s.json"))
            == AIProvider.gemini.completionArguments(prompt: "p", model: "", answerFile: "/a"))
    }

    @Test func schemaIsValidJSON() throws {
        let object = try JSONSerialization.jsonObject(with: Data(ReviewPrompt.schema.utf8)) as? [String: Any]
        #expect(object?["required"] as? [String] == ["findings"])
    }

    @Test func scopesFollowThePromptSource() {
        #expect(ReviewScope(.uncommitted(group: "staged")) == .uncommitted)
        #expect(ReviewScope(.commit(sha: "abc", message: "m")) == .commit(sha: "abc"))
        #expect(ReviewScope(.branch(name: "feat/x", base: "main")) == .branch(name: "feat/x"))
    }
}

@Suite struct ApplyFindingPromptTests {
    @Test func namesTheFindingAndItsLines() {
        let diff = FileDiff(
            oldPath: "a.swift", newPath: "a.swift", kind: .modified,
            hunks: [Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 2, lines: [
                DiffLine(kind: .context, text: "let a = 1", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .addition, text: "let c = a / 0", oldLineNumber: nil, newLineNumber: 2),
            ])])
        let finding = ReviewFinding(path: "a.swift", line: 2, severity: .high, message: "Divides by zero.", suggestion: "Guard it.")
        let context = PromptContext(repositoryPath: "/repo", isGitButler: false, source: .commit(sha: "abcdef1234567", message: "feat: x"))
        let prompt = ClaudePrompt.apply(finding, context: context, diff: diff)
        #expect(prompt.contains("high-severity problem at line 2 of the new file `a.swift`"))
        #expect(prompt.contains("> Divides by zero."))
        #expect(prompt.contains("> Guard it."))
        #expect(prompt.contains("+let c = a / 0"))
        #expect(prompt.contains("Lines: 2 in the new file"))
        #expect(prompt.contains("change nothing"))
    }
}
