import AppKit
import OhMyDiffCore
import SwiftUI

/// The Branches page: each stack as a card of its branches and their commits, and the selected branch's
/// pull request in the panel on the right.
struct BranchesPageView: View {
    let model: AppModel
    let session: ProjectSession
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true

    private var history: HistoryModel { session.history }

    var body: some View {
        let cards = history.branchCards(for: history.branchFilter)
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if cards.isEmpty {
                        emptyState
                    }
                    ForEach(cards, id: \.first?.name) { branches in
                        StackCard(
                            model: model, session: session, branches: branches,
                            isSelected: branches.contains { $0.name == history.selection?.branchName })
                    }
                    if history.isGitButler, !cards.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 11))
                                .frame(width: 13, height: 13)
                                .padding(.top, 2)
                            Text("GitButler applies several branches at once. Uncommitted changes stay in Changes until you commit them to a branch.")
                                .font(.caption11)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)
            if isInspectorShown {
                Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                Group {
                    if let branch = history.selectedBranch {
                        BranchPanel(model: model, session: session, branch: branch)
                            .id(branch.name)
                    } else {
                        EmptyState("No branch selected", systemImage: "arrow.triangle.branch")
                    }
                }
                .frame(width: 440)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .branchActionPresentation(history) { await session.suggestions() }
        .onChange(of: cards.map { $0.map(\.name) }, initial: true) { _, names in
            // Keep a listed branch selected, so the panel always has one to show.
            let all = names.flatMap(\.self)
            if let current = history.selection?.branchName, all.contains(current) { return }
            if let first = all.first { history.selection = .branch(first) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch history.branchFilter {
        case .applied:
            EmptyState(
                history.isGitButler ? "No applied branches" : "No branch checked out",
                systemImage: "arrow.triangle.branch",
                description: "Create one with New branch, or commit changes to a new branch.")
        case .all:
            EmptyState("No branches yet", systemImage: "arrow.triangle.branch")
        case .merged:
            EmptyState("Nothing merged yet", systemImage: "arrow.triangle.merge", description: "Branches whose pull request was merged show here.")
        }
    }
}

// MARK: - Top bar

/// Branches: the filter, refresh, New branch and the pull request panel.
struct BranchesTopBar: View {
    @Bindable var model: AppModel
    let session: ProjectSession
    @Bindable var history: HistoryModel
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true

    var body: some View {
        PageTitle(title: "Branches")
        Segmented(
            selection: $history.branchFilter,
            options: [(.applied, history.isGitButler ? "Applied" : "Current"), (.all, "All"), (.merged, "Merged")],
            systemImages: [.applied: "square.3.layers.3d", .all: "arrow.triangle.branch", .merged: "arrow.triangle.merge"],
            counts: counts)
        Spacer(minLength: 8)
        IconButton("Refresh", systemImage: "arrow.clockwise") {
            session.refresh()
            Task { await history.loadPullRequests() }
        }
        .padding(.trailing, 6)
        Button { model.isNewBranchPresented = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                Text("New branch")
                KeyCap("⌘B")
            }
        }
        .buttonStyle(.pill())
        .popover(isPresented: $model.isNewBranchPresented, arrowEdge: .bottom) {
            NewBranchPopover(history: history, isGitButler: history.isGitButler) { model.isNewBranchPresented = false }
        }
        .padding(.trailing, 6)
        IconButton(isInspectorShown ? "Hide Pull Request  ⌥⌘I" : "Show Pull Request  ⌥⌘I", systemImage: "sidebar.right", isSelected: isInspectorShown) {
            withAnimation(.snappy(duration: 0.2)) { isInspectorShown.toggle() }
        }
    }

    private var counts: [HistoryModel.BranchFilter: String] {
        let applied = history.branchCards(for: .applied).joined().count
        let all = history.branchCards(for: .all).joined().count
        return [.applied: "\(applied)", .all: "\(all)"]
    }
}

/// A name for a new, empty branch.
private struct NewBranchPopover: View {
    let history: HistoryModel
    let isGitButler: Bool
    let dismiss: () -> Void

    @State private var name = ""
    @State private var isCreating = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New branch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            TextField("feat/name", text: $name)
                .textFieldStyle(.plain)
                .font(.code(12.5))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.hover, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Theme.lineStrong : Theme.line))
                .focused($isFocused)
                .onSubmit(create)
            Text(isGitButler ? "GitButler applies it as an empty lane next to your other branches." : "Switches to it from the current commit and keeps your uncommitted changes.")
                .font(.detail)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(isGitButler ? "but branch new \(trimmed.isEmpty ? "…" : trimmed)" : "git switch -c \(trimmed.isEmpty ? "…" : trimmed)")
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Cancel", action: dismiss)
                    .buttonStyle(.pill(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button(action: create) {
                    HStack(spacing: 6) {
                        Text("Create")
                        KeyCap("↩", onInverse: true)
                    }
                }
                .buttonStyle(.pill(.prominent))
                .disabled(trimmed.isEmpty || isCreating)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { isFocused = true }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func create() {
        guard !trimmed.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            if await history.createBranch(trimmed) { dismiss() }
            isCreating = false
        }
    }
}

