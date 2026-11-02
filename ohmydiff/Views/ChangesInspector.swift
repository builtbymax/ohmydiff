import AppKit
import OhMyDiffCore
import SwiftUI

/// The right side of uncommitted changes on the Branches page: the selected file's kind, branch and facts, the
/// commits that last changed the current hunk, the file's recent history, its branch's ticket and pull request,
/// and copying its path or opening it.
struct ChangesInspector: View {
    let model: AppModel
    let session: ProjectSession

    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true

    var body: some View {
        VStack(spacing: 0) {
            head
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            if let file = session.selectedFile {
                InspectorFileContent(model: model, session: session, file: file)
                    .id(file.id)
            } else {
                EmptyState("No file selected", systemImage: "doc")
            }
        }
    }

    private var head: some View {
        HStack(spacing: 8) {
            Text("Inspector")
                .font(.row.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            KeyCap("⌥⌘I")
            IconButton("Hide Inspector  ⌥⌘I", systemImage: "xmark") {
                withAnimation(.snappy(duration: 0.2)) { isInspectorShown = false }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
    }
}

/// One file's sections and the footer, rebuilt when the selection moves to another file.
private struct InspectorFileContent: View {
    let model: AppModel
    let session: ProjectSession
    let file: ChangedFile

    @FocusedValue(\.diffHunk) private var focusedHunk
    @FocusedValue(\.diffFile) private var focusedFile
    @State private var facts: FileFacts?
    @State private var blame: [BlameCommit]?
    @State private var fileHistory: FileHistory?
    @State private var ticket: Ticket?

    private var history: HistoryModel { session.history }
    private var name: String { (file.path as NSString).lastPathComponent }
    private var directory: String { (file.path as NSString).deletingLastPathComponent }
    private var url: URL { session.rootURL.appending(path: file.path) }

    private var diff: FileDiff? {
        guard let state = session.diff, state.fileID == file.id, case .diff(let diff) = state.content else { return nil }
        return diff
    }

    /// The hunk at the top of the diff, else the first.
    private var currentHunk: (index: Int, hunk: Hunk)? {
        if let focusedHunk, focusedHunk.path == diff?.path { return (focusedHunk.index, focusedHunk.hunk) }
        return diff?.hunks.first.map { (0, $0) }
    }

    /// The top of the file's GitButler stack, or the checked-out branch; `nil` for unassigned changes.
    private var branchName: String? {
        session.project.kind == .gitButler ? session.assignedBranch(of: file.path) : session.currentBranch
    }

    private var branch: HistoryBranch? {
        guard let branchName else { return nil }
        return history.groups.lazy.flatMap(\.branches).first { $0.name == branchName }
    }

    private var pullRequest: PullRequest? { branch.flatMap(history.pullRequest(of:)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    fileSection
                    if let currentHunk { blameSection(currentHunk.index, currentHunk.hunk) }
                    if let fileHistory, !fileHistory.commits.isEmpty { historySection(fileHistory) }
                    if ticket != nil || pullRequest != nil { linkedSection }
                }
                .padding(16)
            }
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            footer
        }
        .task(id: session.lastRefreshed) {
            facts = await FileFacts.load(file: file, url: url, session: session)
            fileHistory = await session.fileHistory(of: file.path)
        }
        .task(id: blameKey) {
            guard let currentHunk else { return blame = nil }
            // Scrolling through hunks only asks git about the one it stops at.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let lines = Self.blamedLines(currentHunk.hunk) else { return blame = [] }
            blame = await session.blame(file.path, lines: lines)
        }
        .task(id: branchName) {
            guard let branchName else { return ticket = nil }
            // A branch looked up before shows its ticket at once; the tracker is only asked once per branch.
            if let known = history.tickets[branchName] { return ticket = known }
            guard let tickets = await session.suggestions()?.tickets, !tickets.isEmpty else { return }
            let found = await tickets.ticket(forBranch: branchName, pattern: AppSettings.ticketPattern())
            history.tickets[branchName] = .some(found)
            ticket = found
        }
    }

    private var blameKey: String {
        "\(session.lastRefreshed?.timeIntervalSinceReferenceDate ?? 0) \(currentHunk.map { "\($0.index) \($0.hunk.header)" } ?? "")"
    }

    /// The lines a hunk deletes, else the context it sits in; `nil` when HEAD has none of its lines.
    static func blamedLines(_ hunk: Hunk) -> ClosedRange<Int>? {
        let deleted = hunk.lines.filter { $0.kind == .deletion }.compactMap(\.oldLineNumber)
        let lines = deleted.isEmpty ? hunk.lines.compactMap(\.oldLineNumber) : deleted
        guard let first = lines.min(), let last = lines.max() else { return nil }
        return first...last
    }

    // MARK: File

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.hover, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.projectName)
                        .foregroundStyle(Theme.textPrimary)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.code(11))
                            .foregroundStyle(Theme.textTertiary)
                            .truncationMode(.head)
                    }
                }
                .lineLimit(1)
                .textSelection(.enabled)
            }
            FlowRow(spacing: 6) {
                Chip(file.kind.title, tone: Self.tone(file.kind))
                if let branchName {
                    Chip(branchName, systemImage: "arrow.triangle.branch", truncates: true)
                } else if session.project.kind == .gitButler {
                    Chip("Unassigned", systemImage: "tray")
                }
                if let stats = diff.map({ LineStats(additions: $0.additions, deletions: $0.deletions) }) ?? file.stats {
                    LineStatsLabel(stats: stats, font: .code(11.5))
                }
            }
            if let previousPath = file.previousPath {
                Text("from \(previousPath)")
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            facts.map(factsCard)
        }
    }

    private func factsCard(_ facts: FileFacts) -> some View {
        VStack(spacing: 0) {
            factRow("Language", facts.language)
            if let lines = facts.lines {
                let hunks = diff?.hunks.count ?? 0
                factRow("Lines", hunks == 0 ? "\(lines)" : "\(lines) · \(hunks == 1 ? "1 hunk" : "\(hunks) hunks")")
            }
            if let saved = facts.saved {
                factRow("Saved", "\(RelativeAge.short(saved)) ago")
            }
            if let encoding = facts.encoding {
                factRow("Encoding", encoding)
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Theme.textSecondary)
        }
        .font(.detail)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    static func tone(_ kind: FileChangeKind) -> Chip.Tone {
        switch kind {
        case .added, .untracked: .ok
        case .modified: .warn
        case .deleted, .conflicted: .danger
        case .renamed, .copied: .info
        case .typeChanged: .merged
        case .unknown: .neutral
        }
    }

    // MARK: Blame

    @ViewBuilder
    private func blameSection(_ index: Int, _ hunk: Hunk) -> some View {
        section("Hunk \(index + 1) · lines last changed in", trailing: "git blame") {
            switch blame {
            case nil:
                DelayedProgress().frame(maxWidth: .infinity).frame(height: 52)
            case let commits? where commits.isEmpty:
                note(Self.blamedLines(hunk) == nil ? "New lines, not committed before." : "Not committed before.")
            case let commits?:
                ForEach(commits.prefix(3)) { blamed in
                    Button { showInHistory(blamed.commit.sha) } label: { BlameRow(blamed: blamed) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: History

    private func historySection(_ fileHistory: FileHistory) -> some View {
        section("File history", trailing: fileHistory.count == 1 ? "1 commit" : "\(fileHistory.count) commits") {
            VStack(spacing: 0) {
                ForEach(fileHistory.commits) { commit in
                    Button { showInHistory(commit.id) } label: { HistoryRow(commit: commit) }
                        .buttonStyle(.hover(cornerRadius: 7))
                        .focusEffectDisabled()
                }
            }
        }
    }

    private func showInHistory(_ sha: String) {
        model.mode = .history
        session.log.filter = .all
        session.log.reveal(sha)
    }

    // MARK: Linked

    private var linkedSection: some View {
        section("Linked") {
            if let ticket {
                LinkedRow(systemImage: "ticket", id: ticket.id, title: ticket.title, url: ticket.url) {
                    Chip(ticket.source.displayName)
                }
            }
            if let pullRequest {
                LinkedRow(systemImage: "arrow.triangle.pull", id: "#\(pullRequest.number)", title: pullRequest.title, url: pullRequest.url) {
                    if pullRequest.state == .open, let status = history.pullRequestStatuses[pullRequest.number], status.checks != .none {
                        ChecksChip(checks: status.checks, isCompact: true)
                    } else {
                        Chip(pullRequest.stateTitle, tone: pullRequest.tone)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        let target = DiffFileTarget(url: url, relativePath: file.path, line: focusedFile?.relativePath == file.path ? focusedFile?.line : nil)
        return HStack(spacing: 8) {
            Button {
                model.copyPath(target)
                Toasts.shared.show("Copied the path of \(name)", systemImage: "doc.on.doc")
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
            .buttonStyle(.pill())
            Spacer(minLength: 8)
            Button { model.openInEditor(target) } label: {
                Label("Open in editor", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.pill(.prominent))
            .disabled(!target.exists)
        }
        .focusEffectDisabled()
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: Parts

    private func section(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.sectionLabel)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.caption11)
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.detail)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hover, in: .rect(cornerRadius: 9))
    }
}

/// What the meta card says about a file: read from its contents and the working tree.
private struct FileFacts {
    var language: String
    var lines: Int?
    var saved: Date?
    /// `UTF-8 · LF`; `nil` when the file could not be read.
    var encoding: String?

    static func load(file: ChangedFile, url: URL, session: ProjectSession) async -> FileFacts {
        let data = await session.contents(of: file, side: file.kind == .deleted ? .old : .new)
        let saved = file.kind == .deleted ? nil : try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let language = FileLanguage(path: file.path)?.name ?? "Plain text"
        guard let data else { return FileFacts(language: language, saved: saved) }
        guard let text = String(data: data, encoding: .utf8) else {
            return FileFacts(language: data.contains(0) ? "Binary" : language, saved: saved, encoding: data.contains(0) ? nil : "Unknown")
        }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        let lines = newlines + (data.last == 0x0A || data.isEmpty ? 0 : 1)
        let ending = text.contains("\r\n") ? "CRLF" : newlines > 0 ? "LF" : nil
        return FileFacts(language: language, lines: lines, saved: saved, encoding: ["UTF-8", ending].compactMap(\.self).joined(separator: " · "))
    }
}

/// `(B) Discard by hunk id  7be02d1 · builtbymax  40m`.
private struct BlameRow: View {
    let blamed: BlameCommit
    @State private var isHovered = false

    var body: some View {
        let commit = blamed.commit
        HStack(alignment: .top, spacing: 10) {
            Text(commit.authorName.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: 9.6, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
                .background(Theme.selected, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.summary)
                    .font(.control)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(commit.shortSHA) · \(commit.authorName)")
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let date = commit.date {
                Text(RelativeAge.short(date))
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isHovered ? Theme.selected : Theme.hover, in: .rect(cornerRadius: 9))
        .contentShape(.rect(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .glassTooltip(blamed.lineCount == 1 ? "1 line · Show in History" : "\(blamed.lineCount) lines · Show in History")
    }
}

/// `-o- Add diff layout and scope pickers  a41c9e2  12m`; unpushed commits get an amber dot.
private struct HistoryRow: View {
    let commit: LogCommit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.and.line.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(commit.isPushed ? Theme.textTertiary : Theme.warnFg)
                .frame(width: 13, height: 13)
                .glassTooltip(commit.isPushed ? "Pushed" : "Not pushed")
            Text(commit.commit.summary)
                .font(.control)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(commit.commit.shortSHA)
                .font(.code(11))
                .foregroundStyle(Theme.textTertiary)
            if let date = commit.commit.date {
                Text(RelativeAge.short(date))
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(minWidth: 18, alignment: .trailing)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .contentShape(.rect)
    }
}

/// A ticket or pull request: its icon, id and title, and a chip; opens it in the browser.
private struct LinkedRow<Trailing: View>: View {
    let systemImage: String
    let id: String
    let title: String
    let url: URL?
    @ViewBuilder var trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 14)
                Text(id)
                    .font(.code(11.5))
                    .foregroundStyle(Theme.textTertiary)
                Text(title)
                    .font(.control)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 34)
            .background(isHovered ? Theme.selected : Theme.hover, in: .rect(cornerRadius: 9))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(url == nil)
    }
}
