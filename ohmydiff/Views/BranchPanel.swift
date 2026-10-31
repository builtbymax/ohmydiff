import AppKit
import OhMyDiffCore
import SwiftUI

/// The right side of the Branches page: the branch's pull request with its checks, linked ticket and
/// description, or what it takes to open one.
struct BranchPanel: View {
    let model: AppModel
    let session: ProjectSession
    let branch: HistoryBranch

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var ticket: Ticket?
    @State private var suggestions: Suggestions?

    private var history: HistoryModel { session.history }
    private var pullRequest: PullRequest? { history.pullRequest(of: branch) }
    private var detail: PullRequestDetail? { pullRequest.flatMap { history.details[$0.number] } }
    private var status: PullRequestStatus? { pullRequest.flatMap { history.pullRequestStatuses[$0.number] } }

    var body: some View {
        VStack(spacing: 0) {
            head
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let status, status.isMergeable == false, let pullRequest {
                        ConflictSteps(session: session, branch: branch, pullRequest: pullRequest)
                    }
                    if let detail, !detail.checks.isEmpty {
                        checks(detail)
                    }
                    if let ticket {
                        section("Linked ticket") { TicketRow(ticket: ticket) }
                    }
                    description
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            footer
                .padding(.horizontal, 20)
                .frame(height: 60)
        }
        .task(id: branch.name) {
            history.selection = .branch(branch.name)
            suggestions = await session.suggestions()
            if let tickets = suggestions?.tickets, !tickets.isEmpty {
                ticket = await tickets.ticket(forBranch: branch.name, pattern: AppSettings.ticketPattern())
            }
        }
        .task(id: pullRequest?.number) {
            guard let pullRequest else { return }
            await history.loadDetail(of: pullRequest)
            // Follow running checks while the panel is open.
            while !Task.isCancelled, history.details[pullRequest.number]?.runningCheckCount ?? 0 > 0 {
                try? await Task.sleep(for: .seconds(20))
                await history.loadDetail(of: pullRequest)
                await history.loadStatus(of: pullRequest)
            }
        }
    }

    // MARK: Head

