import AppKit
import OhMyDiffCore
import SwiftUI

/// The 46 pt bar at the top of the content panel. Changes shows the open file and the branch's remote
/// actions; the other pages show their title and filters.
struct PageTopBar: View {
    let model: AppModel
    let mode: WorkspaceMode
    /// Room for the window controls while the sidebar is hidden.
    var leadingInset: CGFloat = 0
    @Binding var isSidebarHidden: Bool

    var body: some View {
        HStack(spacing: 2) {
            if isSidebarHidden {
                IconButton("Show Sidebar  ⌃⌘S", systemImage: "sidebar.left") {
                    withAnimation(.snappy(duration: 0.2)) { isSidebarHidden = false }
                }
                .padding(.trailing, 6)
            }
            if let session = model.selectedSession {
                switch mode {
                case .changes, .branches, .pullRequests:
                    ChangesTopBar(model: model, session: session)
                case .history:
                    HistoryTopBar(history: session.history)
                }
            } else {
                dragArea
            }
        }
        .padding(.leading, 8 + leadingInset)
        .padding(.trailing, 10)
        .frame(height: 46)
        .background(dragArea)
    }

    /// The bar's empty stretch moves the window, like a title bar.
    private var dragArea: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(WindowDragGesture())
    }
}

/// Changes: the selected file, then fetching, pushing and the pull request of its branch.
private struct ChangesTopBar: View {
    let model: AppModel
    let session: ProjectSession

    var body: some View {
        if let file = session.selectedFile {
            FileTab(file: file, isSelected: true)
        }
        Spacer(minLength: 8)
        if session.project.kind != .gitButler, let branch = session.currentBranch {
            Chip(branch, systemImage: "arrow.triangle.branch")
                .padding(.trailing, 6)
        }
        if session.phase == .ready {
            FetchButton(model: model, session: session, isLabeled: session.project.kind != .gitButler)
            if let branch {
                PushButton(history: session.history, branch: branch)
                    .padding(.leading, 4)
                if let pullRequest = session.history.pullRequest(of: branch) {
                    PullRequestButton(history: session.history, pullRequest: pullRequest)
                        .padding(.leading, 6)
                }
            }
        }
    }

    /// The branch the bar acts on: the selected file's in GitButler, the checked-out one in plain git.
    private var branch: HistoryBranch? {
        let name: String? = session.project.kind == .gitButler
            ? session.selectedFile.flatMap { session.assignedBranch(of: $0.path) } ?? session.branchNames.first
            : session.currentBranch
        guard let name else { return nil }
        return session.history.groups.lazy.flatMap(\.branches).first { $0.name == name }
    }
}

/// An open file: its change letter and name.
struct FileTab: View {
    let file: ChangedFile
    let isSelected: Bool
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Text(FileBadge(kind: file.kind).letter)
                .font(.statusLetter)
                .foregroundStyle(Theme.changeColor(file.kind))
            Text((file.path as NSString).lastPathComponent)
                .font(.control.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isSelected ? Theme.selected : .clear, in: .rect(cornerRadius: 8))
    }
}

/// `↓`: fetches, or opens the update once the remote has something new. Plain git labels it `Fetch`.
private struct FetchButton: View {
    let model: AppModel
    let session: ProjectSession
    let isLabeled: Bool

    var body: some View {
        let hasUpdates = session.upstream?.hasUpdates == true
        Button {
            if hasUpdates {
                model.isUpstreamUpdatePresented = true
            } else {
                Task { await session.fetch() }
            }
        } label: {
            HStack(spacing: 6) {
                if session.isFetching {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: session.fetchError != nil ? "exclamationmark.triangle" : isLabeled && !hasUpdates ? "arrow.clockwise" : "arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(session.fetchError != nil ? Theme.warnFg : hasUpdates ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 14, height: 14)
                }
                if hasUpdates, let upstream = session.upstream {
                    Text(UpstreamControls.updateTitle(upstream))
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                } else if isLabeled {
                    Text("Fetch")
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 8))
        .disabled(session.isFetching || session.isUpdatingFromUpstream)
        .focusEffectDisabled()
        .glassTooltip(tooltip)
    }

    private var tooltip: String {
        if let error = session.fetchError { return "Fetch failed: \(error)" }
        if session.upstream?.hasUpdates == true { return "Review and Update…  ⇧⌘U" }
        let fetched = session.lastFetched.map { " · fetched \(UpstreamControls.fetchedTitle($0).lowercased())" } ?? ""
        return "Fetch from \(session.upstream?.target ?? "the remote")\(fetched)  ⇧⌘F"
    }
}

/// `↑ Push 2`: the branch's unpushed commits.
private struct PushButton: View {
    let history: HistoryModel
    let branch: HistoryBranch

    var body: some View {
        Button { history.requestPush(branch) } label: {
            HStack(spacing: 6) {
                if history.branchActivity == "Pushing…" {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12))
                        .frame(width: 14, height: 14)
                }
                Text("Push")
                    .font(.control.weight(.medium))
                if unpushed > 0 {
                    Text("\(unpushed)")
                        .font(.caption11)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(.pill(height: 28))
        .disabled(!history.canPush(branch) || history.branchActivity != nil)
        .focusEffectDisabled()
        .glassTooltip(branch.needsForcePush ? "Force Push \(branch.name)…  ⇧⌘P" : "Push \(branch.name)  ⇧⌘P")
    }

    private var unpushed: Int {
        switch branch.status {
        case .tracking(let ahead, _)?: ahead
        case .unpushed?, .unpushedCommits?, .requiresForce?, nil: history.canPush(branch) ? branch.commits.count : 0
        default: 0
        }
    }
}

/// `⇅ #142 ◌ 3/5`: the branch's pull request and its checks; opens it on GitHub.
private struct PullRequestButton: View {
    let history: HistoryModel
    let pullRequest: PullRequest

    var body: some View {
        Button { NSWorkspace.shared.open(pullRequest.url) } label: {
            HStack(spacing: 6) {
                Image(systemName: pullRequest.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                Text("#\(pullRequest.number)")
                    .font(.control.weight(.medium))
                    .monospacedDigit()
                if let checks = history.pullRequestStatuses[pullRequest.number]?.checks {
                    ChecksChip(checks: checks)
                }
            }
        }
        .buttonStyle(.pill(height: 28))
        .focusEffectDisabled()
        .glassTooltip(pullRequest.title)
    }
}

/// `◌ 3/5` while checks run, `✓ Checks` once they passed, `✕ 1 failing` when one failed.
struct ChecksChip: View {
    let checks: PullRequestStatus.Checks

    var body: some View {
        switch checks {
        case .none: EmptyView()
        case .pending(let done, let total): Chip("\(done)/\(total)", systemImage: "circle.dotted", tone: .warn)
        case .passed: Chip("Checks", systemImage: "checkmark.circle", tone: .ok)
        case .failed(let names, _): Chip(names.count == 1 ? "1 failing" : "\(names.count) failing", systemImage: "xmark", tone: .danger)
        }
    }
}

/// History: the title and the branch filter.
private struct HistoryTopBar: View {
    let history: HistoryModel

    var body: some View {
        Text("History")
            .font(.row.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 6)
            .padding(.trailing, 10)
        Spacer(minLength: 8)
    }
}
