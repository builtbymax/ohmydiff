import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct EditorCommandTests {
    @Test func fillsPresetTemplates() {
        let file = "/repo/Sources/App.swift"
        #expect(EditorCommand.commandLine(template: EditorPreset.cursor.template!, file: file, line: 12) == "cursor -g '/repo/Sources/App.swift':12")
        #expect(EditorCommand.commandLine(template: EditorPreset.xcode.template!, file: file, line: 3) == "xed -l 3 '/repo/Sources/App.swift'")
        #expect(EditorCommand.commandLine(template: EditorPreset.zed.template!, file: file, line: 0) == "zed '/repo/Sources/App.swift':1")
    }

    @Test func quotesAwkwardPaths() {
        let line = EditorCommand.commandLine(template: "edit {file}", file: "/a b/it's $HOME.txt", line: 1)
        #expect(line == "edit '/a b/it'\\''s $HOME.txt'")
    }

    @Test func runsCommandsAndReportsFailures() async throws {
        let toolchain = try await Toolchain.discover()
        let directory = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "opened")

        // A stand-in editor that records its arguments.
        try await EditorCommand.open(
            template: "printf '%s\\n' {file}:{line} > \(EditorCommand.shellQuoted(marker.path))",
            file: "/x y/z.swift", line: 7, toolchain: toolchain)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "/x y/z.swift:7\n")

        await #expect {
            try await EditorCommand.open(template: "definitely-not-an-editor-xyz {file}", file: "/f", line: 1, toolchain: toolchain)
        } throws: { error in
            if case EditorError.failed(_, 127, _) = error { true } else { false }
        }
        await #expect(throws: EditorError.self) {
            try await EditorCommand.open(template: "  ", file: "/f", line: 1, toolchain: toolchain)
        }
    }
}

@Suite struct CLILauncherTests {
    @Test func parsesRequestURLs() {
        #expect(CLIRequest(url: URL(string: "ohmydiff://open?path=%2FUsers%2Fme%2Fmy%20repo")!) == .open(path: "/Users/me/my repo"))
        #expect(CLIRequest(url: URL(string: "ohmydiff://show?path=%2Fr%2Fa.swift&line=12")!) == .show(path: "/r/a.swift", line: 12))
        #expect(CLIRequest(url: URL(string: "ohmydiff://show?path=%2Fr%2Fa.swift&line=")!) == .show(path: "/r/a.swift", line: nil))
        #expect(CLIRequest(url: URL(string: "ohmydiff://branch?path=%2Fr&name=feat%2Fx")!) == .branch(path: "/r", name: "feat/x"))
        #expect(CLIRequest(url: URL(string: "ohmydiff://commit?path=%2Fr&sha=abc123")!) == .commit(path: "/r", sha: "abc123"))
        #expect(CLIRequest(url: URL(string: "ohmydiff://open?other=1")!) == nil)
        #expect(CLIRequest(url: URL(string: "ohmydiff://branch?path=%2Fr")!) == nil)
        #expect(CLIRequest(url: URL(string: "ohmydiff://close?path=%2Fx")!) == nil)
        #expect(CLIRequest(url: URL(string: "https://open?path=%2Fx")!) == nil)
    }

