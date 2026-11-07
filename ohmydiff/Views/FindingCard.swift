import AppKit
import OhMyDiffCore
import SwiftUI

/// A review finding under its line: what is wrong, what to change, and Apply, which hands it to the agent.
/// Advisory only; nothing here changes the code.
struct FindingCard: View {
    let finding: ReviewFinding
    let isApplied: Bool
    /// Starts the agent with the finding; `nil` where the diff has no agent actions, e.g. a diff window.
    let apply: (() -> Void)?
    let dismiss: () -> Void
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: finding.severity == .low ? "info.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 14, height: 14)
                Text(finding.side == .new ? "Line \(finding.line)" : "Removed line \(finding.line)")
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Chip(finding.severity.title, tone: tone)
                Chip(origin, systemImage: "checklist")
                if isApplied { Chip("Sent to agent", systemImage: "apple.terminal", tone: .info) }
                Spacer(minLength: 8)
                IconButton("Copy", systemImage: "doc.on.doc", size: 24) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if let apply {
                    Button(action: apply) { Label("Apply", systemImage: "wand.and.sparkles") }
                        .buttonStyle(.pill(.ghost))
                        .help("Start \(AppSettings.aiProvider().displayName) with this finding; ohmydiff changes nothing itself.")
                }
                IconButton("Dismiss", systemImage: "xmark", size: 24, action: dismiss)
            }
            Text(markdown(finding.message))
                .font(.control)
                .lineSpacing(2)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !finding.suggestion.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Suggestion")
                        .font(.caption11.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                    Text(markdown(finding.suggestion))
                        .font(.control)
                        .lineSpacing(2)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background { RoundedRectangle(cornerRadius: 12).fill(Theme.surface).shadow(color: Theme.cardShadow, radius: 3.5, y: 4) }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(tint).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .padding(.leading, 60)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: Theme.canvasColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
    }

    private var tone: Chip.Tone {
        switch finding.severity {
        case .high: .danger
        case .medium: .warn
        case .low: .neutral
        }
    }

    private var tint: Color {
        switch finding.severity {
        case .high: Theme.delFg
        case .medium: Theme.warnFg
        case .low: Theme.textTertiary
        }
    }

    private var origin: String {
        switch finding.origin {
        case .task: AppSettings.suggestionProvider()?.displayName ?? "Review"
        case .agent(let name): name.isEmpty ? "Agent" : name
        }
    }

    private var text: String {
        var lines = ["\(finding.path):\(finding.line) [\(finding.severity.rawValue)] \(finding.message)"]
        if !finding.suggestion.isEmpty { lines.append("Suggestion: \(finding.suggestion)") }
        return lines.joined(separator: "\n")
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Starts a review of a selection's changes and shows how it went: reviewing, the number of findings, or why it failed.
struct ReviewButton: View {
    let reviews: ReviewFindings
    let scope: ReviewScope
    let start: () -> Void
    @Environment(\.openSettings) private var openSettings

    @AppStorage(AITask.review.enabledKey) private var isEnabled = true

    var body: some View {
        if isEnabled || reviews.states[scope] != nil { content }
    }

    private var content: some View {
        HStack(spacing: 6) {
            switch reviews.states[scope] {
            case .reviewing?:
                ProgressView().controlSize(.mini)
                Text("Reviewing…").font(.detail).foregroundStyle(Theme.textTertiary)
                IconButton("Stop", systemImage: "xmark", size: 22) { reviews.cancel(scope) }
            case .failed(let message)?:
                Button(action: start) { Label("Review failed · Retry", systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.pill(.ghost))
                    .help(message)
                IconButton("AI settings", systemImage: "slider.horizontal.3", size: 22) { SettingsWindow.open(.ai, with: openSettings) }
            case .done(let isCut)?:
                let count = reviews.count(for: scope)
                Button(action: start) {
                    Label(count == 0 ? "No findings" : count == 1 ? "1 finding" : "\(count) findings", systemImage: "checklist")
                }
                .buttonStyle(.pill(.ghost))
                .help((isCut ? "Some files were left out to keep the prompt short. " : "") + "Review again")
                if count > 0 {
                    IconButton("Clear findings", systemImage: "xmark", size: 22) { reviews.clear(scope) }
                }
            case nil:
                Button(action: start) { Label("Review", systemImage: "checklist") }
                    .buttonStyle(.pill(.ghost))
                    .help("Ask \(AppSettings.suggestionProvider()?.displayName ?? "the AI provider") to review these changes for bugs")
            }
        }
    }
}
