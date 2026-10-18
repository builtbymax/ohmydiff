import Foundation

/// A line of a diff by its hunk and line index, e.g. a selected row.
public struct DiffPosition: Sendable, Hashable, Comparable {
    public var hunk: Int
    public var line: Int

    public init(hunk: Int, line: Int) {
        self.hunk = hunk
        self.line = line
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hunk, lhs.line) < (rhs.hunk, rhs.line)
    }
}

/// Where a diff comes from, so a prompt can tell Claude what it is looking at.
public struct PromptContext: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Uncommitted changes; `group` describes where they sit, e.g. "staged" or "assigned to branch `x`".
        case uncommitted(group: String?)
        case commit(sha: String, message: String)
        /// A whole branch compared with its base.
        case branch(name: String, base: String?)
    }

    public var repositoryPath: String
    public var isGitButler: Bool
    public var source: Source

    public init(repositoryPath: String, isGitButler: Bool, source: Source) {
        self.repositoryPath = repositoryPath
        self.isGitButler = isGitButler
        self.source = source
    }
}

/// What to ask about the selected lines.
public enum PromptQuestion: String, Sendable, Hashable, CaseIterable, Identifiable {
    case explain
    case review
    case tests
    /// No question: the context only, for the user to add their own.
    case none

    public var id: Self { self }

    public var title: String {
        switch self {
        case .explain: "Explain"
        case .review: "Review for Bugs"
        case .tests: "Suggest Tests"
        case .none: "Context Only"
        }
    }

    var text: String? {
        switch self {
        case .explain: "Explain this change: what it does, and why it was likely made."
        case .review: "Review this change for bugs, unhandled edge cases and risky behavior. Point to the exact lines."
        case .tests: "Suggest tests that cover this change, including edge cases. Follow the repository's existing test style."
        case .none: nil
        }
    }
}

/// Builds Markdown prompts about selected diff lines for Claude Code.
public enum ClaudePrompt {
    /// Unchanged lines kept around the selection within its hunk.
    public static let contextLines = 3

    public static func make(question: PromptQuestion, context: PromptContext, diff: FileDiff, positions: [DiffPosition]) -> String {
        let hunks = excerpt(of: diff, positions: positions)
        var sections: [String] = []
        if let text = question.text { sections.append(text) }

        var facts = ["Repository: `\(context.repositoryPath)`" + (context.isGitButler ? " (GitButler workspace)" : "")]
        switch context.source {
        case .uncommitted(let group):
            facts.append("Changes: uncommitted" + (group.map { ", \($0)" } ?? ""))
        case .commit(let sha, let message):
            let subject = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            facts.append("Commit: `\(sha.prefix(12))`" + (subject.isEmpty ? "" : " \(subject)"))
        case .branch(let name, let base):
            facts.append("Branch: `\(name)`" + (base.map { " compared with `\($0)`" } ?? ""))
        }
        var file = "File: `\(diff.path)`"
        if let oldPath = diff.oldPath, let newPath = diff.newPath, oldPath != newPath { file += " (renamed from `\(oldPath)`)" }
        facts.append(file)
        if let lines = lineSummary(diff: diff, positions: positions) { facts.append("Lines: \(lines)") }
        sections.append(facts.map { "- \($0)" }.joined(separator: "\n"))

        if case .commit(_, let message) = context.source, message.contains("\n") {
            sections.append("Commit message:\n\n" + quoted(message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        let body = hunks.map { hunk in
            ([hunk.header] + hunk.lines.map { marker($0.kind) + $0.text }).joined(separator: "\n")
        }
        .joined(separator: "\n")
        sections.append(fenced(body, language: "diff"))

        if question != .none {
            sections.append("Read the surrounding code in the repository as needed.")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// The parts of the hunks the positions fall in: from the first to the last selected line, with up
    /// to `contextLines` lines around them, and headers matching the cut.
    public static func excerpt(of diff: FileDiff, positions: [DiffPosition], contextLines: Int = contextLines) -> [Hunk] {
        let byHunk = Dictionary(grouping: positions.filter { diff.hunks.indices.contains($0.hunk) }, by: \.hunk)
        return byHunk.keys.sorted().compactMap { h in
            let hunk = diff.hunks[h]
            let selected = byHunk[h]!.map(\.line).filter { hunk.lines.indices.contains($0) }
            guard let first = selected.min(), let last = selected.max() else { return nil }
            let range = max(first - contextLines, 0)...min(last + contextLines, hunk.lines.count - 1)
            let lines = Array(hunk.lines[range])
            let before = hunk.lines[..<range.lowerBound]
            let oldCount = lines.count { $0.kind != .addition }
            let newCount = lines.count { $0.kind != .deletion }
            // A side without lines starts after the last line before the cut, like git's `-n,0` ranges.
            let oldStart = oldCount > 0
                ? lines.lazy.compactMap(\.oldLineNumber).first ?? hunk.oldStart
                : before.lazy.compactMap(\.oldLineNumber).last ?? max(hunk.oldStart - (hunk.oldCount == 0 ? 0 : 1), 0)
            let newStart = newCount > 0
                ? lines.lazy.compactMap(\.newLineNumber).first ?? hunk.newStart
                : before.lazy.compactMap(\.newLineNumber).last ?? max(hunk.newStart - (hunk.newCount == 0 ? 0 : 1), 0)
            return Hunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, section: hunk.section, lines: lines)
        }
    }

    /// E.g. "12–18 in the new file, 10–15 in the old file".
    static func lineSummary(diff: FileDiff, positions: [DiffPosition]) -> String? {
        let lines = positions.compactMap { position -> DiffLine? in
            guard diff.hunks.indices.contains(position.hunk), diff.hunks[position.hunk].lines.indices.contains(position.line) else { return nil }
            return diff.hunks[position.hunk].lines[position.line]
        }
        func range(_ numbers: [Int], _ side: String) -> String? {
            guard let low = numbers.min(), let high = numbers.max() else { return nil }
            return (low == high ? "\(low)" : "\(low)–\(high)") + " in the \(side) file"
        }
        let parts = [range(lines.compactMap(\.newLineNumber), "new"), range(lines.compactMap(\.oldLineNumber), "old")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        }
    }

    /// A fenced code block whose fence is longer than any backtick run inside it.
    static func fenced(_ text: String, language: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }
}
