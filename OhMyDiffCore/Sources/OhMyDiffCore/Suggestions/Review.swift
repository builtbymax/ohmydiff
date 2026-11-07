import Foundation

/// How much a review finding matters.
public enum ReviewSeverity: String, Sendable, Hashable, CaseIterable, Codable, Comparable {
    case high
    case medium
    case low

    public var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Also takes the words models use instead, e.g. "critical" or "nit".
    init(loose text: String) {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "high", "critical", "error", "major", "blocker": self = .high
        case "low", "minor", "info", "nit", "suggestion", "style": self = .low
        default: self = .medium
        }
    }
}

/// Which side of the diff a finding's line number counts on.
public enum ReviewSide: String, Sendable, Hashable, Codable {
    /// The changed file, for added and unchanged lines.
    case new
    /// The file before the change, for removed lines.
    case old
}

/// What a review was asked for, so its findings show on the same diff.
public enum ReviewScope: Sendable, Hashable {
    case uncommitted
    case commit(sha: String)
    case branch(name: String)

    public init(_ source: PromptContext.Source) {
        switch source {
        case .uncommitted: self = .uncommitted
        case .commit(let sha, _): self = .commit(sha: sha)
        case .branch(let name, _): self = .branch(name: name)
        }
    }
}

/// One thing a review points out at a line of a file. Advisory only: nothing applies it.
public struct ReviewFinding: Sendable, Hashable, Identifiable {
    /// Who found it: the Review task, or an agent through the MCP server.
    public enum Origin: Sendable, Hashable {
        case task
        case agent(String)
    }

    public var id: UUID
    public var path: String
    public var line: Int
    public var side: ReviewSide
    public var severity: ReviewSeverity
    public var message: String
    /// What to change, if the reviewer said; may be empty.
    public var suggestion: String
    public var origin: Origin

    public init(
        id: UUID = UUID(), path: String, line: Int, side: ReviewSide = .new, severity: ReviewSeverity, message: String,
        suggestion: String = "", origin: Origin = .task
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
        self.origin = origin
    }

    /// The row of `diff` showing this finding's line, `nil` when the diff no longer has it, so a finding is never
    /// placed on a line it was not about.
    public func position(in diff: FileDiff) -> DiffPosition? {
        guard diff.path == path || diff.oldPath == path else { return nil }
        func first(where matches: (DiffLine) -> Bool) -> DiffPosition? {
            for (h, hunk) in diff.hunks.enumerated() {
                if let l = hunk.lines.firstIndex(where: matches) { return DiffPosition(hunk: h, line: l) }
            }
            return nil
        }
        switch side {
        case .new:
            return first { $0.newLineNumber == line }
        case .old:
            // Unchanged lines carry an old number too; the removed line is the one it names.
            return first { $0.kind == .deletion && $0.oldLineNumber == line } ?? first { $0.kind == .context && $0.oldLineNumber == line }
        }
    }
}

