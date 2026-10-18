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
            ContentUnavailableView {
                Label("Folder Not Found", systemImage: "questionmark.folder")
            } description: {
                Text("\(session.project.path) was moved or deleted.")
            } actions: {
                Button("Locate…") { isLocating = true }
                Button("Remove Project") { model.remove(session.project.id) }
                Button("Try Again") { session.refresh() }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load Project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { session.refresh() }
            }
        case .ready where visibleGroups.isEmpty:
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
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
                    .padding(.bottom, 16)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveSelection(1, proxy: proxy) }
                .onKeyPress(.upArrow) { moveSelection(-1, proxy: proxy) }
                .onKeyPress("n") { jumpToHunk(1) }
                .onKeyPress("p") { jumpToHunk(-1) }
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
    @Bindable var session: ProjectSession

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
                VStack(spacing: 0) {
                    ForEach(group.files) { file in
                        Button { session.selectedFileID = file.id } label: {
                            FileRow(path: file.path, previousPath: file.previousPath, kind: file.kind, stats: file.stats,
                                    isSelected: session.selectedFileID == file.id)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.row(isSelected: session.selectedFileID == file.id))
                        .id(file.id)
                        .contextMenu { ChangeActionMenu(session: session, targets: [ChangeTarget(file: file)], isGroup: false) }
                    }
                }
                .padding(4)
            }
        }
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
                        // Top of the stack first, like `but status`.
                        .help(branches.joined(separator: "\n"))
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
                .background(badge.color.opacity(0.14), in: .rect(cornerRadius: 6))
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
        .help(previousPath.map { "\($0) → \(path)" } ?? path)
    }

    private var name: String { (path as NSString).lastPathComponent }
    private var directory: String { (path as NSString).deletingLastPathComponent }

    private var badge: (letter: String, color: Color) {
        switch kind {
        case .added: ("A", .green)
        case .untracked: ("U", .green)
        case .deleted: ("D", .red)
        case .modified: ("M", .orange)
        case .renamed: ("R", .blue)
        case .copied: ("C", .blue)
        case .typeChanged: ("T", .purple)
        case .conflicted: ("!", .red)
        case .unknown: ("?", .secondary)
        }
    }
}
