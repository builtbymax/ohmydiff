import OhMyDiffCore
import SwiftUI

/// A commit being written: the message, the branch it goes to and the AI suggestion for it. One per
/// project, so a message survives switching files and pages.
@Observable
final class CommitDraft {
    var message = ""
    /// The applied branch picked in the composer; empty to follow the selection.
    var branch = ""
    private(set) var isGenerating = false
    var suggestionError: Error?
    var error: String?
    /// GitButler: the branch the changes build on, after `but commit` refused them for the picked branch.
    var dependency: (branch: String, anchor: String)?
    @ObservationIgnored private var task: Task<Void, Never>?

    var hasMessage: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The first line, shown as the title in the composer.
    var title: String { message.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces) }

    /// Asks the AI provider for a message from `targets`. Never commits.
    func generate(_ session: ProjectSession, targets: [ChangeTarget], branch: String, isExistingBranch: Bool, ticket: Ticket? = nil) {
        task?.cancel()
        suggestionError = nil
        isGenerating = true
        task = Task {
            defer { isGenerating = false }
            do {
                guard let suggestions = await session.suggestions() else { throw SuggestionUnavailable.noToolchain }
                _ = try suggestions.suggester()
                let diff = try await session.patch(for: targets)
                let commits = isExistingBranch ? await session.commitLog(ofBranch: branch) : ""
                var ticket = ticket
                if ticket == nil, !suggestions.tickets.isEmpty {
                    ticket = await suggestions.tickets.ticket(forBranch: branch, pattern: AppSettings.ticketPattern())
                }
                let text = try await suggestions.commitMessage(TemplateContext(diff: diff, commits: commits, branch: branch, ticket: ticket))
                guard !Task.isCancelled else { return }
                message = text
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                suggestionError = error
            }
        }
    }

    /// Commits `targets` to `branch`; on success the message is cleared.
    func commit(_ session: ProjectSession, targets: [ChangeTarget], branch: String, stackedOn anchor: String? = nil) async -> Bool {
        error = nil
        dependency = nil
        do {
            try await session.run(.commit, on: targets, branch: branch, stackedOn: anchor, message: message)
            message = ""
            return true
        } catch {
            if case ChangeActionError.dependsOn(let anchor) = error { dependency = (branch, anchor) }
            self.error = String(describing: error)
            return false
        }
    }

    func cancel() {
        task?.cancel()
        isGenerating = false
    }
}

