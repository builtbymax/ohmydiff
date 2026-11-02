import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The project while it loads, or why it cannot be shown: its folder is gone or git failed. Once loaded, `content`.
struct ProjectPhaseGate<Content: View>: View {
    let model: AppModel
    let session: ProjectSession
    @ViewBuilder var content: Content

    @State private var isLocating = false

    var body: some View {
        Group {
            switch session.phase {
            case .idle:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                EmptyState("Folder not found", systemImage: "questionmark.folder", description: "\(session.project.path) was moved or deleted.") {
                    Button("Locate…") { isLocating = true }
                    Button("Remove project") { model.remove(session.project.id) }
                        .buttonStyle(.pill(.destructive))
                    Button("Try again") { session.refresh() }
                }
            case .failed(let message):
                EmptyState("Could not load the project", systemImage: "exclamationmark.triangle", description: message) {
                    Button("Try again") { session.refresh() }
                }
            case .ready:
                content
            }
        }
        .fileImporter(isPresented: $isLocating, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.relocate(session.project.id, to: url) }
        }
    }
}

/// The uncommitted files on the Branches page: a filter, the change groups (branch lanes in GitButler, staged
/// and unstaged in git), or one lane's files, and the commit composer.
struct ChangesListView: View {
    let model: AppModel
    @Bindable var session: ProjectSession
    /// The one group listed; `nil` for all of them.
    var scope: ChangeGroup.ID? = nil

    @State private var filter = ""
    @State private var collapsedGroups: Set<ChangeGroup.ID> = []
    @AppStorage(AppSettings.groupsChangesKey) private var groupsChanges = true
    @AppStorage(AppSettings.collapsesGeneratedFilesKey) private var collapsesGeneratedFiles = true

    /// Group headers only make sense with more than the one group of a lane.
    private var showsGroups: Bool { groupsChanges && scope == nil }

    var body: some View {
        VStack(spacing: 1) {
            filterRow
                .padding(.bottom, 6)
            list
            CommitComposer(session: session, draft: session.commitDraft)
                .padding(.top, 6)
        }
        .padding(8)
    }

    /// `Filter files`, collapse generated files, group by branch.
    private var filterRow: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .frame(width: 13, height: 13)
                TextField("Filter files", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.control)
                    .foregroundStyle(Theme.textPrimary)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.hover, in: .rect(cornerRadius: 8))
            IconButton(
                collapsesGeneratedFiles ? "Show Generated Files" : "Collapse Generated Files",
                systemImage: collapsesGeneratedFiles ? "eye.slash" : "eye", isSelected: !collapsesGeneratedFiles
            ) { collapsesGeneratedFiles.toggle() }
            if scope == nil {
                IconButton(groupsChanges ? "Show as One List" : "Group by Branch", systemImage: "square.3.layers.3d", isSelected: !groupsChanges) {
                    groupsChanges.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        let groups = visibleGroups
        if groups.isEmpty {
            NothingToReview(model: model, session: session, isFiltered: !filter.isEmpty)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if showsGroups {
                            ForEach(groups) { group in
                                ChangeGroupHeader(group: group, isCollapsed: collapsedGroups.contains(group.id)) {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        if collapsedGroups.contains(group.id) { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
                                    }
                                }
                                .contextMenu { ChangeActionMenu(session: session, targets: group.files.map { ChangeTarget(file: $0) }, isGroup: true) }
                                .padding(.top, group.id == groups.first?.id ? 0 : 6)
                                if !collapsedGroups.contains(group.id) {
                                    ForEach(group.files) { file in
                                        ChangeFileRow(file: file, session: session)
                                    }
                                }
                            }
                        } else {
                            ForEach(groups.flatMap(\.files)) { file in
                                ChangeFileRow(file: file, session: session)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .overlay(alignment: .bottom) {
                    if session.selectedFiles.count > 1 {
                        SelectionBar(session: session)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: session.selectedFiles.count > 1)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveSelection(1, proxy: proxy) }
                .onKeyPress(.upArrow) { moveSelection(-1, proxy: proxy) }
                .onKeyPress(.escape) {
                    guard !session.extraSelectedFileIDs.isEmpty else { return .ignored }
                    session.clearExtraSelection()
                    return .handled
                }
                .onKeyPress("n") { jumpToHunk(1) }
                .onKeyPress("p") { jumpToHunk(-1) }
                .onChange(of: session.fileReveal) { _, reveal in
                    guard let reveal else { return }
                    if let group = session.groups.first(where: { $0.files.contains { $0.id == reveal.fileID } }) {
                        collapsedGroups.remove(group.id)
                    }
                    withAnimation(.snappy) { proxy.scrollTo(reveal.fileID) }
                }
            }
        }
    }

    /// Selects the next or previous file across all groups.
    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let files = visibleGroups.filter { !collapsedGroups.contains($0.id) || !showsGroups }.flatMap(\.files)
        guard !files.isEmpty else { return .ignored }
        let current = files.firstIndex { $0.id == session.selectedFileID }
        let next = current.map { min(max($0 + offset, 0), files.count - 1) } ?? 0
        session.selectedFileID = files[next].id
        proxy.scrollTo(files[next].id)
        return .handled
    }

    private func jumpToHunk(_ direction: Int) -> KeyPress.Result {
        NotificationCenter.default.post(name: .jumpToHunk, object: direction)
        return .handled
    }

    /// Groups with files; the branch list beside shows the lanes without. The filter matches file paths.
    private var visibleGroups: [ChangeGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return session.uncommittedGroups(scope).compactMap { group in
            var group = group
            if !query.isEmpty {
                group.files = group.files.filter { FuzzyMatcher.match(query, in: $0.path) != nil }
                return group.files.isEmpty ? nil : group
            }
            return group.files.isEmpty ? nil : group
        }
    }
}

