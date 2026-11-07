import Foundation
import FoundationModels

/// Apple's on-device model, through the Foundation Models framework: no CLI, no API key, and the diff never
/// leaves the Mac. Its context is small, so it only takes small jobs: branch names and commit messages of
/// small diffs.
public enum OnDeviceModel {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case unavailable(String)
        /// The prompt would not fit the model's context; the numbers are estimated tokens.
        case tooLarge(tokens: Int, limit: Int)
        case failed(String)

        public var description: String {
            switch self {
            case .unavailable(let reason): "Apple Intelligence is not available: \(reason)"
            case .tooLarge(let tokens, let limit):
                "These changes are too large for on-device Apple Intelligence (about \(tokens) tokens, it takes about \(limit)). "
                    + "Select fewer changes, or choose an AI provider in Settings → AI for larger ones."
            case .failed(let message): "Apple Intelligence failed: \(message)"
            }
        }
    }

    /// Why the model cannot run here, or `nil` when it can.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "this Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): "its model is still downloading."
        case .unavailable: "unknown reason."
        }
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    /// Tokens per session, prompt and answer together (TN3193).
    static let contextSize = 4096
    /// Kept free for the answer.
    static let answerReserve = 600

    /// A conservative token count: code runs shorter than prose's three to four characters per token. The SDK's
    /// `tokenCount(for:)` needs macOS 26.4; `exceededContextWindowSize` still catches what this misses.
    static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    /// Up to `count` different branch names, best first.
    public static func branchNames(context: TemplateContext, count: Int = 3) async throws -> [String] {
        try checkAvailable()
        let instructions = "You suggest git branch names for code changes."
        // A name needs the gist, not every line: the start of the diff that fits.
        let budget = (contextSize - answerReserve - estimatedTokens(instructions) - 300) * 3
        var prompt = "Suggest \(count) different branch names for these changes, best first."
        if let ticket = context.ticket { prompt += "\nStart each short name with the ticket ID in lowercase: \(ticket.id.lowercased())." }
        prompt += "\n\n" + gist(of: context.diff, characters: max(budget - prompt.utf8.count, 500))
        let names = try await respond(instructions: instructions, prompt: prompt, generating: BranchNames.self)
        var result: [String] = []
        for suggestion in names.names {
            if let name = branchName(type: suggestion.type, words: suggestion.name), !result.contains(name) { result.append(name) }
        }
        guard !result.isEmpty else { throw Failure.failed("it returned no usable branch name.") }
        return Array(result.prefix(count))
    }

    /// A commit message in `style`; too large diffs throw `Failure.tooLarge` rather than being cut, so the
    /// message never describes only part of the changes.
    ///
    /// The small model loses track of a long template, so it fills typed parts from a short prompt, and the
    /// message is put together here.
    public static func commitMessage(
        context: TemplateContext, style: CommitParts.Style, titleLimit: Int = 72, ticketInTitle: Bool = false
    ) async throws -> String {
        try checkAvailable()
        let instructions = "You write git commit messages that describe exactly the given diff. Use present tense: add, not added."
        var prompt = "Write a commit message for this diff."
        if let ticket = context.ticket { prompt += "\nIt is for ticket \(ticket.id): \(ticket.title)" }
        prompt += "\n\n" + context.diff
        let tokens = estimatedTokens(instructions) + estimatedTokens(prompt) + schemaTokens
        let limit = contextSize - answerReserve
        guard tokens <= limit else { throw Failure.tooLarge(tokens: tokens, limit: limit) }
        let parts = try await respond(instructions: instructions, prompt: prompt, generating: CommitParts.self)
        let message = parts.formatted(style: style, titleLimit: titleLimit, ticket: context.ticket?.id, ticketInTitle: ticketInTitle)
        guard !parts.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.failed("it returned no message.") }
        return message
    }

    /// About what `CommitParts`' schema and guides take of the context.
    static let schemaTokens = 250

    private static func checkAvailable() throws {
        if let reason = unavailableReason { throw Failure.unavailable(reason) }
    }

    private static func respond<Content: Generable>(instructions: String, prompt: String, generating type: Content.Type) async throws -> Content {
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: type).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw Failure.tooLarge(tokens: estimatedTokens(instructions + prompt), limit: contextSize - answerReserve)
        } catch let error as LanguageModelSession.GenerationError {
            throw Failure.failed(String(describing: error))
        }
    }

    /// The files a diff touches, then as much of the diff as fits in `characters`.
    static func gist(of diff: String, characters: Int) -> String {
        let files = diff.split(separator: "\n").compactMap { line -> Substring? in
            guard line.hasPrefix("+++ b/") else { return nil }
            return line.dropFirst(6)
        }
        var text = files.isEmpty ? "" : "Files: " + files.joined(separator: ", ") + "\n\n"
        let room = max(characters - text.utf8.count, 0)
        text += diff.utf8.count <= room ? diff : String(diff.prefix(room)) + "\n[… the rest of the diff is left out]"
        return text
    }

    /// `type/two-to-five-words` from a type and words in any case, e.g. `DarkModeToggle` or `Fix Return Value`.
    static func branchName(type: String, words: String) -> String? {
        var spaced = ""
        var previous: Character?
        for character in words {
            // Splits camel case: `DarkMode` → `Dark Mode`.
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        var parts = spaced.lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
        // Models like to repeat the type, e.g. `fix/fix-crash`.
        if parts.first == type.lowercased(), parts.count > 2 { parts.removeFirst() }
        guard !parts.isEmpty else { return nil }
        return Suggester.branchName(from: "\(type.lowercased())/\(parts.prefix(5).joined(separator: "-"))")
    }
}

