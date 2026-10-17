import OhMyDiffCore
import SwiftUI

/// The detail pane in Changes mode: the selected file's diff.
struct DiffDetailView: View {
    let session: ProjectSession

    var body: some View {
        if let state = session.diff, let file = session.selectedFile {
            content(state.content, file: file)
        } else if session.phase == .ready && session.changeCount == 0 {
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle")
                .backgroundExtensionEffect()
        } else {
            ContentUnavailableView("No Selection", systemImage: "text.alignleft")
                .backgroundExtensionEffect()
        }
    }

    @ViewBuilder
    private func content(_ content: ProjectSession.DiffState.Content, file: ChangedFile) -> some View {
        switch content {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noDifference:
            ContentUnavailableView("No Differences", systemImage: "equal", description: Text("\(file.path) matches the last commit."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { session.refresh() }
            }
        case .diff(let diff):
            Group {
                if diff.isBinary {
                    ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("Binary changes cannot be shown."))
                } else if diff.hunks.isEmpty {
                    ContentUnavailableView(
                        diff.isModeChange ? "Mode Changed" : "Empty File", systemImage: "doc",
                        description: Text(diff.isModeChange ? "\(diff.oldMode ?? "") → \(diff.newMode ?? "")" : "The file has no content."))
                } else {
                    DiffTableView(fileID: file.id, diff: diff)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                DiffHeader(file: file, diff: diff)
            }
        }
    }
}

private struct DiffHeader: View {
    let file: ChangedFile
    let diff: FileDiff

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            if diff.isModeChange, !diff.hunks.isEmpty {
                Text("\(diff.oldMode ?? "") → \(diff.newMode ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            LineStatsLabel(stats: LineStats(additions: diff.additions, deletions: diff.deletions))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: String {
        if let oldPath = diff.oldPath, let newPath = diff.newPath, oldPath != newPath {
            return "\(oldPath) → \(newPath)"
        }
        return file.path
    }
}
