import Foundation
import Observation
import OhMyDiffCore

/// History mode state of one project: its branches, the selected branch or commit, and that selection's files.
@Observable
final class HistoryModel {
    enum Phase: Equatable {
        case idle
        case ready
        case failed(String)
    }

    enum Selection: Hashable {
        /// A whole branch, diffed from its base to its tip.
        case branch(String)
        /// One commit, listed under `branch`; the same commit can appear under several plain-git branches.
        case commit(sha: String, branch: String)

        var branchName: String {
            switch self {
            case .branch(let name), .commit(_, let name): name
            }
        }
    }

    enum Files: Equatable {
        case loading
        case loaded([FileDiff])
        /// The selected branch has no commits of its own, or no base to compare against.
        case unavailable(String)
        case failed(String)
    }

    private(set) var groups: [HistoryGroup] = []
    private(set) var phase: Phase = .idle
    private(set) var isRefreshing = false
    private(set) var files: Files?
    /// The web page of the repository's remote, for Open on GitHub.
    private(set) var remoteURL: URL?
    /// Syntax colors per file of the current selection, filled in as files are shown.
    private(set) var highlights: [FileDiff.ID: SyntaxHighlights] = [:]
    /// Each looked-up branch's newest pull request; a `nil` value means it has none.
    private(set) var pullRequests: [String: PullRequest?] = [:]
    /// Checks, conflicts and reviews of open pull requests, by number, once looked up.
    private(set) var pullRequestStatuses: [Int: PullRequestStatus] = [:]
    /// What runs on a branch right now, e.g. `Pushing…`; one at a time.
    private(set) var branchActivity: String?
    var branchActionError: String?
    /// The branch whose pull request sheet is open; it opens once the branch's diff has loaded.
    var pullRequestDraftBranch: String?
    /// A plain-git branch waiting for the force push to be confirmed.
    var forcePushBranch: HistoryBranch?
    /// A merge waiting for confirmation.
    var pendingMerge: (pullRequest: PullRequest, method: MergeMethod, branch: String)?
    /// Plain-git branches waiting for their deletion to be confirmed.
    var pendingDeletion: [HistoryBranch]?
    @ObservationIgnored private var pullRequestsLoaded: Date?

    var selection: Selection? {
        didSet {
            guard oldValue != selection else { return }
            loadFiles()
        }
    }

    var selectedFileID: FileDiff.ID? {
        didSet {
            guard oldValue != selectedFileID else { return }
            loadHighlights()
        }
    }

    /// A branch or commit asked for by `ohmydiff` or an agent.
    enum RevealTarget: Equatable {
        case branch(String)
        /// A full or abbreviated SHA.
        case commit(String)
    }

    /// Called when a revealed branch or commit is not listed.
    @ObservationIgnored var onRevealFailure: ((String) -> Void)?
    @ObservationIgnored private var pendingReveal: RevealTarget?
    @ObservationIgnored private var repository: Repository?
    /// The repository `remoteURL` was looked up for.
    @ObservationIgnored private var remoteRoot: URL?
    /// The revisions the current `files` were loaded for, to skip reloads when nothing moved.
    @ObservationIgnored private var loadedRevisions: Revisions?
    @ObservationIgnored private var filesTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    var isGitButler: Bool { repository?.kind == .gitButler }
    /// Whether `gh` is installed, which reading and changing pull requests needs.
    var canManagePullRequests: Bool { repository?.canManagePullRequests ?? false }

    var selectedBranch: HistoryBranch? {
        guard let name = selection?.branchName else { return nil }
        return groups.lazy.flatMap(\.branches).first { $0.name == name }
    }

    var selectedCommit: CommitInfo? {
        guard case .commit(let sha, _) = selection else { return nil }
        return selectedBranch?.commits.first { $0.sha == sha }
    }

    var selectedFile: FileDiff? {
        guard case .loaded(let diffs) = files else { return nil }
        return diffs.first { $0.id == selectedFileID }
    }

    // MARK: Loading

