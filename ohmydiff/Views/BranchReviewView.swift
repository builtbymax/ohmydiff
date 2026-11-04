import AppKit
import OhMyDiffCore
import SwiftUI

/// How the Branches page shows its stacks: as cards beside the pull request panel, or as narrow columns beside
/// the diff of the selected branch, commit or uncommitted changes.
enum BranchesLayout: String {
    case overview
    case review

    /// The stored layout, for code outside the views that read it with `@AppStorage`.
    static var current: BranchesLayout {
        get { UserDefaults.standard.string(forKey: AppSettings.branchesLayoutKey).flatMap(Self.init(rawValue:)) ?? .overview }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppSettings.branchesLayoutKey) }
    }
}

/// The Branches page's review layout: a compact column of uncommitted changes, branches and commits, the
/// selection's files, and the selected file's diff, with the branch's details on the right. Uncommitted changes
/// list with the commit composer and get hunk actions and the file inspector. The first column widens over the
/// files while the pointer rests on it.
struct BranchReviewView: View {
    let model: AppModel
    let session: ProjectSession

    @AppStorage(AppSettings.branchListWidthKey) private var filesWidth = 240.0
    @AppStorage(AppSettings.listWidthKey) private var changesWidth = 300.0
    @AppStorage(AppSettings.isListHiddenKey) private var isFileListHidden = false
    @AppStorage(AppSettings.branchesLayoutKey) private var layout = BranchesLayout.overview
    @AppStorage(Self.isListPinnedKey) private var isListPinned = false
    @AppStorage(Self.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true
    @State private var isListExpanded = false
    /// Branches whose commits are folded away with their chevron or ←.
    @State private var collapsed: Set<String> = []
    @State private var expandTask: Task<Void, Never>?

    private var history: HistoryModel { session.history }
    /// Whether the branch list stays open at full width instead of widening while the pointer rests on it.
    static let isListPinnedKey = "branchReviewListPinned"
    /// Whether the branch list is left out; the sidebar's branches still select them.
    static let isListHiddenKey = "branchReviewListHidden"
    private static let compactWidth: CGFloat = 190
    private static let expandedWidth: CGFloat = 320
    private static let detailsWidth: CGFloat = 380
    private static let inspectorWidth: CGFloat = 320
    /// The narrowest the diff gets before panels beside it make way: about its file header's controls.
    private static let diffMinWidth: CGFloat = 460

    var body: some View {
        GeometryReader { geometry in
            content(fitting(uncommittedScope, in: geometry.size.width))
        }
    }

    private func content(_ fit: Fit) -> some View {
        let cards = session.listedBranchCards(in: .review)
        let scope = uncommittedScope
        return ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if fit.showsList {
                    // Holds the compact width; the list draws over the files when it widens.
                    Color.clear
                        .frame(width: fit.listWidth)
                        .overlay(alignment: .leading) { list(cards) }
                        .zIndex(1)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if let scope {
                    if !isFileListHidden {
                        UncommittedFilesColumn(model: model, session: session, scope: scope)
                            .frame(width: fit.filesWidth)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                            }
                            .overlay(alignment: .trailing) { ColumnResizer(width: $changesWidth, range: AppSettings.listWidths) }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Group {
                        if scope == nil || session.selectedFile.map(isInScope) == true {
                            DiffDetailView(session: session)
                        } else {
                            EmptyState("No Selection", systemImage: "text.alignleft")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BranchFilesColumn(history: history)
                        .frame(width: fit.filesWidth)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                        }
                        .overlay(alignment: .trailing) { ColumnResizer(width: $filesWidth, range: AppSettings.branchFilesWidths) }
                    BranchReviewDetail(model: model, session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if fit.showsInspector {
                    Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                    Group {
                        if scope != nil {
                            ChangesInspector(model: model, session: session)
                        } else {
                            details
                        }
                    }
                    .frame(width: scope != nil ? Self.inspectorWidth : Self.detailsWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if scope != nil, let request = session.actionRequest, request.action == .commit {
                    ZStack(alignment: .bottomLeading) {
                        // Clicking outside the card closes it, like a popover.
                        Color.black.opacity(0.001)
                            .onTapGesture { session.actionRequest = nil }
                        CommitTargetCard(session: session, request: request) { session.actionRequest = nil }
                            .id(request.id)
                            .padding(.leading, fit.listWidth + 12)
                            .padding(.bottom, 168)
                            .popoverTransition(anchor: .bottomLeading)
                    }
                }
            }
            .animation(Theme.popoverAnimation, value: session.actionRequest?.id)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: cards, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, in: cards, proxy: proxy) }
            .onKeyPress(.leftArrow) { fold(true) }
            .onKeyPress(.rightArrow) { fold(false) }
            .onKeyPress("n") { jumpToHunk(1) }
            .onKeyPress("p") { jumpToHunk(-1) }
            .onKeyPress(.escape) {
                history.picksLayout = false
                withAnimation(.snappy(duration: 0.2)) { layout = .overview }
                return .handled
            }
            .onAppear { history.selection.map { proxy.scrollTo($0) } }
            .onChange(of: session.selectedFileID) {
                // A refresh selects the next file once the selected one is committed; keep to the lane's files.
                guard case .uncommitted(let scope?)? = history.selection, let file = session.selectedFile, !isInScope(file),
                      let first = session.uncommittedGroups(scope).allFiles.first
                else { return }
                session.select(first.id)
            }
        }
    }

    private var listWidth: CGFloat { isListHidden ? 0 : isListPinned ? Self.expandedWidth : Self.compactWidth }

    /// The panels shown at the page's width, and the files column's width.
    private struct Fit {
        var showsList: Bool
        var showsInspector: Bool
        var listWidth: CGFloat
        var filesWidth: CGFloat
    }

    /// When the window is too narrow for every panel, the inspector makes way first, then the branch list, then
    /// the files column narrows to its minimum. The panels' settings stay as they are.
    private func fitting(_ scope: ChangeGroup.ID??, in width: CGFloat) -> Fit {
        let isUncommitted = scope != nil
        let range = isUncommitted ? AppSettings.listWidths : AppSettings.branchFilesWidths
        let sideWidth = (isUncommitted ? Self.inspectorWidth : Self.detailsWidth) + 1
        var fit = Fit(
            showsList: !isListHidden, showsInspector: isInspectorShown, listWidth: listWidth,
            filesWidth: isUncommitted && isFileListHidden ? 0 : isUncommitted ? changesWidth : filesWidth)
        var room = width - Self.diffMinWidth - fit.filesWidth - fit.listWidth
        if fit.showsInspector {
            if room < sideWidth { fit.showsInspector = false } else { room -= sideWidth }
        }
        if fit.showsList, room < 0 {
            fit.showsList = false
            room += fit.listWidth
            fit.listWidth = 0
        }
        if fit.filesWidth > 0, room < 0 {
            fit.filesWidth = max(range.lowerBound, fit.filesWidth + room)
        }
        return fit
    }

    /// Whether the selected lane, or all uncommitted changes, list the file.
    private func isInScope(_ file: ChangedFile) -> Bool {
        guard case .uncommitted(let scope)? = history.selection else { return false }
        return session.uncommittedGroups(scope).allFiles.contains { $0.id == file.id }
    }

    /// The uncommitted changes the selection lists: `.some(nil)` for all of them, `nil` for a branch or commit.
    private var uncommittedScope: ChangeGroup.ID?? {
        guard case .uncommitted(let scope)? = history.selection else { return nil }
        return .some(scope)
    }

    /// The selected branch's details, or those of the branch a selected commit is on.
    @ViewBuilder private var details: some View {
        if let branch = history.selectedBranch {
            BranchPanel(model: model, session: session, branch: branch)
                .id(branch.name)
        } else {
            EmptyState("No branch selected", systemImage: "arrow.triangle.branch")
        }
    }

    private func list(_ cards: [[HistoryBranch]]) -> some View {
        let isWide = isListPinned || isListExpanded
        return BranchReviewList(session: session, cards: cards, isCompact: !isWide, collapsed: $collapsed)
            .frame(width: isWide ? Self.expandedWidth : Self.compactWidth)
            .frame(maxHeight: .infinity)
            .background(Theme.canvas)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.lineSubtle).frame(width: 1)
            }
            .shadow(color: isListExpanded && !isListPinned ? Theme.cardShadow : .clear, radius: 8, x: 2)
            .onHover { isHovered in
                expandTask?.cancel()
                guard isHovered, !isListPinned else {
                    withAnimation(.snappy(duration: 0.18)) { isListExpanded = false }
                    return
                }
                // A short rest first, so passing over the list on the way to the files does not widen it.
                expandTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy(duration: 0.2)) { isListExpanded = true }
                }
            }
    }

    /// Steps through the selection's files, then on to the next or previous row of the list.
    private func move(_ offset: Int, in cards: [[HistoryBranch]], proxy: ScrollViewProxy) -> KeyPress.Result {
        if let scope = uncommittedScope {
            let files = session.uncommittedGroups(scope).allFiles
            if let index = files.firstIndex(where: { $0.id == session.selectedFileID }), files.indices.contains(index + offset) {
                let next = files[index + offset].id
                session.selectedFileID = next
                proxy.scrollTo(next)
                return .handled
            }
        } else if case .loaded(let diffs) = history.files, let index = diffs.firstIndex(where: { $0.id == history.selectedFileID }),
           diffs.indices.contains(index + offset) {
            let next = diffs[index + offset].id
            history.selectedFileID = next
            proxy.scrollTo(next)
            return .handled
        }
        let items = BranchReviewList.rows(session: session, cards: cards, collapsed: collapsed)
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0 == history.selection }
        let next = items[current.map { min(max($0 + offset, 0), items.count - 1) } ?? 0]
        guard next != history.selection else { return .handled }
        if case .uncommitted(let scope) = next {
            session.reviewUncommitted(scope)
        } else {
            history.selection = next
        }
        proxy.scrollTo(next)
        return .handled
    }

    /// ← folds the selected branch, or steps from a commit up to its branch; → unfolds it.
    private func fold(_ isFolding: Bool) -> KeyPress.Result {
        switch history.selection {
        case .branch(let name)?:
            withAnimation(.snappy(duration: 0.18)) {
                if isFolding { collapsed.insert(name) } else { collapsed.remove(name) }
            }
            return .handled
        case .commit(_, let branch)? where isFolding:
            history.selection = .branch(branch)
            return .handled
        default:
            return .ignored
        }
    }

    private func jumpToHunk(_ direction: Int) -> KeyPress.Result {
        NotificationCenter.default.post(name: .jumpToHunk, object: direction)
        return .handled
    }
}

