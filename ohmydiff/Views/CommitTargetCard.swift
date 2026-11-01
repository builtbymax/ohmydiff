import OhMyDiffCore
import SwiftUI

/// Commits files or hunks: to an applied branch (1–9), or to a new one the AI names, stacked when the
/// changes build on another branch. A card over the page, never a modal.
struct CommitTargetCard: View {
    let session: ProjectSession
    let request: ProjectSession.ActionRequest
    let dismiss: () -> Void

    @State private var branch = ""
    @State private var isNewBranch = false
    @State private var newBranch = ""
    @State private var isNameSuggested = false
    @State private var alternatives: [String] = []
    @State private var message = ""
    @State private var error: String?
    /// GitButler: the branch the changes build on, after `but commit` refused them for the picked branch.
    @State private var dependency: (branch: String, anchor: String)?
    @State private var stacksOnDependency = true
    @State private var suggestions: Suggestions?
    @State private var tickets: TicketResolver?
    @State private var ticket: Ticket?
    @State private var isTicketChosen = false
    @State private var isDetectingTicket = false
    @State private var generating: Suggestion?
    @State private var suggestionError: Error?
    @State private var suggestionTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field { case branchName, message }
    private enum Suggestion { case message, branch }

    private var isGitButler: Bool { session.project.kind == .gitButler }
    private var targetBranch: String { isNewBranch ? newBranch.trimmingCharacters(in: .whitespaces) : branch }
    private var anchor: String? {
        guard let dependency, dependency.branch == targetBranch, stacksOnDependency else { return nil }
        return dependency.anchor
    }
    private var canCommit: Bool {
        !targetBranch.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isPerformingAction
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 2) {
                if !session.commitBranches.isEmpty {
                    sectionLabel(isGitButler ? "Applied branches" : "Current branch")
                    ForEach(Array(session.commitBranches.prefix(9).enumerated()), id: \.element) { index, name in
                        BranchTargetRow(
                            name: name, detail: detail(of: name), key: index + 1, isSelected: !isNewBranch && branch == name
                        ) { select(name) }
                    }
                }
                sectionLabel("New branch")
                newBranchBox
                if let dependency, dependency.branch == targetBranch {
                    stackCard(dependency)
                        .padding(.top, 6)
                }
                ticketRow
                    .padding(.top, 6)
                messageField
                    .padding(.top, 6)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
            footer
        }
        .frame(width: 420)
        // The footer's fill stays inside the rounded corners.
        .clipShape(.rect(cornerRadius: 14))
        .popoverSurface(in: .rect(cornerRadius: 14))
        .onKeyPress(characters: .decimalDigits) { press in
            // 1–9 pick an applied branch, unless a field is typing.
            guard focus == nil, let digit = Int(press.characters), digit > 0, session.commitBranches.indices.contains(digit - 1) else { return .ignored }
            select(session.commitBranches[digit - 1])
            return .handled
        }
        .onAppear {
            branch = session.suggestedBranch(for: request.targets)
            isNewBranch = session.commitBranches.isEmpty || request.fromComposer
            if request.fromComposer { message = session.commitDraft.message }
            focus = isNewBranch ? .branchName : .message
        }
        .task {
            suggestions = await session.suggestions()
            tickets = suggestions?.tickets
        }
        // Follows the target branch, e.g. `feature/hal-128` links HAL-128, until the user picks a ticket.
        .task(id: "\(targetBranch)|\(tickets?.providers.count ?? -1)") {
            guard !isTicketChosen, let tickets, !tickets.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isDetectingTicket = true
            let found = await tickets.ticket(forBranch: targetBranch, pattern: AppSettings.ticketPattern())
            guard !Task.isCancelled, !isTicketChosen else { return }
            isDetectingTicket = false
            ticket = found
        }
        .onDisappear { suggestionTask?.cancel() }
        .onExitCommand(perform: dismiss)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Text("Commit \(countTitle)")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Chip(subject, systemImage: "doc")
            Spacer(minLength: 8)
            KeyCap("esc")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
    }

    /// `1 hunk`, `2 files`.
    private var countTitle: String {
        let hunks = request.targets.allSatisfy { $0.hunk != nil }
        let count = request.targets.count
        return hunks ? (count == 1 ? "1 hunk" : "\(count) hunks") : (count == 1 ? "1 file" : "\(count) files")
    }

    /// `DiffDetailView.swift · hunk 2`.
    private var subject: String {
        guard request.targets.count == 1, let target = request.targets.first else { return "\(request.targets.count) changes" }
        let name = (target.file.path as NSString).lastPathComponent
        // `hunk 2 of DiffDetailView.swift` when the hunk's number is known.
        let words = session.toastSubject(request.targets).split(separator: " ")
        guard target.hunk != nil, words.first == "hunk", words.count > 1 else { return name }
        return "\(name) · hunk \(words[1])"
    }

    private func detail(of name: String) -> String {
        let branch = session.history.groups.flatMap(\.branches).first { $0.name == name }
        var parts: [String] = []
        if let branch, let pullRequest = session.history.pullRequest(of: branch) {
            parts.append("#\(pullRequest.number)" + (pullRequest.isDraft ? " draft" : ""))
        }
        if let branch, !branch.commits.isEmpty {
            parts.append(branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits")
        }
        return parts.joined(separator: " · ")
    }

    private var newBranchBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14, height: 14)
                TextField("feat/name", text: $newBranch)
                    .textFieldStyle(.plain)
                    .font(.code(12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focus, equals: .branchName)
                    .onChange(of: newBranch) { _, _ in if focus == .branchName { isNameSuggested = false } }
                    .onSubmit { focus = .message }
                if generating == .branch {
                    ProgressView().controlSize(.mini)
                } else if isNameSuggested {
                    Chip("✦ suggested", tone: .info)
                }
                IconButton(alternatives.isEmpty ? "Suggest a name" : "Suggest again", systemImage: alternatives.isEmpty ? "sparkles" : "arrow.clockwise", size: 24) {
                    suggest(.branch)
                }
                .disabled(generating != nil)
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(height: 34)
            .background(Theme.canvas, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .branchName ? Theme.lineStrong : Theme.line))
            if !alternatives.isEmpty {
                HStack(spacing: 6) {
                    Text("Or")
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                    ForEach(alternatives, id: \.self) { name in
                        Button {
                            newBranch = name
                            isNameSuggested = true
                        } label: {
                            Chip(name, systemImage: "sparkles")
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let suggestionError, generating == nil {
                Text(String(describing: suggestionError))
                    .font(.caption11)
                    .foregroundStyle(Theme.delFg)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.infoFg)
                        .frame(width: 12, height: 12)
                    Text(sourceLine)
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(10)
        .background(Theme.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isNewBranch ? Theme.lineStrong : Theme.line))
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { selectNewBranch() }
        .onChange(of: focus) { _, field in if field == .branchName { selectNewBranch() } }
    }

    /// `From the hunk (4 lines) and ticket HAL-128 · Claude · Haiku`.
    private var sourceLine: String {
        let lines = request.targets.reduce(0) { sum, target in sum + (target.hunk?.lines.count { $0.kind != .context } ?? 0) }
        var source = request.targets.allSatisfy { $0.hunk != nil }
            ? "From the \(request.targets.count == 1 ? "hunk" : "hunks") (\(lines) \(lines == 1 ? "line" : "lines"))"
            : "From the \(request.targets.count == 1 ? "file" : "files")"
        if let ticket { source += " and ticket \(ticket.id)" }
        guard let provider = AppSettings.suggestionProvider() else { return source + " · choose an AI provider in Settings" }
        let model = AppSettings.model(for: .branchName)
        return source + " · " + (model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)")
    }

    private func stackCard(_ dependency: (branch: String, anchor: String)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warnFg)
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stack on \(dependency.anchor)")
                    .font(.control.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("These changes edit lines committed on \(dependency.anchor), so the new branch has to sit on top of it.")
                    .font(.caption11)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(isOn: $stacksOnDependency)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.warnBg, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder private var ticketRow: some View {
        if let ticket {
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
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Chip(ticket.source.displayName)
                IconButton("Unlink ticket", systemImage: "xmark", size: 22) {
                    self.ticket = nil
                    isTicketChosen = true
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        } else if let tickets, !tickets.isEmpty {
            TicketField(ticket: $ticket, isDetecting: isDetectingTicket, resolver: tickets) { isTicketChosen = true }
        }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Message")
                    .font(.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button { suggest(.message) } label: {
                    HStack(spacing: 5) {
                        if generating == .message { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles").font(.system(size: 10.5)) }
                        Text(message.isEmpty ? "Generate" : "Regenerate")
                    }
                }
                .buttonStyle(.pill(.ghost, height: 24))
                .disabled(generating != nil)
            }
            .padding(.horizontal, 8)
            TextEditor(text: $message)
                .font(.control)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .message)
                .padding(6)
                .frame(height: 72)
                .background(Theme.canvas, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .message ? Theme.lineStrong : Theme.line))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Summary of the change")
                            .font(.control)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 11)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Text(error)
                    .font(.caption11)
                    .foregroundStyle(Theme.delFg)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text(command)
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Button(action: dismiss) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyCap("esc")
                    }
                }
                .buttonStyle(.pill(.ghost))
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button { commit() } label: {
                    HStack(spacing: 6) {
                        if session.isPerformingAction {
                            ProgressView().controlSize(.mini).tint(Theme.textInverse)
                        }
                        Text(isNewBranch ? "Create branch & commit" : "Commit")
                        KeyCap("⌘↩", onInverse: true)
                    }
                }
                .buttonStyle(.pill(.prominent, height: 30))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
    }

    /// What runs, e.g. `but commit -b fix/x --anchor feat/y`.
    private var command: String {
        let name = targetBranch.isEmpty ? "…" : targetBranch
        if isGitButler {
            return "but commit -b \(name)" + (anchor.map { " --anchor \($0)" } ?? "")
        }
        return isNewBranch ? "git switch -c \(name) · git commit" : "git commit"
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.sectionLabel)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 26)
    }

    // MARK: Actions

    private func select(_ name: String) {
        branch = name
        isNewBranch = false
        if focus == .branchName { focus = nil }
    }

    /// Only picks the new branch; names are suggested when ✦ is clicked, never on their own.
    private func selectNewBranch() {
        guard !isNewBranch else { return }
        isNewBranch = true
    }

    /// Asks the AI provider for a commit message or branch names from the selected changes. Never commits.
    private func suggest(_ kind: Suggestion) {
        suggestionTask?.cancel()
        suggestionError = nil
        generating = kind
        if kind == .branch { selectNewBranch() }
        let branch = kind == .message ? targetBranch : ""
        let isExisting = kind == .message && !isNewBranch
        suggestionTask = Task {
            do {
                guard let suggestions else { throw SuggestionUnavailable.noToolchain }
                let diff = try await session.patch(for: request.targets)
                let commits = isExisting ? await session.commitLog(ofBranch: branch) : ""
                let context = TemplateContext(diff: diff, commits: commits, branch: branch, ticket: ticket)
                switch kind {
                case .message:
                    let text = try await suggestions.commitMessage(context)
                    guard !Task.isCancelled else { return }
                    message = text
                case .branch:
                    let names = try await suggestions.branchNames(context)
                    guard !Task.isCancelled, let first = names.first else { return }
                    newBranch = first
                    isNameSuggested = true
                    alternatives = Array(names.dropFirst())
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                suggestionError = error
            }
            generating = nil
        }
    }

    private func commit() {
        guard canCommit else { return }
        let branch = targetBranch
        error = nil
        Task {
            do {
                try await session.run(.commit, on: request.targets, branch: branch, stackedOn: anchor, message: message)
                if request.fromComposer { session.commitDraft.message = "" }
                dismiss()
            } catch {
                if case ChangeActionError.dependsOn(let anchor) = error {
                    // Offer stacking instead of failing outright: on for a new branch, the user's call otherwise.
                    dependency = (branch, anchor)
                    stacksOnDependency = true
                    self.error = nil
                } else {
                    self.error = String(describing: error)
                }
            }
        }
    }
}

/// An applied branch to commit to, with its pull request, commit count and number key.
private struct BranchTargetRow: View {
    let name: String
    let detail: String
    let key: Int
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 14, height: 14)
                Text(name)
                    .font(.row)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                KeyCap("\(key)")
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(isSelected ? Theme.selected : isHovered ? Theme.hover : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