// MARK: - Stack cards

/// One stack: its branches from the bottom up, each with its own commits. Plain git branches get a card each.
private struct StackCard: View {
    let model: AppModel
    let session: ProjectSession
    let branches: [HistoryBranch]
    let isSelected: Bool

    @Environment(\.openWindow) private var openWindow
    private var history: HistoryModel { session.history }

    var body: some View {
        // GitButler lists a stack top first; the card reads like the stack is built, base first.
        let ordered = Array(branches.reversed())
        let isAllMerged = branches.allSatisfy(history.isMerged)
        VStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.name) { index, branch in
                BranchHead(
                    session: session, branch: branch, below: index > 0 ? ordered[index - 1].name : nil,
                    isSelected: history.selection?.branchName == branch.name)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
                    }
                if !history.isMerged(branch) {
                    ForEach(branch.commits, id: \.sha) { commit in
                        CommitLine(
                            commit: commit, isLocal: isLocal(commit, in: branch), indent: index > 0 ? 30 : 14,
                            open: { review(commit, of: branch) },
                            showInHistory: {
                                model.mode = .history
                                session.log.reveal(commit.sha)
                            })
                    }
                }
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Theme.lineStrong : Theme.line))
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface)
                .shadow(color: isSelected ? Theme.cardShadow : .clear, radius: 4, y: 2)
        }
        .opacity(isAllMerged ? 0.7 : 1)
    }

    /// Commits the remote does not have: all of a never pushed branch, else what the log knows is unpushed.
    private func isLocal(_ commit: CommitInfo, in branch: HistoryBranch) -> Bool {
        switch branch.status {
        case .unpushed: return true
        case .tracking(let ahead, _):
            return branch.commits.prefix(ahead).contains { $0.sha == commit.sha }
        case .upToDate, .integrated: return false
        default:
            return session.log.commits.first { $0.id == commit.sha }.map { !$0.isPushed } ?? false
        }
    }

    /// The commit's diff in a review window, so reviewing stays one click from the branch.
    private func review(_ commit: CommitInfo, of branch: HistoryBranch) {
        Task {
            do {
                let diffs = try await history.diff(ofCommit: commit.sha)
                guard let first = diffs.first else {
                    Toasts.shared.show("\(commit.shortSHA) changes no files", systemImage: "circle.and.line.horizontal")
                    return
                }
                let snapshot = DiffSnapshot(
                    project: session.project.displayName, context: "\(commit.shortSHA) · \(commit.summary)", root: session.rootURL,
                    files: diffs.map { diff in
                        DiffSnapshot.File(diff: diff, sources: (
                            diff.oldPath.map { RevisionFile(revision: "\(commit.sha)^", path: $0) },
                            diff.newPath.map { RevisionFile(revision: commit.sha, path: $0) }))
                    },
                    selectedID: first.id, highlights: [:],
                    promptContext: PromptContext(
                        repositoryPath: session.rootURL.path, isGitButler: history.isGitButler,
                        source: .commit(sha: commit.sha, message: commit.message)))
                openWindow(id: DiffWindow.id, value: model.register(.snapshot(snapshot)))
            } catch {
                history.branchActionError = String(describing: error)
            }
        }
    }
}

/// A branch's row in its card: name, pull request and checks, push state and actions.
private struct BranchHead: View {
    let session: ProjectSession
    let branch: HistoryBranch
    /// The branch it is stacked on, for all but the base of a stack.
    let below: String?
    let isSelected: Bool