// MARK: - Branches and commits

/// The uncommitted changes, then each stack's branches from the base up, with their commits and the lane's
/// uncommitted changes on top. Compact, it leaves out SHAs and pull requests.
private struct BranchReviewList: View {
    let session: ProjectSession
    let cards: [[HistoryBranch]]
    let isCompact: Bool
    @Binding var collapsed: Set<String>

    private var history: HistoryModel { session.history }

    /// Every row in list order, for ↑ and ↓.
    static func rows(session: ProjectSession, cards: [[HistoryBranch]], collapsed: Set<String>) -> [HistoryModel.Selection] {
        let history = session.history
        let top: [HistoryModel.Selection] = showsUncommitted(session: session, scope: nil) ? [.uncommitted(nil)] : []
        return top + cards.flatMap { stackRows(session: session, branches: $0, collapsed: collapsed) }
    }

    /// One stack's rows, base first: each branch, the lane's uncommitted changes on the top branch, and commits.
    static func stackRows(session: ProjectSession, branches: [HistoryBranch], collapsed: Set<String>) -> [HistoryModel.Selection] {
        let history = session.history
        let lane = session.lane(of: branches).flatMap { showsUncommitted(session: session, scope: $0.id) ? $0 : nil }
        return branches.reversed().flatMap { branch in
            [HistoryModel.Selection.branch(branch.name)]
                + (branch.name == branches.first?.name ? lane.map { [.uncommitted($0.id)] } ?? [] : [])
                + (history.isMerged(branch) || collapsed.contains(branch.name) ? [] : branch.commits.map { .commit(sha: $0.sha, branch: branch.name) })
        }
    }

