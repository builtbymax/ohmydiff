import AppKit
import OhMyDiffCore
import SwiftUI

/// The Branches page: each stack as a card of its branches, their commits and uncommitted changes, and the selected
/// branch's pull request in the panel on the right; or, in the review layout, a list of them beside the diff.
struct BranchesPageView: View {
    let model: AppModel
    let session: ProjectSession
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true
    @AppStorage(AppSettings.branchesLayoutKey) private var layout = BranchesLayout.overview

    private var history: HistoryModel { session.history }

    var body: some View {
        let cards = session.listedBranchCards(in: layout)
        ProjectPhaseGate(model: model, session: session) {
            if layout == .review {
                BranchReviewView(model: model, session: session)
            } else {
                overview(cards)
            }
        }
        .butCompatibilityBanner(session)
        .changeActionPresentation(session)
        .branchActionPresentation(history) { await session.suggestions() }
        // The Merged filter lists the user's merged pull requests from the Pull requests page's inbox.
        .task(id: session.lastRefreshed) { await session.refreshPullRequests() }
        .onChange(of: cards.map { $0.map(\.name) }, initial: true) { _, names in
            // Keep a listed branch selected, so the panel always has one to show.
            if history.selection?.isUncommitted == true { return }
            let all = names.flatMap(\.self)
            if let current = history.selection?.branchName, all.contains(current) { return }
            if let first = all.first { history.selection = .branch(first) }
        }
        .onChange(of: session.groups.map(\.id)) { _, ids in
            // A lane that went away, e.g. unapplied, hands its selection to all uncommitted changes.
            if case .uncommitted(let scope?)? = history.selection, !ids.contains(scope) { history.selection = .uncommitted(nil) }
        }
        .onChange(of: layout) {
            // The overview's panel shows a branch: the lane's, or the first.
            guard layout == .overview, case .uncommitted(let scope)? = history.selection else { return }
            let lane = session.groups.first { $0.id == scope }
            if case .stack(_, let names)? = lane?.kind, let top = names.first {
                history.selection = .branch(top)
            } else {
                history.selection = cards.joined().first.map { .branch($0.name) }
            }
        }
        .onChange(of: isReadyToLand, initial: true) { _, isReady in
            if isReady { session.land() }
        }
        .onChange(of: session.actionRequest?.id) {
            // A commit or discard asked for elsewhere, e.g. from the launcher, confirms beside the changes.
            if session.actionRequest != nil, layout != .review || history.selection?.isUncommitted != true {
                session.reviewUncommitted()
            }
        }
    }

    private var isReadyToLand: Bool {
        history.needsLanding && session.phase == .ready && history.phase == .ready
    }

    private func overview(_ cards: [[HistoryBranch]]) -> some View {
        let merged = history.branchFilter == .merged ? session.mergedPullRequests : []
        return HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.changeCount > 0, history.branchFilter != .merged {
                        UncommittedCard(session: session)
                    }
                    if cards.isEmpty && merged.isEmpty {
                        emptyState
                    }
                    ForEach(cards, id: \.first?.name) { branches in
                        StackCard(
                            model: model, session: session, branches: branches,
                            isSelected: branches.contains { $0.name == history.selection?.branchName })
                    }
                    if !merged.isEmpty {
                        MergedPullRequestsCard(model: model, session: session, items: merged)
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
            EmptyState(
                "Nothing merged this week", systemImage: "arrow.triangle.merge",
                description: "Your pull requests merged in the last seven days show here, and branches that are in the target already.")
        }
    }
}

/// Every uncommitted change, above the stacks: how many files and lines; opens them in the review layout.
private struct UncommittedCard: View {
    let session: ProjectSession

    @State private var isHovered = false

    var body: some View {
        let files = session.groups.allFiles
        let unassigned = session.groups.first { $0.kind == .unassigned }?.files.count ?? 0
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 15, height: 15)
            Text("Uncommitted changes")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Chip(files.count == 1 ? "1 file" : "\(files.count) files")
            if unassigned > 0, unassigned < files.count {
                Chip("\(unassigned) unassigned")
            }
            if let stats = files.lineStats {
                LineStatsLabel(stats: stats)
            }
            Spacer(minLength: 8)
            Text("Review")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .rowHeight(46)
        .background(isHovered ? Theme.hover.opacity(0.5) : .clear)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { session.reviewUncommitted() }
        .help("Review Uncommitted Changes")
    }
}

