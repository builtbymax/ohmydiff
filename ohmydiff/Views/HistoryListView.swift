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
            .navigationTitle(session.project.displayName)
            .navigationSubtitle(history.isRefreshing ? "History · Refreshing…" : "History")
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
            List(selection: $history.selection) {
                ForEach(history.groups) { group in
                    Section(group.kind == .stack ? "Stack" : "Branches") {
                        ForEach(group.branches) { branch in
                            BranchRow(branch: branch)
                                .tag(HistoryModel.Selection.branch(branch.name))
                            if showsCommits(of: branch, in: group) {
                                ForEach(branch.commits) { commit in
                                    CommitRow(commit: commit)
                                        .tag(HistoryModel.Selection.commit(sha: commit.sha, branch: branch.name))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// GitButler stacks are short, so all their commits are listed; plain-git branches list theirs
    /// only while selected.
    private func showsCommits(of branch: HistoryBranch, in group: HistoryGroup) -> Bool {
        group.kind == .stack || history.selection?.branchName == branch.name
    }
}

private struct BranchRow: View {
    let branch: HistoryBranch

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .help(branch.isCurrent ? "Checked out" : "")
            Text(branch.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let label = BranchStatusLabel(branch: branch) { label }
            Text("\(branch.commits.count)")
                .font(.caption.monospacedDigit())
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
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.summary.isEmpty ? "(no message)" : commit.summary)
                    .lineLimit(1)
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
        .padding(.leading, 12)
        .help(commit.message)
    }
}
