import OhMyDiffCore
import SwiftUI

/// The sparkles button of the hunk bar and its panel: start Claude Code with a question about the lines,
/// or copy the prompt instead.
struct ClaudePromptMenu: View {
    let target: DiffPromptTarget

    @Environment(\.claudeCode) private var claudeCode
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .buttonStyle(.hoverCapsule(isSelected: isPresented))
        .fixedSize()
        .focusEffectDisabled()
        .glassTooltip(AppSettings.openClaudeCodeTitle(), edge: .top)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ClaudePromptPanel(target: target, dismiss: { isPresented = false }) { kind, question in
                isPresented = false
                let prompt = target.prompt(question)
                switch kind {
                case .open: claudeCode.open(prompt, target.root)
                case .copy: claudeCode.copy(prompt)
                }
            }
        }
    }
}

private struct ClaudePromptPanel: View {
    let target: DiffPromptTarget
    let dismiss: () -> Void
    let choose: (ClaudeRequest.Kind, PromptQuestion) -> Void

    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(Array(PromptQuestion.asked.enumerated()), id: \.element) { offset, question in
                QuestionRow(question: question, isHighlighted: offset == highlighted) { choose($0, question) }
                    .onHover { if $0 { highlighted = offset } }
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 10)
            Button { choose(.copy, .none) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Text("Copy \(target.scope) as Context")
                        .lineLimit(1)
                    Spacer()
                    KeyCap("⌥⇧⌘C")
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.hover(cornerRadius: 10))
            .focusEffectDisabled()
        }
        .padding(6)
        .frame(width: 340)
        .paletteKeys(
            up: { move(-1) }, down: { move(1) },
            choose: { choose(.open, PromptQuestion.asked[highlighted]) },
            dismiss: dismiss)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Theme.logo, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask Claude Code")
                    .fontWeight(.semibold)
                Text(AppSettings.openClaudeCodeNote(scope: target.scope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func move(_ delta: Int) {
        let count = PromptQuestion.asked.count
        highlighted = (highlighted + delta + count) % count
    }
}

/// A question: starts Claude Code when clicked, with a button to copy its prompt instead.
private struct QuestionRow: View {
    let question: PromptQuestion
    let isHighlighted: Bool
    let choose: (ClaudeRequest.Kind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { choose(.open) } label: {
                HStack(spacing: 10) {
                    Image(systemName: question.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(question.title)
                            .lineLimit(1)
                        Text(question.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if question == .explain { KeyCap("⌥⌘E") }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.hover(cornerRadius: 10, isSelected: isHighlighted))
            .focusEffectDisabled()
            Button { choose(.copy) } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.hover(cornerRadius: 10))
            .focusEffectDisabled()
            .glassTooltip("Copy Prompt", edge: .trailing)
            .padding(.leading, 2)
        }
    }
}

extension PromptQuestion {
    var systemImage: String {
        switch self {
        case .explain: "text.bubble"
        case .review: "ladybug"
        case .tests: "checklist"
        case .none: "doc.on.clipboard"
        }
    }

    /// One line below the title in the Claude Code panel.
    var summary: String {
        switch self {
        case .explain: "What it does and why it was made"
        case .review: "Bugs, edge cases and risky behavior"
        case .tests: "Tests in the repository's style"
        case .none: "The lines and where they come from"
        }
    }
}
