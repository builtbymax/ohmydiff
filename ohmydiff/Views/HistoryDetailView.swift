import AppKit
import OhMyDiffCore
import SwiftUI

/// The detail pane in History mode: the selected commit or branch, its files and the selected file's diff.
struct HistoryDetailView: View {
    @Bindable var history: HistoryModel
    let root: URL

    /// The commit details sidebar; stays open while moving between commits.
    @State private var isInfoShown = false
    @AppStorage(AppSettings.historyFilesWidthKey) private var filesWidth = 280.0

    var body: some View {
        if let selection = history.selection, let branch = history.selectedBranch {
            VStack(spacing: 0) {
                if let commit = history.selectedCommit {
                    CommitHeader(commit: commit, isInfoShown: $isInfoShown)
                } else {
                    BranchHeader(branch: branch, history: history)
                    if let pullRequest = history.pullRequest(of: branch), pullRequest.state == .open {
                        PullRequestBanner(pullRequest: pullRequest, history: history)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 6)
                    }
                }
                files(for: selection)
            }
            .overlay(alignment: .trailing) {
                if isInfoShown, let commit = history.selectedCommit {
                    CommitInfoPanel(commit: commit, branch: branch.name, remoteURL: history.remoteURL) { isInfoShown = false }
                        .padding(10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: isInfoShown)
        } else {
            EmptyState("No Selection", systemImage: "clock")
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
            EmptyState("Nothing to Review", systemImage: "doc", description: message)
        case .failed(let message):
            EmptyState("Could Not Load Diff", systemImage: "exclamationmark.triangle", description: message)
        case .loaded(let diffs) where diffs.isEmpty:
            EmptyState("No Changes", systemImage: "equal", description: "No files changed.")
        case .loaded(let diffs):
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Card {
                            Text(diffs.count == 1 ? "1 file" : "\(diffs.count) files")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } content: {
                            LazyVStack(spacing: 0) {
                                ForEach(diffs) { diff in
                                    Button { history.selectedFileID = diff.id } label: {
                                        FileRow(path: diff.path, previousPath: diff.oldPath == diff.newPath ? nil : diff.oldPath, kind: diff.kind,
                                                stats: diff.isBinary ? nil : LineStats(additions: diff.additions, deletions: diff.deletions),
                                                isSelected: history.selectedFileID == diff.id)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 7)
                                    }
                                    .buttonStyle(.row(isSelected: history.selectedFileID == diff.id))
                                    .id(diff.id)
                                }
                            }
                            .padding(4)
                        }
                        .padding(12)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { moveFile(1, in: diffs, proxy: proxy) }
                    .onKeyPress(.upArrow) { moveFile(-1, in: diffs, proxy: proxy) }
                    .onKeyPress("n") { jumpToHunk(1) }
                    .onKeyPress("p") { jumpToHunk(-1) }
                }
                .frame(width: filesWidth.clamped(to: AppSettings.historyFilesWidths))
                .overlay(alignment: .trailing) { ColumnResizer(width: $filesWidth, range: AppSettings.historyFilesWidths) }
                .zIndex(1)

                Group {
                    if let file = history.selectedFile {
                        FileDiffView(
                            fileID: "\(selection):\(file.id)", diff: file, highlights: history.highlights[file.id], root: root,
                            popout: .snapshot(
                                project: root.lastPathComponent, context: context(for: selection), diff: file,
                                highlights: history.highlights[file.id], root: root,
                                sources: (history.source(of: file, side: .old), history.source(of: file, side: .new)),
                                promptContext: history.promptContext(root: root)),
                            promptContext: history.promptContext(root: root)
                        ) { side in
                            await history.contents(of: file, side: side)
                        }
                    } else {
                        EmptyState("No File Selected", systemImage: "text.alignleft")
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// `feature/x` or `1ab49f8 on feature/x`, for a diff window's subtitle.
    private func context(for selection: HistoryModel.Selection) -> String {
        switch selection {
        case .branch(let name): name
        case .commit(let sha, let branch): "\(sha.prefix(7)) on \(branch)"
        }
    }

    private func moveFile(_ offset: Int, in diffs: [FileDiff], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !diffs.isEmpty else { return .ignored }
        let current = diffs.firstIndex { $0.id == history.selectedFileID }
        let next = current.map { min(max($0 + offset, 0), diffs.count - 1) } ?? 0
        history.selectedFileID = diffs[next].id
        proxy.scrollTo(diffs[next].id)
        return .handled
    }

    private func jumpToHunk(_ direction: Int) -> KeyPress.Result {
        NotificationCenter.default.post(name: .jumpToHunk, object: direction)
        return .handled
    }
}

/// The commit's subject, a two-line preview of its body and its author; the full message and more
/// live in the details sidebar.
private struct CommitHeader: View {
    let commit: CommitInfo
    @Binding var isInfoShown: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(commit.summary.isEmpty ? "(no message)" : commit.summary)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if !commit.body.isEmpty {
                    Text(commit.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentShape(.rect)
                        .onTapGesture { isInfoShown = true }
                }
                HStack(spacing: 6) {
                    AuthorAvatar(name: commit.authorName, size: 18)
                    Text(commit.authorName)
                        .fontWeight(.medium)
                    if let date = commit.date {
                        Text("·")
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if commit.isConflicted {
                    Label("Conflicted", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                CopySHAButton(sha: commit.sha)
                Button { isInfoShown.toggle() } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.hover(cornerRadius: 8, isSelected: isInfoShown))
                .focusEffectDisabled()
                .glassTooltip(isInfoShown ? "Hide Details" : "Show Details")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct BranchHeader: View {
    let branch: HistoryBranch
    let history: HistoryModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name)
                    .font(.system(size: 18, weight: .bold))
                    .textSelection(.enabled)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let label = BranchStatusLabel(branch: branch) { label }
            if !branch.tip.isEmpty { CopySHAButton(sha: branch.tip) }
            if let remoteURL = history.remoteURL, isOnRemote {
                Link(destination: remoteURL.appending(path: "tree").appending(path: branch.name)) {
                    Label("Open on \(RemoteHost(remoteURL).name)", systemImage: "arrow.up.right")
                }
                .buttonStyle(.pill(height: 28))
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Branches that were pushed and not yet cleaned up after merging.
    private var isOnRemote: Bool {
        switch branch.status {
        case .upToDate, .tracking, .unpushedCommits, .requiresForce: true
        case .unpushed, .integrated, .upstreamGone, nil: false
        }
    }

    private var summary: String {
        let count = branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits"
        guard let baseName = branch.baseName else { return count }
        return "\(count) · all changes since \(baseName)"
    }
}

/// `GitHub`, `GitLab` or the host of other remotes.
struct RemoteHost {
    let name: String

    init(_ url: URL) {
        name = switch url.host() {
        case "github.com": "GitHub"
        case "gitlab.com": "GitLab"
        case "bitbucket.org": "Bitbucket"
        case let host: host ?? "Remote"
        }
    }
}

/// A floating sidebar over the diff with a commit's full message, author, SHA and actions.
private struct CommitInfoPanel: View {
    let commit: CommitInfo
    let branch: String
    let remoteURL: URL?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(.secondary)
                Text("Commit")
                    .font(.callout.weight(.semibold))
                Text(commit.shortSHA)
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: .capsule)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.hoverCapsule())
                .focusEffectDisabled()
                .keyboardShortcut(.cancelAction)
                .glassTooltip("Close  esc")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(commit.summary.isEmpty ? "(no message)" : commit.summary)
                                .font(.system(size: 15, weight: .semibold))
                            if !commit.body.isEmpty {
                                Text(commit.body)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                            }
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    PanelCard {
                        HStack(spacing: 11) {
                            AuthorAvatar(name: commit.authorName, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.authorName.isEmpty ? "Unknown author" : commit.authorName)
                                    .font(.callout.weight(.semibold))
                                if !commit.authorEmail.isEmpty {
                                    Text(commit.authorEmail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            Spacer(minLength: 0)
                            if !commit.authorEmail.isEmpty {
                                CopyButton(text: commit.authorEmail, title: "Copy Email")
                            }
                        }
                    }

                    PanelCard(padding: 4) {
                        VStack(spacing: 0) {
                            if let date = commit.date {
                                InfoRow(systemImage: "calendar", title: "Authored") {
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(date.formatted(date: .abbreviated, time: .shortened))
                                        Text(date, format: .relative(presentation: .named))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Divider().padding(.leading, 38)
                            }
                            InfoRow(systemImage: "arrow.triangle.branch", title: "Branch") {
                                Text(branch).lineLimit(1).truncationMode(.middle)
                            }
                            Divider().padding(.leading, 38)
                            InfoRow(systemImage: "number", title: "SHA") {
                                HStack(spacing: 6) {
                                    Text(String(commit.sha.prefix(12)))
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                    CopyButton(text: commit.sha, title: "Copy Full SHA")
                                }
                            }
                            if commit.isConflicted {
                                Divider().padding(.leading, 38)
                                InfoRow(systemImage: "exclamationmark.triangle.fill", title: "Conflicted", tint: .red) {
                                    Text("Needs resolving").foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            VStack(spacing: 8) {
                if let commitURL {
                    Link(destination: commitURL) {
                        Label("Open on \(RemoteHost(commitURL).name)", systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pill(.prominent, height: 36))
                }
                HStack(spacing: 8) {
                    Button { copy(commit.message) } label: {
                        Label("Copy Message", systemImage: "text.quote").frame(maxWidth: .infinity)
                    }
                    if let commitURL {
                        Button { copy(commitURL.absoluteString) } label: {
                            Label("Copy Link", systemImage: "link").frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.pill(height: 32))
            }
            .focusEffectDisabled()
            .padding(12)
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 22))
        .shadow(color: Theme.overlayShadow, radius: 18, y: 6)
    }

    private var commitURL: URL? {
        remoteURL?.appending(path: "commit").appending(path: commit.sha)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A soft rounded group inside the details panel.
private struct PanelCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }
}

/// An icon, a label and its value on the right.
private struct InfoRow<Value: View>: View {
    let systemImage: String
    let title: String
    var tint: Color = .secondary
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 7))
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

/// A small icon button that copies `text` and briefly shows a checkmark.
private struct CopyButton: View {
    let text: String
    let title: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? AnyShapeStyle(Theme.addition) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.hoverCapsule())
        .focusEffectDisabled()
        .glassTooltip(copied ? "Copied" : title)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
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
        .glassTooltip(copied ? "Copied" : "Copy Full SHA")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
