import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The middle pane in Changes mode: the selected project's change groups.
struct ChangesListView: View {
    let model: AppModel
    @Bindable var session: ProjectSession

    @State private var isLocating = false

    var body: some View {
        content
            .butCompatibilityBanner(session.butIncompatibility)
            .fileImporter(isPresented: $isLocating, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                Task { await model.relocate(session.project.id, to: url) }
            }
            .changeActionPresentation(session)
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            EmptyState("Folder Not Found", systemImage: "questionmark.folder", description: "\(session.project.path) was moved or deleted.") {
                Button("Locate…") { isLocating = true }
                Button("Remove Project") { model.remove(session.project.id) }
                    .buttonStyle(.pill(.destructive))
                Button("Try Again") { session.refresh() }
            }
        case .failed(let message):
            EmptyState("Could Not Load Project", systemImage: "exclamationmark.triangle", description: message) {
                Button("Try Again") { session.refresh() }
            }
        case .ready where visibleGroups.isEmpty:
            EmptyState("No Changes", systemImage: "checkmark.circle", description: "The working tree is clean.")
        case .ready:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(visibleGroups) { group in
                            ChangeGroupCard(group: group, session: session)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, session.selectedFiles.count > 1 ? 72 : 16)
                }
                .overlay(alignment: .bottom) {
                    if session.selectedFiles.count > 1 {
                        SelectionBar(session: session)
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: session.selectedFiles.count > 1)
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
                    if let reveal { withAnimation(.snappy) { proxy.scrollTo(reveal.fileID) } }
                }
            }
        }
    }

    /// Selects the next or previous file across all groups.
    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let files = visibleGroups.flatMap(\.files)
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

    /// Applied GitButler stacks are always listed; other groups only when they contain files.
    private var visibleGroups: [ChangeGroup] {
        session.groups.filter { group in
            if case .stack = group.kind { return true }
            return !group.files.isEmpty
        }
    }
}

/// A change group as a card: the branch (or Staged, Unassigned…) on top, its files below.
private struct ChangeGroupCard: View {
    let group: ChangeGroup
    let session: ProjectSession

    var body: some View {
        Card {
            ChangeGroupHeader(group: group)
                .contextMenu { ChangeActionMenu(session: session, targets: group.files.map { ChangeTarget(file: $0) }, isGroup: true) }
        } content: {
            if group.files.isEmpty {
                Text("No changes on this branch")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                // Lazy, so a group of thousands of untracked files only builds the rows on screen.
                LazyVStack(spacing: 3) {
                    ForEach(group.files) { file in
                        ChangeFileRow(file: file, session: session)
                    }
                }
                .padding(4)
            }
        }
    }
}

/// A file of a group. It reads the selection itself, so selecting another file only updates the rows
/// whose state changes instead of every card.
private struct ChangeFileRow: View {
    let file: ChangedFile
    let session: ProjectSession

    var body: some View {
        let isSelected = session.isSelected(file.id)
        Button { select() } label: {
            FileRow(path: file.path, previousPath: file.previousPath, kind: file.kind, stats: file.stats, isSelected: isSelected)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
        }
        .buttonStyle(.row(isSelected: isSelected))
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

/// `3 files selected` with the actions every selected file supports, over the bottom of the list.
private struct SelectionBar: View {
    let session: ProjectSession

    var body: some View {
        let targets = session.selectedFiles.map { ChangeTarget(file: $0) }
        HStack(spacing: 8) {
            Button { session.clearExtraSelection() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.hoverCapsule())
            .focusEffectDisabled()
            .glassTooltip("Clear Selection  esc", edge: .top)
            Text("\(targets.count) files")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .fixedSize()
            Spacer(minLength: 4)
            if session.supports(.stage, on: targets) {
                Button("Stage") { session.request(.stage, on: targets) }
                    .buttonStyle(.pill(height: 30))
            }
            if session.supports(.unstage, on: targets) {
                Button("Unstage") { session.request(.unstage, on: targets) }
                    .buttonStyle(.pill(height: 30))
            }
            if session.supports(.commit, on: targets) {
                Button { session.request(.commit, on: targets) } label: { Label("Commit…", systemImage: "checkmark") }
                    .buttonStyle(.pill(.prominent, height: 30))
            }
            if session.supports(.discard, on: targets) {
                Button { session.request(.discard, on: targets) } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.pill(.destructive, height: 30))
                .glassTooltip("Discard Changes…", edge: .top)
            }
        }
        .focusEffectDisabled()
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 44)
        .glassEffect(Theme.barGlass, in: .capsule)
        .shadow(color: Theme.overlayShadow, radius: 12, y: 4)
        .padding(.horizontal, 12)
    }
}

private struct ChangeGroupHeader: View {
    let group: ChangeGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .stack(_, let branches) = group.kind, let top = branches.first {
                Text(top)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if branches.count > 1 {
                    Text("+ \(branches.count - 1) below")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .hoverCard { StackHoverCard(branches: branches) }
                }
            } else {
                Text(group.title)
            }
            Spacer(minLength: 4)
            Text("\(group.files.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary.opacity(0.8))
        .contentShape(.rect)
    }

    private var icon: String {
        switch group.kind {
        case .stack(_, let branches): branches.count > 1 ? "square.stack.3d.up" : "arrow.triangle.branch"
        case .unassigned: "tray"
        case .staged: "checkmark.circle"
        case .unstaged: "pencil"
        case .untracked: "questionmark.circle"
        case .conflicted: "exclamationmark.triangle"
        }
    }
}

/// A changed file: its kind badge, name, directory and line counts.
struct FileRow: View {
    let path: String
    /// Source path of a rename or copy.
    let previousPath: String?
    let kind: FileChangeKind
    let stats: LineStats?
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            Text(badge.letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(badge.color)
                .frame(width: 22, height: 22)
                .badgeTile(badge.color, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(1)
                if !directory.isEmpty {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let stats {
                LineStatsLabel(stats: stats)
            }
        }
        .hoverCard {
            FileHoverCard(path: path, previousPath: previousPath, kind: kind, stats: stats, badge: badge)
        }
    }

    private var name: String { (path as NSString).lastPathComponent }
    private var directory: String { (path as NSString).deletingLastPathComponent }

    private var badge: FileBadge { FileBadge(kind: kind) }
}

/// The letter and color of a file's change kind, e.g. a green `A` for an added file.
struct FileBadge {
    let letter: String
    let color: Color

    init(kind: FileChangeKind) {
        (letter, color) = switch kind {
        case .added: ("A", Theme.changeAdded)
        case .untracked: ("U", Theme.changeAdded)
        case .deleted: ("D", Theme.changeDeleted)
        case .modified: ("M", Theme.changeModified)
        case .renamed: ("R", Theme.changeMoved)
        case .copied: ("C", Theme.changeMoved)
        case .typeChanged: ("T", Theme.changeTypeChanged)
        case .conflicted: ("!", Theme.changeConflicted)
        case .unknown: ("?", .secondary)
        }
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
                Text(kindTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(badge.color.opacity(Theme.badgeTintOpacity), in: .capsule)
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

    private var kindTitle: String {
        switch kind {
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