/// The empty file list: nothing to review, and the one next step.
private struct NothingToReview: View {
    let model: AppModel
    let session: ProjectSession
    let isFiltered: Bool

    var body: some View {
        if isFiltered {
            EmptyState("No matching files", systemImage: "magnifyingglass")
        } else {
            VStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.okFg)
                    .frame(width: 32, height: 32)
                    .background(Theme.okBg, in: .circle)
                    .padding(.bottom, 12)
                Text("Nothing to review")
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                if let branch = pushableBranch {
                    Button { session.history.requestPush(branch) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up")
                            Text(branch.commits.count == 1 ? "Push 1 commit" : "Push \(branch.commits.count) commits")
                            KeyCap("⇧⌘P", onInverse: true)
                        }
                    }
                    .buttonStyle(.pill(.prominent))
                    .padding(.top, 14)
                }
                HStack(spacing: 5) {
                    KeyCap(Shortcuts.label(.launcher))
                    Text("for anything else")
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        }
    }

    private var subtitle: String {
        let branch = session.currentBranch ?? session.branchNames.first
        let since = session.history.groups.lazy.flatMap(\.branches).first { $0.name == branch }?.commits.first?.date
            .map { " · \(RelativeAge.short($0)) ago" } ?? ""
        return branch.map { "\($0) matches your last commit\(since)" } ?? "The working tree is clean."
    }

    private var pushableBranch: HistoryBranch? {
        let name = session.currentBranch ?? session.branchNames.first
        guard let branch = session.history.groups.lazy.flatMap(\.branches).first(where: { $0.name == name }),
              session.history.canPush(branch)
        else { return nil }
        return branch
    }
}

/// A file of a group. It reads the selection itself, so selecting another file only updates the rows
/// whose state changes.
private struct ChangeFileRow: View {
    let file: ChangedFile
    let session: ProjectSession

    var body: some View {
        let isSelected = session.isSelected(file.id)
        Button { select() } label: {
            FileRow(
                path: file.path, previousPath: file.previousPath, kind: file.kind, stats: file.stats,
                hunks: session.hunkSizes[file.id], isSelected: isSelected)
        }
        .buttonStyle(.row(isSelected: isSelected))
        .focusEffectDisabled()
        .id(file.id)
        .contextMenu { ChangeActionMenu(session: session, targets: menuTargets(isSelected: isSelected), isGroup: false) }
    }

