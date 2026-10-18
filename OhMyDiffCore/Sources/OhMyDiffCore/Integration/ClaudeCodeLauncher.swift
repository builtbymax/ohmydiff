import Foundation

/// A coding agent CLI that can be started with a prompt.
public enum AIProvider: String, Sendable, Hashable, CaseIterable, Identifiable {
    case claude
    case codex
    case gemini
    case opencode

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        }
    }

    /// The executable on the login shell PATH.
    public var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .opencode: "opencode"
        }
    }

    /// Arguments before the prompt that start an interactive session with it as the first message.
    var promptFlags: [String] {
        switch self {
        case .claude, .codex: []
        case .gemini: ["--prompt-interactive"]
        case .opencode: ["--prompt"]
        }
    }

    var installHint: String {
        switch self {
        case .claude: "Install it from claude.com/claude-code."
        case .codex: "Install it with `npm install -g @openai/codex`."
        case .gemini: "Install it with `npm install -g @google/gemini-cli`."
        case .opencode: "Install it from opencode.ai."
        }
    }
}

/// A terminal app a coding agent can be started in.
public enum TerminalApp: String, Sendable, Hashable, CaseIterable, Identifiable {
    case terminal
    case iterm
    case ghostty

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .ghostty: "Ghostty"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        }
    }

    /// `open` arguments that run `script` in a new window.
    func openArguments(script: String) -> [String] {
        switch self {
        // Both run an executable file they are asked to open.
        case .terminal, .iterm: ["-b", bundleIdentifier, script]
        // A new instance, since `--args` only reaches a launching app; `-e` runs the rest as the command.
        case .ghostty: ["-na", "Ghostty", "--args", "-e", "/bin/sh", script]
        }
    }
}

public enum ClaudeCodeError: Error, Sendable, CustomStringConvertible {
    case notInstalled(AIProvider)
    case failed(String)

    public var description: String {
        switch self {
        case .notInstalled(let provider):
            "\(provider.displayName) (`\(provider.executable)`) was not found on your login shell PATH. \(provider.installHint)"
        case .failed(let message):
            "Could not open the terminal: \(message)"
        }
    }
}

/// Starts a coding agent in a terminal window with a prompt.
public enum ClaudeCodeLauncher {
    /// The provider's executable on the login shell PATH.
    public static func locate(_ provider: AIProvider, environment: [String: String]) -> URL? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.claude/local", "\(NSHomeDirectory())/.opencode/bin"]
        return directories.lazy
            .map { URL(fileURLWithPath: $0).appending(path: provider.executable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Opens `terminal` at `root` and runs the provider with `prompt`. The prompt goes through a file rather
    /// than the command line, so no quoting can break it.
    public static func open(prompt: String, in root: URL, provider: AIProvider, terminal: TerminalApp, toolchain: Toolchain) async throws {
        guard let executable = locate(provider, environment: toolchain.environment) else { throw ClaudeCodeError.notInstalled(provider) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString
        let promptFile = directory.appending(path: "\(name).md")
        let script = directory.appending(path: "\(name).command")
        try Data(prompt.utf8).write(to: promptFile)
        try Data(self.script(root: root.path, promptFile: promptFile.path, provider: provider, executable: executable.path).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let output = try await toolchain.runner.run(
            URL(fileURLWithPath: "/usr/bin/open"), arguments: terminal.openArguments(script: script.path),
            environment: sessionFree(toolchain.environment), timeout: .seconds(15))
        guard output.exitCode == 0 else {
            try? FileManager.default.removeItem(at: promptFile)
            try? FileManager.default.removeItem(at: script)
            throw ClaudeCodeError.failed(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The environment without the markers of a Claude Code session, e.g. when ohmydiff was started from
    /// one, so the new session does not take itself for a child and stop saving its transcript.
    static func sessionFree(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in key != "CLAUDECODE" && !key.hasPrefix("CLAUDE_CODE_") }
    }

    /// Runs the provider in the user's login shell, so it finds the same tools as in their own terminal,
    /// and leaves a shell open in the repository when it exits. Removes itself and the prompt file.
    static func script(root: String, promptFile: String, provider: AIProvider, executable: String) -> String {
        let quote = EditorCommand.shellQuoted
        let arguments = (provider.promptFlags.map(quote) + ["\"$prompt\""]).joined(separator: " ")
        return """
        #!/bin/sh
        # Written by ohmydiff: starts \(provider.displayName) with a prompt about a diff.
        cd \(quote(root)) || exit 1
        unset CLAUDECODE $(env | sed -n 's/^\\(CLAUDE_CODE_[A-Za-z0-9_]*\\)=.*/\\1/p')
        prompt=$(cat \(quote(promptFile)))
        rm -f \(quote(promptFile)) "$0"
        clear
        "${SHELL:-/bin/zsh}" -l -c '"$0" "$@"' \(quote(executable)) \(arguments)
        exec "${SHELL:-/bin/zsh}" -l

        """
    }
}
