import Foundation
import Observation
import SwiftUI
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
        /// Whitespace-only changes are left out, so the hunks are for reading and cannot be staged or discarded.
        var ignoresWhitespace = false
    }

    /// Whether the View menu hides whitespace-only changes.
    static var ignoresWhitespace: Bool {
        !(UserDefaults.standard.object(forKey: AppSettings.showsWhitespaceChangesKey) as? Bool ?? true)
    }

    /// Loads the selected file's diff again, e.g. after a View option changed how it is read.
    func reloadDiff() {
        diff = nil
        loadDiff()
    }

    private(set) var project: Project
    private(set) var phase: Phase = .idle
    private(set) var groups: [ChangeGroup] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?
    private(set) var diff: DiffState?
    /// Why a GitButler workspace is shown as plain git; `nil` when it is not one or `but` is supported.
    private(set) var butIncompatibility: ButIncompatibility?
    /// Set when a GitButler workspace runs on a `but` release ohmydiff was not tested against.
    private(set) var butVersionMismatch: ButVersionMismatch?
    /// A discard waiting for confirmation or a commit waiting for its message.
    var actionRequest: ActionRequest?
    private(set) var isPerformingAction = false
    var actionError: String?
    let history = HistoryModel()
    /// The History page's log of every branch.
    let log = CommitLogModel()
    /// The message in the commit composer.
    let commitDraft = CommitDraft()
    /// The Pull requests page.
    let pullRequests = PullRequestsModel()
    /// Hunk sizes of listed files, in changed lines, for the file list's hunk bars; filled as diffs load.
    private(set) var hunkSizes: [ChangedFile.ID: [Int]] = [:]

    /// What the last fetch found on the remote; `nil` before the first fetch or without a tracked upstream.
    private(set) var upstream: UpstreamStatus?
    private(set) var lastFetched: Date?
    /// The Dashboard page's summary of the main line, once the page loaded it.
    private(set) var dashboard: Dashboard?
    private(set) var dashboardError: String?
    private(set) var isFetching = false
    private(set) var fetchError: String?
    private(set) var isUpdatingFromUpstream = false
    /// Plain git: the checked-out branch, which commits go to; `nil` on a detached HEAD or for GitButler.
    private(set) var currentBranch: String?
    @ObservationIgnored private var fetchLoop: Task<Void, Never>?
    /// What `refreshHistory` last loaded for.
    @ObservationIgnored private var historyFingerprint: String?
    @ObservationIgnored private var historyRefreshed: Date?

    var selectedFileID: ChangedFile.ID? {
        didSet {
            guard oldValue != selectedFileID else { return }
            // Moving the selection any other way than `select(_:extending:)` drops the files picked along.
            extraSelectedFileIDs = []
            if let selectedFileID, !openTabs.contains(selectedFileID) {
                openTabs.append(selectedFileID)
                if openTabs.count > Self.tabLimit { openTabs.removeFirst(openTabs.count - Self.tabLimit) }
            }
            loadDiff()
        }
    }

    /// Files opened lately, as editor-style tabs in the top bar, oldest first.
    private(set) var openTabs: [ChangedFile.ID] = []
    static let tabLimit = 8

    /// The open tabs whose files are still changed.
    var tabFiles: [ChangedFile] {
        let files = Dictionary(groups.flatMap(\.files).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return openTabs.compactMap { files[$0] }
    }

    /// Closes a tab; closing the selected one selects its neighbour.
    func closeTab(_ id: ChangedFile.ID) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: index)
        guard id == selectedFileID else { return }
        let remaining = tabFiles
        if let next = remaining.indices.contains(index) ? remaining[index] : remaining.last {
            selectedFileID = next.id
        }
    }

    /// The selected file's tab, when it has one: what ⌘W closes.
    var selectedTab: ChangedFile.ID? {
        selectedFileID.flatMap { id in tabFiles.contains { $0.id == id } ? id : nil }
    }

    /// Selects the tab `offset` places along, wrapping around, for ⌃Tab and ⌃⇧Tab.
    func selectAdjacentTab(_ offset: Int) {
        let ids = tabFiles.map(\.id)
        guard ids.count > 1 else { return }
        let index = selectedFileID.flatMap(ids.firstIndex(of:)) ?? (offset > 0 ? -1 : 0)
        selectedFileID = ids[(index + offset + ids.count) % ids.count]
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
    /// `<common-dir>/gitbutler` and whether it existed when `repository` was opened. `but setup` and `but teardown`
    /// create and remove it, so a change means the kind must be detected again.
    @ObservationIgnored private var gitButlerMarker: (url: URL, existed: Bool)?
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

    /// Selects the first file of a group, e.g. a branch picked in the sidebar.
    func select(group id: ChangeGroup.ID) {
        guard let file = groups.first(where: { $0.id == id })?.files.first else { return }
        select(file.id)
        fileReveal = FileReveal(fileID: file.id, line: nil)
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
        startFetchLoop()
    }

    /// Stops live updates; the cached state is kept.
    func deactivate() {
        isActive = false
        stopWatching()
        stopFetchLoop()
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

    /// Reloads History mode's branches; a no-op until the first refresh opened the repository. Unless forced, only
    /// when refs moved since the last time, or a minute went by for what refs don't show, e.g. pull requests.
    func refreshHistory(force: Bool = false) async {
        guard let repository else { return }
        let fingerprint = await repository.refsFingerprint()
        let isStale = historyRefreshed.map { Date.now.timeIntervalSince($0) > 60 } ?? true
        guard force || isStale || fingerprint == nil || fingerprint != historyFingerprint else { return }
        historyFingerprint = fingerprint
        historyRefreshed = .now
        await history.refresh(repository)
        if log.isActive { await log.refresh(repository) }
    }

    /// Loads the History page's log, e.g. when the page opens.
    /// Loads the Pull requests page's inbox; at most once a minute unless forced.
    func refreshPullRequests(force: Bool = false) async {
        guard let repository = await openedRepository() else { return }
        await pullRequests.refresh(repository, force: force)
    }

    func refreshDashboard() async {
        guard let repository = await openedRepository() else { return }
        do {
            dashboard = try await repository.dashboard()
            dashboardError = nil
        } catch {
            dashboardError = String(describing: error)
        }
    }

    func refreshLog() async {
        guard let repository = await openedRepository() else { return }
        await log.refresh(repository)
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

        if let marker = gitButlerMarker, Self.isDirectory(marker.url) != marker.existed {
            // The watcher hands batches to the repository it started with, so it restarts with the new one.
            repository = nil
            stopWatching()
        }
        do {
            let repository = try await openRepository(toolchain)
            apply(try await repository.changeGroups())
            let branch = repository.kind == .git ? try await repository.currentBranch() : nil
            if branch != currentBranch { currentBranch = branch }
            phase = .ready
            lastRefreshed = .now
            resolvePendingReveal(isFinal: true)
            if isActive, watcher == nil, AppSettings.isOn(AppSettings.watchesFilesKey) { await startWatching(repository) }
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
        let marker = try? await repository.gitDirectories().commonDir.appending(path: "gitbutler")
        gitButlerMarker = marker.map { ($0, Self.isDirectory($0)) }
        if repository.butIncompatibility != butIncompatibility { butIncompatibility = repository.butIncompatibility }
        if repository.butVersionMismatch != butVersionMismatch { butVersionMismatch = repository.butVersionMismatch }
        if repository.kind != project.kind {
            project.kind = repository.kind
            onKindChange?(repository.kind)
        }
        return repository
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func markMissing() {
        stopWatching()
        repository = nil
        apply([])
        phase = .missing
    }

    // MARK: - Upstream

    /// How often the open project fetches in the background, from Settings; `nil` for never.
    static var fetchInterval: TimeInterval? {
        let minutes = AppSettings.fetchInterval()
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// Fetches now, then again whenever the last fetch is older than `fetchInterval`, while the project is open.
    private func startFetchLoop() {
        stopFetchLoop()
        fetchLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let interval = Self.fetchInterval, lastFetched.map({ Date.now.timeIntervalSince($0) >= interval }) ?? true {
                    await fetch()
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stopFetchLoop() {
        fetchLoop?.cancel()
        fetchLoop = nil
    }

    /// Fetches from the remote and works out what an update would bring in.
    func fetch() async {
        guard !isFetching, !isUpdatingFromUpstream, let repository = await openedRepository() else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            applyFetch(try await repository.fetchUpstream())
            // A fetch moves remote branches, which History shows.
            refresh()
        } catch is CancellationError {
            return
        } catch {
            fetchError = String(describing: error)
        }
    }

    /// Updates the workspace from the remote, then reads what is left to update.
    func updateFromUpstream() async throws -> UpstreamUpdateResult {
        guard !isUpdatingFromUpstream, let repository = await openedRepository() else { return UpstreamUpdateResult() }
        isUpdatingFromUpstream = true
        defer {
            isUpdatingFromUpstream = false
            refresh()
        }
        let result = try await repository.updateFromUpstream()
        if let status = try? await repository.fetchUpstream() { applyFetch(status) }
        return result
    }

    private func applyFetch(_ status: UpstreamStatus?) {
        if status != upstream { upstream = status }
        fetchError = nil
        lastFetched = .now
    }

    /// The repository, waiting for the refresh that opens it; `nil` when the project cannot be opened.
    private func openedRepository() async -> Repository? {
        while repository == nil, phase == .idle || isRefreshing {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return nil }
        }
        return repository
    }

    // MARK: - Actions

    /// An action the user started that needs one more step: a confirmation or a commit message.
    struct ActionRequest: Identifiable {
        let id = UUID()
        var action: ChangeAction
        var targets: [ChangeTarget]
        /// Opened from the composer: the card starts with its message and clears it once committed.
        var fromComposer = false

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
        case .discard where !Self.confirmsDiscard(of: targets):
            Task { await perform(action, on: targets) }
        case .commit, .discard:
            actionRequest = ActionRequest(action: action, targets: targets)
        }
    }

    /// Whether discarding these targets asks first, as set in Settings → General → Safety.
    static func confirmsDiscard(of targets: [ChangeTarget]) -> Bool {
        switch AppSettings.discardConfirmation() {
        case .filesAndHunks: true
        case .filesOnly: targets.contains { $0.hunk == nil }
        case .never: false
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
    func run(_ action: ChangeAction, on targets: [ChangeTarget], branch: String = "", stackedOn anchor: String? = nil, message: String = "") async throws {
        guard let repository, !isPerformingAction else { return }
        isPerformingAction = true
        defer {
            isPerformingAction = false
            refresh()
        }
        switch action {
        case .stage: try await repository.stage(targets)
        case .unstage: try await repository.unstage(targets)
        case .discard:
            try await repository.discard(targets)
            Toasts.shared.show(
                "Discarded \(toastSubject(targets))", systemImage: "arrow.uturn.backward", tint: Theme.delFg,
                action: repository.kind == .gitButler ? Toasts.undo { [weak self] in self?.undoLastOperation() } : nil)
        case .commit:
            try await repository.commit(targets, toBranch: branch, stackedOn: anchor, message: message)
            lastCommitBranch = branch
            let head = repository.kind == .git ? await repository.headSHA() : nil
            Toasts.shared.show(
                "Committed \(toastSubject(targets)) to \(branch)", systemImage: "circle.and.line.horizontal", tint: Theme.okFg,
                action: Toasts.undo { [weak self] in self?.undoCommit(head: head) })
        }
    }

    /// e.g. `hunk 2 of notes.txt`, `notes.txt` or `3 files`, for toasts.
    func toastSubject(_ targets: [ChangeTarget]) -> String {
        guard targets.count == 1, let target = targets.first else { return "\(targets.count) files" }
        let name = (target.file.path as NSString).lastPathComponent
        guard let hunk = target.hunk else { return name }
        if case .diff(let diff)? = diff?.content, diff.path == target.file.path, let index = diff.hunks.firstIndex(of: hunk) {
            return "hunk \(index + 1) of \(name)"
        }
        return "a hunk of \(name)"
    }

    /// Takes the last commit back: `but undo` in GitButler, a soft reset of `head` in plain git.
    private func undoCommit(head: String?) {
        guard let repository else { return }
        if repository.kind == .gitButler { return undoLastOperation() }
        guard let head else { return }
        Task {
            do { try await repository.uncommit(head) } catch { actionError = String(describing: error) }
            refresh()
        }
    }

    /// `but undo`: reverts GitButler's last operation.
    func undoLastOperation() {
        guard let repository else { return }
        Task {
            do { try await repository.undoLastOperation() } catch { actionError = String(describing: error) }
            refresh()
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
    /// The branches a commit can go to: every applied GitButler branch, or the checked-out plain-git branch.
    var commitBranches: [String] {
        project.kind == .gitButler ? branchNames : currentBranch.map { [$0] } ?? []
    }

    func suggestedBranch(for targets: [ChangeTarget]) -> String {
        if let assigned = targets.lazy.compactMap({ self.assignedBranch(of: $0.file.path) }).first { return assigned }
        if let lastCommitBranch, commitBranches.contains(lastCommitBranch) { return lastCommitBranch }
        return commitBranches.first ?? ""
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

    /// The latest commits that touched `path`, for the inspector; `nil` when they could not be read.
    func fileHistory(of path: String) async -> FileHistory? {
        guard let repository = await openedRepository() else { return nil }
        return try? await repository.fileHistory(of: path)
    }

    /// The commits that last changed `lines` of `path` at HEAD, for the inspector.
    func blame(_ path: String, lines: ClosedRange<Int>) async -> [BlameCommit] {
        guard let repository = await openedRepository() else { return [] }
        return (try? await repository.blame(path, lines: lines)) ?? []
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
        if newGroups != previous {
            groups = newGroups
            pruneDiffCache()
        }
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
        let ignoresWhitespace = Self.ignoresWhitespace
        let key = DiffCacheKey(fileID: file.id, ignoresWhitespace: ignoresWhitespace)
        // A file seen lately shows at once from the cache and is checked again below; others show loading.
        // The same file reloading keeps what it shows, so live refreshes do not flash.
        if diff?.fileID != file.id || diff?.ignoresWhitespace != ignoresWhitespace {
            diff = diffCache[key] ?? DiffState(fileID: file.id, content: .loading, ignoresWhitespace: ignoresWhitespace)
        }
        // Before the first refresh opens the repository; that refresh calls back here.
        guard let repository else { return }

        diffTask = Task {
            let state = await Self.loadState(of: file, repository: repository, ignoresWhitespace: ignoresWhitespace) { [weak self] plain in
                // Highlights are slow for this file: show the plain diff instead of loading, never over shown content.
                guard let self, self.selectedFileID == file.id, self.diff?.content == .loading else { return }
                self.diff = plain
            }
            guard let state, !Task.isCancelled, selectedFileID == file.id else { return }
            if case .diff(let fileDiff) = state.content, !ignoresWhitespace {
                let sizes = fileDiff.hunks.map(\.size)
                if hunkSizes[file.id] != sizes { hunkSizes[file.id] = sizes }
            }
            storeInCache(state, key: key)
            if state != diff { diff = state }
            prefetchNeighbors(of: file, repository: repository, ignoresWhitespace: ignoresWhitespace)
        }
    }

    // MARK: - Diff cache

    private struct DiffCacheKey: Hashable {
        var fileID: ChangedFile.ID
        var ignoresWhitespace: Bool
    }

    /// Diffs with their colors, most recent last; shown at once when a file is selected again.
    @ObservationIgnored private var diffCache: [DiffCacheKey: DiffState] = [:]
    @ObservationIgnored private var diffCacheOrder: [DiffCacheKey] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    private static let diffCacheLimit = 40

    private func storeInCache(_ state: DiffState, key: DiffCacheKey) {
        guard state.content != .loading else { return }
        diffCache[key] = state
        diffCacheOrder.removeAll { $0 == key }
        diffCacheOrder.append(key)
        while diffCacheOrder.count > Self.diffCacheLimit { diffCache[diffCacheOrder.removeFirst()] = nil }
    }

    /// Drops cached diffs of files no longer changed.
    private func pruneDiffCache() {
        let ids = Set(groups.lazy.flatMap(\.files).map(\.id))
        diffCacheOrder.removeAll { key in
            guard !ids.contains(key.fileID) else { return false }
            diffCache[key] = nil
            return true
        }
    }

    /// Loads the files above and below the selected one in the background, so moving through the list is instant.
    private func prefetchNeighbors(of file: ChangedFile, repository: Repository, ignoresWhitespace: Bool) {
        prefetchTask?.cancel()
        let files = groups.flatMap(\.files)
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        let neighbors = [index + 1, index - 1, index + 2].filter(files.indices.contains).map { files[$0] }
            .filter { diffCache[DiffCacheKey(fileID: $0.id, ignoresWhitespace: ignoresWhitespace)] == nil }
        guard !neighbors.isEmpty else { return }
        prefetchTask = Task(priority: .utility) { [weak self] in
            for neighbor in neighbors {
                guard !Task.isCancelled,
                      let state = await Self.loadState(of: neighbor, repository: repository, ignoresWhitespace: ignoresWhitespace, showPlain: { _ in }),
                      !Task.isCancelled
                else { return }
                self?.storeInCache(state, key: DiffCacheKey(fileID: neighbor.id, ignoresWhitespace: ignoresWhitespace))
            }
        }
    }

    /// A file's diff with its syntax colors. Colors that take longer than a moment arrive after `showPlain`
    /// got the diff without them, so text never waits on highlighting.
    private static func loadState(
        of file: ChangedFile, repository: Repository, ignoresWhitespace: Bool, showPlain: @escaping (DiffState) -> Void
    ) async -> DiffState? {
        let content: DiffState.Content
        do {
            content = try await repository.diff(for: file, ignoringWhitespace: ignoresWhitespace).map(DiffState.Content.diff) ?? .noDifference
        } catch is CancellationError {
            return nil
        } catch {
            content = .failed(String(describing: error))
        }
        var state = DiffState(fileID: file.id, content: content, ignoresWhitespace: ignoresWhitespace)
        guard case .diff(let fileDiff) = content, !fileDiff.isBinary, let language = SyntaxLanguage(path: fileDiff.path) else { return state }
        let highlighting = Task {
            await DiffHighlighting.highlights(for: fileDiff, language: language) { side in
                try? await repository.contents(of: file, side: side, limit: SyntaxHighlighter.maximumLength)
            }
        }
        // Wait a moment so text and colors usually appear together.
        let waited = Task {
            try? await Task.sleep(for: .milliseconds(90))
            return true
        }
        let isQuick = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await highlighting.value; return true }
            group.addTask { _ = await waited.value; return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !isQuick { showPlain(state) }
        state.highlights = await withTaskCancellationHandler { await highlighting.value } onCancel: { highlighting.cancel() }
        guard !Task.isCancelled else { return nil }
        return state
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