    /// Uncommitted rows show while they have files, and while selected, so committing the last file does not
    /// pull the row away. A lane's only shows when it has its own files.
    private static func showsUncommitted(session: ProjectSession, scope: ChangeGroup.ID?) -> Bool {
        if session.history.selection == .uncommitted(scope) { return true }
        return !session.uncommittedGroups(scope).allFiles.isEmpty
    }

    var body: some View {
        if cards.isEmpty && !Self.showsUncommitted(session: session, scope: nil) {
            EmptyState("No branches", systemImage: "arrow.triangle.branch")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if Self.showsUncommitted(session: session, scope: nil) {
                        ReviewUncommittedRow(
                            title: "Uncommitted", systemImage: "tray", files: session.groups.allFiles, indent: 11,
                            isSelected: history.selection == .uncommitted(nil)
                        ) { session.reviewUncommitted() }
                        .id(HistoryModel.Selection.uncommitted(nil))
                        .padding(.bottom, cards.isEmpty ? 0 : 8)
                    }
                    ForEach(Array(cards.enumerated()), id: \.element.first?.name) { index, branches in
                        stack(branches)
                            .padding(.top, index == 0 ? 0 : 8)
                    }
                }
                .padding(8)
            }
        }
    }

    /// A stack of several branches sits on a card under a `Stack · 2` label; a single branch stands on its own.
    @ViewBuilder
    private func stack(_ branches: [HistoryBranch]) -> some View {
        let isStack = branches.count > 1
        VStack(alignment: .leading, spacing: 1) {
            if isStack {
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 10.5))
                        .frame(width: 14, height: 14)
                    Text("Stack · \(branches.count)")
                        .font(.sectionLabel)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .help("\(branches.count) stacked branches, base first")
            }
            rows(branches)
        }
        .padding(isStack ? 3 : 0)
        .background {
            if isStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.hover.opacity(0.5))
                    .strokeBorder(Theme.lineSubtle, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func rows(_ branches: [HistoryBranch]) -> some View {
        // Base first, like the overview's cards. Stacked branches are joined by a line through their icons
        // and commits, from the first row to the last.
        let ordered = Array(branches.reversed())
        let all = branches.count > 1 ? Self.stackRows(session: session, branches: branches, collapsed: collapsed) : []
        let rail = { (selection: HistoryModel.Selection) in
            StackRail(continuesUp: all.first != selection && all.contains(selection), continuesDown: all.last != selection && all.contains(selection))
        }
        let lane = session.lane(of: branches).flatMap { Self.showsUncommitted(session: session, scope: $0.id) ? $0 : nil }
        ForEach(Array(ordered.enumerated()), id: \.element.name) { index, branch in
            let selection = HistoryModel.Selection.branch(branch.name)
            let isCollapsed = collapsed.contains(branch.name)
            ReviewBranchRow(
                history: history, branch: branch, isCompact: isCompact,
                isSelected: history.selection == selection, isCollapsed: isCollapsed,
                toggle: { toggle(branch.name) }
            ) { history.selection = selection }
            .modifier(rail(selection))
            .id(selection)
            // The lane's uncommitted changes go on top of the stack, above its newest commit.
            if index == ordered.count - 1, let lane {
                ReviewUncommittedRow(
                    title: "Uncommitted", systemImage: "circle.dashed", files: lane.files, indent: 22,
                    isSelected: history.selection == .uncommitted(lane.id)
                ) { session.reviewUncommitted(lane.id) }
                .modifier(rail(.uncommitted(lane.id)))
                .id(HistoryModel.Selection.uncommitted(lane.id))
            }
            if !history.isMerged(branch), !isCollapsed {
                ForEach(branch.commits, id: \.sha) { commit in
                    let selection = HistoryModel.Selection.commit(sha: commit.sha, branch: branch.name)
                    ReviewCommitRow(
                        commit: commit, isLocal: session.isLocal(commit, in: branch), indent: 22,
                        isCompact: isCompact, isSelected: history.selection == selection
                    ) { history.selection = selection }
                    .modifier(rail(selection))
                    .id(selection)
                }
            }
        }
    }
}