    func refresh(_ repository: Repository) async {
        if remoteRoot != repository.root {
            remoteRoot = repository.root
            remoteURL = await repository.remoteWebURL()
        }
        self.repository = repository
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let groups = try await repository.history()
            if groups != self.groups { self.groups = groups }
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(String(describing: error))
            return
        }

        resolvePendingReveal(isFinal: true)
        if pullRequestsLoaded.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
            Task { await loadPullRequests() }
        }
        if let selection, let branch = selectedBranch, selection.isValid(in: branch) {
            // Same selection; reload its files only if the branch moved.
            if revisions(for: selection) != loadedRevisions { loadFiles(isReload: true) }
        } else {
            selection = groups.lazy.flatMap(\.branches).first.map { .branch($0.name) }
        }
    }

    // MARK: Pushing and pull requests

    /// Looks up the pull requests of every listed branch at once.
    func loadPullRequests() async {
        guard let repository, repository.canManagePullRequests else { return }
        pullRequestsLoaded = .now
        // A failed lookup (offline, `gh` not signed in) shows no pull requests rather than an error.
        guard let found = try? await repository.pullRequests() else { return }
        var lookup: [String: PullRequest?] = [:]
        for branch in groups.flatMap(\.branches) { lookup[branch.name] = .some(found[branch.name]) }
        if lookup != pullRequests { pullRequests = lookup }
    }

    /// Looks up an open pull request's checks, conflicts and reviews; failures keep the last known status.
    func loadStatus(of pullRequest: PullRequest) async {
        guard let repository, pullRequest.state == .open,
              let status = try? await repository.status(of: pullRequest), status != pullRequestStatuses[pullRequest.number]
        else { return }
        pullRequestStatuses[pullRequest.number] = status
    }

    /// The branch's pull request, unless it was closed without merging.
    func pullRequest(of branch: HistoryBranch) -> PullRequest? {
        guard case .some(.some(let pullRequest)) = pullRequests[branch.name], pullRequest.state != .closed else { return nil }
        return pullRequest
    }

    /// Branches with commits the remote does not have yet.
    func canPush(_ branch: HistoryBranch) -> Bool {
        guard !branch.commits.isEmpty else { return false }
        switch branch.status {
        case .unpushed, .unpushedCommits, .requiresForce: return true
        case .tracking(let ahead, let behind): return ahead > 0 && behind == 0
        case nil: return !isGitButler && !branch.isDefault
        case .upToDate, .integrated, .upstreamGone: return false
        }
    }

    /// Branches with their own commits that are not the main line, merged, deleted upstream, or already in a pull request.
    func canOpenPullRequest(_ branch: HistoryBranch) -> Bool {
        !branch.isDefault && !branch.commits.isEmpty && branch.status != .integrated && branch.status != .upstreamGone
            && pullRequest(of: branch) == nil
    }

    /// Plain git: branches whose upstream was deleted, typically after their pull request was merged.
    var goneBranches: [HistoryBranch] {
        guard !isGitButler else { return [] }
        return groups.flatMap(\.branches).filter(canDelete)
    }

    /// Plain git: a branch whose upstream was deleted, unless it is checked out.
    func canDelete(_ branch: HistoryBranch) -> Bool {
        !isGitButler && branch.status == .upstreamGone && !branch.isCurrent
    }

    func deleteBranches(_ branches: [HistoryBranch]) async {
        await perform(branches.count == 1 ? "Deleting…" : "Deleting \(branches.count) branches…", branch: nil) { repository in
            try await repository.deleteBranches(branches.map(\.name))
        }
    }

    /// Pushes, asking first when a plain-git branch needs a force push.
    func requestPush(_ branch: HistoryBranch) {
        if branch.status == .requiresForce, !isGitButler {
            forcePushBranch = branch
        } else {
            Task { await push(branch) }
        }
    }

    /// Selects the branch, so its whole diff loads, and opens its pull request sheet.
    func requestPullRequestDraft(_ branch: HistoryBranch) {
        selection = .branch(branch.name)
        pullRequestDraftBranch = branch.name
    }

    /// Looks up the branch's pull request, unless it was already looked up and `force` is not set.
    func loadPullRequest(for branch: String, force: Bool = false) async {
        guard let repository, force || pullRequests[branch] == nil else { return }
        // A failed lookup (offline, `gh` not signed in) shows no pull request rather than an error.
        let found = (try? await repository.pullRequest(forBranch: branch)) ?? nil
        pullRequests[branch] = .some(found)
    }

    func push(_ branch: HistoryBranch) async {
        await perform("Pushing…", branch: branch.name) { repository in
            try await repository.push(branch: branch.name, force: branch.status == .requiresForce)
        }
    }

    /// Pushes the branch and opens its pull request; throws so the sheet can show the error.
    func createPullRequest(branch: String, text: String, isDraft: Bool) async throws {
        guard let repository, branchActivity == nil else { return }
        branchActivity = "Creating pull request…"
        defer { branchActivity = nil }
        let created = try await repository.createPullRequest(branch: branch, text: text, isDraft: isDraft)
        pullRequests[branch] = .some(created)
        await refresh(repository)
    }

    func setDraft(_ isDraft: Bool, pullRequest: PullRequest, branch: String) async {
        await perform(isDraft ? "Converting to draft…" : "Marking ready…", branch: branch) { repository in
            try await repository.setDraft(isDraft, pullRequest: pullRequest)
        }
    }

    func merge(_ pullRequest: PullRequest, method: MergeMethod, branch: String) async {
        await perform("Merging…", branch: branch) { repository in
            try await repository.merge(pullRequest, method: method)
        }
    }

    /// Runs a branch action, then reloads the branches and the branch's pull request.
    private func perform(_ activity: String, branch: String?, _ action: (Repository) async throws -> Void) async {
        guard let repository, branchActivity == nil else { return }
        branchActivity = activity
        defer { branchActivity = nil }
        do {
            try await action(repository)
        } catch {
            branchActionError = String(describing: error)
        }
        await refresh(repository)
        if let branch { await loadPullRequest(for: branch, force: true) }
    }

    /// Selects a branch or commit, now when it is listed, else after the next refresh.
    func reveal(_ target: RevealTarget) {
        pendingReveal = target
        resolvePendingReveal(isFinal: false)
    }

    private func resolvePendingReveal(isFinal: Bool) {
        guard let target = pendingReveal else { return }
        let branches = groups.flatMap(\.branches)
        let found: Selection?
        switch target {
        case .branch(let name):
            found = branches.contains { $0.name == name } ? .branch(name) : nil
        case .commit(let sha):
            let prefix = sha.lowercased()
            // The checked-out branch first, since plain git lists a commit under every branch containing it.
            let ordered = branches.filter(\.isCurrent) + branches.filter { !$0.isCurrent }
            found = prefix.count < 4 ? nil : ordered.lazy.compactMap { branch in
                branch.commits.first { $0.sha.hasPrefix(prefix) }.map { Selection.commit(sha: $0.sha, branch: branch.name) }
            }.first
        }
        guard let found else {
            if isFinal, phase == .ready {
                pendingReveal = nil
                let message = switch target {
                case .branch(let name): "No branch named \(name) is listed in History."
                case .commit(let sha): "Commit \(sha.prefix(12)) is not on a branch listed in History."
                }
                onRevealFailure?(message)
            }
            return
        }
        pendingReveal = nil
        selection = found
    }

    func close() {
        filesTask?.cancel()
        highlightTask?.cancel()
    }

    struct Revisions: Equatable {
        /// `nil` for a commit, whose diff comes from `git diff-tree`.
        var base: String?
        var tip: String
    }

    private func revisions(for selection: Selection) -> Revisions? {
        switch selection {
        case .branch:
            guard let branch = selectedBranch, let base = branch.base else { return nil }
            return Revisions(base: base, tip: branch.tip)
        case .commit(let sha, _):
            return Revisions(base: nil, tip: sha)
        }
    }

    /// A reload keeps the current files visible until the new ones arrive, so live refreshes do not flash.
    private func loadFiles(isReload: Bool = false) {
        filesTask?.cancel()
        highlightTask?.cancel()
        guard let selection, let repository else {
            files = nil
            loadedRevisions = nil
            return
        }
        guard let revisions = revisions(for: selection) else {
            let message = selectedBranch?.commits.isEmpty == true ? "This branch has no commits yet." : "There is no base branch to compare against."
            files = .unavailable(message)
            loadedRevisions = nil
            return
        }
        if !isReload || files == nil {
            files = .loading
            highlights = [:]
        }

        filesTask = Task {
            let result: Files
            do {
                let diffs = if let base = revisions.base {
                    try await repository.diff(from: base, to: revisions.tip)
                } else {
                    try await repository.diff(commit: revisions.tip)
                }
                result = .loaded(diffs)
            } catch is CancellationError {
                return
            } catch {
                result = .failed(String(describing: error))
            }
            guard !Task.isCancelled, self.selection == selection else { return }
            loadedRevisions = revisions
            if result != files {
                highlights = [:]
                files = result
            }
            // Keep the same file selected when it is still part of the diff.
            if case .loaded(let diffs) = result {
                let kept = diffs.first { $0.id == selectedFileID } ?? diffs.first { $0.path == selectedFile?.path }
                selectedFileID = (kept ?? diffs.first)?.id
                loadHighlights()
            }
        }
    }

    private func loadHighlights() {
        highlightTask?.cancel()
        guard let repository, let file = selectedFile, highlights[file.id] == nil, !file.isBinary,
              let language = SyntaxLanguage(path: file.path), let revisions = loadedRevisions
        else { return }
        let old = revisions.base ?? "\(revisions.tip)^"
        let new = revisions.tip

        highlightTask = Task {
            let result = await DiffHighlighting.highlights(for: file, language: language) { side in
                let (revision, path) = side == .old ? (old, file.oldPath) : (new, file.newPath)
                guard let path else { return nil }
                return try? await repository.contents(at: revision, path: path, limit: SyntaxHighlighter.maximumLength)
            }
            guard !Task.isCancelled, loadedRevisions == revisions else { return }
            highlights[file.id] = result
        }
    }

    /// One side of a file of the current selection, for image previews and the whole-file view.
    func contents(of file: FileDiff, side: Repository.FileSide) async -> Data? {
        guard let repository, let source = source(of: file, side: side) else { return nil }
        return try? await repository.contents(at: source.revision, path: source.path)
    }

    /// What a prompt to Claude Code says about the current selection: the commit, or the branch and its base.
    func promptContext(root: URL) -> PromptContext? {
        let source: PromptContext.Source
        if let commit = selectedCommit {
            source = .commit(sha: commit.sha, message: commit.message)
        } else if let branch = selectedBranch {
            source = .branch(name: branch.name, base: branch.baseName ?? branch.base)
        } else {
            return nil
        }
        return PromptContext(repositoryPath: root.path, isGitButler: repository?.kind == .gitButler, source: source)
    }

    /// Where one side of a file of the current selection is stored; `nil` when the file does not exist there.
    func source(of file: FileDiff, side: Repository.FileSide) -> RevisionFile? {
        guard let revisions = loadedRevisions, let path = side == .old ? file.oldPath : file.newPath else { return nil }
        return RevisionFile(revision: side == .old ? revisions.base ?? "\(revisions.tip)^" : revisions.tip, path: path)
    }
}

/// A file at a revision, e.g. `HEAD^:src/main.swift`.
struct RevisionFile: Hashable {
    var revision: String
    var path: String
}

private extension HistoryModel.Selection {
    func isValid(in branch: HistoryBranch) -> Bool {
        switch self {
        case .branch: true
        case .commit(let sha, _): branch.commits.contains { $0.sha == sha }
        }
    }
}
