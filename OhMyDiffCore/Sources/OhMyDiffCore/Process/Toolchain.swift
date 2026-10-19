import Foundation

/// The resolved `git` and `but` binaries plus the environment they run with.
///
/// GUI apps launched from Finder get a minimal `PATH`, so discovery asks the user's login shell for
/// its `PATH` and searches that for the binaries.
public struct Toolchain: Sendable {
    public let git: URL
    public let but: URL?
    public let environment: [String: String]
    public let runner: ProcessRunner

    public init(git: URL, but: URL?, environment: [String: String], runner: ProcessRunner = ProcessRunner()) {
        self.git = git
        self.but = but
        self.environment = environment
        self.runner = runner
    }

    /// GitHub's `gh`, for pull requests; `nil` when it is not installed.
    public var gh: URL? { Self.locate("gh", in: environment["PATH"] ?? "") }

    /// Finds `git` (required) and `but` (optional) on the login shell `PATH`.
    public static func discover(
        environment base: [String: String] = ProcessInfo.processInfo.environment,
        runner: ProcessRunner = ProcessRunner()
    ) async throws -> Toolchain {
        var environment = base
        let shellPath = await loginShellPath(environment: base, runner: runner)
        environment["PATH"] = mergedPath(shellPath, base["PATH"], home: base["HOME"])

        let path = environment["PATH"] ?? ""
        guard let git = locate("git", in: path) else { throw ProcessError.toolNotFound("git") }
        return Toolchain(git: git, but: locate("but", in: path), environment: environment, runner: runner)
    }

    /// Returns the first executable named `name` in a colon-separated search path.
    public static func locate(_ name: String, in searchPath: String) -> URL? {
        let fileManager = FileManager.default
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static let pathMarker = "__OHMYDIFF_PATH__"

    /// The `PATH` an interactive login shell sees, e.g. to check that an installed command will be found.
    public static func loginShellPath() async -> String? {
        await loginShellPath(environment: ProcessInfo.processInfo.environment, runner: ProcessRunner())
    }

    static func loginShellPath(environment: [String: String], runner: ProcessRunner) async -> String? {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // Markers keep login-shell banners or rc-file output out of the parsed value.
        let script = "printf '\(pathMarker)%s\(pathMarker)' \"$PATH\""
        guard let output = try? await runner.run(
            URL(fileURLWithPath: shell), arguments: ["-l", "-c", script],
            environment: environment, timeout: .seconds(5)
        ), output.exitCode == 0 else { return nil }

        let parts = output.stdoutString.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func mergedPath(_ shellPath: String?, _ inheritedPath: String?, home: String?) -> String {
        var fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let home { fallback.insert("\(home)/.local/bin", at: 0) }

        var seen = Set<String>()
        var result: [String] = []
        for entry in [shellPath, inheritedPath].compactMap({ $0 }).flatMap({ $0.split(separator: ":").map(String.init) }) + fallback
        where !entry.isEmpty && seen.insert(entry).inserted {
            result.append(entry)
        }
        return result.joined(separator: ":")
    }
}

extension Toolchain {
    /// Runs `git` in `directory` and returns its output, throwing on a non-zero exit unless the code is in `allowedExitCodes`.
    func git(
        _ arguments: [String],
        in directory: URL,
        allowedExitCodes: Set<Int32> = [0],
        input: Data? = nil,
        timeout: Duration = ProcessRunner.defaultTimeout
    ) async throws -> ProcessOutput {
        // Stable, machine-readable output regardless of the user's git config.
        let base = ["-c", "core.quotePath=false", "-c", "color.ui=false", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false"]
        let output = try await runner.run(
            git, arguments: base + arguments, currentDirectory: directory,
            environment: gitEnvironment, input: input, timeout: timeout)
        guard allowedExitCodes.contains(output.exitCode) else {
            throw ProcessError.nonZeroExit(
                command: "git " + arguments.joined(separator: " "), exitCode: output.exitCode, stderr: output.stderrString)
        }
        return output
    }

    /// Runs `but` against the project at `directory`.
    func but(
        _ arguments: [String],
        in directory: URL,
        timeout: Duration = ProcessRunner.defaultTimeout
    ) async throws -> ProcessOutput {
        guard let but else { throw ProcessError.toolNotFound("but") }
        let output = try await runner.run(
            but, arguments: ["-C", directory.path] + arguments, currentDirectory: directory,
            environment: environment, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ProcessError.nonZeroExit(
                command: "but " + arguments.joined(separator: " "), exitCode: output.exitCode, stderr: output.stderrString)
        }
        return output
    }

    /// Runs GitHub's `gh` in `directory`, never prompting.
    func gh(
        _ arguments: [String],
        in directory: URL,
        input: Data? = nil,
        timeout: Duration = ProcessRunner.defaultTimeout
    ) async throws -> ProcessOutput {
        guard let gh else { throw ProcessError.toolNotFound("gh") }
        var environment = gitEnvironment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        let output = try await runner.run(
            gh, arguments: arguments, currentDirectory: directory, environment: environment, input: input, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ProcessError.nonZeroExit(
                command: "gh " + arguments.joined(separator: " "), exitCode: output.exitCode, stderr: output.stderrString)
        }
        return output
    }

    private var gitEnvironment: [String: String] {
        var environment = environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        return environment
    }
}