/// The card at the bottom of the file list: where the commit goes, its message, ✦ Generate and Commit.
struct CommitComposer: View {
    let session: ProjectSession
    @Bindable var draft: CommitDraft
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            target
            editor
            if let warning = formatWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption11)
                    .foregroundStyle(Theme.warnFg)
            }
            if let error = draft.suggestionError {
                SuggestionNotice(error: error)
            } else if let error = draft.error {
                Text(error)
                    .font(.detail)
                    .foregroundStyle(Theme.delFg)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            actions
        }
        .padding(10)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 2)
        .onReceive(NotificationCenter.default.publisher(for: .tryCommitTemplate)) { _ in
            if !targets.isEmpty { generate() }
        }
    }

    /// The title against Settings → Templates → Commit format: its length and style.
    private var formatWarning: String? {
        guard draft.hasMessage else { return nil }
        let limit = AppSettings.titleLimit()
        if draft.title.count > limit { return "Title is \(draft.title.count) characters, over the \(limit) limit" }
        return AppSettings.commitStyle().problem(with: draft.title)
    }

    // MARK: Parts

    /// `Commit to ⑂ feat/diff-modes ⌄` (GitButler) or `Commit ✓ 2 staged` (git).
    @ViewBuilder
    private var target: some View {
        HStack(spacing: 6) {
            if isGitButler {
                Text("Commit to")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                Menu {
                    ForEach(session.branchNames, id: \.self) { name in
                        Button(name) { draft.branch = name }
                    }
                    if session.branchNames.isEmpty {
                        Text("No applied branches")
                    }
                    Divider()
                    Button("New Branch…") { openCard() }
                        .disabled(cardTargets.isEmpty)
                } label: {
                    HStack(spacing: 4) {
                        Chip(branch.isEmpty ? "Pick a branch" : branch, systemImage: "arrow.triangle.branch", isEmphasized: true)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 12, height: 12)
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            } else {
                Text("Commit")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                let count = targets.count
                Chip(count == 0 ? "nothing staged" : "\(count) staged", systemImage: count == 0 ? nil : "checkmark", tone: count == 0 ? .neutral : .ok)
                if let branch = session.currentBranch {
                    Text("to")
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                    Button(action: openCard) {
                        HStack(spacing: 4) {
                            Chip(branch, systemImage: "arrow.triangle.branch", isEmphasized: true)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 12, height: 12)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(targets.isEmpty)
                    .help("Commit to another or a new branch")
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The title in medium, the body below it; editable in place.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if !draft.hasMessage && !isEditing {
                Text(draft.isGenerating ? "Writing a message…" : "Message")
                    .font(.row)
                    .foregroundStyle(Theme.textTertiary)
                    .allowsHitTesting(false)
            } else if !isEditing {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title)
                        .font(.row.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    let body = draft.message.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        Text(body)
                            .font(.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(2)
                            .lineLimit(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { isEditing = true }
            }
            TextEditor(text: $draft.message)
                .font(.row)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isEditing)
                .frame(minHeight: 54, maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isEditing ? 1 : 0)
                .allowsHitTesting(isEditing || !draft.hasMessage)
                .padding(.leading, -5)
        }
        .frame(minHeight: 36, alignment: .topLeading)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button { generate() } label: {
                Label {
                    Text(draft.isGenerating ? "Generating…" : draft.hasMessage ? "Regenerate" : "Generate")
                } icon: {
                    if draft.isGenerating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles").foregroundStyle(Theme.infoFg)
                    }
                }
            }
            .buttonStyle(.pill(.ghost, height: 26))
            .disabled(draft.isGenerating || targets.isEmpty)
            .focusEffectDisabled()
            Spacer(minLength: 4)
            if let dependency = draft.dependency, dependency.branch == branch {
                Button("On top of \(dependency.anchor)") { commit(stackedOn: dependency.anchor) }
                    .buttonStyle(.pill(height: 28))
                    .disabled(!canCommit)
                    .glassTooltip("Create \(dependency.branch) stacked on \(dependency.anchor) and commit to it", edge: .top)
            }
            Button { commit() } label: {
                HStack(spacing: 6) {
                    if session.isPerformingAction {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Commit")
                    }
                    KeyCap("⌘↩", onInverse: true)
                }
            }
            .buttonStyle(.pill(.prominent, height: 28))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCommit)
            .focusEffectDisabled()
        }
    }

    // MARK: Logic

    private var isGitButler: Bool { session.project.kind == .gitButler }

    /// The picked branch, else the selected file's lane, else the first applied branch; the checked-out one in git.
    private var branch: String {
        guard isGitButler else { return session.currentBranch ?? "" }
        if !draft.branch.isEmpty, session.branchNames.contains(draft.branch) { return draft.branch }
        return session.selectedFile.flatMap { session.assignedBranch(of: $0.path) } ?? session.branchNames.first ?? ""
    }

    /// git: everything staged. GitButler: the target branch's lane, plus the files selected in Unassigned.
    private var targets: [ChangeTarget] {
        if !isGitButler {
            return session.groups.first { $0.kind == .staged }?.files.map { ChangeTarget(file: $0) } ?? []
        }
        var files = session.groups.first {
            if case .stack(_, let branches) = $0.kind { return branches.contains(branch) }
            return false
        }?.files ?? []
        let unassigned = session.selectedFiles.filter { session.assignedBranch(of: $0.path) == nil }
        files += unassigned.filter { file in !files.contains(file) }
        return files.map { ChangeTarget(file: $0) }
    }

    /// What the commit card commits: the composer's targets, else the selected files.
    private var cardTargets: [ChangeTarget] {
        targets.isEmpty ? session.selectedFiles.map { ChangeTarget(file: $0) } : targets
    }

    /// The commit card for these changes, starting from the composer's message, e.g. for a new branch.
    private func openCard() {
        let targets = cardTargets
        guard session.supports(.commit, on: targets) else { return }
        session.actionRequest = ProjectSession.ActionRequest(action: .commit, targets: targets, fromComposer: true)
    }

    private var canCommit: Bool {
        // Not while the commit card is open: it owns ⌘↩ then.
        !branch.isEmpty && draft.hasMessage && !targets.isEmpty && !session.isPerformingAction && session.actionRequest == nil
            && session.supports(.commit, on: targets)
    }

    private func generate() {
        draft.generate(session, targets: targets, branch: branch, isExistingBranch: true)
    }

    private func commit(stackedOn anchor: String? = nil) {
        guard canCommit else { return }
        let targets = targets
        let branch = branch
        isEditing = false
        Task { _ = await draft.commit(session, targets: targets, branch: branch, stackedOn: anchor) }
    }
}