extension [ChangedFile] {
    /// The files' added and deleted lines; `nil` when none of them knows its stats.
    var lineStats: LineStats? {
        let known = compactMap(\.stats)
        guard !known.isEmpty else { return nil }
        return LineStats(additions: known.reduce(0) { $0 + $1.additions }, deletions: known.reduce(0) { $0 + $1.deletions })
    }
}

// MARK: - Top bar

/// Branches: the layout and, in the overview, the filter; the open files while reviewing uncommitted changes,
/// the branch's push, refresh, New branch and which panels show.
struct BranchesTopBar: View {
    @Bindable var model: AppModel
    let session: ProjectSession
    @Bindable var history: HistoryModel
    @AppStorage(AppSettings.branchesLayoutKey) private var layout = BranchesLayout.overview
    @Environment(\.isTopBarNarrow) private var isNarrow

    var body: some View {
        // The controls of both layouts keep their places; what only the review layout needs comes after them.
        let isReviewingUncommitted = layout == .review && history.selection?.isUncommitted == true
        PageTitle(title: "Branches")
        Segmented(
            selection: Binding(get: { layout }, set: { value in
                history.picksLayout = false
                withAnimation(.snappy(duration: 0.2)) { layout = value }
            }),
            options: [(.overview, "Overview"), (.review, "Review")],
            systemImages: [.overview: "rectangle.grid.1x2", .review: "sidebar.left"],
            isIconOnly: isNarrow)
            .padding(.trailing, 6)
        if layout == .overview {
            // The review layout lists the applied branches; the sidebar reaches the others.
            Segmented(
                selection: $history.branchFilter,
                options: [(.applied, history.isGitButler ? "Applied" : "Current"), (.all, "All"), (.merged, "Merged")],
                systemImages: [.applied: "square.3.layers.3d", .all: "arrow.triangle.branch", .merged: "arrow.triangle.merge"],
                counts: counts,
                isIconOnly: isNarrow)
        }
        if isReviewingUncommitted {
            FileTabs(session: session)
                .padding(.leading, 8)
        }
        Spacer(minLength: 8)
        if isReviewingUncommitted {
            UncommittedBranchButtons(session: session)
                .padding(.trailing, 6)
        }
        IconButton("Refresh", systemImage: "arrow.clockwise") {
            session.refresh()
            Task { await history.loadPullRequests() }
        }
        .padding(.trailing, 6)
        Button { model.isNewBranchPresented = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                if !isNarrow {
                    Text("New branch")
                    KeyCap("⌘B")
                }
            }
        }
        .buttonStyle(.pill())
        .help(isNarrow ? "New Branch  ⌘B" : "")
        .popover(isPresented: $model.isNewBranchPresented, arrowEdge: .bottom) {
            NewBranchPopover(history: history, isGitButler: history.isGitButler) { model.isNewBranchPresented = false }
        }
        .padding(.trailing, 6)
        PanelsMenu(layout: layout, isReviewingUncommitted: isReviewingUncommitted)
    }

    private var counts: [HistoryModel.BranchFilter: String] {
        let applied = history.branchCards(for: .applied).joined().count
        let all = history.branchCards(for: .all).joined().count
        let merged = history.branchCards(for: .merged).joined().count + session.mergedPullRequests.count
        return [.applied: "\(applied)", .all: "\(all)", .merged: "\(merged)"]
    }
}

/// Which panels the Branches page shows, by layout: the details or inspector on the right, and in the review
/// layout the branch list, whether it stays wide and, beside uncommitted changes, the file list.
private struct PanelsMenu: View {
    let layout: BranchesLayout
    let isReviewingUncommitted: Bool

    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true
    @AppStorage(AppSettings.isListHiddenKey) private var isFileListHidden = false
    @AppStorage(BranchReviewView.isListPinnedKey) private var isListPinned = false
    @AppStorage(BranchReviewView.isListHiddenKey) private var isBranchListHidden = false