    @ViewBuilder private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let pullRequest {
                    Chip(pullRequest.stateTitle, systemImage: pullRequest.systemImage, tone: pullRequest.tone)
                    if pullRequest.state == .open, let status {
                        ChecksChip(checks: status.checks)
                        switch status.isMergeable {
                        case true?: Chip("No conflicts", systemImage: "checkmark")
                        case false?: Chip("Conflicts with \(pullRequest.baseRefName)", systemImage: "xmark", tone: .danger)
                        case nil: EmptyView()
                        }
                    }
                    if detail?.autoMerge == true {
                        Chip("Merges when green", systemImage: "arrow.triangle.merge", tone: .merged)
                    }
                } else {
                    Chip("No pull request", systemImage: "arrow.triangle.pull")
                    if branch.isConflicted { Chip("conflicted", systemImage: "exclamationmark.triangle", tone: .danger) }
                }
                Spacer(minLength: 8)
                if let pullRequest {
                    IconButton("Copy Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
                        Toasts.shared.show("Copied the link to #\(pullRequest.number)", systemImage: "doc.on.doc")
                    }
                    IconButton("Open on GitHub", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(pullRequest.url) }
                }
            }
            .frame(height: 28)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pullRequest?.title ?? branch.name)
                    .font(.panelTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let pullRequest {
                    Text("#\(pullRequest.number)")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: 6) {
                Chip(pullRequest?.baseRefName ?? branch.baseName ?? "main", systemImage: "arrow.triangle.branch")
                Text("←")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                Chip(branch.name, systemImage: "arrow.triangle.branch", isEmphasized: true)
                Text(byline)
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// `· 3 commits · builtbymax`.
    private var byline: String {
        let count = detail?.commitCount ?? branch.commits.count
        var parts = ["\(count) \(count == 1 ? "commit" : "commits")"]
        if let author = detail?.author ?? branch.commits.first?.authorName { parts.append(author) }
        return "· " + parts.joined(separator: " · ")
    }

    // MARK: Body

    private func checks(_ detail: PullRequestDetail) -> some View {
        section("Checks", trailing: detail.runningCheckCount > 0 ? "\(detail.runningCheckCount) running" : nil) {
            VStack(spacing: 0) {
                ForEach(detail.checks) { check in
                    CheckRow(check: check)
                }
            }
        }
    }

    @ViewBuilder private var description: some View {
        let body = detail?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasDraft = history.drafts[branch.name] != nil || history.drafting.contains(branch.name) || history.draftErrors[branch.name] != nil
        section("Description", trailing: pullRequest != nil && detail != nil && body.isEmpty ? "empty on GitHub" : nil) {
            if !body.isEmpty, !hasDraft {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownText(text: body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.hover, in: .rect(cornerRadius: 9))
                    Button { draft() } label: {
                        Label("Redraft with AI", systemImage: "sparkles")
                    }
                    .buttonStyle(.pill(.ghost))
                }
            } else {
                DraftCard(
                    branch: branch, history: history, ticket: ticket, changedFiles: detail?.changedFiles,
                    primaryTitle: pullRequest == nil ? "Create pull request" : "Use as description",
                    draft: draft, use: useDraft, openTemplate: { SettingsWindow.open(.templates, with: openSettings) })
            }
        }
    }

    private func section(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            content()
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if let pullRequest, pullRequest.state == .open {
                Text("\(mergeMethodTitle) · delete branch")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                reviewButton
                MergeButton(history: history, pullRequest: pullRequest, branch: branch.name, status: status, detail: detail)
            } else if let pullRequest {
                Text(pullRequest.state == .merged ? "Merged into \(pullRequest.baseRefName)" : "Closed without merging")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                reviewButton
            } else {
                Spacer(minLength: 8)
                reviewButton
                if history.canPush(branch) {
                    Button { history.requestPush(branch) } label: {
                        Label(branch.needsForcePush ? "Force push" : "Push", systemImage: "arrow.up")
                    }
                    .buttonStyle(.pill(height: 32))
                }
                if history.canOpenPullRequest(branch) {
                    Button { history.requestPullRequestDraft(branch) } label: {
                        Label("Pull request…", systemImage: "arrow.triangle.pull")
                    }
                    .buttonStyle(.pill(.prominent, height: 32))
                }
            }
        }
        .disabled(history.branchActivity != nil)
    }

    private var reviewButton: some View {
        Button(action: review) {
            Label("Review", systemImage: "eye")
        }
        .buttonStyle(.pill(height: 32))
        .disabled(!canReview)
    }

    private var mergeMethodTitle: String { "Squash" }

    private var canReview: Bool {
        guard history.selection == .branch(branch.name), case .loaded(let diffs) = history.files else { return false }
        return !diffs.isEmpty
    }

    /// The branch's whole diff in a review window.
    private func review() {
        guard canReview, case .loaded(let diffs) = history.files, let first = diffs.first, let base = branch.base else { return }
        let snapshot = DiffSnapshot(
            project: session.project.displayName, context: "\(branch.name) · \(branch.commits.count) commits", root: session.rootURL,
            files: diffs.map { diff in
                DiffSnapshot.File(diff: diff, sources: (
                    diff.oldPath.map { RevisionFile(revision: base, path: $0) },
                    diff.newPath.map { RevisionFile(revision: branch.tip, path: $0) }))
            },
            selectedID: first.id, highlights: [:], promptContext: nil)
        openWindow(id: DiffWindow.id, value: model.register(.snapshot(snapshot)))
    }

    // MARK: Drafting

    private func draft() {
        Task { await history.draftDescription(for: branch, ticket: ticket, suggestions: suggestions) }
    }

    private func useDraft() {
        if let pullRequest {
            Task { await history.useDraft(for: branch, on: pullRequest) }
        } else if let text = history.drafts[branch.name] {
            Task {
                do {
                    try await history.createPullRequest(branch: branch.name, text: text, isDraft: false)
                    history.drafts[branch.name] = nil
                } catch {
                    history.branchActionError = String(describing: error)
                }
            }
        }
    }
}

/// One check of a pull request: its state, name and how long it ran.
private struct CheckRow: View {
    let check: PullRequestDetail.Check

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 14, height: 14)
            Text(check.name)
                .font(.control)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(trailing)
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(height: 28)
    }

    @ViewBuilder private var icon: some View {
        switch check.state {
        case .passed: Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.okFg)
        case .failed: Image(systemName: "xmark.circle").font(.system(size: 12)).foregroundStyle(Theme.delFg)
        case .running: ProgressView().controlSize(.mini).tint(Theme.warnFg)
        case .queued: Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        case .skipped: Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        }
    }

    /// `1m 52s`, `running`, `queued`.
    private var trailing: String {
        switch check.state {
        case .running: return "running"
        case .queued: return "queued"
        case .skipped: return "skipped"
        case .passed, .failed:
            guard let duration = check.duration else { return check.state == .failed ? "failed" : "" }
            let seconds = Int(duration.components.seconds)
            return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        }
    }
}

