import OhMyDiffCore
import SwiftUI

/// Amends files or hunks into an existing commit, which keeps its message: any commit of an applied GitButler
/// branch (1–9 pick the first nine), or the latest commit in plain git. A card over the page, never a modal.
struct AmendTargetCard: View {
    let session: ProjectSession
    let request: ProjectSession.ActionRequest
    let dismiss: () -> Void

    @State private var selection: CommitInfo?
    @State private var error: String?
    @FocusState private var isFocused: Bool

    private var isGitButler: Bool { session.project.kind == .gitButler }
    private var sections: [(branch: String, commits: [CommitInfo])] { session.amendableCommits }
    /// The commits in list order, for the number keys.
    private var commits: [CommitInfo] { sections.flatMap(\.commits) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.branch) { section in
                        sectionLabel(section.branch)
                        ForEach(section.commits) { commit in
                            let branch = session.history.groups.lazy.flatMap(\.branches).first { $0.name == section.branch }
                            AmendCommitRow(
                                commit: commit, isLocal: branch.map { session.isLocal(commit, in: $0) } ?? true,
                                key: commits.firstIndex(of: commit).flatMap { $0 < 9 ? $0 + 1 : nil },
                                isSelected: selection == commit
                            ) { selection = commit }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .frame(width: 420)
        .clipShape(.rect(cornerRadius: 14))
        .popoverSurface(in: .rect(cornerRadius: 14))
        // Focused, so the number keys and arrows pick a commit.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = Int(press.characters), digit > 0, digit <= min(9, commits.count) else { return .ignored }
            selection = commits[digit - 1]
            return .handled
        }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .onAppear {
            isFocused = true
            // The newest commit of the branch the changes are assigned to, else of the first branch.
            let branch = session.suggestedBranch(for: request.targets)
            selection = sections.first { $0.branch == branch }?.commits.first ?? commits.first
        }
        .onExitCommand(perform: dismiss)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Text("Amend \(request.subject) into")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            KeyCap("esc")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
    }

    private func sectionLabel(_ branch: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
            Text(branch)
                .font(.sectionLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                ScrollView {
                    Text(error)
                        .font(.caption11)
                        .foregroundStyle(Theme.delFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 100)
            } else {
                Text(note)
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button { amend() } label: {
                    HStack(spacing: 6) {
                        if session.isPerformingAction {
                            Spinner(color: Theme.textInverse).controlSize(.mini)
                        }
                        Text("Amend")
                        KeyCap("⌘↩", onInverse: true)
                    }
                }
                .buttonStyle(.pill(.prominent, height: 30))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selection == nil || session.isPerformingAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
    }

    /// What runs, and what it means for the commits above and a pushed commit.
    private var note: String {
        guard let selection else { return "" }
        if isGitButler {
            // Newest first, so its index is how many of the branch's commits sit above it.
            let above = sections.first { $0.commits.contains(selection) }?.commits.firstIndex(of: selection) ?? 0
            let rebase = above == 0 ? "" : above == 1 ? " The commit above it is rebased." : " The \(above) commits above it are rebased."
            return "but amend -t \(selection.shortSHA) keeps the message.\(rebase) but undo takes it back."
        }
        return "git commit --amend keeps the message. Only the latest commit can be amended."
    }

    // MARK: Actions

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let selection, let index = commits.firstIndex(of: selection), commits.indices.contains(index + offset) else { return .ignored }
        self.selection = commits[index + offset]
        return .handled
    }

    private func amend() {
        guard let selection, !session.isPerformingAction else { return }
        error = nil
        Task {
            do {
                try await session.run(.amend, on: request.targets, into: selection)
                dismiss()
            } catch {
                if case ProcessError.nonZeroExit(_, let code, let output) = error {
                    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.error = detail.isEmpty ? "Amend failed (exit code \(code))." : detail
                } else {
                    self.error = String(describing: error)
                }
            }
        }
    }
}

/// A commit to amend into: summary, `local` until pushed, short SHA and number key.
private struct AmendCommitRow: View {
    let commit: CommitInfo
    let isLocal: Bool
    let key: Int?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: "circle.and.line.horizontal")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isLocal ? Theme.warnFg : Theme.textTertiary)
                    .frame(width: 14, height: 14)
                Text(commit.summary)
                    .font(.row)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isLocal {
                    Chip("pushed")
                        .help("Pushing the amended commit needs a force push")
                }
                Text(commit.shortSHA)
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                if let key {
                    KeyCap("\(key)")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(isSelected ? Theme.selected : isHovered ? Theme.hover : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(commit.summary)
    }
}
