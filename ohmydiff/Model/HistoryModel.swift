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

    @ObservationIgnored private var repository: Repository?
    /// The repository `remoteURL` was looked up for.
    @ObservationIgnored private var remoteRoot: URL?
    /// The revisions the current `files` were loaded for, to skip reloads when nothing moved.
    @ObservationIgnored private var loadedRevisions: Revisions?
    @ObservationIgnored private var filesTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

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

        if let selection, let branch = selectedBranch, selection.isValid(in: branch) {
            // Same selection; reload its files only if the branch moved.
            if revisions(for: selection) != loadedRevisions { loadFiles(isReload: true) }
        } else {
            selection = groups.lazy.flatMap(\.branches).first.map { .branch($0.name) }
        }
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