/// The ticket the branch name points at.
private struct TicketRow: View {
    let ticket: Ticket
    @State private var isHovered = false

    var body: some View {
        Button {
            if let url = ticket.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "ticket")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 14)
                Text(ticket.id)
                    .font(.code(11.5))
                    .foregroundStyle(Theme.textTertiary)
                Text(ticket.title)
                    .font(.control)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Chip(ticket.source.displayName)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isHovered ? Theme.selected : Theme.hover, in: .rect(cornerRadius: 9))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(ticket.url == nil)
    }
}

/// The AI drafted description: where it comes from, the draft, and using it.
private struct DraftCard: View {
    let branch: HistoryBranch
    let history: HistoryModel
    let ticket: Ticket?
    let changedFiles: Int?
    let primaryTitle: String
    let draft: () -> Void
    let use: () -> Void
    let openTemplate: () -> Void

    var body: some View {
        let text = history.drafts[branch.name]
        let isDrafting = history.drafting.contains(branch.name)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.infoFg)
                    .frame(width: 14, height: 14)
                Text("Draft description")
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Chip(providerTitle, systemImage: "apple.terminal")
            }
            HStack(spacing: 6) {
                Text("From")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                Chip("\(branch.commits.count) \(branch.commits.count == 1 ? "commit" : "commits")", systemImage: "circle.and.line.horizontal")
                if let changedFiles {
                    Chip("\(changedFiles) \(changedFiles == 1 ? "file" : "files")", systemImage: "doc")
                }
                if let ticket { Chip(ticket.id, systemImage: "ticket") }
                Chip("PR template", systemImage: "doc.text")
            }
            if isDrafting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Drafting from the commits, diff and ticket…")
                        .font(.detail)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.hover, in: .rect(cornerRadius: 9))
            } else if let error = history.draftErrors[branch.name] {
                AIErrorNote(message: error)
            } else if let text {
                MarkdownText(text: text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.hover, in: .rect(cornerRadius: 9))
            }
            HStack(spacing: 6) {
                if text != nil, !isDrafting {
                    Button(primaryTitle, action: use)
                        .buttonStyle(.pill(.prominent))
                    Button(action: draft) { Label("Regenerate", systemImage: "arrow.clockwise") }
                        .buttonStyle(.pill(.ghost))
                } else {
                    Button(action: draft) {
                        Label(history.draftErrors[branch.name] == nil ? "Draft" : "Retry", systemImage: history.draftErrors[branch.name] == nil ? "sparkles" : "arrow.clockwise")
                    }
                    .buttonStyle(.pill(.prominent))
                    .disabled(isDrafting)
                }
                Spacer(minLength: 8)
                Button(action: openTemplate) { Label("Template", systemImage: "doc.text") }
                    .buttonStyle(.pill(.ghost))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    private var providerTitle: String {
        guard let provider = AppSettings.suggestionProvider() else { return "No provider" }
        let model = AppSettings.model(for: .pullRequest)
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }
}

/// An AI failure inside the card that caused it: the reason, and the command output in mono.
struct AIErrorNote: View {
    let message: String

    var body: some View {
        let lines = message.split(separator: "\n", maxSplits: 1).map(String.init)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.delFg)
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                Text(lines.first ?? message)
                    .font(.control)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lines.count > 1 {
                Text(lines[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.hover, in: .rect(cornerRadius: 8))
            }
        }
    }
}

/// Markdown in the card style: headings as semibold primary lines, the rest secondary.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.isHeading {
                    Text(block.text)
                        .font(.control.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .font(.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [(text: String, isHeading: Bool)] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                return (trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces), true)
            }
            return (trimmed, false)
        }
    }
}

