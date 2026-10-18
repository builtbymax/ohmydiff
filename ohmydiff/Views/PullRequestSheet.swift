import AppKit
import OhMyDiffCore
import SwiftUI

/// Drafts a pull request title and description for a branch with the AI provider and template from Settings,
/// for the user to edit and copy.
struct PullRequestSheet: View {
    let branch: HistoryBranch
    let diffs: [FileDiff]
    let suggestions: () async -> Suggestions?

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 14, weight: .bold))
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
            }

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
                    .padding(8)
                    .fieldBackground(isFocused: false)
                if let error { SuggestionNotice(error: error) }
            }

            HStack(spacing: 8) {
                Text("Nothing is pushed or opened: copy the text into your pull request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .buttonStyle(.pill(.prominent, height: 32))
                .disabled(text.isEmpty)
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
            // Opening the sheet asks for a draft; without a provider this shows the way to Settings.
            generate()
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .onDisappear { task?.cancel() }
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