/// The line joining a stack's rows: through the icon column, above and below the row's icon. The branch and
/// commit icons sit 29 pt in, so the line runs through them all.
private struct StackRail: ViewModifier {
    let continuesUp: Bool
    let continuesDown: Bool

    private static let x: CGFloat = 29
    /// Room left around the icon.
    private static let gap: CGFloat = 9

    func body(content: Content) -> some View {
        content.overlay {
            if continuesUp || continuesDown {
                GeometryReader { proxy in
                    let middle = proxy.size.height / 2
                    Path { path in
                        if continuesUp {
                            path.move(to: CGPoint(x: Self.x, y: 0))
                            path.addLine(to: CGPoint(x: Self.x, y: middle - Self.gap))
                        }
                        if continuesDown {
                            // On into the 1 pt between rows.
                            path.move(to: CGPoint(x: Self.x, y: middle + Self.gap))
                            path.addLine(to: CGPoint(x: Self.x, y: proxy.size.height + 1))
                        }
                    }
                    .stroke(Theme.lineStrong, lineWidth: 1.5)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// Uncommitted changes in the review list: all of them or a lane's, with how many files.
private struct ReviewUncommittedRow: View {
    let title: String
    let systemImage: String
    let files: [ChangedFile]
    let indent: CGFloat
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.control.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(files.count)")
                    .font(.caption11.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .rowHeight(28)
            .contentShape(.rect)
        }
        .buttonStyle(.row(isSelected: isSelected))
        .focusEffectDisabled()
        .help(files.count == 1 ? "1 uncommitted file" : "\(files.count) uncommitted files")
    }
}

extension BranchReviewList {
    /// Folds or unfolds a branch's commits; a selected commit that folds away hands the selection to its branch.
    fileprivate func toggle(_ branch: String) {
        withAnimation(.snappy(duration: 0.18)) {
            if collapsed.remove(branch) == nil { collapsed.insert(branch) }
        }
        if collapsed.contains(branch), case .commit(_, branch)? = history.selection {
            history.selection = .branch(branch)
        }
    }
}

/// A branch in the review list: its name, pull request and commit count; selecting it diffs it from its base.
private struct ReviewBranchRow: View {
    let history: HistoryModel
    let branch: HistoryBranch
    let isCompact: Bool
    let isSelected: Bool
    let isCollapsed: Bool
    let toggle: () -> Void
    let select: () -> Void

    var body: some View {
        let isMerged = history.isMerged(branch)
        Button(action: select) {
            HStack(spacing: 7) {
                // Merged branches list no commits; the slot stays so names line up.
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 14, height: 14)
                        .contentShape(.rect)
                }
                .buttonStyle(.hover(cornerRadius: 4))
                .focusEffectDisabled()
                .opacity(isMerged || branch.commits.isEmpty ? 0 : 1)
                .disabled(isMerged || branch.commits.isEmpty)
                .help(isCollapsed ? "Show Commits  →" : "Hide Commits  ←")
                .padding(.trailing, -3)
                Image(systemName: isMerged ? "arrow.triangle.merge" : "arrow.triangle.branch")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isMerged ? Theme.mergedFg : Theme.textSecondary)
                    .frame(width: 14, height: 14)
                Text(branch.name)
                    .font(.control.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if branch.isConflicted {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.delFg)
                }
                if !isCompact, let pullRequest = history.pullRequest(of: branch) {
                    Chip("#\(pullRequest.number)", systemImage: pullRequest.systemImage, tone: pullRequest.tone)
                }
                Text("\(branch.commits.count)")
                    .font(.caption11.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .help(branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits")
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .rowHeight(30)
            .contentShape(.rect)
        }
        .buttonStyle(.row(isSelected: isSelected))
        .focusEffectDisabled()
        .opacity(isMerged ? 0.7 : 1)
        .help(branch.name)
        .contextMenu { BranchMenuItems(branch: branch, history: history) }
    }
}

/// A commit in the review list: summary and, when wide, short SHA; selecting it shows its own diff.
private struct ReviewCommitRow: View {
    let commit: CommitInfo
    let isLocal: Bool
    let indent: CGFloat
    let isCompact: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: "circle.and.line.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(isLocal ? Theme.warnFg : Theme.textTertiary)
                    .frame(width: 14, height: 14)
                Text(commit.summary)
                    .font(.control)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if commit.isConflicted {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.delFg)
                }
                if !isCompact {
                    Text(commit.shortSHA)
                        .font(.code(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .rowHeight(28)
            .contentShape(.rect)
        }
        .buttonStyle(.row(isSelected: isSelected))
        .focusEffectDisabled()
        .help(commit.summary)
        .contextMenu {
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.sha, forType: .string)
            }
        }
    }
}

// MARK: - Files

/// The selected branch's or commit's files under a head naming it.
private struct BranchFilesColumn: View {
    let history: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.control.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) { files }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
    }

