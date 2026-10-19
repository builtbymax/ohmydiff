import AppKit
import OhMyDiffCore
import SwiftUI

/// Drafts a pull request title and description for a branch with the AI provider and template from Settings,
/// for the user to edit, then copy or open as a pull request.
struct PullRequestSheet: View {
    let branch: HistoryBranch
    let diffs: [FileDiff]
    let suggestions: () async -> Suggestions?
    let history: HistoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var service: Suggestions?
    @State private var tickets: TicketResolver?
    @State private var ticket: Ticket?
    @State private var isTicketChosen = false
    @State private var isDetectingTicket = true
    @State private var text = ""
    @State private var isGenerating = false
    @State private var error: Error?
    @State private var copied = false
    @State private var task: Task<Void, Never>?
    @State private var isDraft = false
    @State private var createError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PullRequestGlyph(size: 15)
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Theme.logo, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull Request for \(branch.name)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits") · \(diffs.count == 1 ? "1 file" : "\(diffs.count) files")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    // The native tooltip: glass tooltips are not shown inside sheets.
                    .help(createNote)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)

            if let tickets, !tickets.isEmpty {
                TicketField(ticket: $ticket, isDetecting: isDetectingTicket, resolver: tickets) { isTicketChosen = true }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Title and Description")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    SuggestButton(title: text.isEmpty ? "Generate" : "Regenerate", isRunning: isGenerating) { generate() }
                }
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Title on the first line, then the description. Link a ticket, then Generate to draft it.")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(8)
                    .fieldBackground(isFocused: false)
                if let error { SuggestionNotice(error: error) }
            }

            if let createError {
                Label(createError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.deletion)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Toggle("Draft", isOn: $isDraft)
                    .toggleStyle(.checkbox)
                    .disabled(!canCreate)
                Spacer(minLength: 8)
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.pill(height: 32))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .buttonStyle(.pill(height: 32))
                .disabled(text.isEmpty)
                Button { create() } label: {
                    if history.branchActivity != nil {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Text("Create Pull Request")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.pill(.prominent, height: 32))
                .disabled(!canCreate || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || history.branchActivity != nil)
            }
            .focusEffectDisabled()
        }
        .padding(20)
        .frame(width: 560)
        .task {
            service = await suggestions()
            tickets = service?.tickets
            if let tickets, !tickets.isEmpty {
                ticket = await tickets.ticket(forBranch: branch.name)
            }
            isDetectingTicket = false
            // No draft yet: the ticket can be linked first, then Generate writes it.
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .onDisappear { task?.cancel() }
    }

    /// GitButler creates pull requests with `but pr`; plain repositories need `gh`.
    private var canCreate: Bool { history.isGitButler || history.canManagePullRequests }

    private var createNote: String {
        if !canCreate { return "Install the GitHub CLI (gh) to open pull requests from here." }
        return history.isGitButler ? "Pushes with `but pr new`; the first line is the title." : "Pushes and opens it with `gh`; the first line is the title."
    }

    private func create() {
        createError = nil
        Task {
            do {
                try await history.createPullRequest(branch: branch.name, text: text, isDraft: isDraft)
                dismiss()
            } catch {
                createError = String(describing: error)
            }
        }
    }

    private func generate() {
        task?.cancel()
        error = nil
        isGenerating = true
        task = Task {
            do {
                guard let service else { throw SuggestionUnavailable.noToolchain }
                let context = TemplateContext(
                    diff: diffs.map(\.patch).joined(separator: "\n"), commits: Suggestions.commitLog(branch.commits),
                    branch: branch.name, ticket: ticket)
                let draft = try await service.pullRequest(context)
                guard !Task.isCancelled else { return }
                text = draft
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.error = error
            }
            isGenerating = false
        }
    }
}
