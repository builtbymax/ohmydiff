import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct ProcessRunnerTests {
    private let runner = ProcessRunner()
    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndExitCode() async throws {
        let output = try await runner.run(sh, arguments: ["-c", "printf out; printf err >&2; exit 3"])
        #expect(output.stdoutString == "out")
        #expect(output.stderrString == "err")
        #expect(output.exitCode == 3)
    }

    @Test func usesWorkingDirectoryAndEnvironment() async throws {
        let directory = URL(fileURLWithPath: "/usr")
        let output = try await runner.run(
            sh, arguments: ["-c", "pwd; printf %s \"$OHMYDIFF_TEST\""],
            currentDirectory: directory, environment: ["OHMYDIFF_TEST": "value"])
        #expect(output.stdoutString == "/usr\nvalue")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        // Well past the 64 KiB pipe buffer on both streams.
        let output = try await runner.run(
            sh, arguments: ["-c", "head -c 1000000 /dev/zero; head -c 1000000 /dev/zero >&2"], timeout: .seconds(10))
        #expect(output.stdout.count == 1_000_000)
        #expect(output.stderr.count == 1_000_000)
    }

    @Test func timesOut() async throws {
        let start = ContinuousClock.now
        await #expect {
            try await runner.run(sh, arguments: ["-c", "sleep 10"], timeout: .milliseconds(200))
        } throws: { error in
            if case ProcessError.timedOut = error { true } else { false }
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellationTerminatesProcess() async throws {
        let start = ContinuousClock.now
        let task = Task {
            try await runner.run(sh, arguments: ["-c", "sleep 10"], timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func missingExecutableFailsToLaunch() async {
        await #expect {
            try await runner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        } throws: { error in
            if case ProcessError.launchFailed = error { true } else { false }
        }
    }

    @Test func locatesToolsOnSearchPath() throws {
        #expect(Toolchain.locate("sh", in: "/nonexistent:/bin")?.path == "/bin/sh")
        #expect(Toolchain.locate("definitely-not-a-tool", in: "/bin:/usr/bin") == nil)
        let merged = Toolchain.mergedPath("/a:/b", "/b:/c", home: "/h")
        #expect(merged.hasPrefix("/a:/b:/c:/h/.local/bin:"))
    }

    @Test func discoversGit() async throws {
        let toolchain = try await Toolchain.discover()
        #expect(toolchain.git.lastPathComponent == "git")
    }
}

@Suite struct ProcessRunnerInputTests {
    @Test func feedsStandardInput() async throws {
        let output = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/cat"), arguments: [], input: Data("piped\0data".utf8))
        #expect(output.stdout == Data("piped\0data".utf8))
    }

    @Test func survivesChildThatIgnoresInput() async throws {
        // `true` exits without reading; writing must not raise SIGPIPE.
        let input = Data(repeating: 0x61, count: 1_000_000)
        let output = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], input: input)
        #expect(output.exitCode == 0)
    }
}

/// Children that misbehave must not hold the app up past the timeout, nor fill memory.
///
/// The children run for 30 s and the bounds are 10 s: well above what a busy CI runner needs to stop them, and
/// still failing clearly if the runner waits for the child instead.
@Suite struct ProcessRunnerLimitTests {
    private let runner = ProcessRunner()
    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func killsAChildThatIgnoresSIGTERM() async throws {
        let start = ContinuousClock.now
        await #expect {
            try await runner.run(sh, arguments: ["-c", "trap '' TERM; sleep 30"], timeout: .milliseconds(100))
        } throws: { error in
            if case ProcessError.timedOut = error { true } else { false }
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func stopsTheChildsDescendantsOnTimeout() async throws {
        let marker = "30.\(Int.random(in: 100_000...999_999))"
        await #expect(throws: ProcessError.self) {
            try await runner.run(sh, arguments: ["-c", "trap '' TERM; sleep \(marker) & wait"], timeout: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        let left = try await runner.run(URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", "sleep \(marker)"])
        #expect(left.stdoutString.isEmpty)
    }

    @Test func doesNotWaitForDescendantsHoldingTheOutputOpen() async throws {
        let start = ContinuousClock.now
        let output = try await runner.run(sh, arguments: ["-c", "sleep 30 & echo done"], timeout: .seconds(20))
        #expect(output.stdoutString == "done\n")
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func stopsAtTheOutputLimit() async throws {
        let start = ContinuousClock.now
        await #expect {
            try await runner.run(sh, arguments: ["-c", "yes"], timeout: .seconds(20), outputLimit: 1 << 20)
        } throws: { error in
            if case ProcessError.outputTooLarge = error { true } else { false }
        }
        #expect(ContinuousClock.now - start < .seconds(10))
        // Up to the limit is fine, on either stream.
        let output = try await runner.run(sh, arguments: ["-c", "head -c 1048576 /dev/zero >&2"], outputLimit: 1 << 20)
        #expect(output.stderr.count == 1 << 20)
    }
}
