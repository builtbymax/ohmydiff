import Foundation
import Observation
import OhMyDiffCore

/// The History page: every commit of the project's branches in date order, drawn as a graph, and the
/// selected commit's files.
@Observable
final class CommitLogModel {
    enum Phase: Equatable {
        case idle
        case ready
        case failed(String)
    }

    /// All branches, or one branch's history.
    enum Filter: Hashable {
        case all
        case branch(String)
    }

    enum Files: Equatable {
        case loading
        case loaded([FileDiff])
        case failed(String)
    }

    /// Undoing a commit, after the user confirmed it.
    enum UndoAction: Equatable {
        case revert
        case uncommit
    }

    private(set) var phase = Phase.idle
    private(set) var commits: [LogCommit] = []
    /// One per commit, in the same order: where it sits in the graph.
    private(set) var graph: [GraphRow] = []
    var filter = Filter.all {
        didSet { if filter != oldValue { reload() } }
    }
    var search = ""
    var showsMerges = true
    var onlyMine = false
    var selectedID: LogCommit.ID? {
        didSet { if selectedID != oldValue { loadFiles() } }
    }
    private(set) var files: Files?
    var selectedFileID: FileDiff.ID?
    /// The hunk of the selected file the inspector shows.
    var selectedHunk = 0
    private(set) var isPerforming = false
    var actionError: String?
    /// Who the user is, for Only my commits.
    private(set) var userEmail: String?
    /// The default branch, e.g. `main`, offered as a filter.
    private(set) var defaultBranch: String?
    /// The checked-out commit; plain git can only uncommit it.
    private(set) var headSHA: String?

    /// Set while the History page is shown, so other pages do not reload the log on every refresh.
    var isActive = false

    @ObservationIgnored private var repository: Repository?
    @ObservationIgnored private var filesTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var isGitButler: Bool { repository?.kind == .gitButler }

    var selectedCommit: LogCommit? {
        commits.first { $0.id == selectedID }
    }

    var selectedFile: FileDiff? {
        guard case .loaded(let diffs) = files else { return nil }
        return diffs.first { $0.id == selectedFileID } ?? diffs.first
    }

