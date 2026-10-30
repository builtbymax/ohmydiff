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
    case outputTooLarge(executable: String, limit: Int)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case .toolNotFound(let name):
            "`\(name)` was not found on the login shell PATH"
        case .launchFailed(let executable, let underlying):
            "failed to launch \(executable): \(underlying)"
        case .timedOut(let executable, let after):
            "\(executable) timed out after \(after)"
        case .outputTooLarge(let executable, let limit):
            "\(executable) printed more than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary))"
        case .nonZeroExit(let command, let exitCode, let stderr):
            "\(command) exited with \(exitCode): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Runs external processes asynchronously with a timeout, an output limit and cooperative cancellation.
///
/// Cancelling the calling task terminates the child process and throws `CancellationError`. Stopping sends
/// SIGTERM to the child's process group, then SIGKILL after `killGrace`, so neither the child nor what it
/// started can hold the caller up. Output is read until the child exits, plus `drainGrace` for what it
/// still had in flight; descendants that keep the pipes open after that are not waited for.
public struct ProcessRunner: Sendable {
    public static let defaultTimeout: Duration = .seconds(30)
    /// Per stream; far above anything the app shows, so it only stops runaway output.
    public static let defaultOutputLimit = 256 << 20
    static let killGrace: Duration = .seconds(1)
    static let drainGrace: Duration = .seconds(1)

    public init() {}

    public func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
        timeout: Duration = ProcessRunner.defaultTimeout,
        outputLimit: Int = ProcessRunner.defaultOutputLimit
    ) async throws -> ProcessOutput {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        let stdinPipe = input.map { _ in Pipe() }
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let handle = RunningProcess(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, any Error>) in
                // Drain both pipes concurrently so a chatty child never blocks on a full pipe buffer.
                let group = DispatchGroup()
                let readers = [stdoutPipe, stderrPipe].map { pipe in
                    group.enter()
                    return PipeReader(pipe.fileHandleForReading, limit: outputLimit,
                                      onLimit: { handle.terminate(reason: .outputLimit) }, onEnd: { group.leave() })
                }

                group.enter()
                process.terminationHandler = { _ in
                    group.leave()
                    // Descendants may still hold the pipes; read only what is already on its way.
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace.timeInterval) {
                        readers.forEach { $0.stop() }
                    }
                }

                do {
                    try process.run()
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    process.terminationHandler = nil
                    readers.forEach { $0.stop() }
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
                readers.forEach { $0.start() }
                handle.didLaunch()

                if let stdinPipe, let input {
                    try? stdinPipe.fileHandleForReading.close()
                    // Report EPIPE instead of raising SIGPIPE when the child exits before reading everything.
                    _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global(qos: .userInitiated).async {
                        // The child may exit without reading everything; a failed write is fine.
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                    handle.terminate(reason: .timeout)
                }

                group.notify(queue: .global()) {
                    // Keeps the pipes, and so the descriptors the readers used, open until reading stopped.
                    withExtendedLifetime((stdoutPipe, stderrPipe)) {}
                    switch handle.stopReason {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .timeout:
                        continuation.resume(throwing: ProcessError.timedOut(executable: executable.lastPathComponent, after: timeout))
                    case .outputLimit:
                        continuation.resume(throwing: ProcessError.outputTooLarge(executable: executable.lastPathComponent, limit: outputLimit))
                    case nil:
                        continuation.resume(returning: ProcessOutput(
                            exitCode: process.terminationStatus, stdout: readers[0].data, stderr: readers[1].data))
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
    case outputLimit
}

/// Thread-safe wrapper that lets cancellation, timeouts and the output limit stop the process exactly once.
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
        if pending { stop() }
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
        if shouldTerminate { stop() }
    }

    /// SIGTERM to the child's process group (`Process` makes the child its leader), SIGKILL to what is left
    /// after the grace period.
    private func stop() {
        let group = process.processIdentifier
        guard group > 0 else { return }
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killGrace.timeInterval) {
            kill(-group, SIGKILL)
        }
    }
}

/// Reads a pipe without blocking a thread, until EOF, `stop()` or more than `limit` bytes.
private final class PipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let limit: Int
    private let onLimit: @Sendable () -> Void
    private let source: DispatchSourceRead
    private let storage = Mutex(Data())

    init(_ handle: FileHandle, limit: Int, onLimit: @escaping @Sendable () -> Void, onEnd: @escaping @Sendable () -> Void) {
        descriptor = handle.fileDescriptor
        self.limit = limit
        self.onLimit = onLimit
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "ohmydiff.pipe", qos: .userInitiated))
        // Dispatch releases both handlers once the source is cancelled, which ends the cycle through `self`.
        source.setEventHandler { self.readAvailable() }
        source.setCancelHandler { onEnd() }
    }

    var data: Data { storage.withLock { $0 } }

    func start() { source.activate() }

    /// Ends reading; safe to call repeatedly, before `start()` or after EOF.
    func stop() {
        source.activate()
        source.cancel()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let total = storage.withLock { data in
                    data.append(contentsOf: buffer[..<count])
                    return data.count
                }
                if total > limit {
                    onLimit()
                    source.cancel()
                    return
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                // EOF or an error ends reading; EAGAIN waits for the next event.
                if count == 0 || errno != EAGAIN { source.cancel() }
                return
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