    @Test func requestURLsRoundTrip() {
        let requests: [CLIRequest] = [
            .open(path: "/a b/c&d=e+f#g?h"),
            .show(path: "/r/ä ö.swift", line: 3),
            .show(path: "/r/x", line: nil),
            .branch(path: "/r", name: "feat/a+b&c"),
            .commit(path: "/r", sha: "HEAD~1"),
        ]
        for request in requests { #expect(CLIRequest(url: request.url) == request) }
    }

    @Test func checksSearchPath() {
        let directory = URL(fileURLWithPath: "/Users/me/.local/bin")
        #expect(CLILauncher.searchPath("/usr/bin:/Users/me/.local/bin/", contains: directory))
        #expect(!CLILauncher.searchPath("/usr/bin:/bin", contains: directory))
    }

    @Test func reportsInstallState() throws {
        let bin = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bin) }
        #expect(CLILauncher.installState(app: "/A/ohmydiff", in: bin) == .missing)
        try CLILauncher.install(app: "/A/ohmydiff", in: bin)
        #expect(CLILauncher.installState(app: "/A/ohmydiff", in: bin) == .current)
        #expect(CLILauncher.installState(app: "/B/ohmydiff", in: bin) == .outdated)
    }

    @Test func refreshesCommandsFromEarlierVersions() throws {
        let bin = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bin) }
        let command = bin.appending(path: "ohmydiff")
        #expect(try !CLILauncher.refresh(app: "/A/ohmydiff", in: bin))

        // An earlier version's script for the same app is rewritten.
        try CLILauncher.install(app: "/A/ohmydiff", in: bin)
        try Data(String(contentsOf: command, encoding: .utf8).replacing("set -eu", with: "set -e").utf8).write(to: command)
        #expect(try CLILauncher.refresh(app: "/A/ohmydiff", in: bin))
        #expect(CLILauncher.installState(app: "/A/ohmydiff", in: bin) == .current)
        #expect(try !CLILauncher.refresh(app: "/A/ohmydiff", in: bin))

        // One for another copy of the app stays outdated.
        #expect(try !CLILauncher.refresh(app: "/B/ohmydiff", in: bin))
        #expect(CLILauncher.installState(app: "/B/ohmydiff", in: bin) == .outdated)
    }

    /// Runs the installed script with `open` swapped for `echo`, so the test sees the URL instead of launching the app.
    private struct Probe {
        let base: URL
        let script: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-cli-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let bin = try CLILauncher.install(app: base.appending(path: "fake-app").path, in: base.appending(path: "bin"))
            let text = try String(contentsOf: bin, encoding: .utf8).replacing("exec open ", with: "exec echo ")
            script = base.appending(path: "probe.sh")
            try Data(text.utf8).write(to: script)
        }

        func run(_ arguments: String..., in directory: URL? = nil) async throws -> (code: Int32, request: CLIRequest?, output: String) {
            let output = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: [script.path] + arguments, currentDirectory: directory)
            let text = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output.exitCode, URL(string: text).flatMap(CLIRequest.init(url:))?.withoutPrivatePrefix, text + output.stderrString)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    /// The script's percent-encoding must round-trip through `URLComponents`, spaces and non-ASCII included.
    @Test func scriptEncodesPathsTheAppCanRead() async throws {
        let probe = try Probe()
        defer { probe.remove() }
        let folder = probe.base.appending(path: "my répo & co", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let opened = try await probe.run(folder.path)
        #expect(opened.code == 0)
        #expect(opened.request == .open(path: folder.path))
        #expect(try await probe.run("open", folder.path).request == .open(path: folder.path))
        #expect(try await probe.run(in: folder).request == .open(path: folder.path))

        #expect(try await probe.run(probe.base.appending(path: "nope").path).code == 1)
    }

    @Test func scriptShowsFilesAtLines() async throws {
        let probe = try Probe()
        defer { probe.remove() }
        let file = probe.base.appending(path: "a b.swift")
        try Data("x\n".utf8).write(to: file)
        // A file whose name looks like a line suffix is taken as is.
        let odd = probe.base.appending(path: "notes:12")
        try Data("x\n".utf8).write(to: odd)

        #expect(try await probe.run("show", file.path + ":42").request == .show(path: file.path, line: 42))
        #expect(try await probe.run("show", "a b.swift", in: probe.base).request == .show(path: file.path, line: nil))
        #expect(try await probe.run("show", odd.path).request == .show(path: odd.path, line: nil))
        // Deleted files can still be shown; their folder must exist.
        let deleted = probe.base.appending(path: "gone.txt").path
        #expect(try await probe.run("show", deleted + ":3").request == .show(path: deleted, line: 3))
        #expect(try await probe.run("show", "/nope/at/all.txt").code == 1)
        #expect(try await probe.run("show").code == 2)
    }

    @Test func scriptShowsBranchesAndCommits() async throws {
        let probe = try Probe()
        defer { probe.remove() }
        #expect(try await probe.run("branch", "feat/a&b", in: probe.base).request == .branch(path: probe.base.path, name: "feat/a&b"))
        #expect(try await probe.run("commit", "abc1234", probe.base.path).request == .commit(path: probe.base.path, sha: "abc1234"))
        #expect(try await probe.run("branch").code == 2)

        let mcp = try await probe.run("mcp")
        #expect(mcp.code == 1)
        #expect(mcp.output.contains("Reinstall"))
        #expect(try await probe.run("--help").output.contains("ohmydiff mcp"))
    }
}

extension CLIRequest {
    /// `pwd -P` and git report /private/var/…, while `resolvingSymlinksInPath` gives the /var/… the tests compare with.
    var withoutPrivatePrefix: CLIRequest {
        func strip(_ path: String) -> String { path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path }
        return switch self {
        case .open(let path): .open(path: strip(path))
        case .show(let path, let line): .show(path: strip(path), line: line)
        case .branch(let path, let name): .branch(path: strip(path), name: name)
        case .commit(let path, let sha): .commit(path: strip(path), sha: sha)
        }
    }
}
