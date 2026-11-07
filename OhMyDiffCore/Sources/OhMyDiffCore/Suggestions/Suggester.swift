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

    /// Asks for `prompt` and returns the cleaned answer.
    ///
    /// The provider runs in a fresh, empty directory rather than the repository, so it never finds the
    /// repository's settings, hooks, plugins, MCP servers or instructions, and with its tools turned off
    /// where the CLI allows. The prompt itself carries everything the answer needs.
    ///
    /// With a JSON `schema`, Claude Code and Codex are held to it and the answer is the JSON object; other CLIs
    /// only get the prompt's own instructions.
    public func complete(_ prompt: String, schema: String? = nil, timeout: Duration = .seconds(180)) async throws -> String {
        guard let executable = ClaudeCodeLauncher.locate(provider, environment: toolchain.environment) else {
            throw SuggestionError.notInstalled(provider)
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ohmydiff-suggestion-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Codex prints progress on stdout; its final answer goes to a file instead.
        let answerFile = directory.appending(path: "answer.txt")
        let schemaFile = directory.appending(path: "schema.json")
        if let schema { try Data(schema.utf8).write(to: schemaFile) }

        let output = try await toolchain.runner.run(
            executable,
            arguments: provider.completionArguments(prompt: prompt, model: model, answerFile: answerFile.path, schema: schema.map { ($0, schemaFile.path) }),
            currentDirectory: directory, environment: provider.completionEnvironment(toolchain.environment, directory: directory),
            timeout: timeout)
        guard output.exitCode == 0 else {
            // Claude Code's JSON result carries its error; its tail alone is unreadable.
            let message = (schema != nil && provider == .claude ? Self.claudeError(output.stdoutString) : nil)
                ?? Self.stripANSI(output.stderrString.isEmpty ? output.stdoutString : output.stderrString)
            throw SuggestionError.failed(provider, String(message.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)))
        }
        var raw = provider == .codex ? (try? String(contentsOf: answerFile, encoding: .utf8)) ?? output.stdoutString : output.stdoutString
        if schema != nil, provider == .claude { raw = Self.structuredOutput(fromClaude: raw) }
        let answer = Self.clean(raw)
        guard !answer.isEmpty else { throw SuggestionError.emptyAnswer(provider) }
        return answer
    }

    /// A commit message, without the `Refs:` line when no ticket is linked.
    public func commitMessage(template: String, context: TemplateContext) async throws -> String {
        let answer = try await complete(Self.prompt(template, context))
        return context.ticket == nil ? Self.removingEmptyRefs(answer) : answer
    }

    public func pullRequest(template: String, context: TemplateContext) async throws -> String {
        try await complete(Self.prompt(template, context))
    }

    public func branchName(context: TemplateContext) async throws -> String {
        let answer = try await complete(Self.prompt(PromptTemplate.branchName, context))
        guard let name = Self.branchName(from: answer) else { throw SuggestionError.emptyAnswer(provider) }
        return name
    }

    /// Up to `count` different branch names, best first.
    public func branchNames(context: TemplateContext, count: Int = 3) async throws -> [String] {
        let prompt = Self.prompt(PromptTemplate.branchName, context)
            + "\n\nSuggest \(count) different names instead of one, one per line, best first, nothing else."
        let names = Self.branchNames(from: try await complete(prompt), count: count)
        guard !names.isEmpty else { throw SuggestionError.emptyAnswer(provider) }
        return names
    }

    /// Valid names from an answer with one per line, without list markers or duplicates.
    public static func branchNames(from answer: String, count: Int = 3) -> [String] {
        var names: [String] = []
        for line in answer.split(whereSeparator: \.isNewline) {
            let cleaned = line.trimmingCharacters(in: .whitespaces).replacing(/^(\d+[.)]|[-*•])\s*/, with: "")
            if let name = branchName(from: cleaned), !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(count))
    }

    /// Findings about `diffs`; `description` says what they are, e.g. "These are the uncommitted changes.".
    public func review(_ diffs: [FileDiff], description: String) async throws -> (findings: [ReviewFinding], isCut: Bool) {
        let (prompt, isCut) = ReviewPrompt.make(diffs: diffs, description: description)
        let answer = try await complete(prompt, schema: ReviewPrompt.schema, timeout: .seconds(600))
        return (try ReviewPrompt.findings(in: answer), isCut)
    }

    /// The error in Claude Code's JSON result, e.g. `Not logged in · Please run /login`; `nil` when there is none.
    static func claudeError(_ output: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        if let result = object["result"] as? String, !result.isEmpty { return result }
        if let errors = object["errors"] as? [String], !errors.isEmpty { return errors.joined(separator: "\n") }
        return (object["subtype"] as? String).map { $0.replacing("_", with: " ") }
    }

    /// The checked object of Claude Code's JSON result, else its text result.
    static func structuredOutput(fromClaude output: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return output }
        if let structured = object["structured_output"], JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: data, as: UTF8.self)
        }
        return object["result"] as? String ?? output
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
    /// Arguments that answer `prompt` once and exit, printing only the answer, with as few tools as the CLI
    /// allows. A CLI too old for these flags fails rather than running unrestricted.
    /// With a `schema` (its JSON and the file it is written to), the CLIs that support it check the answer against it.
    func completionArguments(prompt: String, model: String, answerFile: String, schema: (json: String, file: String)? = nil) -> [String] {
        let modelFlag = model.isEmpty ? [] : ["--model", model]
        return switch self {
        // `--tools` takes a list, so another flag must follow it before the prompt.
        case .claude:
            ["-p", "--tools", ""] + (schema.map { ["--output-format", "json", "--json-schema", $0.json] } ?? ["--output-format", "text"])
                + ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] + modelFlag + [prompt]
        case .codex:
            ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--output-last-message", answerFile]
                + (schema.map { ["--output-schema", $0.file] } ?? []) + modelFlag + [prompt]
        // Headless Gemini refuses tools that need approval; this keeps a configured `yolo` default from applying.
        case .gemini: ["--approval-mode", "default"] + modelFlag + ["--prompt", prompt]
        case .opencode: ["run"] + modelFlag + [prompt]
        }
    }

    /// The app's environment without what could point the CLI at a repository or another agent session, run
    /// from `directory`. OpenCode gets its tools denied through inline config, which outranks its other configs.
    func completionEnvironment(_ environment: [String: String], directory: URL) -> [String: String] {
        var result = ClaudeCodeLauncher.sessionFree(environment).filter { key, _ in !key.hasPrefix("GIT_") }
        result["PWD"] = directory.path
        if self == .opencode {
            result["OPENCODE_CONFIG_CONTENT"] = #"{"permission":{"*":"deny"}}"#
            result["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
            result["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
            result["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
        }
        return result
    }
}