    @State private var isHovered = false
    private var history: HistoryModel { session.history }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: history.isMerged(branch) ? "arrow.triangle.merge" : "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(history.isMerged(branch) ? Theme.mergedFg : Theme.textSecondary)
                .frame(width: 15, height: 15)
            Text(branch.name)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if below != nil {
                Chip("stacked", systemImage: "square.3.layers.3d")
            }
            if let pullRequest = history.pullRequest(of: branch) {
                Chip("#\(pullRequest.number) · \(pullRequest.stateTitle)", systemImage: pullRequest.systemImage, tone: pullRequest.tone)
                if pullRequest.state == .open, let status = history.pullRequestStatuses[pullRequest.number] {
                    ChecksChip(checks: status.checks, isCompact: true)
                }
            }
            if branch.isConflicted {
                Chip("conflicted", systemImage: "exclamationmark.triangle", tone: .danger)
            }
            Spacer(minLength: 8)
            Text(statusText)
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if history.canPush(branch) {
                IconButton(branch.needsForcePush ? "Force Push" : "Push", systemImage: "arrow.up") { history.requestPush(branch) }
                    .disabled(history.branchActivity != nil)
            }
            if history.isMerged(branch), history.canDelete(branch) {
                IconButton("Delete Branch…", systemImage: "xmark") { history.pendingDeletion = [branch] }
            } else {
                BranchMoreMenu(branch: branch, history: history)
            }
        }
        .padding(.leading, below == nil ? 14 : 30)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(isSelected ? Theme.hover : isHovered ? Theme.hover.opacity(0.5) : .clear)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { history.selection = .branch(branch.name) }
        .contextMenu { BranchMenuItems(branch: branch, history: history) }
    }

    private var statusText: String {
        if let below { return "on \(below)" }
        if history.isMerged(branch) { return "merged" }
        switch branch.status {
        case .unpushed: return "not pushed"
        case .unpushedCommits: return "unpushed commits"
        case .requiresForce: return "needs force push"
        case .upToDate: return "pushed"
        case .integrated: return "merged"
        case .tracking(let ahead, let behind):
            if ahead == 0 && behind == 0 { return "pushed" }
            return [ahead > 0 ? "↑\(ahead) ahead" : nil, behind > 0 ? "↓\(behind) behind" : nil].compactMap(\.self).joined(separator: " ")
        case .upstreamGone: return "remote deleted"
        case nil: return branch.commits.isEmpty ? "no commits" : ""
        }
    }
}

/// The ⋯ menu of a branch.
private struct BranchMoreMenu: View {
    let branch: HistoryBranch
    let history: HistoryModel

    var body: some View {
        Menu {
            BranchMenuItems(branch: branch, history: history)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hover(cornerRadius: 8))
        .fixedSize()
    }
}

/// What can be done with a branch, in its ⋯ menu and context menu.
private struct BranchMenuItems: View {
    let branch: HistoryBranch
    let history: HistoryModel

    var body: some View {
        if history.canPush(branch) {
            Button(branch.needsForcePush ? "Force Push" : "Push") { history.requestPush(branch) }
        }
        if let pullRequest = history.pullRequest(of: branch) {
            Button("Open #\(pullRequest.number) on GitHub") { NSWorkspace.shared.open(pullRequest.url) }
        } else if history.canOpenPullRequest(branch) {
            Button("Create Pull Request…") { history.requestPullRequestDraft(branch) }
        }
        StackMenuItems(branch: branch, history: history)
        Divider()
        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch.name, forType: .string)
        }
        if history.canDelete(branch) {
            Divider()
            Button("Delete Branch…", role: .destructive) { history.pendingDeletion = [branch] }
        }
    }
}

/// A commit in a branch card: summary, `local` until pushed, short SHA and age.
private struct CommitLine: View {
    let commit: CommitInfo
    let isLocal: Bool
    let indent: CGFloat
    let open: () -> Void
    let showInHistory: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.and.line.horizontal")
                .font(.system(size: 10.5))
                .foregroundStyle(isLocal ? Theme.warnFg : Theme.textTertiary)
                .frame(width: 14, height: 14)
            Text(commit.summary)
                .font(.control)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if commit.isConflicted {
                Chip("conflicted", tone: .danger)
            }
            if isLocal {
                Chip("local", tone: .warn)
            }
            Text(commit.shortSHA)
                .font(.code(11))
                .foregroundStyle(Theme.textTertiary)
            Text(commit.date.map { RelativeAge.short($0) } ?? "")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.leading, indent)
        .padding(.trailing, 14)
        .frame(height: 32)
        .background(isHovered ? Theme.hover : .clear)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .help("Review Commit")
        .contextMenu {
            Button("Review Commit", action: open)
            Button("Show in History", action: showInHistory)
            Divider()
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.sha, forType: .string)
            }
        }
    }
}

/// `3/5` while checks run, `2 failing`, or `5/5` once they pass.
struct ChecksChip: View {
    let checks: PullRequestStatus.Checks
    var isCompact = false

    var body: some View {
        switch checks {
        case .none:
            EmptyView()
        case .pending(let done, let total):
            Chip(isCompact ? "\(done)/\(total)" : "Checks \(done)/\(total)", systemImage: "circle.dotted", tone: .warn)
        case .failed(let names, _):
            Chip(names.count == 1 ? "1 failing" : "\(names.count) failing", systemImage: "xmark", tone: .danger)
        case .passed(let total):
            Chip(isCompact ? "\(total)/\(total)" : "Checks passed", systemImage: "checkmark.circle", tone: .ok)
        }
    }
}

extension PullRequest {
    var stateTitle: String {
        switch state {
        case .open: isDraft ? "Draft" : "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    var systemImage: String {
        state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull"
    }

    var tone: Chip.Tone {
        switch state {
        case .open: isDraft ? .neutral : .ok
        case .merged: .merged
        case .closed: .neutral
        }
    }
}
