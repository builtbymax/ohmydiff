import AppKit
import OhMyDiffCore
import SwiftUI

/// The History page: the log of every branch as a graph, and the selected commit in the inspector.
struct HistoryPageView: View {
    let model: AppModel
    let session: ProjectSession
    @Bindable var log: CommitLogModel
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true

    init(model: AppModel, session: ProjectSession) {
        self.model = model
        self.session = session
        self.log = session.log
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isInspectorShown {
                Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                CommitInspector(model: model, session: session, log: log)
                    .frame(width: 460)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .task {
            log.isActive = true
            await session.refreshLog()
        }
        .onDisappear { log.isActive = false }
        .alert(
            "Could not undo the commit",
            isPresented: Binding(get: { log.actionError != nil }, set: { if !$0 { log.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(log.actionError ?? "")
        }
    }

    @ViewBuilder
    private var list: some View {
        switch log.phase {
        case .idle:
            DelayedProgress()
        case .failed(let message):
            EmptyState("Could not load the history", systemImage: "exclamationmark.triangle", description: message) {
                Button("Try again") { Task { await session.refreshLog() } }
            }
        case .ready:
            let visible = log.visible
            if visible.isEmpty {
                EmptyState(log.search.isEmpty ? "No commits yet" : "No matching commits", systemImage: "clock.arrow.circlepath")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // By the first commit: the graph's order is not by date, so a day can head more than one section.
                            ForEach(sections(visible), id: \.items.first?.commit.id) { section in
                                // The day sits next to the graph, whose lanes run on through it.
                                HStack(spacing: 10) {
                                    GraphPassage(lanes: log.drawsGraph ? section.items.first?.row.above ?? [] : [])
                                        .frame(width: 60, height: 32)
                                    Text(section.title)
                                        .font(.sectionLabel)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                ForEach(section.items, id: \.commit.id) { item in
                                    CommitRow(
                                        commit: item.commit, row: item.row, drawsGraph: log.drawsGraph,
                                        pullRequest: pullRequest(for: item.commit), isSelected: item.commit.id == log.selectedID
                                    ) { log.selectedID = item.commit.id }
                                    .id(item.commit.id)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { move(1, in: visible, proxy: proxy) }
                    .onKeyPress(.upArrow) { move(-1, in: visible, proxy: proxy) }
                    .onKeyPress(.return) {
                        openInReview()
                        return .handled
                    }
                }
            }
        }
    }

    private func move(_ offset: Int, in visible: [(commit: LogCommit, row: GraphRow)], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !visible.isEmpty else { return .ignored }
        let index = visible.firstIndex { $0.commit.id == log.selectedID } ?? -1
        let next = visible[min(max(index + offset, 0), visible.count - 1)].commit.id
        log.selectedID = next
        proxy.scrollTo(next)
        return .handled
    }

    private func openInReview() {
        NotificationCenter.default.post(name: .openCommitInReview, object: nil)
    }

    /// The pull request of the branch a commit is the tip of.
    private func pullRequest(for commit: LogCommit) -> PullRequest? {
        for branch in commit.branches {
            if case .some(.some(let pullRequest)) = session.history.pullRequests[branch] { return pullRequest }
        }
        return nil
    }

    /// Today, Yesterday, then the day.
    private func sections(_ items: [(commit: LogCommit, row: GraphRow)]) -> [(title: String, items: [(commit: LogCommit, row: GraphRow)])] {
        var result: [(title: String, items: [(commit: LogCommit, row: GraphRow)])] = []
        let calendar = Calendar.current
        for item in items {
            let date = item.commit.commit.date ?? .distantPast
            let title = calendar.isDateInToday(date) ? "Today"
                : calendar.isDateInYesterday(date) ? "Yesterday"
                : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append((title, [item]))
            }
        }
        return result
    }
}

extension Notification.Name {
    /// Opens the selected History commit in a diff window.
    static let openCommitInReview = Notification.Name("ohmydiff.openCommitInReview")
}

/// A commit in the log: its place in the graph, message, branches and tags, author, SHA and age.
private struct CommitRow: View {
    let commit: LogCommit
    let row: GraphRow
    let drawsGraph: Bool
    let pullRequest: PullRequest?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                GraphCell(row: row, isPushed: commit.isPushed, drawsLines: drawsGraph)
                    .frame(width: 60, height: 40)
                Text(commit.commit.summary)
                    .font(.row.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(commit.branches.prefix(2), id: \.self) { branch in
                    Chip(branch, systemImage: "arrow.triangle.branch", isEmphasized: true)
                }
                if let pullRequest {
                    Chip("#\(pullRequest.number)", systemImage: "arrow.triangle.pull", tone: pullRequest.state == .merged ? .merged : .ok)
                }
                ForEach(commit.tags.prefix(1), id: \.self) { tag in
                    Chip(tag, systemImage: "checkmark")
                }
                Text(commit.commit.authorName.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Theme.hover, in: .circle)
                    .glassTooltip(commit.commit.authorName)
                Text(commit.commit.shortSHA)
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                Text(commit.commit.date.map { RelativeAge.short($0) } ?? "")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.trailing, 10)
            .frame(height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 8, isSelected: isSelected))
        .focusEffectDisabled()
    }
}

/// The graph of one row: lanes passing through, the commit's dot, and lines to its parents.
private struct GraphCell: View {
    let row: GraphRow
    let isPushed: Bool
    let drawsLines: Bool

    private static let spacing: CGFloat = 12
    private static let maxLanes = 4

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let x = Self.x
            if drawsLines {
                for lane in row.above {
                    var path = Path()
                    path.move(to: CGPoint(x: x(lane), y: 0))
                    if row.merging.contains(lane) {
                        path.addQuadCurve(to: CGPoint(x: x(row.lane), y: middle), control: CGPoint(x: x(lane), y: middle))
                    } else if lane == row.lane || row.below.contains(lane) {
                        path.addLine(to: CGPoint(x: x(lane), y: lane == row.lane ? middle : size.height))
                    }
                    context.stroke(path, with: .color(Self.color(lane)), lineWidth: 1.5)
                }
                for lane in row.below where !row.above.contains(lane) || lane == row.lane {
                    var path = Path()
                    if row.forking.contains(lane), lane != row.lane {
                        path.move(to: CGPoint(x: x(row.lane), y: middle))
                        path.addQuadCurve(to: CGPoint(x: x(lane), y: size.height), control: CGPoint(x: x(lane), y: middle))
                    } else if lane == row.lane {
                        path.move(to: CGPoint(x: x(lane), y: middle))
                        path.addLine(to: CGPoint(x: x(lane), y: size.height))
                    } else {
                        path.move(to: CGPoint(x: x(lane), y: middle))
                        path.addLine(to: CGPoint(x: x(lane), y: size.height))
                    }
                    context.stroke(path, with: .color(Self.color(lane)), lineWidth: 1.5)
                }
            }
            let dot = CGRect(x: x(row.lane) - 4, y: middle - 4, width: 8, height: 8)
            if isPushed {
                context.fill(Path(ellipseIn: dot), with: .color(Self.color(row.lane)))
            } else {
                context.fill(Path(ellipseIn: dot), with: .color(Theme.canvas))
                context.stroke(Path(ellipseIn: dot.insetBy(dx: 0.75, dy: 0.75)), with: .color(Theme.warnFg), lineWidth: 1.5)
            }
        }
    }

    static func x(_ lane: Int) -> CGFloat { 14 + CGFloat(min(lane, maxLanes)) * spacing }

    /// The first lane is the main line; the others take the state colours in turn.
    static func color(_ lane: Int) -> Color {
        let colors = [Theme.textPrimary, Theme.okFg, Theme.mergedFg, Theme.infoFg, Theme.warnFg]
        return colors[lane % colors.count]
    }
}

/// The graph's lanes running straight through a day's heading, so the lines are not cut between days.
private struct GraphPassage: View {
    let lanes: [Int]