    /// The commits the list shows: filtered by the search, merges and author.
    var visible: [(commit: LogCommit, row: GraphRow)] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return zip(commits, graph).filter { commit, _ in
            if !showsMerges, commit.isMerge { return false }
            if onlyMine, let userEmail, commit.commit.authorEmail.lowercased() != userEmail.lowercased() { return false }
            guard !query.isEmpty else { return true }
            return commit.commit.message.lowercased().contains(query) || commit.commit.authorName.lowercased().contains(query)
                || commit.commit.sha.hasPrefix(query)
        }
        .map { ($0, $1) }
    }

    /// Whether the graph is drawn: lines only make sense over the whole, unfiltered log.
    var drawsGraph: Bool { search.trimmingCharacters(in: .whitespaces).isEmpty && showsMerges && !onlyMine }

    // MARK: Loading

    /// Selects a commit asked for from outside, e.g. by `ohmydiff commit`, once the log lists it.
    func reveal(_ sha: String) {
        pendingReveal = sha
        resolvePendingReveal()
    }

    @ObservationIgnored private var pendingReveal: String?

    private func resolvePendingReveal() {
        guard let sha = pendingReveal, let found = commits.first(where: { $0.id.hasPrefix(sha) || sha.hasPrefix($0.id) }) else { return }
        pendingReveal = nil
        selectedID = found.id
    }

    func refresh(_ repository: Repository) async {
        self.repository = repository
        if userEmail == nil {
            let email = try? await repository.toolchainGitConfig("user.email")
            userEmail = email
        }
        if defaultBranch == nil {
            defaultBranch = await repository.defaultBranchName()
        }
        await load()
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        guard let repository else { return }
        do {
            let revisions: [String] = switch filter {
            case .all: []
            case .branch(let name): [name]
            }
            let commits = try await repository.commitLog(revisions)
            guard !Task.isCancelled else { return }
            headSHA = await repository.headSHA()
            if commits != self.commits {
                self.commits = commits
                graph = CommitGraph.layout(commits)
            }
            phase = .ready
            resolvePendingReveal()
            if selectedID == nil || !commits.contains(where: { $0.id == selectedID }) {
                selectedID = commits.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func loadFiles() {
        filesTask?.cancel()
        selectedHunk = 0
        guard let repository, let sha = selectedID else {
            files = nil
            return
        }
        files = .loading
        filesTask = Task {
            do {
                let diffs = try await repository.diff(commit: sha)
                guard !Task.isCancelled else { return }
                files = .loaded(diffs)
                if !diffs.contains(where: { $0.id == selectedFileID }) { selectedFileID = diffs.first?.id }
            } catch is CancellationError {
                return
            } catch {
                files = .failed(String(describing: error))
            }
        }
    }

    /// One side of a file of the selected commit, for the diff window.
    func contents(of file: FileDiff, side: Repository.FileSide) async -> Data? {
        guard let repository, let commit = selectedCommit else { return nil }
        let source = self.source(of: file, side: side, commit: commit)
        guard let source else { return nil }
        return try? await repository.contents(at: source.revision, path: source.path)
    }

    func source(of file: FileDiff, side: Repository.FileSide, commit: LogCommit) -> RevisionFile? {
        switch side {
        case .old: file.oldPath.map { RevisionFile(revision: commit.parents.first ?? "\(commit.id)^", path: $0) }
        case .new: file.newPath.map { RevisionFile(revision: commit.id, path: $0) }
        }
    }

    // MARK: Undoing commits

    /// Revert: plain git only, `but` has no revert, and only for commits on the checked-out branch. Uncommit: GitButler commits that are not on the target
    /// yet, or the last commit of the checked-out branch in plain git, when not pushed.
    func canUndo(_ action: UndoAction, _ commit: LogCommit) -> Bool {
        guard repository != nil, !isPerforming else { return false }
        switch action {
        case .revert: return !isGitButler && !commit.isMerge && commit.isOnHead
        case .uncommit: return !commit.isPushed && (isGitButler || commit.id == headSHA)
        }
    }

    func perform(_ action: UndoAction, on commit: LogCommit) async {
        guard let repository, !isPerforming else { return }
        isPerforming = true
        defer { isPerforming = false }
        do {
            switch action {
            case .revert: try await repository.revert(commit.id)
            case .uncommit: try await repository.uncommit(commit.id)
            }
            await load()
        } catch {
            actionError = String(describing: error)
        }
    }
}

/// Where a commit sits in the graph: its lane, and the lanes that run through, end in or leave its row.
struct GraphRow: Hashable {
    var lane: Int
    /// Lanes drawn from the top of the row to its middle: the commit's own lane when a child continues into it,
    /// lanes that merge into it, and lanes passing through.
    var above: [Int]
    /// Lanes drawn from the middle to the bottom: towards the parents, and lanes passing through.
    var below: [Int]
    /// Lanes that end at this commit from above, other than its own.
    var merging: [Int]
    /// Lanes its second and later parents continue in.
    var forking: [Int]
}

enum CommitGraph {
    /// Assigns lanes like `git log --graph`: a commit takes the lane that expects it, its first parent
    /// continues there and further parents open lanes of their own.
    static func layout(_ commits: [LogCommit]) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            let expecting = lanes.indices.filter { lanes[$0] == commit.id }
            let lane: Int
            if let first = expecting.first {
                lane = first
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                lane = free
                lanes[lane] = commit.id
            } else {
                lane = lanes.count
                lanes.append(commit.id)
            }
            let above = lanes.indices.filter { lanes[$0] != nil && (lanes[$0] != commit.id || expecting.contains($0)) }
            let merging = expecting.filter { $0 != lane }
            for index in merging { lanes[index] = nil }
            lanes[lane] = commit.parents.first
            var forking: [Int] = []
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    forking.append(existing)
                } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = parent
                    forking.append(free)
                } else {
                    lanes.append(parent)
                    forking.append(lanes.count - 1)
                }
            }
            while lanes.last == .some(nil) { lanes.removeLast() }
            let below = lanes.indices.filter { lanes[$0] != nil }
            rows.append(GraphRow(lane: lane, above: above, below: below, merging: merging, forking: forking))
        }
        return rows
    }
}
