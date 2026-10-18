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
            .navigationTitle(session.project.displayName)
            .navigationSubtitle(subtitle)
            .fileImporter(isPresented: $isLocating, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                Task { await model.relocate(session.project.id, to: url) }
            }
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
                Button("Remove from Sidebar") { model.remove(session.project.id) }
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
            List(selection: $session.selectedFileID) {
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.files) { file in
                            FileRow(path: file.path, previousPath: file.previousPath, kind: file.kind, stats: file.stats)
                                .tag(file.id)
                        }
                        if group.files.isEmpty {
                            Text("No assigned changes")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .selectionDisabled()
                        }
                    } header: {
                        ChangeGroupHeader(group: group)
                    }
                }
            }
            .onKeyPress("n") { jumpToHunk(1) }
            .onKeyPress("p") { jumpToHunk(-1) }
        }
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

    private var subtitle: String {
        if session.phase == .missing { return "Missing" }
        let kind = session.project.kind == .gitButler ? "GitButler" : "Git"
        return session.isRefreshing ? "\(kind) · Refreshing…" : kind
    }
}

private struct ChangeGroupHeader: View {
    let group: ChangeGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if case .stack(_, let branches) = group.kind {
                Image(systemName: branches.count > 1 ? "square.stack.3d.up" : "arrow.triangle.branch")
                VStack(alignment: .leading, spacing: 1) {
                    // Top of the stack first, like `but status`.
                    ForEach(branches, id: \.self) { Text($0).lineLimit(1).truncationMode(.middle) }
                }
            } else {
                Text(group.title)
            }
            Spacer()
            Text("\(group.files.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 8) {
            Text(badge.letter)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(badge.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
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

/// `+3 −1` in the usual diff colours; zero counts are left out.
struct LineStatsLabel: View {
    let stats: LineStats

    var body: some View {
        HStack(spacing: 4) {
            if stats.additions > 0 || stats.deletions == 0 {
                Text("+\(stats.additions)").foregroundStyle(.green)
            }
            if stats.deletions > 0 {
                Text("−\(stats.deletions)").foregroundStyle(.red)
            }
        }
        .font(.caption.monospacedDigit())
    }
}