    var body: some View {
        Canvas { context, size in
            for lane in lanes {
                var path = Path()
                path.move(to: CGPoint(x: GraphCell.x(lane), y: 0))
                path.addLine(to: CGPoint(x: GraphCell.x(lane), y: size.height))
                context.stroke(path, with: .color(GraphCell.color(lane)), lineWidth: 1.5)
            }
        }
    }
}

/// The selected commit: its branch and push state, message, author, files, a hunk of the selected file,
/// and undoing it or opening it whole.
private struct CommitInspector: View {
    let model: AppModel
    let session: ProjectSession
    @Bindable var log: CommitLogModel
    @State private var confirming: CommitLogModel.UndoAction?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let commit = log.selectedCommit {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        head(commit)
                        Rectangle().fill(Theme.lineSubtle).frame(height: 1)
                        files(commit)
                    }
                }
                Rectangle().fill(Theme.lineSubtle).frame(height: 1)
                footer(commit)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCommitInReview)) { _ in openInReview(commit) }
        } else {
            EmptyState("No commit selected", systemImage: "circle.and.line.horizontal")
        }
    }

    private func head(_ commit: LogCommit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let branch = commit.branches.first ?? branch(of: commit) {
                    Chip(branch, systemImage: "arrow.triangle.branch", isEmphasized: true)
                }
                if commit.isPushed {
                    Chip("Pushed", systemImage: "checkmark", tone: .ok)
                } else {
                    Chip("Not pushed", systemImage: "arrow.up", tone: .warn)
                }
                Spacer(minLength: 4)
                IconButton("Copy SHA", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.id, forType: .string)
                }
                if let url = session.history.remoteURL {
                    IconButton("Open on GitHub", systemImage: "arrow.up.forward.square") {
                        NSWorkspace.shared.open(url.appending(path: "commit/\(commit.id)"))
                    }
                    .disabled(!commit.isPushed)
                }
                Menu {
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.commit.message, forType: .string)
                    }
                    Button("Copy SHA") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.id, forType: .string)
                    }
                    Divider()
                    Button("Revert…") { confirming = .revert }
                        .disabled(!log.canUndo(.revert, commit))
                    Button("Uncommit…") { confirming = .uncommit }
                        .disabled(!log.canUndo(.uncommit, commit))
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.hover(cornerRadius: 8))
                .fixedSize()
            }
            Text(commit.commit.summary)
                .font(.panelTitle)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !commit.commit.body.isEmpty {
                Text(commit.commit.body)
                    .font(.control)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(commit.commit.authorName.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textInverse)
                    .frame(width: 20, height: 20)
                    .background(Theme.inverse, in: .circle)
                Text(commit.commit.authorName)
                    .font(.detail)
                    .foregroundStyle(Theme.textSecondary)
                if let date = commit.commit.date {
                    Text("· \(Self.dateTitle(date)) ·")
                        .font(.detail)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(commit.commit.shortSHA)
                    .font(.code(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                if let parent = commit.parents.first {
                    Button { log.selectedID = parent } label: {
                        Text("← \(parent.prefix(7))")
                            .font(.code(11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .glassTooltip("Show Parent")
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func files(_ commit: LogCommit) -> some View {
        switch log.files {
        case .loading, nil:
            DelayedProgress().frame(maxWidth: .infinity).padding(20)
        case .failed(let message):
            Text(message).font(.detail).foregroundStyle(Theme.delFg).padding(20)
        case .loaded(let diffs):
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(diffs.count == 1 ? "1 file" : "\(diffs.count) files")
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    LineStatsLabel(stats: LineStats(
                        additions: diffs.reduce(0) { $0 + $1.additions }, deletions: diffs.reduce(0) { $0 + $1.deletions }))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                ForEach(diffs) { diff in
                    Button {
                        log.selectedFileID = diff.id
                        log.selectedHunk = 0
                    } label: {
                        FileRow(
                            path: diff.path, previousPath: diff.oldPath == diff.newPath ? nil : diff.oldPath, kind: diff.kind,
                            stats: LineStats(additions: diff.additions, deletions: diff.deletions), hunks: diff.hunks.map(\.size),
                            isSelected: diff.id == log.selectedFile?.id)
                    }
                    .buttonStyle(.row(isSelected: diff.id == log.selectedFile?.id))
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if let file = log.selectedFile, !file.hunks.isEmpty {
                HunkBox(file: file, index: $log.selectedHunk)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
        }
    }

    private func footer(_ commit: LogCommit) -> some View {
        HStack(spacing: 6) {
            if log.canUndo(.revert, commit) {
                Button { confirming = .revert } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.pill(.ghost))
            }
            if log.canUndo(.uncommit, commit) {
                Button { confirming = .uncommit } label: { Label("Uncommit", systemImage: "arrow.down") }
                    .buttonStyle(.pill(.ghost))
            }
            Spacer(minLength: 4)
            Button { openInReview(commit) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 12))
                    Text("Open in Review")
                    KeyCap("↩")
                }
            }
            .buttonStyle(.pill())
            .disabled(!(log.files.map { if case .loaded = $0 { true } else { false } } ?? false))
        }
        .focusEffectDisabled()
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottomLeading) {
            if let confirming {
                ConfirmCard(
                    title: confirming == .revert ? "Revert \(commit.commit.shortSHA)?" : "Uncommit \(commit.commit.shortSHA)?",
                    message: confirming == .revert
                        ? "Adds a commit to \(session.currentBranch ?? "the branch") that undoes “\(commit.commit.summary)”. The original stays in history."
                        : log.isGitButler
                            ? "Moves its changes back to uncommitted. GitButler keeps it in the oplog, so but undo brings it back."
                            : "Moves its changes back to staged. git reflog still has the commit.",
                    confirmTitle: confirming == .revert ? "Revert" : "Uncommit",
                    isDestructive: confirming == .uncommit,
                    cancel: { self.confirming = nil }
                ) {
                    let action = confirming
                    self.confirming = nil
                    Task { await log.perform(action, on: commit) }
                }
                .padding(.leading, 16)
                .padding(.bottom, 52)
                .popoverTransition(anchor: .bottomLeading)
            }
        }
        .animation(Theme.popoverAnimation, value: confirming)
    }

    /// The branch a commit belongs to: the nearest branch tip above it in the log.
    private func branch(of commit: LogCommit) -> String? {
        guard let index = log.commits.firstIndex(where: { $0.id == commit.id }) else { return nil }
        return log.commits[...index].reversed().lazy.compactMap(\.branches.first).first
    }

    private func openInReview(_ commit: LogCommit) {
        guard case .loaded(let diffs) = log.files, let selected = log.selectedFile ?? diffs.first else { return }
        let root = session.rootURL
        let snapshot = DiffSnapshot(
            project: session.project.displayName, context: "\(commit.commit.shortSHA) · \(commit.commit.summary)", root: root,
            files: diffs.map { DiffSnapshot.File(diff: $0, sources: (log.source(of: $0, side: .old, commit: commit), log.source(of: $0, side: .new, commit: commit))) },
            selectedID: selected.id, highlights: [:], promptContext: nil)
        openWindow(id: DiffWindow.id, value: model.register(.snapshot(snapshot)))
    }

    static func dateTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " \(time)"
    }
}

/// One hunk of a file, compact: its range and size, `2 of 3` to move between hunks, and its lines.
struct HunkBox: View {
    let file: FileDiff
    @Binding var index: Int

    var body: some View {
        let current = min(index, file.hunks.count - 1)
        let hunk = file.hunks[current]
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                if hunk.isOneLineChange {
                    Chip("1-line change", systemImage: "eye", tone: .warn)
                }
                Spacer(minLength: 4)
                if file.hunks.count > 1 {
                    Button { index = (current + file.hunks.count - 1) % file.hunks.count } label: {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                Text("\(current + 1) of \(file.hunks.count)")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                if file.hunks.count > 1 {
                    Button { index = (current + 1) % file.hunks.count } label: {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.hunkBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
            ForEach(Array(hunk.lines.prefix(40).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(line.oldLineNumber.map(String.init) ?? "")
                            .frame(width: 22, alignment: .trailing)
                        Text(line.newLineNumber.map(String.init) ?? "")
                            .frame(width: 22, alignment: .trailing)
                    }
                    .font(.code(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(width: 64, alignment: .trailing)
                    Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
                        .font(.code(11.5))
                        .foregroundStyle(line.kind == .addition ? Theme.addFg : Theme.delFg)
                        .frame(width: 10, alignment: .leading)
                    Text(line.text)
                        .font(.code(11.5))
                        .foregroundStyle(line.kind == .context ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 20)
                .background(line.kind == .addition ? Theme.addBg : line.kind == .deletion ? Theme.delBg : .clear)
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

/// The small card that confirms a destructive action where it was started: what goes, how to get it back.
struct ConfirmCard: View {
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive = true
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.row.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.detail)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button(action: cancel) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyCap("esc")
                    }
                }
                .buttonStyle(.pill(.ghost))
                .keyboardShortcut(.cancelAction)
                Button(action: confirm) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                        Text(confirmTitle)
                        KeyCap("↩")
                    }
                }
                .buttonStyle(.pill(isDestructive ? .destructive : .normal))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .popoverSurface(in: .rect(cornerRadius: 12))
    }
}
