import Foundation

public enum SuggestionError: Error, Sendable, CustomStringConvertible {
    case notInstalled(AIProvider)
    case failed(AIProvider, String)
    case emptyAnswer(AIProvider)

    public var description: String {
        switch self {
        case .notInstalled(let provider):
            "\(provider.displayName) (`\(provider.executable)`) was not found on your login shell PATH. \(provider.installHint)"
        case .failed(let provider, let message):
            "\(provider.displayName) failed: \(message.isEmpty ? "no details" : message)"
        case .emptyAnswer(let provider):
            "\(provider.displayName) returned no suggestion."
        }
    }
}

/// Asks an AI provider's CLI for a one-off answer, e.g. a commit message, without a terminal window.
public struct Suggester: Sendable {
    public let provider: AIProvider
    /// A model name for the provider's `--model` flag; empty for its default.
    public let model: String
    let toolchain: Toolchain

    public init(provider: AIProvider, model: String = "", toolchain: Toolchain) {
        self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespaces)
        self.toolchain = toolchain
    }

    /// Runs `prompt` in `directory` and returns the cleaned answer.
    public func complete(_ prompt: String, in directory: URL, timeout: Duration = .seconds(180)) async throws -> String {
        guard let executable = ClaudeCodeLauncher.locate(provider, environment: toolchain.environment) else {
            throw SuggestionError.notInstalled(provider)
        }
        // Codex prints progress on stdout; its final answer goes to a file instead.
        let answerFile = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-suggestion-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: answerFile) }

        let output = try await toolchain.runner.run(
            executable, arguments: provider.completionArguments(prompt: prompt, model: model, answerFile: answerFile.path),
            currentDirectory: directory, environment: ClaudeCodeLauncher.sessionFree(toolchain.environment), timeout: timeout)
        guard output.exitCode == 0 else {
            let message = Self.stripANSI(output.stderrString.isEmpty ? output.stdoutString : output.stderrString)
            throw SuggestionError.failed(provider, String(message.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)))
        }
        let raw = provider == .codex ? (try? String(contentsOf: answerFile, encoding: .utf8)) ?? output.stdoutString : output.stdoutString
        let answer = Self.clean(raw)
        guard !answer.isEmpty else { throw SuggestionError.emptyAnswer(provider) }
        return answer
    }

    /// A commit message, without the `Refs:` line when no ticket is linked.
    public func commitMessage(template: String, context: TemplateContext, in directory: URL) async throws -> String {
        let answer = try await complete(Self.prompt(template, context), in: directory)
        return context.ticket == nil ? Self.removingEmptyRefs(answer) : answer
    }

    public func pullRequest(template: String, context: TemplateContext, in directory: URL) async throws -> String {
        try await complete(Self.prompt(template, context), in: directory)
    }

    public func branchName(context: TemplateContext, in directory: URL) async throws -> String {
        let answer = try await complete(Self.prompt(PromptTemplate.branchName, context), in: directory)
        guard let name = Self.branchName(from: answer) else { throw SuggestionError.emptyAnswer(provider) }
        return name
    }

    static func prompt(_ template: String, _ context: TemplateContext) -> String {
        var context = context
        context.diff = PromptTemplate.limitedDiff(context.diff)
        return PromptTemplate.render(template, context: context)
    }

    // MARK: - Cleaning answers

    /// Without terminal colors, surrounding blank lines or a code fence around the whole answer.
    static func clean(_ text: String) -> String {
        var text = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= 2, lines.first?.hasPrefix("```") == true, lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
            lines.removeLast()
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Trailing spaces would otherwise end up in the commit.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/\s+$/, with: "") }
            .joined(separator: "\n")
    }

    static func stripANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
    }

    /// Drops a `Refs:` line left without an ID.
    static func removingEmptyRefs(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != "refs:" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A valid `<type>/<short-name>` from an answer that may add quotes, backticks or prose.
    public static func branchName(from answer: String) -> String? {
        let line = answer.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.contains("/") } ?? answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // The word with the slash, e.g. from "Branch: feat/x", else the last one.
        let words = line.split(separator: " ").map(String.init)
        let word = words.first { $0.contains("/") } ?? words.last ?? ""
        let lowered = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,:;"))
        var name = ""
        for character in lowered {
            if character.isASCII, character.isLetter || character.isNumber || character == "/" || character == "." {
                name.append(character)
            } else if !name.hasSuffix("-"), !name.hasSuffix("/") {
                name.append("-")
            }
        }
        let parts = name.split(separator: "/").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-.")) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "/").replacing("..", with: ".")
        return joined.hasSuffix(".lock") ? String(joined.dropLast(5)) : joined
    }
}

extension AIProvider {
    /// Arguments that answer `prompt` once and exit, printing only the answer.
    func completionArguments(prompt: String, model: String, answerFile: String) -> [String] {
        let modelFlag = model.isEmpty ? [] : ["--model", model]
        return switch self {
        case .claude: ["-p", "--output-format", "text"] + modelFlag + [prompt]
        case .codex: ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--output-last-message", answerFile] + modelFlag + [prompt]
        case .gemini: modelFlag + ["--prompt", prompt]
        case .opencode: ["run"] + modelFlag + [prompt]
        }
    }
}