    /// The commit's summary, or the branch's name.
    private var title: String {
        history.selectedCommit?.summary ?? history.selectedBranch?.name ?? "Files"
    }

    /// `9e4fe8c · 1 file`, `whole branch · 4 files`.
    private var subtitle: String {
        var parts = [history.selectedCommit?.shortSHA ?? (history.selectedBranch == nil ? nil : "whole branch")].compactMap(\.self)
        if case .loaded(let diffs) = history.files { parts.append(diffs.count == 1 ? "1 file" : "\(diffs.count) files") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var files: some View {
        switch history.files {
        case .loading, nil:
            DelayedProgress()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28)
        case .unavailable(let message), .failed(let message):
            Text(message)
                .font(.detail)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        case .loaded(let diffs):
            if diffs.isEmpty {
                Text("Changes no files")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            }
            ForEach(diffs) { diff in
                let isSelected = diff.id == history.selectedFileID
                Button { history.selectedFileID = diff.id } label: {
                    FileRow(
                        path: diff.path, previousPath: diff.oldPath == diff.newPath ? nil : diff.oldPath, kind: diff.kind,
                        stats: diff.isBinary ? nil : LineStats(additions: diff.additions, deletions: diff.deletions),
                        hunks: diff.hunks.map(\.size), isSelected: isSelected)
                }
                .buttonStyle(.row(isSelected: isSelected))
                .focusEffectDisabled()
                .id(diff.id)
            }
        }
    }
}

/// The selected uncommitted changes under a head naming them: the filter, the files and the commit composer.
private struct UncommittedFilesColumn: View {
    let model: AppModel
    let session: ProjectSession
    let scope: ChangeGroup.ID?

