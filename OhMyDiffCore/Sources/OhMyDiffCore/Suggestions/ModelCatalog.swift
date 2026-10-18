import Foundation

/// A model a provider's CLI accepts for `--model`.
public struct ModelOption: Sendable, Hashable, Identifiable {
    /// What goes into `--model`.
    public var id: String
    public var name: String
    public var detail: String

    public init(id: String, name: String? = nil, detail: String = "") {
        self.id = id
        self.name = name ?? id
        self.detail = detail
    }
}

/// The models each provider offers, read from the provider where it keeps a list and built in otherwise.
public enum ModelCatalog {
    public static func models(for provider: AIProvider, toolchain: Toolchain?, home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [ModelOption] {
        switch provider {
        case .claude:
            return claude
        case .codex:
            let cache = home.appending(path: ".codex/models_cache.json")
            return (try? Data(contentsOf: cache)).map(codex(cache:)).flatMap { $0.isEmpty ? nil : $0 } ?? []
        case .gemini:
            return gemini
        case .opencode:
            guard let toolchain, let executable = ClaudeCodeLauncher.locate(.opencode, environment: toolchain.environment),
                  let output = try? await toolchain.runner.run(executable, arguments: ["models"], environment: toolchain.environment, timeout: .seconds(15)),
                  output.exitCode == 0
            else { return [] }
            return opencode(output.stdoutString)
        }
    }

    /// Claude Code's aliases follow the newest model of each family; full IDs pin one.
    static let claude = [
        ModelOption(id: "haiku", name: "Haiku", detail: "Fastest, newest Haiku"),
        ModelOption(id: "sonnet", name: "Sonnet", detail: "Balanced, newest Sonnet"),
        ModelOption(id: "opus", name: "Opus", detail: "Most capable, newest Opus"),
        ModelOption(id: "claude-haiku-5-5", detail: "Haiku 5.5"),
        ModelOption(id: "claude-sonnet-5-5", detail: "Sonnet 5.5"),
        ModelOption(id: "claude-opus-5-5", detail: "Opus 5.5"),
        ModelOption(id: "claude-fable-5-1", detail: "Fable 5.1"),
    ]

    static let gemini = [
        ModelOption(id: "gemini-2.5-flash-lite", detail: "Fastest"),
        ModelOption(id: "gemini-2.5-flash", detail: "Fast and balanced"),
        ModelOption(id: "gemini-2.5-pro", detail: "Most capable"),
    ]

    /// The listed models of Codex's model cache, in Codex's order.
    static func codex(cache data: Data) -> [ModelOption] {
        struct Cache: Decodable {
            struct Model: Decodable {
                var slug: String
                var display_name: String?
                var description: String?
                var visibility: String?
                var priority: Int?
            }
            var models: [Model]
        }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return cache.models
            .filter { $0.visibility == nil || $0.visibility == "list" }
            .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
            .map { ModelOption(id: $0.slug, name: $0.display_name ?? $0.slug, detail: $0.description ?? "") }
    }

    /// `opencode models` prints one `provider/model` per line.
    static func opencode(_ output: String) -> [ModelOption] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains(" ") }
            .map { ModelOption(id: $0) }
    }

    /// Options matching what was typed: by ID or name, prefix matches first.
    public static func matching(_ text: String, in options: [ModelOption]) -> [ModelOption] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return options }
        let matches = options.filter { $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query) }
        return matches.filter { $0.id.lowercased().hasPrefix(query) } + matches.filter { !$0.id.lowercased().hasPrefix(query) }
    }
}
