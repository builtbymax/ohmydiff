import Testing
@testable import OhMyDiffCore

@Suite struct SyntaxHighlighterTests {
    /// The highlighted substrings of a line with their tokens.
    private func tokens(_ line: String, _ spans: [SyntaxSpan]?) -> [String: SyntaxToken] {
        let characters = Array(line)
        return Dictionary((spans ?? []).map { (String(characters[$0.range]), $0.token) }, uniquingKeysWith: { $1 })
    }

    @Test func detectsLanguagesFromPaths() {
        #expect(SyntaxLanguage(path: "Sources/App.swift") == .swift)
        #expect(SyntaxLanguage(path: "web/index.TSX") == .tsx)
        #expect(SyntaxLanguage(path: "config/ci.yml") == .yaml)
        #expect(SyntaxLanguage(path: "home/.zshrc") == .bash)
        #expect(SyntaxLanguage(path: "Makefile") == nil)
    }

    @Test(arguments: SyntaxLanguage.allCases)
    func loadsEveryHighlightQuery(_ language: SyntaxLanguage) {
        #expect(SyntaxHighlighter.query(for: language) != nil)
    }

    @Test func mapsCaptureNames() {
        #expect(SyntaxToken(captureName: "keyword.function") == .keyword)
        #expect(SyntaxToken(captureName: "function.method.call") == .function)
        #expect(SyntaxToken(captureName: "string.escape") == .escape)
        #expect(SyntaxToken(captureName: "variable.builtin") == .keyword)
        #expect(SyntaxToken(captureName: "variable") == nil)
        #expect(SyntaxToken(captureName: "punctuation.bracket") == nil)
    }

    @Test func highlightsSwift() {
        let source = """
            // greet
            func greet(_ name: String) -> String {
                return "hi \\(name)" + 42.description
            }
            """
        let spans = SyntaxHighlighter.highlight(source, language: .swift)
        #expect(tokens("// greet", spans[1])["// greet"] == .comment)
        let declaration = tokens("func greet(_ name: String) -> String {", spans[2])
        #expect(declaration["func"] == .keyword)
        #expect(declaration["String"] == .type)
        #expect(tokens("    return \"hi \\(name)\" + 42.description", spans[3])["42"] == .number)
    }

    @Test func keepsMultilineConstructsAcrossLines() {
        let source = "a = 1\n/* start\n   still comment */\nb = 2\n"
        let spans = SyntaxHighlighter.highlight(source, language: .javascript)
        #expect(spans[3]?.first?.token == .comment)
        #expect(spans[3]?.first?.range == 0..<19)
    }

    @Test func countsCharactersNotUTF16Units() {
        let source = "let s = \"👋🏽 hi\"; let n = 1\n"
        let line = String(source.dropLast())
        let spans = SyntaxHighlighter.highlight(source, language: .javascript)
        #expect(tokens(line, spans[1])["1"] == .number)
        #expect(tokens(line, spans[1])["\"👋🏽 hi\""] == .string)
    }

    @Test func mapsSpansOntoDiffLines() {
        let old = "let a = 1\nlet b = 2\n"
        let new = "let a = 1\nlet b = \"two\"\n"
        let diff = FileDiff(oldPath: "x.js", newPath: "x.js", kind: .modified, hunks: [
            Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, lines: [
                DiffLine(kind: .context, text: "let a = 1", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .deletion, text: "let b = 2", oldLineNumber: 2, newLineNumber: nil),
                DiffLine(kind: .addition, text: "let b = \"two\"", oldLineNumber: nil, newLineNumber: 2),
            ]),
        ])
        let highlights = SyntaxHighlighter.highlights(for: diff, language: .javascript, old: old, new: new)
        let lines = diff.hunks[0].lines
        #expect(tokens(lines[1].text, highlights.spans(for: lines[1]))["2"] == .number)
        #expect(tokens(lines[2].text, highlights.spans(for: lines[2]))["\"two\""] == .string)
        #expect(tokens(lines[0].text, highlights.spans(for: lines[0]))["let"] == .keyword)
    }

    @Test func skipsLinesThatDoNotMatchTheDiff() {
        let diff = FileDiff(oldPath: nil, newPath: "x.js", kind: .added, hunks: [
            Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1, lines: [
                DiffLine(kind: .addition, text: "let a = 1", oldLineNumber: nil, newLineNumber: 1),
            ]),
        ])
        let highlights = SyntaxHighlighter.highlights(for: diff, language: .javascript, old: nil, new: "var other = 2\n")
        #expect(highlights.new.isEmpty)
    }
}