/// A commit message as the on-device model fills it in.
@Generable
public struct CommitParts: Sendable {
    public enum Style: Sendable { case conventional, gitmoji, free }

    @Guide(description: "The kind of change", .anyOf(["feat", "fix", "chore", "refactor", "docs", "style", "test", "ci", "build"]))
    var type: String
    @Guide(description: "The component or feature changed, one lowercase word")
    var scope: String
    @Guide(description: "What the change does, in present tense, lowercase, under 60 characters")
    var title: String
    @Guide(description: "The most important changes, each a short lowercase sentence in present tense", .count(1...4))
    var bullets: [String]

    init(type: String, scope: String, title: String, bullets: [String]) {
        self.type = type
        self.scope = scope
        self.title = title
        self.bullets = bullets
    }

    /// The message: the title in `style` within `titleLimit` characters, the bullets, and a `Refs:` line for a ticket.
    func formatted(style: Style, titleLimit: Int, ticket: String?, ticketInTitle: Bool) -> String {
        let type = type.lowercased()
        let scope = scope.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "-") }.joined(separator: "-")
        var title = Self.sentence(title)
        let suffix = ticketInTitle ? ticket.map { " (\($0))" } ?? "" : ""
        let prefix = switch style {
        case .conventional: scope.isEmpty ? "\(type): " : "\(type)(\(scope)): "
        case .gitmoji: (Self.gitmoji[type] ?? "✨") + " "
        case .free: ""
        }
        if style == .free, let first = title.first { title = first.uppercased() + title.dropFirst() }
        title = Self.cut(title, to: titleLimit - prefix.count - suffix.count)
        var lines = [prefix + title + suffix]
        let bullets = bullets.map(Self.sentence).filter { !$0.isEmpty }
        if !bullets.isEmpty { lines += [""] + bullets.map { "- " + $0 } }
        if let ticket { lines += ["", "Refs: \(ticket)"] }
        return lines.joined(separator: "\n")
    }

    static let gitmoji = [
        "feat": "✨", "fix": "🐛", "chore": "🔧", "refactor": "♻️", "docs": "📝", "style": "💄", "test": "✅", "ci": "👷", "build": "📦",
    ]

    /// Trimmed, lowercase first letter, no full stop; words in capitals, e.g. `URL`, stay as they are.
    static func sentence(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first, !(text.dropFirst().first?.isUppercase ?? false) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// At most `limit` characters, cut at a word.
    static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 0 else { return text }
        let prefix = text.prefix(limit)
        return String(prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix)
    }
}

@Generable
struct BranchNames {
    @Guide(description: "Different names, best first", .count(3))
    var names: [BranchSuggestion]
}

@Generable
struct BranchSuggestion {
    @Guide(description: "The kind of change", .anyOf(["feat", "fix", "chore", "refactor", "docs", "style", "test", "ci", "build"]))
    var type: String
    @Guide(description: "2 to 5 lowercase words joined by hyphens, e.g. dark-mode-toggle")
    var name: String
}
