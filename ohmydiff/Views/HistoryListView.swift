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
    let history: HistoryModel

    var body: some View {
        Card {
            SelectableHistoryRow(selection: .branch(branch.name), history: history) {
                BranchRow(branch: branch)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .padding(-6)
        } content: {
            if showsCommits, !branch.commits.isEmpty {
                // Lazy, so a plain-git branch with hundreds of commits only builds the rows on screen.
                LazyVStack(spacing: 0) {
                    ForEach(branch.commits) { commit in
                        SelectableHistoryRow(selection: .commit(sha: commit.sha, branch: branch.name), history: history) {
                            CommitRow(commit: commit)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(4)
            }
        }
    }
}

/// A branch or commit row. It reads the selection itself, so selecting another row only updates the
/// rows whose state changes instead of every card.
private struct SelectableHistoryRow<Label: View>: View {
    let selection: HistoryModel.Selection
    let history: HistoryModel
    @ViewBuilder var label: Label

    var body: some View {
        Button { history.selection = selection } label: { label }
            .buttonStyle(.row(isSelected: history.selection == selection))
            .id(selection)
    }
}

private struct BranchRow: View {
    let branch: HistoryBranch

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(branch.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(branch.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let label = BranchStatusLabel(branch: branch) { label }
            Text("\(branch.commits.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .hoverCard { BranchHoverCard(branch: branch) }
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
        .hoverCard { CommitHoverCard(commit: commit) }
    }
}

/// A branch's push state, commit count, base and tip.
private struct BranchHoverCard: View {
    let branch: HistoryBranch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(branch.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if branch.isCurrent {
                    Text("Checked out")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: .capsule)
                }
                if let label = BranchStatusLabel(branch: branch) { label }
            }
            VStack(alignment: .leading, spacing: 4) {
                HoverCardField(label: "Commits", value: branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits")
                if let baseName = branch.baseName { HoverCardField(label: "Since", value: baseName) }
                if !branch.tip.isEmpty { HoverCardField(label: "Tip", value: String(branch.tip.prefix(10)), monospaced: true) }
                if let latest = branch.commits.first?.date {
                    HoverCardField(label: "Updated", value: latest.formatted(.relative(presentation: .named)))
                }
            }
        }
    }
}

/// A commit's full message, author and date.
struct CommitHoverCard: View {
    let commit: CommitInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(commit.summary.isEmpty ? "(no message)" : commit.summary)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !commit.body.isEmpty {
                    Text(commit.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(spacing: 8) {
                AuthorAvatar(name: commit.authorName, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.authorName.isEmpty ? "Unknown author" : commit.authorName)
                        .font(.caption.weight(.semibold))
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
                Spacer(minLength: 0)
                if commit.isConflicted {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
    }
}

/// A person's initials on a color derived from their name.
struct AuthorAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.nameColor(name).gradient, in: .circle)
    }

    private var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = words.count > 1 ? [words.first!.first!, words.last!.first!] : Array(name.prefix(2))
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

}
