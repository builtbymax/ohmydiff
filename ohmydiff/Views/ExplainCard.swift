import AppKit
import OhMyDiffCore
import SwiftUI

/// An inline explanation of one hunk and its follow-ups, answered by the AI provider without leaving the diff.
@MainActor @Observable
final class HunkExplanation {
    struct Turn: Identifiable {
        let id = UUID()
        /// `nil` for the first explanation.
        var question: String?
        var answer: String?
        var error: String?
    }

    let hunk: Int
    let path: String
    /// The hunk as sent: its header and lines.
    let patch: String
    let lineCount: Int
    private(set) var turns: [Turn] = []
    var followUp = ""
    private let ask: (AITask, String) async throws -> String
    @ObservationIgnored private var task: Task<Void, Never>?

    init(hunk: Int, diff: FileDiff, ask: @escaping (AITask, String) async throws -> String) {
        self.hunk = hunk
        path = diff.path
        let lines = diff.hunks[hunk].lines
        patch = ([diff.hunks[hunk].header] + lines.map { $0.marker + $0.text }).joined(separator: "\n")
        lineCount = lines.count { $0.kind != .context }
        self.ask = ask
    }

    var isAnswering: Bool { turns.last.map { $0.answer == nil && $0.error == nil } ?? false }

    func start() {
        guard turns.isEmpty else { return }
        send(nil)
    }

    func send(_ question: String?) {
        let question = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let question, question.isEmpty { return }
        guard !isAnswering else { return }
        turns.append(Turn(question: question))
        followUp = ""
        run()
    }

    /// Asks the last question again after a failure.
    func retry() {
        guard let last = turns.indices.last else { return }
        turns[last].error = nil
        run()
    }

    func cancel() { task?.cancel() }

    private func run() {
        let prompt = self.prompt()
        task = Task {
            let index = turns.count - 1
            do {
                let answer = try await ask(.explain, prompt)
                guard !Task.isCancelled, turns.indices.contains(index) else { return }
                turns[index].answer = answer
            } catch {
                guard !Task.isCancelled, turns.indices.contains(index) else { return }
                turns[index].error = String(describing: error)
            }
        }
    }

    /// The hunk and the conversation so far; only this hunk is sent.
    private func prompt() -> String {
        var sections = [
            "You explain one hunk of a code change to the developer reviewing it. Answer in plain prose, at most 3 sentences, "
                + "no headings or lists. Say what the change does and what to watch out for, e.g. a test worth running.",
            "File: `\(path)`",
            "```diff\n\(patch)\n```",
        ]
        for turn in turns {
            if let question = turn.question { sections.append("Question: \(question)") }
            if let answer = turn.answer { sections.append("Your answer: \(answer)") }
        }
        if turns.last?.question == nil { sections.append("Explain the hunk.") } else { sections.append("Answer the last question.") }
        return sections.joined(separator: "\n\n")
    }

    var transcript: String {
        turns.map { turn in
            [turn.question.map { "Q: \($0)" }, turn.answer].compactMap(\.self).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}

/// The card under a hunk: what the AI says about it, and a follow-up field.
struct ExplainCard: View {
    @Bindable var explanation: HunkExplanation
    let close: () -> Void
    let openSettings: () -> Void
    var onHeight: (CGFloat) -> Void = { _ in }

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.infoFg)
                    .frame(width: 14, height: 14)
                Text("Explain hunk \(explanation.hunk + 1)")
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Chip(explanation.lineCount == 1 ? "Sends 1 line" : "Sends \(explanation.lineCount) lines", systemImage: "eye")
                    .help("Only this hunk is sent, nothing else from the repository.")
                Chip(providerTitle, systemImage: "apple.terminal")
                Spacer(minLength: 8)
                IconButton("Copy", systemImage: "doc.on.doc", size: 24) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(explanation.transcript, forType: .string)
                }
                .disabled(explanation.transcript.isEmpty)
                IconButton("Close  esc", systemImage: "xmark", size: 24, action: close)
            }
            ForEach(explanation.turns) { turn in
                if let question = turn.question {
                    Text(question)
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                if let answer = turn.answer {
                    Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                        .font(.control)
                        .lineSpacing(2)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = turn.error {
                    AIErrorNote(message: error)
                    HStack(spacing: 6) {
                        Button(action: explanation.retry) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 11))
                                Text("Retry")
                            }
                        }
                        .buttonStyle(.pill(.prominent))
                        Spacer(minLength: 8)
                        Button(action: openSettings) { Label("AI settings", systemImage: "slider.horizontal.3") }
                            .buttonStyle(.pill(.ghost))
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Reading the hunk…").font(.detail).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Ask a follow-up about this hunk…", text: $explanation.followUp)
                    .textFieldStyle(.plain)
                    .font(.detail)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($isFocused)
                    .onSubmit { explanation.send(explanation.followUp) }
                    .onExitCommand(perform: close)
                KeyCap("↩")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.hover, in: .rect(cornerRadius: 8))
            .disabled(explanation.isAnswering)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.1), radius: 3.5, y: 4)
        .padding(.leading, 60)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: Theme.canvasColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .onAppear { explanation.start() }
    }

    private var providerTitle: String {
        guard let provider = AppSettings.suggestionProvider() else { return "No provider" }
        let model = AppSettings.model(for: .explain)
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }
}
