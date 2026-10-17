import Foundation
import Observation
import OhMyDiffCore

/// In-memory state of one project. Kept for the app's lifetime so switching back shows the
/// cached state at once while a background refresh brings it up to date.
@Observable
final class ProjectSession {
    enum Phase: Equatable {
        /// Never loaded.
        case idle
        case ready
        /// The folder no longer exists at the saved path.
        case missing
        case failed(String)
    }

    private(set) var project: Project
    private(set) var phase: Phase = .idle
    private(set) var groups: [ChangeGroup] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?

    /// Called when detection finds a different kind than the saved one.
    @ObservationIgnored var onKindChange: ((RepositoryKind) -> Void)?

    @ObservationIgnored private let toolchain: () async -> Toolchain?
    @ObservationIgnored private var repository: Repository?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherRefresh = false
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false

    init(project: Project, toolchain: @escaping () async -> Toolchain?) {
        self.project = project
        self.toolchain = toolchain
    }

    var changeCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    /// Starts live updates and refreshes; the cached state stays visible meanwhile.
    func activate() {
        isActive = true
        // Re-detect the kind in case `but setup` or `but teardown` ran while we were away.
        repository = nil
        refresh()
    }

    /// Stops live updates; the cached state is kept.
    func deactivate() {
        isActive = false
        stopWatching()
    }

    /// Points the project at a new folder after it was moved.
    func relocate(to project: Project) {
        self.project = project
        repository = nil
        stopWatching()
        groups = []
        phase = .idle
        refresh()
    }

    func close() {
        deactivate()
        refreshTask?.cancel()
    }

    /// Coalesces requests: while a refresh runs, further requests schedule exactly one more.
    func refresh() {
        guard refreshTask == nil else {
            needsAnotherRefresh = true
            return
        }
        refreshTask = Task {
            repeat {
                needsAnotherRefresh = false
                await performRefresh()
            } while needsAnotherRefresh && !Task.isCancelled
            refreshTask = nil
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        guard project.exists else {
            markMissing()
            return
        }
        guard let toolchain = await toolchain() else {
            phase = .failed("git was not found on your login shell PATH.")
            return
        }

        do {
            let repository = try await openRepository(toolchain)
            groups = try await repository.changeGroups()
            phase = .ready
            lastRefreshed = .now
            if isActive, watcher == nil { await startWatching(repository) }
        } catch is CancellationError {
            return
        } catch RepositoryError.notARepository {
            groups = []
            phase = project.exists ? .failed("This folder is no longer a git repository.") : .missing
        } catch {
            if !project.exists {
                markMissing()
            } else {
                // Force re-detection next time, e.g. after `but teardown` made `but status` fail.
                self.repository = nil
                phase = .failed(String(describing: error))
            }
        }
    }

    private func openRepository(_ toolchain: Toolchain) async throws -> Repository {
        if let repository { return repository }
        let repository = try await Repository.open(project.url, toolchain: toolchain)
        self.repository = repository
        if repository.kind != project.kind {
            project.kind = repository.kind
            onKindChange?(repository.kind)
        }
        return repository
    }

    private func markMissing() {
        stopWatching()
        repository = nil
        groups = []
        phase = .missing
    }

    // MARK: - Watching

    private func startWatching(_ repository: Repository) async {
        guard let directories = try? await repository.gitDirectories(), isActive, watcher == nil else { return }
        let filter = WatchFilter(
            root: repository.root.resolvingSymlinksInPath().path,
            gitDirectories: [directories.gitDir, directories.commonDir].map { $0.resolvingSymlinksInPath().path })
        let watcher = FileWatcher(filter: filter)
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await batch in watcher.batches {
                await self?.handle(batch, repository: repository)
            }
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
    }

    /// Only these many changed paths are checked against `.gitignore`; larger batches refresh directly.
    private static let ignoreCheckLimit = 200

    private func handle(_ batch: WatchBatch, repository: Repository) async {
        if batch.rootChanged || batch.mustRescan || batch.gitMetadataChanged
            || batch.worktreePaths.count > Self.ignoreCheckLimit {
            refresh()
            return
        }
        // Skip refreshes caused only by ignored files such as build output.
        let paths = Array(batch.worktreePaths)
        let ignored = (try? await repository.ignoredPaths(paths)) ?? []
        if ignored.count < paths.count { refresh() }
    }
}