    var body: some View {
        let files = session.uncommittedGroups(scope).allFiles
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(scope.flatMap { id in session.groups.first { $0.id == id }?.title } ?? "Uncommitted changes")
                    .font(.control.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(["uncommitted", files.count == 1 ? "1 file" : "\(files.count) files"].joined(separator: " · "))
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            ChangesListView(model: model, session: session, scope: scope)
        }
    }
}

// MARK: - Detail

/// The selected file of the selected branch or commit.
private struct BranchReviewDetail: View {
    let model: AppModel
    let session: ProjectSession

    /// Syntax colors by `fileKey`, loaded as files are shown.
    @State private var highlights: [String: SyntaxHighlights] = [:]
    private var history: HistoryModel { session.history }

    var body: some View {
        switch history.files {
        case .loading, nil:
            DelayedProgress()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            EmptyState("Nothing to review", systemImage: "arrow.triangle.branch", description: message)
        case .failed(let message):
            EmptyState("Could Not Load Diff", systemImage: "exclamationmark.triangle", description: message)
        case .loaded(let diffs):
            if let file = history.selectedFile {
                let key = fileKey(file)
                FileDiffView(
                    fileID: key, diff: file, highlights: highlights[key], root: session.rootURL,
                    popout: .snapshot(snapshot(diffs, selected: file)),
                    promptContext: history.promptContext(root: session.rootURL),
                    contents: { side in await history.contents(of: file, side: side) })
                    .task(id: key) { await loadHighlights(file, key: key) }
            } else {
                EmptyState(diffs.isEmpty ? "No Files" : "No Selection", systemImage: "doc")
            }
        }
    }

    /// The file at the revisions it is diffed between, so a branch that moved loads its colors again.
    private func fileKey(_ file: FileDiff) -> String {
        let old = history.source(of: file, side: .old)?.revision ?? ""
        let new = history.source(of: file, side: .new)?.revision ?? ""
        return "\(old)..\(new):\(file.id)"
    }

    /// The selection's files for Open Diff in New Window.
    private func snapshot(_ diffs: [FileDiff], selected: FileDiff) -> DiffSnapshot {
        let context = history.selectedCommit.map { "\($0.shortSHA) · \($0.summary)" }
            ?? history.selectedBranch.map { "\($0.name) · \($0.commits.count) commits" } ?? ""
        return DiffSnapshot(
            project: session.project.displayName, context: context, root: session.rootURL,
            files: diffs.map { diff in
                DiffSnapshot.File(diff: diff, sources: (history.source(of: diff, side: .old), history.source(of: diff, side: .new)))
            },
            selectedID: selected.id, highlights: highlights[fileKey(selected)].map { [selected.id: $0] } ?? [:],
            promptContext: history.promptContext(root: session.rootURL))
    }

    private func loadHighlights(_ file: FileDiff, key: String) async {
        guard highlights[key] == nil, !file.isBinary, let language = SyntaxLanguage(path: file.path),
              let toolchain = await model.toolchain()
        else { return }
        let root = session.rootURL
        let sources = (old: history.source(of: file, side: .old), new: history.source(of: file, side: .new))
        let result = await DiffHighlighting.highlights(for: file, language: language) { side in
            guard let source = side == .old ? sources.old : sources.new else { return nil }
            return try? await Repository(root: root, kind: .git, toolchain: toolchain)
                .contents(at: source.revision, path: source.path, limit: SyntaxHighlighter.maximumLength)
        }
        guard !Task.isCancelled else { return }
        highlights[key] = result
    }
}
