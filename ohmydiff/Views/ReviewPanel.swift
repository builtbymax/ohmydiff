import AppKit
import OhMyDiffCore
import SwiftUI

/// The right side of the Pull requests page: where to look first, the files with their viewed state, and
/// commenting, asking for changes or reviewing the diff in ohmydiff.
struct ReviewPanel: View {
    let model: AppModel
    let session: ProjectSession
    let item: InboxPullRequest

    @Environment(\.openWindow) private var openWindow
    @State private var composing: ReviewVerdict?
    @State private var isOpening = false

    private var inbox: PullRequestsModel { session.pullRequests }
    private var files: PullRequestFiles? { inbox.files[item.number] }

    var body: some View {
        VStack(spacing: 0) {
            head
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if item.state == .open {
                        FocusCard(session: session, item: item) { path, hunk in open(path: path, hunk: hunk) }
                    }
                    filesSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            footer
                .padding(.horizontal, 20)
                .frame(height: 60)
        }
        // Again after the pull request changed, e.g. a new push.
        .task(id: item) {
            await inbox.loadFiles(of: item.number)
            await session.history.loadDetail(of: item.pullRequest)
        }
    }

    // MARK: Head

    private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if inbox.needsYou(item) {
                    Chip("Review requested", systemImage: "eye", tone: .info)
                } else {
                    Chip(item.pullRequest.stateTitle, systemImage: item.pullRequest.systemImage, tone: item.pullRequest.tone)
                }
                if item.state == .open { ChecksChip(checks: item.checks) }
                Spacer(minLength: 8)
                IconButton("Open on GitHub", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(item.url) }
            }
            .frame(height: 28)
            Text(item.title)
                .font(.panelTitle)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Avatar(login: item.author, isInverse: true)
                Text(inbox.isMine(item) ? "you" : item.author)
                    .font(.detail)
                    .foregroundStyle(Theme.textSecondary)
                Text("· \(item.baseRefName) ← \(item.headRefName) · \(item.changedFiles) \(item.changedFiles == 1 ? "file" : "files") · +\(item.additions) −\(item.deletions)")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: Files

    @ViewBuilder private var filesSection: some View {
        HStack(spacing: 6) {
            Text("Files")
                .font(.sectionLabel)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            if let files {
                Text("\(files.files.count { $0.isViewed }) of \(files.files.count) viewed")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(height: 24)
        if let files {
            VStack(spacing: 1) {
                ForEach(files.files) { file in
                    ReviewFileRow(file: file) {
                        Task { await inbox.toggleViewed(file, in: item.number) }
                    } open: {
                        open(path: file.path, hunk: nil)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if item.state == .open {
                composeButton(.comment, title: "Comment", systemImage: "bubble.left", style: .pill(.ghost))
            }
            Spacer(minLength: 8)
            if item.state == .open, !inbox.isMine(item) {
                composeButton(.requestChanges, title: "Request changes", systemImage: nil, style: .pill(height: 32))
            }
            Button { open(path: nil, hunk: nil) } label: {
                HStack(spacing: 6) {
                    if isOpening {
                        ProgressView().controlSize(.mini).tint(Theme.textInverse)
                    } else {
                        Image(systemName: "doc.text").font(.system(size: 11.5))
                    }
                    Text("Review in ohmydiff")
                    KeyCap("↩", onInverse: true)
                }
            }
            .buttonStyle(.pill(.prominent, height: 32))
            .keyboardShortcut(.defaultAction)
            .disabled(isOpening)
        }
        .disabled(inbox.isSubmitting)
    }

    private func composeButton(_ verdict: ReviewVerdict, title: String, systemImage: String?, style: PillButtonStyle) -> some View {
        Button { composing = verdict } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(style)
        .popover(isPresented: Binding(get: { composing == verdict }, set: { if !$0 { composing = nil } }), arrowEdge: .top) {
            ReviewComposer(verdict: verdict, item: item, inbox: inbox) { composing = nil }
        }
    }

    /// The pull request's diff in a review window, at a file and hunk when given.
    private func open(path: String?, hunk: Int?) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            guard let diffs = await inbox.loadDiff(of: item.number), let first = diffs.first else { return }
            let selected = path.flatMap { path in diffs.first { $0.path == path } } ?? first
            let snapshot = DiffSnapshot(
                project: session.project.displayName, context: "#\(item.number) · \(item.title)", root: session.rootURL,
                files: diffs.map { DiffSnapshot.File(diff: $0, sources: (nil, nil)) },
                selectedID: selected.id, highlights: [:], promptContext: nil)
            openWindow(id: DiffWindow.id, value: model.register(.snapshot(snapshot)))
            if let hunk {
                // The window scrolls to the hunk once its table is up.
                try? await Task.sleep(for: .milliseconds(400))
                NotificationCenter.default.post(name: .jumpToHunkIndex, object: hunk - 1)
            }
        }
    }
}

/// A file of the pull request: viewed, status letter, name, folder and line counts.
private struct ReviewFileRow: View {
    let file: PullRequestFile
    let toggleViewed: () -> Void
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        let badge = FileBadge(kind: file.kind)
        HStack(spacing: 8) {
            Button(action: toggleViewed) {
                Image(systemName: file.isViewed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(file.isViewed ? Theme.okFg : Theme.textTertiary)
                    .frame(width: 13, height: 13)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(file.isViewed ? "Mark as not viewed" : "Mark as viewed")
            Text(badge.letter)
                .font(.statusLetter)
                .foregroundStyle(badge.color)
            Text((file.path as NSString).lastPathComponent)
                .font(.control)
                .foregroundStyle(file.isViewed ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
            Text((file.path as NSString).deletingLastPathComponent)
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            LineStatsLabel(stats: LineStats(additions: file.additions, deletions: file.deletions))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(isHovered ? Theme.hover : .clear, in: .rect(cornerRadius: 7))
        .contentShape(.rect(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
    }
}

/// Where to look first: the AI's pick of the hunks that change behaviour.
private struct FocusCard: View {
    let session: ProjectSession
    let item: InboxPullRequest
    let open: (String, Int) -> Void

    private var inbox: PullRequestsModel { session.pullRequests }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.infoFg)
                    .frame(width: 14, height: 14)
                Text("Where to look first")
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Chip(providerTitle, systemImage: "apple.terminal")
            }
            switch inbox.focus[item.number] {
            case nil:
                Text("Find the few hunks that change behaviour, so moved and renamed code can wait.")
                    .font(.control)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: find) { Label("Find hunks", systemImage: "sparkles") }
                    .buttonStyle(.pill(.prominent))
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Reading the diff…").font(.detail).foregroundStyle(Theme.textTertiary)
                }
            case .failed(let message):
                AIErrorNote(message: message)
                Button(action: find) { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.pill(.prominent))
            case .loaded(let summary, let hunks):
                if !summary.isEmpty {
                    Text(summary)
                        .font(.control)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(hunks) { hunk in
                    FocusRow(hunk: hunk, isOneLine: isOneLine(hunk)) { open(hunk.path, hunk.hunk) }
                }
            }
            Text("Sent: the PR diff (\(item.changedFiles) \(item.changedFiles == 1 ? "file" : "files")) and its description. Nothing else.")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    private func find() {
        Task {
            let description = session.history.details[item.number]?.body ?? ""
            await inbox.findFocus(for: item, description: description, suggestions: await session.suggestions())
        }
    }

    private func isOneLine(_ hunk: PullRequestsModel.FocusHunk) -> Bool {
        guard let diff = inbox.diffs[item.number]?.first(where: { $0.path == hunk.path }), diff.hunks.indices.contains(hunk.hunk - 1) else { return false }
        return diff.hunks[hunk.hunk - 1].isOneLineChange
    }

    private var providerTitle: String {
        guard let provider = AppSettings.suggestionProvider() else { return "No provider" }
        let model = AppSettings.model(for: .pullRequest)
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }
}

private struct FocusRow: View {
    let hunk: PullRequestsModel.FocusHunk
    let isOneLine: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text((hunk.path as NSString).lastPathComponent)
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("hunk \(hunk.hunk)")
                        .font(.code(11))
                        .foregroundStyle(Theme.textTertiary)
                    if isOneLine { Chip("1 line", tone: .warn) }
                }
                Text(hunk.reason)
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(isHovered ? Theme.selected : Theme.hover, in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
    }
}

/// A comment, or the reason for requesting changes, sent with `gh`.
private struct ReviewComposer: View {
    let verdict: ReviewVerdict
    let item: InboxPullRequest
    let inbox: PullRequestsModel
    let dismiss: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verdict == .comment ? "Comment on #\(item.number)" : "Request changes on #\(item.number)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            TextEditor(text: $text)
                .font(.control)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(6)
                .frame(height: 110)
                .background(Theme.hover, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Theme.lineStrong : Theme.line))
            HStack(spacing: 6) {
                Text(verdict == .comment ? "gh pr comment \(item.number)" : "gh pr review \(item.number) --request-changes")
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", action: dismiss)
                    .buttonStyle(.pill(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { if await inbox.submit(verdict, body: text, on: item) { dismiss() } }
                } label: {
                    HStack(spacing: 6) {
                        Text(verdict == .comment ? "Comment" : "Request changes")
                        KeyCap("⌘↩", onInverse: true)
                    }
                }
                .buttonStyle(.pill(.prominent))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inbox.isSubmitting)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { isFocused = true }
    }
}
