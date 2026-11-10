import OhMyDiffCore
import SwiftUI

/// The two ways to resolve conflicts: in the editor chosen in Settings, or by a coding agent given everything
/// ohmydiff knows about them.
struct ConflictActions: View {
    let session: ProjectSession
    /// The conflicted branch; `nil` for conflicts in the worktree, e.g. a stopped rebase.
    let branch: HistoryBranch?
    var pullRequest: PullRequest?
    /// Off when the conflicts can't reach the worktree from here, e.g. a plain-git pull request before updating.
    var canOpenEditor = true

    @Environment(\.claudeCode) private var claudeCode
    @AppStorage(AppSettings.editorKey) private var editor = AppSettings.defaultEditor
    @AppStorage(AppSettings.aiProviderKey) private var provider = AIProvider.claude
    @State private var isPreparing = false

    var body: some View {
        HStack(spacing: 6) {
            if canOpenEditor {
                Button { Task { await session.openConflictsInEditor(branch: branch) } } label: {
                    HStack(spacing: 6) {
                        AppIconView(bundleIDs: EditorApp.bundleIDs(editor), size: 16) {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        Text("Open in \(editorName)")
                    }
                }
                .buttonStyle(.pill(height: 26))
                .disabled(session.isOpeningConflicts)
                .help(editorHelp)
            }
            Button { prepare(open: true) } label: {
                HStack(spacing: 6) {
                    ProviderIcon(provider: provider, size: 16)
                    Text("Fix with \(provider.displayName)")
                }
            }
            .buttonStyle(.pill(.prominent, height: 26))
            .disabled(isPreparing)
            .help(AppSettings.openClaudeCodeNote(scope: "Conflicts, the commits on both sides and how to finish"))
            .contextMenu {
                Button(AppSettings.copyPromptTitle()) { prepare(open: false) }
            }
        }
        .fixedSize()
    }

    private var editorName: String {
        editor == .custom ? "Editor" : editor.displayName
    }

    private var editorHelp: String {
        let view = editor.mergeTemplate != nil ? "its merge view" : "the first conflict"
        let checkout = session.project.kind == .gitButler && session.resolution == nil
            ? "Checks out the oldest conflicted commit for resolving, then opens " : "Opens "
        return checkout + "each conflicted file in \(editorName) at \(view)"
    }

    private func prepare(open: Bool) {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            guard let prompt = await session.conflictPrompt(branch: branch, pullRequest: pullRequest) else { return }
            if open {
                claudeCode.open(prompt, session.rootURL)
            } else {
                claudeCode.copy(prompt)
                Toasts.shared.show("Copied the prompt", systemImage: "doc.on.clipboard")
            }
        }
    }
}

/// A GitButler branch whose commits were marked conflicted, e.g. by an update, without a pull request saying so.
struct ConflictedBranchCard: View {
    let session: ProjectSession
    let branch: HistoryBranch

    var body: some View {
        let count = branch.commits.count { $0.isConflicted }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.delFg)
                Text(count == 1 ? "1 conflicted commit" : "\(count) conflicted commits")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(message)
                .font(.detail)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ConflictActions(session: session, branch: branch)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private var message: String {
        let target = session.upstream?.target ?? branch.baseName ?? "the target"
        return "These commits no longer apply on \(target). Resolve them, then push the branch again."
    }
}

extension View {
    /// A strip above the page while conflicts are in the worktree: a stopped merge or rebase, or GitButler's
    /// resolution mode, which also offers to finish or cancel it.
    func conflictBanner(_ session: ProjectSession) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if session.hasWorktreeConflicts {
                ConflictBanner(session: session)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
        }
    }
}

private struct ConflictBanner: View {
    let session: ProjectSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.delFg)
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let resolution = session.resolution {
                Button("Cancel") { Task { await session.endResolution(finish: false) } }
                    .buttonStyle(.pill(.ghost, height: 26))
                    .disabled(session.isPerformingAction)
                    .help("Leaves the commit conflicted and returns to the workspace")
                if resolution.isComplete {
                    Button("Finish") { Task { await session.endResolution(finish: true) } }
                        .buttonStyle(.pill(.prominent, height: 26))
                        .disabled(session.isPerformingAction)
                        .help("Writes the resolved commit and returns to the workspace")
                } else {
                    ConflictActions(session: session, branch: nil)
                }
            } else {
                ConflictActions(session: session, branch: nil)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(Theme.delBg, in: .rect(cornerRadius: 10))
    }

    private var conflictedCount: Int {
        session.resolution?.conflictedFiles.count ?? session.groups.first { $0.kind == .conflicted }?.files.count ?? 0
    }

    private var title: String {
        guard session.resolution != nil else { return "Merge conflicts in \(files(conflictedCount))" }
        let commit = session.resolvingCommit.map { "“\($0.summary)”" } ?? "a commit"
        return "Resolving \(commit)"
    }

    private var message: String {
        guard let resolution = session.resolution else {
            return "Resolve them, stage the files and continue the merge or rebase."
        }
        if resolution.isComplete { return "Every conflict is resolved. Finish to write the commit and return to the workspace." }
        return "\(files(resolution.conflictedFiles.count).capitalizedFirst) still \(resolution.conflictedFiles.count == 1 ? "has" : "have") "
            + "conflict markers. Branches show again when you finish or cancel."
    }

    private func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
