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
    @Test func parsesOpenURLs() {
        #expect(CLILauncher.openRequestPath(URL(string: "ohmydiff://open?path=%2FUsers%2Fme%2Fmy%20repo")!) == "/Users/me/my repo")
        #expect(CLILauncher.openRequestPath(URL(string: "ohmydiff://open?other=1")!) == nil)
        #expect(CLILauncher.openRequestPath(URL(string: "ohmydiff://close?path=%2Fx")!) == nil)
        #expect(CLILauncher.openRequestPath(URL(string: "https://open?path=%2Fx")!) == nil)
    }

    @Test func checksSearchPath() {
        let directory = URL(fileURLWithPath: "/Users/me/.local/bin")
        #expect(CLILauncher.searchPath("/usr/bin:/Users/me/.local/bin/", contains: directory))
        #expect(!CLILauncher.searchPath("/usr/bin:/bin", contains: directory))
    }

    /// The script's percent-encoding must round-trip through `URLComponents`, spaces and non-ASCII included.
    @Test func scriptEncodesPathsTheAppCanRead() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "ohmydiff-cli-\(UUID().uuidString)")
        let folder = base.appending(path: "my répo & co", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let bin = try CLILauncher.install(in: base.appending(path: "bin"))
        #expect(CLILauncher.isInstalled(in: base.appending(path: "bin")))

        // Swap `open` for `echo` so the test sees the URL instead of launching the app.
        let script = try String(contentsOf: bin, encoding: .utf8).replacing("exec open ", with: "exec echo ")
        let probe = base.appending(path: "probe.sh")
        try Data(script.utf8).write(to: probe)
        let output = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: [probe.path, folder.path])
        #expect(output.exitCode == 0)

        let url = try #require(URL(string: output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)))
        // `pwd -P` reports /private/var/…, the real location of the temp directory.
        let received = try #require(CLILauncher.openRequestPath(url))
        #expect(URL(fileURLWithPath: received).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        #expect(received.hasSuffix("/my répo & co"))

        let missing = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: [probe.path, base.appending(path: "nope").path])
        #expect(missing.exitCode == 1)
    }
}
