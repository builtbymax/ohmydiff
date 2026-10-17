import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The middle pane in Changes mode: the selected project's change groups.
struct ChangesListView: View {
    let model: AppModel
    let session: ProjectSession

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
        case .ready where session.changeCount == 0:
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
        case .ready:
            List {
                ForEach(session.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            ChangedFileRow(file: file)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.files.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        if session.phase == .missing { return "Missing" }
        let kind = session.project.kind == .gitButler ? "GitButler" : "Git"
        return session.isRefreshing ? "\(kind) · Refreshing…" : kind
    }
}

private struct ChangedFileRow: View {
    let file: ChangedFile

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
        }
        .help(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    private var name: String { (file.path as NSString).lastPathComponent }
    private var directory: String { (file.path as NSString).deletingLastPathComponent }

    private var badge: (letter: String, color: Color) {
        switch file.kind {
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