    /// ⌘-click toggles the file in the selection, ⇧-click selects the range up to it.
    private func select() {
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        session.select(file.id, extending: modifiers.contains(.command) ? .toggle : modifiers.contains(.shift) ? .range : nil)
    }

    /// The whole selection when the file is part of it, else just the file.
    private func menuTargets(isSelected: Bool) -> [ChangeTarget] {
        let selected = session.selectedFiles
        guard isSelected, selected.count > 1 else { return [ChangeTarget(file: file)] }
        return selected.map { ChangeTarget(file: $0) }
    }
}

/// `3 files` with the actions every selected file supports, over the bottom of the list.
private struct SelectionBar: View {
    let session: ProjectSession

    var body: some View {
        let targets = session.selectedFiles.map { ChangeTarget(file: $0) }
        HStack(spacing: 4) {
            IconButton("Clear Selection  esc", systemImage: "xmark", size: 26, tooltipEdge: .top) { session.clearExtraSelection() }
            Text("\(targets.count) files")
                .font(.control.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .fixedSize()
            Spacer(minLength: 4)
            if session.supports(.stage, on: targets) {
                Button("Stage") { session.request(.stage, on: targets) }
                    .buttonStyle(.pill(.ghost))
            }
            if session.supports(.unstage, on: targets) {
                Button("Unstage") { session.request(.unstage, on: targets) }
                    .buttonStyle(.pill(.ghost))
            }
            if session.supports(.commit, on: targets) {
                Button { session.request(.commit, on: targets) } label: { Label("Commit…", systemImage: "smallcircle.filled.circle") }
                    .buttonStyle(.pill(.ghost))
            }
            if session.supports(.discard, on: targets) {
                IconButton("Discard Changes…", systemImage: "arrow.uturn.backward", size: 26, tooltipEdge: .top) {
                    session.request(.discard, on: targets)
                }
            }
        }
        .focusEffectDisabled()
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(height: 38)
        .floatingBar(in: .rect(cornerRadius: 12))
    }
}

/// `⌄ ⑂ feat/diff-modes        4 files`; collapses the group.
private struct ChangeGroupHeader: View {
    let group: ChangeGroup
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 12, height: 12)
                Image(systemName: icon.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(icon.color)
                    .frame(width: 14, height: 14)
                if case .stack(_, let branches) = group.kind, let top = branches.first {
                    Text(top)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if branches.count > 1 {
                        Text("+\(branches.count - 1)")
                            .font(.caption11)
                            .foregroundStyle(Theme.textTertiary)
                            .hoverCard { StackHoverCard(branches: branches) }
                    }
                } else {
                    Text(group.title)
                }
                Spacer(minLength: 4)
                Text(group.files.count == 1 ? "1 file" : "\(group.files.count) files")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.control.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .rowHeight(28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var icon: (name: String, color: Color) {
        switch group.kind {
        case .stack(_, let branches): (branches.count > 1 ? "square.3.layers.3d" : "arrow.triangle.branch", Theme.textSecondary)
        case .unassigned: ("tray", Theme.textSecondary)
        case .staged: ("checkmark", Theme.okFg)
        case .unstaged: ("smallcircle.filled.circle", Theme.warnFg)
        case .untracked: ("plus.circle", Theme.textSecondary)
        case .conflicted: ("exclamationmark.triangle", Theme.delFg)
        }
    }
}

/// A changed file: its change letter, name, folder, one bar per hunk sized by its lines, and `+24 −8`.
struct FileRow: View {
    let path: String
    /// Source path of a rename or copy.
    let previousPath: String?
    let kind: FileChangeKind
    let stats: LineStats?
    /// Changed lines per hunk, when the diff was loaded.
    var hunks: [Int]?
    var isSelected = false

    var body: some View {
        HStack(spacing: 8) {
            Text(badge.letter)
                .font(.statusLetter)
                .foregroundStyle(Theme.changeColor(kind))
                .frame(width: 14, height: 14)
            HStack(spacing: 6) {
                Text(name)
                    .font(.row)
                    .foregroundStyle(Theme.textPrimary)
                    .layoutPriority(1)
                Text(directory)
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .truncationMode(.head)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HunkBars(hunks: hunkSizes)
            if let stats {
                LineStatsLabel(stats: stats)
            }
        }
        .padding(.horizontal, 10)
        .rowHeight(28)
        .contentShape(.rect)
        .hoverCard {
            FileHoverCard(path: path, previousPath: previousPath, kind: kind, stats: stats, badge: badge)
        }
    }

    /// The loaded hunks, else one bar for the whole file.
    private var hunkSizes: [Int] {
        if let hunks { return hunks }
        guard let stats, stats.additions + stats.deletions > 0 else { return [] }
        return [stats.additions + stats.deletions]
    }

    private var name: String { (path as NSString).lastPathComponent }
    private var directory: String { (path as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? "" }
    private var badge: FileBadge { FileBadge(kind: kind) }
}

/// One small bar per hunk, its width growing with the hunk's changed lines; one-line hunks are amber so
/// they are never skimmed.
struct HunkBars: View {
    let hunks: [Int]
    /// At most this many bars; a file with more shows the first ones.
    static let limit = 6

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(hunks.prefix(Self.limit).enumerated()), id: \.offset) { _, lines in
                RoundedRectangle(cornerRadius: 2)
                    .fill(lines == 1 ? Theme.warnFg : Theme.lineStrong)
                    .frame(width: Self.width(lines), height: 4)
            }
        }
        .fixedSize()
    }

    static func width(_ lines: Int) -> CGFloat {
        lines <= 1 ? 3 : min(3 + CGFloat(lines).squareRoot() * 1.4, 12)
    }
}

/// The letter of a file's change kind, e.g. `A` for an added file.
struct FileBadge {
    let letter: String
    let color: Color

