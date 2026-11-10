import Foundation

/// An editor ohmydiff can open files in, each with the command that jumps to a line.
public enum EditorPreset: String, Sendable, Hashable, CaseIterable, Identifiable {
    case cursor
    case vscode
    case zed
    case xcode
    case sublime
    case custom

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .sublime: "Sublime Text"
        case .custom: "Custom"
        }
    }

    /// The command line with `{file}` and `{line}` placeholders; `nil` for `custom`, which brings its own.
    public var template: String? {
        switch self {
        case .cursor: "cursor -g {file}:{line}"
        case .vscode: "code -g {file}:{line}"
        case .zed: "zed {file}:{line}"
        case .xcode: "xed -l {line} {file}"
        case .sublime: "subl {file}:{line}"
        case .custom: nil
        }
    }

    /// The command that opens the editor's three-way merge view, with `{ours}`, `{theirs}`, `{base}` and `{file}`
    /// placeholders; `nil` for editors without one, which open the conflicted file at its first conflict instead.
    public var mergeTemplate: String? {
        switch self {
        case .cursor: "cursor --merge {ours} {theirs} {base} {file}"
        case .vscode: "code --merge {ours} {theirs} {base} {file}"
        default: nil
        }
    }
}

public enum EditorError: Error, Sendable, CustomStringConvertible {
    case emptyCommand
    case failed(command: String, exitCode: Int32, message: String)

    public var description: String {
        switch self {
        case .emptyCommand:
            "No editor command is set. Choose one in Settings."
        case .failed(let command, let exitCode, let message):
            exitCode == 127
                ? "\(command.split(separator: " ").first ?? "") was not found on your login shell PATH."
                : message.isEmpty ? "\(command) exited with status \(exitCode)." : message
        }
    }
}

public enum EditorCommand {
    /// Fills in a template. The file is shell-quoted, so paths with spaces or quotes stay one argument,
    /// and `{file}:{line}` still joins into a single word.
    public static func commandLine(template: String, file: String, line: Int) -> String {
        template
            .replacing("{line}", with: String(max(line, 1)))
            .replacing("{file}", with: shellQuoted(file))
    }

    /// Fills in a merge template; every path is shell-quoted.
    public static func mergeCommandLine(template: String, file: String, ours: String, theirs: String, base: String) -> String {
        template
            .replacing("{ours}", with: shellQuoted(ours))
            .replacing("{theirs}", with: shellQuoted(theirs))
            .replacing("{base}", with: shellQuoted(base))
            .replacing("{file}", with: shellQuoted(file))
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacing("'", with: "'\\''") + "'"
    }

    /// Runs the editor command through `/bin/sh` with the login-shell environment, so editor CLIs
    /// installed in e.g. `/opt/homebrew/bin` or `~/.local/bin` are found.
    public static func open(template: String, file: String, line: Int, toolchain: Toolchain) async throws {
        guard !template.trimmingCharacters(in: .whitespaces).isEmpty else { throw EditorError.emptyCommand }
        try await run(commandLine(template: template, file: file, line: line), toolchain: toolchain)
    }

    /// Opens a conflicted file in the editor's merge view, with its sides in the files `ours`, `theirs` and `base`.
    public static func openMerge(template: String, file: String, ours: String, theirs: String, base: String, toolchain: Toolchain) async throws {
        try await run(mergeCommandLine(template: template, file: file, ours: ours, theirs: theirs, base: base), toolchain: toolchain)
    }

    private static func run(_ command: String, toolchain: Toolchain) async throws {
        // An editor CLI may start the editor itself, which would inherit and hold open our pipes. Only
        // the shell keeps them; the command's output goes to /dev/null and its errors to a file.
        let errorFile = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-editor-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let output = try await toolchain.runner.run(
            URL(fileURLWithPath: "/bin/sh"),
            // Grouped, so redirections inside a custom command still apply to it.
            arguments: ["-c", "{ \(command)\n} </dev/null >/dev/null 2>\(shellQuoted(errorFile.path))"],
            environment: toolchain.environment, timeout: .seconds(15))
        guard output.exitCode == 0 else {
            let message = ((try? String(contentsOf: errorFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw EditorError.failed(command: command, exitCode: output.exitCode, message: message)
        }
    }
}
