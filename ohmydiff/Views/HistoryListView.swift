import OhMyDiffCore
import SwiftUI

/// The middle pane in History mode: GitButler stacks or local branches, with their commits.
struct HistoryListView: View {
    let session: ProjectSession
    @Bindable var history: HistoryModel

    init(session: ProjectSession) {
        self.session = session
        self.history = session.history
    }

    var body: some View {
        content
            .butCompatibilityBanner(session.butIncompatibility)
            // Runs on appear and after every refresh of the project, so live updates reach History too.
            .task(id: session.lastRefreshed) { await session.refreshHistory() }
    }

    @ViewBuilder
    private var content: some View {
        switch (session.phase, history.phase) {
        case (.missing, _):
            ContentUnavailableView("Folder Not Found", systemImage: "questionmark.folder", description: Text("\(session.project.path) was moved or deleted."))
        case (.failed(let message), _), (_, .failed(let message)):
            ContentUnavailableView {
                Label("Could Not Load History", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { session.refresh() }
            }
        case (.idle, _), (_, .idle):
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case (.ready, .ready) where history.groups.allSatisfy(\.branches.isEmpty):
            ContentUnavailableView(
                "No Branches", systemImage: "arrow.triangle.branch",
                description: Text(session.project.kind == .gitButler ? "No branches are applied to the workspace." : "The repository has no local branches."))
        case (.ready, .ready):
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(history.groups) { group in
                            Text(group.kind == .stack ? "Stack" : "Branches")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                                .padding(.top, 4)
                            ForEach(group.branches) { branch in
                                BranchCard(branch: branch, showsCommits: showsCommits(of: branch, in: group), history: history)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveSelection(1, proxy: proxy) }
                .onKeyPress(.upArrow) { moveSelection(-1, proxy: proxy) }
            }
        }
    }

    /// Every selectable row in list order: each branch, then its listed commits.
    private var selectableItems: [HistoryModel.Selection] {
        history.groups.flatMap { group in
            group.branches.flatMap { branch in
                [.branch(branch.name)] + (showsCommits(of: branch, in: group)
                    ? branch.commits.map { HistoryModel.Selection.commit(sha: $0.sha, branch: branch.name) } : [])
            }
        }
    }

    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = selectableItems
        guard !items.isEmpty else { return .ignored }
        let current = history.selection.flatMap(items.firstIndex(of:))
        let next = current.map { min(max($0 + offset, 0), items.count - 1) } ?? 0
        history.selection = items[next]
        proxy.scrollTo(items[next])
        return .handled
    }

    /// GitButler stacks are short, so all their commits are listed; plain-git branches list theirs
    /// only while selected.
    private func showsCommits(of branch: HistoryBranch, in group: HistoryGroup) -> Bool {
        group.kind == .stack || history.selection?.branchName == branch.name
    }
}

/// A branch as a card: the branch on top, its commits below.
private struct BranchCard: View {
    let branch: HistoryBranch
    let showsCommits: Bool
    @Bindable var history: HistoryModel

    var body: some View {
        let branchSelection = HistoryModel.Selection.branch(branch.name)
        Card {
            Button { history.selection = branchSelection } label: {
                BranchRow(branch: branch)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(history.selection == branchSelection ? Theme.selectedRow : .clear, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(-6)
            .id(branchSelection)
        } content: {
            if showsCommits, !branch.commits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(branch.commits) { commit in
                        let selection = HistoryModel.Selection.commit(sha: commit.sha, branch: branch.name)
                        Button { history.selection = selection } label: {
                            CommitRow(commit: commit)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(history.selection == selection ? Theme.selectedRow : .clear, in: .rect(cornerRadius: 8))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(selection)
                    }
                }
                .padding(4)
            }
        }
    }
}

private struct BranchRow: View {
    let branch: HistoryBranch

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(branch.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(branch.isCurrent ? "Checked out" : "")
            Text(branch.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let label = BranchStatusLabel(branch: branch) { label }
            Text("\(branch.commits.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("\(branch.commits.count) commits")
        }
    }
}

/// A small capsule describing a branch's push state; conflicts take precedence.
struct BranchStatusLabel: View {
    let text: String
    let color: Color

    init?(branch: HistoryBranch) {
        if branch.isConflicted {
            (text, color) = ("Conflicted", .red)
            return
        }
        switch branch.status {
        case .unpushed: (text, color) = ("Unpushed", .orange)
        case .unpushedCommits: (text, color) = ("Unpushed commits", .orange)
        case .requiresForce: (text, color) = ("Requires force", .red)
        case .integrated: (text, color) = ("Integrated", .purple)
        case .tracking(let ahead, let behind):
            text = [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil].compactMap(\.self).joined(separator: " ")
            color = .secondary
        case .upstreamGone: (text, color) = ("Upstream gone", .secondary)
        case .upToDate, nil: return nil
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: .capsule)
            .lineLimit(1)
    }
}

private struct CommitRow: View {
    let commit: CommitInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: commit.isConflicted ? "exclamationmark.triangle.fill" : "circle.fill")
                .font(.system(size: commit.isConflicted ? 10 : 5))
                .foregroundStyle(commit.isConflicted ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.summary.isEmpty ? "(no message)" : commit.summary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(commit.shortSHA).monospaced()
                    if let date = commit.date {
                        Text("·")
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .help(commit.message)
    }
}
