import Foundation
import Synchronization

/// Captured result of a finished process.
public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessError: Error, Sendable, CustomStringConvertible {
    case toolNotFound(String)
    case launchFailed(executable: String, underlying: String)
    case timedOut(executable: String, after: Duration)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case .toolNotFound(let name):
            "`\(name)` was not found on the login shell PATH"
        case .launchFailed(let executable, let underlying):
            "failed to launch \(executable): \(underlying)"
        case .timedOut(let executable, let after):
            "\(executable) timed out after \(after)"
        case .nonZeroExit(let command, let exitCode, let stderr):
            "\(command) exited with \(exitCode): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Runs external processes asynchronously with a timeout and cooperative cancellation.
///
/// Cancelling the calling task terminates the child process and throws `CancellationError`.
public struct ProcessRunner: Sendable {
    public static let defaultTimeout: Duration = .seconds(30)

    public init() {}

    public func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = ProcessRunner.defaultTimeout
    ) async throws -> ProcessOutput {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let handle = RunningProcess(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, any Error>) in
                // Drain both pipes concurrently so a chatty child never blocks on a full pipe buffer.
                let group = DispatchGroup()
                let stdout = DataBox()
                let stderr = DataBox()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdout.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderr.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }

                group.enter()
                process.terminationHandler = { _ in group.leave() }

                do {
                    try process.run()
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    process.terminationHandler = nil
                    group.leave()
                    group.notify(queue: .global()) {
                        continuation.resume(throwing: ProcessError.launchFailed(
                            executable: executable.path, underlying: error.localizedDescription))
                    }
                    return
                }
                // Close our copies of the write ends so reads see EOF once the child exits.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                handle.didLaunch()

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                    handle.terminate(reason: .timeout)
                }

                group.notify(queue: .global()) {
                    switch handle.stopReason {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .timeout:
                        continuation.resume(throwing: ProcessError.timedOut(executable: executable.lastPathComponent, after: timeout))
                    case nil:
                        continuation.resume(returning: ProcessOutput(
                            exitCode: process.terminationStatus, stdout: stdout.value, stderr: stderr.value))
                    }
                }
            }
        } onCancel: {
            handle.terminate(reason: .cancelled)
        }
    }
}

private enum StopReason: Sendable {
    case cancelled
    case timeout
}

/// Thread-safe wrapper that lets cancellation and timeouts terminate the process exactly once.
private final class RunningProcess: @unchecked Sendable {
    private struct State {
        var launched = false
        var finished = false
        var stopReason: StopReason?
    }

    private let process: Process
    private let state = Mutex(State())

    init(_ process: Process) {
        self.process = process
    }

    var stopReason: StopReason? {
        state.withLock { $0.stopReason }
    }

    func didLaunch() {
        let pending = state.withLock { state -> Bool in
            state.launched = true
            return state.stopReason != nil
        }
        // Cancellation raced ahead of launch.
        if pending { process.terminate() }
    }

    func terminate(reason: StopReason) {
        let shouldTerminate = state.withLock { state -> Bool in
            guard state.stopReason == nil, !state.finished else { return false }
            guard process.isRunning || !state.launched else {
                state.finished = true
                return false
            }
            state.stopReason = reason
            return state.launched
        }
        if shouldTerminate { process.terminate() }
    }
}

private final class DataBox: @unchecked Sendable {
    private let storage = Mutex(Data())

    var value: Data { storage.withLock { $0 } }

    func set(_ data: Data) {
        storage.withLock { $0 = data }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
