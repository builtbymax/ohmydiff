import AppKit
import OhMyDiffCore
import SwiftUI

/// The detail pane in History mode: the selected commit or branch, its files and the selected file's diff.
struct HistoryDetailView: View {
    @Bindable var history: HistoryModel
    let root: URL

    var body: some View {
        if let selection = history.selection, let branch = history.selectedBranch {
            VStack(spacing: 0) {
                if let commit = history.selectedCommit {
                    CommitHeader(commit: commit)
                } else {
                    BranchHeader(branch: branch)
                }
                Divider()
                files(for: selection)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "clock")
                .backgroundExtensionEffect()
        }
    }

    @ViewBuilder
    private func files(for selection: HistoryModel.Selection) -> some View {
        switch history.files {
        case .loading, nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            ContentUnavailableView("Nothing to Review", systemImage: "doc", description: Text(message))
        case .failed(let message):
            ContentUnavailableView("Could Not Load Diff", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded(let diffs) where diffs.isEmpty:
            ContentUnavailableView("No Changes", systemImage: "equal", description: Text("No files changed."))
        case .loaded(let diffs):
            HSplitView {
                List(selection: $history.selectedFileID) {
                    ForEach(diffs) { diff in
                        FileRow(path: diff.path, previousPath: diff.oldPath == diff.newPath ? nil : diff.oldPath, kind: diff.kind,
                                stats: diff.isBinary ? nil : LineStats(additions: diff.additions, deletions: diff.deletions))
                            .tag(diff.id)
                    }
                }
                .onKeyPress("n") { jumpToHunk(1) }
                .onKeyPress("p") { jumpToHunk(-1) }
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 420)

                Group {
                    if let file = history.selectedFile {
                        FileDiffView(fileID: "\(selection):\(file.id)", diff: file, highlights: history.highlights[file.id], root: root) { side in
                            await history.contents(of: file, side: side)
                        }
                    } else {
                        ContentUnavailableView("No File Selected", systemImage: "text.alignleft")
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func jumpToHunk(_ direction: Int) -> KeyPress.Result {
        NotificationCenter.default.post(name: .jumpToHunk, object: direction)
        return .handled
    }
}

private struct CommitHeader: View {
    let commit: CommitInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(commit.summary.isEmpty ? "(no message)" : commit.summary)
                    .font(.headline)
                    .textSelection(.enabled)
                Spacer()
                if commit.isConflicted {
                    Label("Conflicted", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                CopySHAButton(sha: commit.sha)
            }
            if !commit.body.isEmpty {
                ScrollView {
                    Text(commit.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text(commit.authorName)
                    .help(commit.authorEmail)
                if let date = commit.date {
                    Text("·")
                    Text(date, format: .relative(presentation: .named))
                        .help(date.formatted(date: .complete, time: .standard))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct BranchHeader: View {
    let branch: HistoryBranch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let label = BranchStatusLabel(branch: branch) { label }
            if !branch.tip.isEmpty { CopySHAButton(sha: branch.tip) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var summary: String {
        let count = branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits"
        guard let baseName = branch.baseName else { return count }
        return "\(count) · all changes since \(baseName)"
    }
}

/// The short SHA; clicking copies the full one.
private struct CopySHAButton: View {
    let sha: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sha, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : String(sha.prefix(7)), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.monospaced())
        }
        .buttonStyle(.borderless)
        .help("Copy full SHA (\(sha))")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
