import AppKit
import OhMyDiffCore
import SwiftUI

/// How the Branches page shows its stacks: as cards beside the pull request panel, or as narrow columns beside
/// the selected branch's or commit's diff, like Changes.
enum BranchesLayout: String {
    case overview
    case review
}

/// The Branches page's review layout: a compact column of branches and commits, the selection's files, and the
/// selected file's diff. The first column widens over the files while the pointer rests on it.
struct BranchReviewView: View {
    let model: AppModel
    let session: ProjectSession

    @AppStorage(AppSettings.branchListWidthKey) private var filesWidth = 240.0
    @AppStorage(AppSettings.branchesLayoutKey) private var layout = BranchesLayout.overview
    @AppStorage(Self.isListPinnedKey) private var isListPinned = false
    @State private var isListExpanded = false
    /// Branches whose commits are folded away with their chevron or ←.
    @State private var collapsed: Set<String> = []
    @State private var expandTask: Task<Void, Never>?

    private var history: HistoryModel { session.history }
    /// Whether the branch list stays open at full width instead of widening while the pointer rests on it.
    static let isListPinnedKey = "branchReviewListPinned"
    private static let compactWidth: CGFloat = 190
    private static let expandedWidth: CGFloat = 320

    var body: some View {
        let cards = history.branchCards(for: history.branchFilter)
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                // Holds the compact width; the list draws over the files when it widens.
                Color.clear
                    .frame(width: isListPinned ? Self.expandedWidth : Self.compactWidth)
                    .overlay(alignment: .leading) { list(cards) }
                    .zIndex(1)
                BranchFilesColumn(history: history)
                    .frame(width: filesWidth)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                    }
                    .overlay(alignment: .trailing) { ColumnResizer(width: $filesWidth, range: AppSettings.branchFilesWidths) }
                BranchReviewDetail(model: model, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: cards, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, in: cards, proxy: proxy) }
            .onKeyPress(.leftArrow) { fold(true) }
            .onKeyPress(.rightArrow) { fold(false) }
            .onKeyPress("n") { jumpToHunk(1) }
            .onKeyPress("p") { jumpToHunk(-1) }
            .onKeyPress(.escape) {
                withAnimation(.snappy(duration: 0.2)) { layout = .overview }
                return .handled
            }
            .onAppear { history.selection.map { proxy.scrollTo($0) } }
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

    /// Steps through the selection's files, then on to the next or previous branch or commit.
    private func move(_ offset: Int, in cards: [[HistoryBranch]], proxy: ScrollViewProxy) -> KeyPress.Result {
        if case .loaded(let diffs) = history.files, let index = diffs.firstIndex(where: { $0.id == history.selectedFileID }),
           diffs.indices.contains(index + offset) {
            let next = diffs[index + offset].id
            history.selectedFileID = next
            proxy.scrollTo(next)
            return .handled
        }
        let items = cards.flatMap { branches in
            branches.reversed().flatMap { branch in
                [HistoryModel.Selection.branch(branch.name)]
                    + (history.isMerged(branch) || collapsed.contains(branch.name) ? [] : branch.commits.map { .commit(sha: $0.sha, branch: branch.name) })
            }
        }
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0 == history.selection }
        let next = items[current.map { min(max($0 + offset, 0), items.count - 1) } ?? 0]
        guard next != history.selection else { return .handled }
        history.selection = next
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

/// Each stack's branches from the base up, with their commits. Compact, it leaves out SHAs and pull requests.
private struct BranchReviewList: View {
    let session: ProjectSession
    let cards: [[HistoryBranch]]
    let isCompact: Bool
    @Binding var collapsed: Set<String>

    private var history: HistoryModel { session.history }

    var body: some View {
        if cards.isEmpty {
            EmptyState("No branches", systemImage: "arrow.triangle.branch")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
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
        // Base first, like the overview's cards.
        let ordered = Array(branches.reversed())
        ForEach(Array(ordered.enumerated()), id: \.element.name) { index, branch in
            let selection = HistoryModel.Selection.branch(branch.name)
            let isCollapsed = collapsed.contains(branch.name)
            ReviewBranchRow(
                history: history, branch: branch, isStacked: index > 0, isCompact: isCompact,
                isSelected: history.selection == selection, isCollapsed: isCollapsed,
                toggle: { toggle(branch.name) }
            ) { history.selection = selection }
            .id(selection)
            if !history.isMerged(branch), !isCollapsed {
                ForEach(branch.commits, id: \.sha) { commit in
                    let selection = HistoryModel.Selection.commit(sha: commit.sha, branch: branch.name)
                    ReviewCommitRow(
                        commit: commit, isLocal: session.isLocal(commit, in: branch), indent: index > 0 ? 32 : 22,
                        isCompact: isCompact, isSelected: history.selection == selection
                    ) { history.selection = selection }
                    .id(selection)
                }
            }
        }
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
    let isStacked: Bool
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
            .padding(.leading, isStacked ? 14 : 4)
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