/// Builds the review prompt and reads the findings out of the answer.
public enum ReviewPrompt {
    /// The answer's shape, for CLIs that check it. Every field is required, as Codex wants for a strict schema.
    public static let schema = #"""
        {"type":"object","additionalProperties":false,"required":["findings"],"properties":{"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["file","line","side","severity","message","suggestion"],"properties":{"file":{"type":"string"},"line":{"type":"integer"},"side":{"type":"string","enum":["new","old"]},"severity":{"type":"string","enum":["high","medium","low"]},"message":{"type":"string"},"suggestion":{"type":"string"}}}}}}
        """#

    /// The prompt for reviewing `diffs`, and whether some of them were left out to stay within
    /// `PromptTemplate.diffCharacterLimit`.
    public static func make(diffs: [FileDiff], description: String) -> (prompt: String, isCut: Bool) {
        let (numbered, isCut) = numberedDiff(diffs)
        let prompt = """
            Review this code change for bugs, unhandled edge cases and risky behavior. \(description)

            Rules:
            - Only report real problems a careful reviewer would raise, at most 10, most important first. Report none when there are none.
            - Point each finding at one line, using the numbers shown in the diff: "new" for added or unchanged lines (`N|`), "old" for removed lines (`-N|`).
            - message: what is wrong and why, at most 2 sentences.
            - suggestion: the change to make, in a sentence or a short code snippet; empty when there is nothing specific.
            - severity: "high" for bugs and data loss, "medium" for edge cases and risky behavior, "low" for minor issues.
            - Answer only with JSON of this shape, no prose and no code fence:
              {"findings":[{"file":"path","line":12,"side":"new","severity":"medium","message":"…","suggestion":"…"}]}

            Diff:

            \(numbered)
            """
        return (prompt, isCut)
    }

    /// Each file with its hunks, and every line numbered as it appears in the file, so findings can name lines
    /// without counting. Files that would go past the limit are left out whole.
    static func numberedDiff(_ diffs: [FileDiff]) -> (text: String, isCut: Bool) {
        var parts: [String] = []
        var length = 0
        var isCut = false
        for diff in diffs where !diff.isBinary && !diff.hunks.isEmpty {
            var lines = ["File: \(diff.path)"]
            for hunk in diff.hunks {
                lines.append(hunk.header)
                for line in hunk.lines {
                    switch line.kind {
                    case .addition: lines.append("\(line.newLineNumber ?? 0)| +\(line.text)")
                    case .context: lines.append("\(line.newLineNumber ?? 0)|  \(line.text)")
                    case .deletion: lines.append("-\(line.oldLineNumber ?? 0)| -\(line.text)")
                    }
                }
            }
            let part = lines.joined(separator: "\n")
            guard length + part.count <= PromptTemplate.diffCharacterLimit else {
                isCut = true
                continue
            }
            length += part.count
            parts.append(part)
        }
        if isCut { parts.append("[… some files are left out to keep the prompt short]") }
        return (parts.joined(separator: "\n\n"), isCut)
    }

    public enum ParseError: Error, CustomStringConvertible {
        case noJSON

        public var description: String { "The review answer had no findings in the expected format." }
    }

    /// The findings in an answer: the JSON object, also when wrapped in prose or a code fence, or a bare array.
    /// Findings without a file, a line or a message are skipped.
    public static func findings(in answer: String, origin: ReviewFinding.Origin = .task) throws -> [ReviewFinding] {
        struct Raw: Decodable {
            var file: String?
            var path: String?
            var line: Int?
            var side: String?
            var severity: String?
            var message: String?
            var suggestion: String?
        }
        struct Envelope: Decodable { var findings: [Raw] }

        let decoder = JSONDecoder()
        let raws: [Raw]
        if let object = slice(answer, from: "{", to: "}"), let envelope = try? decoder.decode(Envelope.self, from: Data(object.utf8)) {
            raws = envelope.findings
        } else if let array = slice(answer, from: "[", to: "]"), let list = try? decoder.decode([Raw].self, from: Data(array.utf8)) {
            raws = list
        } else {
            throw ParseError.noJSON
        }
        return raws.compactMap { raw in
            guard let path = (raw.file ?? raw.path)?.trimmingCharacters(in: .whitespaces), !path.isEmpty,
                  let line = raw.line, line > 0,
                  let message = raw.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty
            else { return nil }
            return ReviewFinding(
                path: path.hasPrefix("./") ? String(path.dropFirst(2)) : path, line: line,
                side: raw.side?.lowercased() == "old" ? .old : .new, severity: ReviewSeverity(loose: raw.severity ?? ""),
                message: message, suggestion: raw.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", origin: origin)
        }
    }

    /// From the first `open` to the last `close`, inclusive.
    private static func slice(_ text: String, from open: Character, to close: Character) -> Substring? {
        guard let start = text.firstIndex(of: open), let end = text.lastIndex(of: close), start < end else { return nil }
        return text[start...end]
    }
}
