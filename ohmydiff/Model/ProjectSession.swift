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

    /// What the detail pane shows for the selected file.
    struct DiffState: Equatable {
        enum Content: Equatable {
            case loading
            case diff(FileDiff)
            /// The file no longer differs, e.g. it was reverted between refreshes.
            case noDifference
            case failed(String)
        }

        var fileID: ChangedFile.ID
        var content: Content
        /// Syntax colors for the diff's lines; `nil` while they load or when the language is unknown.
        var highlights: SyntaxHighlights?
    }

    private(set) var project: Project
    private(set) var phase: Phase = .idle
    private(set) var groups: [ChangeGroup] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?
    private(set) var diff: DiffState?
    let history = HistoryModel()

    var selectedFileID: ChangedFile.ID? {
        didSet {
            guard oldValue != selectedFileID else { return }
            loadDiff()
        }
    }

    /// Called when detection finds a different kind than the saved one.
    @ObservationIgnored var onKindChange: ((RepositoryKind) -> Void)?

    @ObservationIgnored private let toolchain: () async -> Toolchain?
    @ObservationIgnored private var repository: Repository?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherRefresh = false
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var diffTask: Task<Void, Never>?

    init(project: Project, toolchain: @escaping () async -> Toolchain?) {
        self.project = project
        self.toolchain = toolchain
    }

    var changeCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    var selectedFile: ChangedFile? {
        guard let selectedFileID else { return nil }
        return groups.lazy.flatMap(\.files).first { $0.id == selectedFileID }
    }

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
        apply([])
        phase = .idle
        refresh()
    }

    func close() {
        deactivate()
        refreshTask?.cancel()
        diffTask?.cancel()
        history.close()
    }

    /// Reloads History mode's branches; a no-op until the first refresh opened the repository.
    func refreshHistory() async {
        guard let repository else { return }
        await history.refresh(repository)
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
            apply(try await repository.changeGroups())
            phase = .ready
            lastRefreshed = .now
            if isActive, watcher == nil { await startWatching(repository) }
        } catch is CancellationError {
            return
        } catch RepositoryError.notARepository {
            apply([])
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
        apply([])
        phase = .missing
    }

    // MARK: - Selection and diff

    /// One side of a changed file, e.g. for image previews; `nil` when it does not exist or cannot be read.
    func contents(of file: ChangedFile, side: Repository.FileSide) async -> Data? {
        guard let repository else { return nil }
        return try? await repository.contents(of: file, side: side)
    }

    /// Replaces the groups, keeping the selection on the same file where possible.
    private func apply(_ newGroups: [ChangeGroup]) {
        let previous = groups
        if newGroups != previous { groups = newGroups }
        let reselected = newGroups.reselecting(selectedFileID, previous: previous)
        if reselected != selectedFileID {
            selectedFileID = reselected
        } else {
            // Same file, but its contents may have changed.
            loadDiff()
        }
    }

    private func loadDiff() {
        diffTask?.cancel()
        guard let file = selectedFile else {
            diff = nil
            return
        }
        // Keep showing the current diff while the same file reloads, so live refreshes do not flash.
        if diff?.fileID != file.id { diff = DiffState(fileID: file.id, content: .loading) }
        // Before the first refresh opens the repository; that refresh calls back here.
        guard let repository else { return }

        diffTask = Task {
            let content: DiffState.Content
            do {
                content = try await repository.diff(for: file).map(DiffState.Content.diff) ?? .noDifference
            } catch is CancellationError {
                return
            } catch {
                content = .failed(String(describing: error))
            }
            guard !Task.isCancelled, selectedFileID == file.id else { return }

            var state = DiffState(fileID: file.id, content: content)
            guard case .diff(let fileDiff) = content, let language = SyntaxLanguage(path: fileDiff.path), !fileDiff.isBinary else {
                if state != diff { diff = state }
                return
            }
            if let current = diff, current.fileID == file.id, current.content == content, current.highlights != nil {
                // Unchanged; keep the highlights already shown.
                return
            }
            // A newly selected file shows its diff at once and gains colors when they are ready. A
            // reload of the shown file waits for them, so a live refresh does not flash uncolored.
            let isReload = diff?.fileID == file.id && diff?.content != .loading
            if !isReload { diff = state }

            let highlights = await DiffHighlighting.highlights(for: fileDiff, language: language) { side in
                try? await repository.contents(of: file, side: side, limit: SyntaxHighlighter.maximumLength)
            }
            guard !Task.isCancelled, selectedFileID == file.id else { return }
            state.highlights = highlights
            if state != diff { diff = state }
        }
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