    init(kind: FileChangeKind) {
        letter = switch kind {
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .conflicted: "!"
        case .unknown: "?"
        }
        color = Theme.changeColor(kind)
    }
}

/// A file's full path, rename source, kind and line counts.
private struct FileHoverCard: View {
    let path: String
    let previousPath: String?
    let kind: FileChangeKind
    let stats: LineStats?
    let badge: FileBadge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(badge.color.opacity(0.12), in: .capsule)
                if let tag = LanguageTag(path: path) { tag }
                Spacer(minLength: 4)
                if let stats { LineStatsLabel(stats: stats) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .font(.callout.weight(.semibold))
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let previousPath {
                HoverCardField(label: "Renamed", value: "from \(previousPath)", monospaced: true)
            }
        }
    }

}

extension FileChangeKind {
    /// `Modified`, `Added`, …, e.g. in a file's hover card and the inspector.
    var title: String {
        switch self {
        case .added: "Added"
        case .untracked: "Untracked"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type Changed"
        case .conflicted: "Conflicted"
        case .unknown: "Changed"
        }
    }
}

/// The branches of a stack, top first like `but status`.
private struct StackHoverCard: View {
    let branches: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stack · \(branches.count) branches")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(branches.enumerated()), id: \.offset) { index, branch in
                    HStack(spacing: 8) {
                        VStack(spacing: 0) {
                            Rectangle().fill(index == 0 ? .clear : Color.secondary.opacity(0.4)).frame(width: 1.5)
                            Circle().fill(index == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).frame(width: 7, height: 7)
                            Rectangle().fill(index == branches.count - 1 ? .clear : Color.secondary.opacity(0.4)).frame(width: 1.5)
                        }
                        .frame(width: 10)
                        Text(branch)
                            .font(.callout.weight(index == 0 ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(height: 24)
                }
            }
        }
    }
}
