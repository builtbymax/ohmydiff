import Foundation

/// A terminal app Claude Code can be started in.
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
    case notInstalled
    case failed(String)

    public var description: String {
        switch self {
        case .notInstalled:
            "Claude Code (`claude`) was not found on your login shell PATH. Install it from claude.com/claude-code."
        case .failed(let message):
            "Could not open the terminal: \(message)"
        }
    }
}

/// Starts Claude Code in a terminal window with a prompt.
public enum ClaudeCodeLauncher {
    /// The `claude` executable on the login shell PATH.
    public static func locate(environment: [String: String]) -> URL? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.claude/local"]
        return directories.lazy
            .map { URL(fileURLWithPath: $0).appending(path: "claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Opens `terminal` at `root` and runs `claude` with `prompt`. The prompt goes through a file rather
    /// than the command line, so no quoting can break it.
    public static func open(prompt: String, in root: URL, terminal: TerminalApp, toolchain: Toolchain) async throws {
        guard let claude = locate(environment: toolchain.environment) else { throw ClaudeCodeError.notInstalled }
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString
        let promptFile = directory.appending(path: "\(name).md")
        let script = directory.appending(path: "\(name).command")
        try Data(prompt.utf8).write(to: promptFile)
        try Data(self.script(root: root.path, promptFile: promptFile.path, claude: claude.path).utf8).write(to: script)
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

    /// Runs Claude Code in the user's login shell, so it finds the same tools as in their own terminal,
    /// and leaves a shell open in the repository when it exits. Removes itself and the prompt file.
    static func script(root: String, promptFile: String, claude: String) -> String {
        let quote = EditorCommand.shellQuoted
        return """
        #!/bin/sh
        # Written by ohmydiff: starts Claude Code with a prompt about a diff.
        cd \(quote(root)) || exit 1
        unset CLAUDECODE $(env | sed -n 's/^\\(CLAUDE_CODE_[A-Za-z0-9_]*\\)=.*/\\1/p')
        prompt=$(cat \(quote(promptFile)))
        rm -f \(quote(promptFile)) "$0"
        clear
        "${SHELL:-/bin/zsh}" -l -c '"$0" "$1"' \(quote(claude)) "$prompt"
        exec "${SHELL:-/bin/zsh}" -l

        """
    }
}