/// Merge when green, or Merge once checks passed, with the other ways in its menu.
private struct MergeButton: View {
    let history: HistoryModel
    let pullRequest: PullRequest
    let branch: String
    let status: PullRequestStatus?
    let detail: PullRequestDetail?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primary) {
                HStack(spacing: 8) {
                    Image(systemName: pullRequest.isDraft ? "checkmark.circle" : "arrow.triangle.merge").font(.system(size: 12))
                    Text(primaryTitle)
                        .lineLimit(1)
                }
                .fixedSize()
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Rectangle().fill(Theme.textInverse.opacity(0.25)).frame(width: 1, height: 16)
            Menu {
                ForEach(MergeMethod.allCases, id: \.self) { method in
                    Button(method.title + " Now") { history.pendingMerge = (pullRequest, method, branch) }
                }
                Divider()
                ForEach(MergeMethod.allCases, id: \.self) { method in
                    Button("\(method.rawValue.capitalized) When Green") {
                        Task { await history.setAutoMerge(true, pullRequest: pullRequest, method: method, branch: branch) }
                    }
                }
                if detail?.autoMerge == true {
                    Button("Cancel Auto-Merge") { Task { await history.setAutoMerge(false, pullRequest: pullRequest, method: .squash, branch: branch) } }
                }
                Divider()
                Button(pullRequest.isDraft ? "Mark Ready for Review" : "Convert to Draft") {
                    Task { await history.setDraft(!pullRequest.isDraft, pullRequest: pullRequest, branch: branch) }
                }
                Button("Refresh Status") {
                    Task {
                        await history.loadPullRequest(for: branch, force: true)
                        await history.loadDetail(of: pullRequest)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 32)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .font(.control.weight(.medium))
        .foregroundStyle(Theme.textInverse)
        .background(Theme.inverse, in: .rect(cornerRadius: 9))
        .fixedSize()
    }

    private var isGreen: Bool {
        guard let status else { return false }
        switch status.checks {
        case .passed, .none: return status.isMergeable != false
        default: return false
        }
    }

    private var primaryTitle: String {
        if pullRequest.isDraft { return "Mark ready" }
        if detail?.autoMerge == true { return "Cancel auto-merge" }
        return isGreen ? "Merge" : "Merge when green"
    }

    private func primary() {
        if pullRequest.isDraft {
            Task { await history.setDraft(false, pullRequest: pullRequest, branch: branch) }
        } else if detail?.autoMerge == true {
            Task { await history.setAutoMerge(false, pullRequest: pullRequest, method: .squash, branch: branch) }
        } else if isGreen {
            history.pendingMerge = (pullRequest, .squash, branch)
        } else {
            Task { await history.setAutoMerge(true, pullRequest: pullRequest, method: .squash, branch: branch) }
        }
    }
}

/// A pull request that conflicts with its base: the three steps to fix it, each with the command it runs.
private struct ConflictSteps: View {
    let session: ProjectSession
    let branch: HistoryBranch
    let pullRequest: PullRequest

    var body: some View {
        let isGitButler = session.project.kind == .gitButler
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text("#\(pullRequest.number) can’t merge")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Chip("Conflicts with \(pullRequest.baseRefName)", systemImage: "xmark", tone: .danger)
            }
            step(
                1, title: "Update from \(pullRequest.baseRefName)", command: isGitButler ? "but pull" : "git pull",
                isDone: session.upstream?.hasUpdates != true
            ) {
                Button("Update…") { NotificationCenter.default.post(name: .showUpstreamUpdate, object: nil) }
                    .buttonStyle(.pill(height: 26))
            }
            step(2, title: "Resolve the conflicts in your editor", command: isGitButler ? "but resolve" : "git status", isDone: false) {
                EmptyView()
            }
            step(3, title: "Mark resolved and push", command: isGitButler ? "but resolve finish · but push" : "git commit · git push", isDone: false) {
                if session.history.canPush(branch) {
                    Button("Push") { session.history.requestPush(branch) }
                        .buttonStyle(.pill(.prominent, height: 26))
                }
            }
        }
    }

    private func step(_ number: Int, title: String, command: String, isDone: Bool, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            Group {
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.okFg)
                } else {
                    Text("\(number)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 22, height: 22)
            .background(isDone ? Theme.okBg : Theme.hover, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.row.weight(.medium))
                    .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                Text(command)
                    .font(.code(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isDone { action() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isDone ? Color.clear : Theme.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

extension Notification.Name {
    /// Opens the update-from-upstream sheet, e.g. from a conflicted pull request's steps.
    static let showUpstreamUpdate = Notification.Name("ohmydiff.showUpstreamUpdate")
}
