import CoreServices
import Foundation
import Synchronization

/// A debounced batch of relevant file system changes.
public struct WatchBatch: Sendable, Hashable {
    /// HEAD, index, refs or GitButler state changed.
    public var gitMetadataChanged = false
    /// Changed worktree paths relative to the root; may still contain ignored files.
    public var worktreePaths: Set<String> = []
    /// The watched root itself was moved, renamed or deleted.
    public var rootChanged = false
    /// FSEvents dropped events or asked for a rescan; treat everything as changed.
    public var mustRescan = false

    public var isEmpty: Bool { !gitMetadataChanged && worktreePaths.isEmpty && !rootChanged && !mustRescan }
}

/// Watches a worktree and its git dirs with FSEvents and emits debounced `WatchBatch`es.
public final class FileWatcher: Sendable {
    public static let defaultDebounce: Duration = .milliseconds(150)

    public let batches: AsyncStream<WatchBatch>

    private let filter: WatchFilter
    private let debounce: Duration
    private let queue = DispatchQueue(label: "dev.koby.ohmydiff.FileWatcher")
    private let continuation: AsyncStream<WatchBatch>.Continuation
    private let state = Mutex(State())

    private struct State: @unchecked Sendable {
        var stream: FSEventStreamRef?
        var pending = WatchBatch()
        var flush: DispatchWorkItem?
    }

    /// Starts watching immediately. The stream finishes when `stop()` is called or the watcher is deallocated.
    public init(filter: WatchFilter, debounce: Duration = FileWatcher.defaultDebounce) {
        self.filter = filter
        self.debounce = debounce
        (batches, continuation) = AsyncStream.makeStream(of: WatchBatch.self, bufferingPolicy: .bufferingNewest(8))
        start()
    }

    deinit {
        stop()
    }

    public func stop() {
        let stream = state.withLock { state -> FSEventStreamRef? in
            state.flush?.cancel()
            state.flush = nil
            defer { state.stream = nil }
            return state.stream
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation.finish()
    }

    private func start() {
        // The root's parent is not watched, so WatchRoot reports moves of the root itself.
        var paths = [filter.root]
        for directory in filter.gitDirectories where WatchFilter.relative(directory, to: filter.root) == nil {
            paths.append(directory)
        }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.03, flags)
        else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        state.withLock { $0.stream = stream }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        watcher.handle(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }

    /// Runs on `queue`.
    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        var batch = WatchBatch()
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                batch.rootChanged = true
                continue
            }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                batch.mustRescan = true
            }
            switch filter.classify(path) {
            case .gitMetadata: batch.gitMetadataChanged = true
            case .worktree(let relative): batch.worktreePaths.insert(relative)
            case .irrelevant: break
            }
        }
        guard !batch.isEmpty else { return }

        let item = DispatchWorkItem { [weak self] in self?.flush() }
        state.withLock { state in
            state.pending.gitMetadataChanged = state.pending.gitMetadataChanged || batch.gitMetadataChanged
            state.pending.rootChanged = state.pending.rootChanged || batch.rootChanged
            state.pending.mustRescan = state.pending.mustRescan || batch.mustRescan
            state.pending.worktreePaths.formUnion(batch.worktreePaths)
            // Trailing debounce: every new event pushes the flush out again.
            state.flush?.cancel()
            state.flush = item
        }
        queue.asyncAfter(deadline: .now() + debounce.timeInterval, execute: item)
    }

    private func flush() {
        let batch = state.withLock { state -> WatchBatch in
            defer {
                state.pending = WatchBatch()
                state.flush = nil
            }
            return state.pending
        }
        if !batch.isEmpty { continuation.yield(batch) }
    }
}