    var body: some View {
        Menu {
            Toggle(isReviewingUncommitted ? "Inspector" : "Branch Details", isOn: animated($isInspectorShown))
            if layout == .review {
                Toggle("Branch List", isOn: animated(Binding(get: { !isBranchListHidden }, set: { isBranchListHidden = !$0 })))
                if !isBranchListHidden {
                    Toggle("Keep Branch List Open", isOn: animated($isListPinned))
                }
            }
            if isReviewingUncommitted {
                Toggle("File List", isOn: animated(Binding(get: { !isFileListHidden }, set: { isFileListHidden = !$0 })))
            }
        } label: {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hover(cornerRadius: 8))
        .fixedSize()
        .help("Panels")
    }

    private func animated(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: { value in withAnimation(.snappy(duration: 0.2)) { binding.wrappedValue = value } })
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
    @AppStorage(AppSettings.branchesLayoutKey) private var layout = BranchesLayout.overview
    private var history: HistoryModel { session.history }

    var body: some View {
        // GitButler lists a stack top first; the card reads like the stack is built, base first.
        let ordered = Array(branches.reversed())
        let isAllMerged = branches.allSatisfy(history.isMerged)
        let lane = session.lane(of: branches)
        VStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.name) { index, branch in
                BranchHead(
                    session: session, branch: branch, below: index > 0 ? ordered[index - 1].name : nil,
                    isSelected: history.selection?.branchName == branch.name)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
                    }
                // The lane's uncommitted changes go on top of the stack, above its newest commit.
                if index == ordered.count - 1, let lane, !lane.files.isEmpty {
                    UncommittedLine(files: lane.files, indent: index > 0 ? 30 : 14) { session.reviewUncommitted(lane.id) }
                }
                if !history.isMerged(branch) {
                    ForEach(branch.commits, id: \.sha) { commit in
                        CommitLine(
                            commit: commit, isLocal: session.isLocal(commit, in: branch), indent: index > 0 ? 30 : 14,
                            open: {
                                history.selection = .commit(sha: commit.sha, branch: branch.name)
                                withAnimation(.snappy(duration: 0.2)) { layout = .review }
                            },
                            openInWindow: { openInWindow(commit) },
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

    /// The commit's diff in a window of its own.
    private func openInWindow(_ commit: CommitInfo) {
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

/// The user's pull requests merged this week whose branch is gone, e.g. removed by `but pull`; each opens in the
/// Pull requests page.
private struct MergedPullRequestsCard: View {
    let model: AppModel
    let session: ProjectSession
    let items: [InboxPullRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Merged this week").font(.sectionLabel)
                Text("\(items.count)").font(.caption11)
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 36, alignment: .leading)
            ForEach(items) { item in
                MergedPullRequestRow(item: item) {
                    session.pullRequests.filter = .mine
                    session.pullRequests.selectedNumber = item.number
                    model.mode = .pullRequests
                }
                .overlay(alignment: .top) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

/// A merged pull request: title, number, its branch and when it merged.
private struct MergedPullRequestRow: View {
    let item: InboxPullRequest
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 12))
                .foregroundStyle(Theme.mergedFg)
                .frame(width: 15, height: 15)
            Text(item.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text("#\(item.number)")
                .font(.detail)
                .foregroundStyle(Theme.textTertiary)
            Chip(item.headRefName, systemImage: "arrow.triangle.branch", truncates: true)
            Spacer(minLength: 8)
            Text(item.mergedAt.map { "merged \(RelativeAge.short($0)) ago" } ?? "merged")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
            IconButton("Open on GitHub", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(item.url) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .rowHeight(46)
        .background(isHovered ? Theme.hover.opacity(0.5) : .clear)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .help("Show in Pull Requests")
        .contextMenu {
            Button("Show in Pull Requests", action: open)
            Button("Open #\(item.number) on GitHub") { NSWorkspace.shared.open(item.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
        }
    }
}

extension ProjectSession {
    /// The branches a layout lists: the overview's by its filter; the review layout's are the applied ones, the
    /// branches being worked on.
    func listedBranchCards(in layout: BranchesLayout) -> [[HistoryBranch]] {
        history.branchCards(for: layout == .review ? .applied : history.branchFilter)
    }

    /// The groups an uncommitted selection lists: one lane's, or all of them.
    func uncommittedGroups(_ scope: ChangeGroup.ID?) -> [ChangeGroup] {
        guard let scope else { return groups }
        return groups.filter { $0.id == scope }
    }

    /// The GitButler lane that holds a stack's uncommitted changes.
    func lane(of branches: [HistoryBranch]) -> ChangeGroup? {
        branches.lazy.compactMap { self.lane(containing: $0.name) }.first
    }

    /// The GitButler lane of the stack a branch is in.
    func lane(containing branch: String) -> ChangeGroup? {
        groups.first { group in
            guard case .stack(_, let names) = group.kind else { return false }
            return names.contains(branch)
        }
    }

    /// Shows uncommitted changes in the Branches page's review layout: a lane's, or all of them. The selected
    /// file stays when it is one of them, else the first is selected.
    func reviewUncommitted(_ scope: ChangeGroup.ID? = nil) {
        history.needsLanding = false
        history.selection = .uncommitted(scope)
        withAnimation(.snappy(duration: 0.2)) { BranchesLayout.current = .review }
        let files = uncommittedGroups(scope).allFiles
        if !files.contains(where: { $0.id == selectedFileID }), let first = files.first { select(first.id) }
    }

    /// Where the Branches page opens: the uncommitted changes in the review layout when there are any, else
    /// the overview. A layout the user picked stays.
    func land() {
        history.needsLanding = false
        if changeCount > 0 {
            if history.picksLayout || BranchesLayout.current == .review { reviewUncommitted() }
            return
        }
        if history.selection?.isUncommitted == true {
            history.selection = listedBranchCards(in: .current).joined().first.map { .branch($0.name) }
        }
        if history.picksLayout {
            withAnimation(.snappy(duration: 0.2)) { BranchesLayout.current = .overview }
        }
    }

    /// The user's pull requests merged this week, unless the Merged filter lists their branch already.
    var mergedPullRequests: [InboxPullRequest] {
        let listed = Set(history.branchCards(for: .merged).joined().map(\.name))
        return pullRequests.mergedThisWeek.filter { !listed.contains($0.headRefName) }
    }

    /// Commits the remote does not have: all of a never pushed branch, else what the log knows is unpushed.
    func isLocal(_ commit: CommitInfo, in branch: HistoryBranch) -> Bool {
        switch branch.status {
        case .unpushed: return true
        case .tracking(let ahead, _):
            return branch.commits.prefix(ahead).contains { $0.sha == commit.sha }
        case .upToDate, .integrated: return false
        default:
            return log.commits.first { $0.id == commit.sha }.map { !$0.isPushed } ?? false
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
        .rowHeight(46)
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
struct BranchMenuItems: View {
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
    let openInWindow: () -> Void
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
        .rowHeight(32)
        .background(isHovered ? Theme.hover : .clear)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .help("Review Commit")
        .contextMenu {
            Button("Review Commit", action: open)
            Button("Open in New Window", action: openInWindow)
            Button("Show in History", action: showInHistory)
            Divider()
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.sha, forType: .string)
            }
        }
    }
}

/// A lane's uncommitted changes in its stack card: how many files and lines; opens them in the review layout.
private struct UncommittedLine: View {
    let files: [ChangedFile]
    let indent: CGFloat
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 14, height: 14)
            Text(files.count == 1 ? "1 uncommitted file" : "\(files.count) uncommitted files")
                .font(.control)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let stats = files.lineStats {
                LineStatsLabel(stats: stats)
            }
        }
        .padding(.leading, indent)
        .padding(.trailing, 14)
        .rowHeight(32)
        .background(isHovered ? Theme.hover : .clear)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .help("Review Uncommitted Changes")
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
