import Foundation
import Observation
import OhMyDiffCore

/// A file selected from outside the list, e.g. by `ohmydiff show`: the list scrolls to it and its diff
/// to `line` of the new file, once per request.
struct FileReveal: Equatable {
    let id = UUID()
    var fileID: ChangedFile.ID
    var line: Int?
}

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
    /// Why a GitButler workspace is shown as plain git; `nil` when it is not one or `but` is supported.
    private(set) var butIncompatibility: ButIncompatibility?
    /// A discard waiting for confirmation or a commit waiting for its message.
    var actionRequest: ActionRequest?
    private(set) var isPerformingAction = false
    var actionError: String?
    let history = HistoryModel()

    var selectedFileID: ChangedFile.ID? {
        didSet {
            guard oldValue != selectedFileID else { return }
            // Moving the selection any other way than `select(_:extending:)` drops the files picked along.
            extraSelectedFileIDs = []
            loadDiff()
        }
    }

    /// Files picked along with the selected one with ⌘- or ⇧-click, e.g. to commit several at once.
    private(set) var extraSelectedFileIDs: Set<ChangedFile.ID> = []
    /// Where a ⇧-click range starts: the last file clicked without ⇧.
    @ObservationIgnored private var selectionAnchor: ChangedFile.ID?

    /// Called when detection finds a different kind than the saved one.
    @ObservationIgnored var onKindChange: ((RepositoryKind) -> Void)?
    /// Called when a file, branch or commit asked for by `ohmydiff` or an agent is not there.
    @ObservationIgnored var onRevealFailure: ((String) -> Void)? {
        didSet { history.onRevealFailure = onRevealFailure }
    }
    /// The last file selected from outside the list.
    private(set) var fileReveal: FileReveal?
    /// A file to select once the next refresh lists it.
    @ObservationIgnored private var pendingReveal: (path: String, line: Int?)?

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

    /// The repository root once opened; the project folder before that.
    var rootURL: URL { repository?.root ?? project.url }

    var changeCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    var selectedFile: ChangedFile? {
        guard let selectedFileID else { return nil }
        return groups.lazy.flatMap(\.files).first { $0.id == selectedFileID }
    }

    /// The selected file and the ones picked along with it, in list order.
    var selectedFiles: [ChangedFile] {
        guard let selectedFileID else { return [] }
        if extraSelectedFileIDs.isEmpty { return selectedFile.map { [$0] } ?? [] }
        return groups.allFiles.filter { $0.id == selectedFileID || extraSelectedFileIDs.contains($0.id) }
    }

    func isSelected(_ id: ChangedFile.ID) -> Bool {
        id == selectedFileID || extraSelectedFileIDs.contains(id)
    }

    enum SelectionExtension { case toggle, range }

    /// Selects a clicked file: alone, toggled in or out of the selection (⌘), or with every file from the
    /// last clicked one (⇧). The clicked file's diff is shown.
    func select(_ id: ChangedFile.ID, extending: SelectionExtension? = nil) {
        let previous = extraSelectedFileIDs.union(selectedFileID.map { [$0] } ?? [])
        switch extending {
        case nil:
            selectedFileID = id
            selectionAnchor = id
        case .toggle:
            if previous.contains(id), previous.count > 1 {
                let remaining = previous.subtracting([id])
                // Show the nearest remaining file in list order.
                let next = groups.allFiles.first { remaining.contains($0.id) }?.id
                selectedFileID = id == selectedFileID ? next : selectedFileID
                extraSelectedFileIDs = remaining.subtracting([selectedFileID].compactMap(\.self))
            } else {
                selectedFileID = id
                extraSelectedFileIDs = previous.subtracting([id])
            }
            selectionAnchor = id
        case .range:
            let files = groups.allFiles.map(\.id)
            guard let anchor = selectionAnchor ?? selectedFileID, let from = files.firstIndex(of: anchor),
                  let to = files.firstIndex(of: id)
            else { return select(id) }
            selectedFileID = id
            extraSelectedFileIDs = Set(files[min(from, to)...max(from, to)]).subtracting([id])
        }
    }

    /// Keeps only the selected file.
    func clearExtraSelection() {
        extraSelectedFileIDs = []
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
            resolvePendingReveal(isFinal: true)
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
        if repository.butIncompatibility != butIncompatibility { butIncompatibility = repository.butIncompatibility }
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

    // MARK: - Actions

    /// An action the user started that needs one more step: a confirmation or a commit message.
    struct ActionRequest: Identifiable {
        let id = UUID()
        var action: ChangeAction
        var targets: [ChangeTarget]

        /// e.g. `notes.txt`, `a hunk of notes.txt` or `3 files`.
        var subject: String {
            if targets.count == 1, let target = targets.first {
                let name = (target.file.path as NSString).lastPathComponent
                return target.hunk == nil ? name : "a hunk of \(name)"
            }
            return "\(targets.count) files"
        }
    }

    /// Whether every target supports `action`; `false` until the repository is open or while another action runs.
    func supports(_ action: ChangeAction, on targets: [ChangeTarget]) -> Bool {
        guard let repository, !targets.isEmpty, !isPerformingAction else { return false }
        return targets.allSatisfy { repository.supports(action, on: $0) }
    }

    /// Stages and unstages right away; discards ask for confirmation and commits for a message first.
    func request(_ action: ChangeAction, on targets: [ChangeTarget]) {
        guard supports(action, on: targets) else { return }
        switch action {
        case .stage, .unstage:
            Task { await perform(action, on: targets) }
        case .commit, .discard:
            actionRequest = ActionRequest(action: action, targets: targets)
        }
    }

    /// Runs an action and refreshes; a failure shows in `actionError`.
    func perform(_ action: ChangeAction, on targets: [ChangeTarget]) async {
        do {
            try await run(action, on: targets)
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Runs an action and refreshes, throwing failures to the caller, e.g. to show them in the commit sheet.
    func run(_ action: ChangeAction, on targets: [ChangeTarget], branch: String = "", message: String = "") async throws {
        guard let repository, !isPerformingAction else { return }
        isPerformingAction = true
        defer {
            isPerformingAction = false
            refresh()
        }
        switch action {
        case .stage: try await repository.stage(targets)
        case .unstage: try await repository.unstage(targets)
        case .discard: try await repository.discard(targets)
        case .commit:
            try await repository.commit(targets, toBranch: branch, message: message)
            lastCommitBranch = branch
        }
    }

    /// Applied GitButler branches, top of each stack first.
    var branchNames: [String] {
        groups.flatMap { group -> [String] in
            if case .stack(_, let branches) = group.kind { return branches }
            return []
        }
    }

    /// What a prompt to Claude Code says about an uncommitted file: the repository and where the change sits.
    func promptContext(forPath path: String) -> PromptContext {
        let group = groups.first { $0.files.contains { $0.path == path } }
        let description: String? = switch group?.kind {
        case .stack(_, let branches)?: branches.first.map { "assigned to branch `\($0)`" }
        case .staged?: "staged"
        case .unstaged?: "not staged"
        case .untracked?: "a new, untracked file"
        case .conflicted?: "with merge conflicts"
        case .unassigned?: "not assigned to a branch yet"
        case nil: nil
        }
        return PromptContext(repositoryPath: rootURL.path, isGitButler: project.kind == .gitButler, source: .uncommitted(group: description))
    }

    /// The top branch of the GitButler stack a file is assigned to; `nil` for unassigned changes.
    func assignedBranch(of path: String) -> String? {
        for group in groups {
            if case .stack(_, let branches) = group.kind, group.files.contains(where: { $0.path == path }) {
                return branches.first
            }
        }
        return nil
    }

    /// The branch a commit of `targets` most likely goes to: the stack they are assigned to, else the last one used.
    func suggestedBranch(for targets: [ChangeTarget]) -> String {
        if let assigned = targets.lazy.compactMap({ self.assignedBranch(of: $0.file.path) }).first { return assigned }
        if let lastCommitBranch, branchNames.contains(lastCommitBranch) { return lastCommitBranch }
        return branchNames.first ?? ""
    }

    @ObservationIgnored private var lastCommitBranch: String?

    // MARK: - Suggestions

    func suggestions() async -> Suggestions? {
        guard let toolchain = await toolchain() else { return nil }
        return Suggestions(root: rootURL, toolchain: toolchain)
    }

    /// The changes `targets` commit, as a unified diff for `{{diff}}`: whole files, or only their selected hunks.
    func patch(for targets: [ChangeTarget]) async throws -> String {
        guard let repository else { return "" }
        var order: [ChangedFile] = []
        var wholeFiles = Set<ChangedFile.ID>()
        var selectedHunks: [ChangedFile.ID: [Hunk]] = [:]
        for target in targets {
            if !order.contains(where: { $0.id == target.file.id }) { order.append(target.file) }
            if let hunk = target.hunk {
                selectedHunks[target.file.id, default: []].append(hunk)
            } else {
                wholeFiles.insert(target.file.id)
            }
        }
        var patches: [String] = []
        for file in order {
            guard var diff = try await repository.diff(for: file) else { continue }
            if !wholeFiles.contains(file.id), let hunks = selectedHunks[file.id] { diff.hunks = hunks }
            patches.append(diff.patch)
        }
        return patches.joined(separator: "\n")
    }

    /// The commits already on `branch`, for `{{commits}}`; empty for a new branch.
    func commitLog(ofBranch branch: String) async -> String {
        guard let repository, let groups = try? await repository.history(),
              let found = groups.lazy.flatMap(\.branches).first(where: { $0.name == branch })
        else { return "" }
        return Suggestions.commitLog(found.commits)
    }

    // MARK: - Selection and diff

    /// Selects the changed file at `path` (relative to the root) and scrolls its diff to `line` of the new
    /// file. Refreshes first, since the change may be newer than the list.
    func reveal(path: String, line: Int?) {
        pendingReveal = (path, line)
        // Already listed: show it at once; the refresh only confirms it.
        resolvePendingReveal(isFinal: false)
        refresh()
    }

    private func resolvePendingReveal(isFinal: Bool) {
        guard let (path, line) = pendingReveal else { return }
        let files = groups.allFiles.filter { $0.path == path }
        // Plain git lists a file both staged and unstaged; the worktree side is the one with the latest line numbers.
        guard let file = files.first(where: { $0.source != .staged }) ?? files.first else {
            if isFinal {
                pendingReveal = nil
                onRevealFailure?("\(path) has no uncommitted changes in \(project.displayName).")
            }
            return
        }
        pendingReveal = nil
        selectedFileID = file.id
        fileReveal = FileReveal(fileID: file.id, line: line)
    }

    /// One side of a changed file, e.g. for image previews; `nil` when it does not exist or cannot be read.
    func contents(of file: ChangedFile, side: Repository.FileSide) async -> Data? {
        guard let repository else { return nil }
        return try? await repository.contents(of: file, side: side)
    }

    /// One side of the changed file at `path`, independent of the selection, e.g. for a diff window.
    func contents(ofPath path: String, side: Repository.FileSide) async -> Data? {
        guard let file = groups.lazy.flatMap(\.files).first(where: { $0.path == path }) else { return nil }
        return await contents(of: file, side: side)
    }

    /// The current diff of the changed file at `path`, with syntax colors, independent of the selection,
    /// e.g. for a diff window. `nil` when the file no longer has changes or the repository is not open yet.
    func diffState(forPath path: String) async -> DiffState? {
        guard let repository, let file = groups.lazy.flatMap(\.files).first(where: { $0.path == path }) else { return nil }
        var state: DiffState
        do {
            state = DiffState(fileID: file.id, content: try await repository.diff(for: file).map(DiffState.Content.diff) ?? .noDifference)
        } catch is CancellationError {
            return nil
        } catch {
            return DiffState(fileID: file.id, content: .failed(String(describing: error)))
        }
        if case .diff(let fileDiff) = state.content, !fileDiff.isBinary, let language = SyntaxLanguage(path: fileDiff.path) {
            state.highlights = await DiffHighlighting.highlights(for: fileDiff, language: language) { side in
                try? await repository.contents(of: file, side: side, limit: SyntaxHighlighter.maximumLength)
            }
        }
        return state
    }

    /// Replaces the groups, keeping the selection on the same file where possible.
    private func apply(_ newGroups: [ChangeGroup]) {
        let previous = groups
        if newGroups != previous { groups = newGroups }
        if !extraSelectedFileIDs.isEmpty {
            extraSelectedFileIDs.formIntersection(newGroups.allFiles.map(\.id))
        }
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
