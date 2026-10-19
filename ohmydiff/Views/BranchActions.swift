import AppKit
import OhMyDiffCore
import SwiftUI

/// Push and pull request actions for a branch: small icons on its card in the list, or labeled pills in the
/// bar under the list.
struct BranchActions: View {
    enum Style { case compact, bar }

    let branch: HistoryBranch
    let history: HistoryModel
    var style: Style = .compact

    var body: some View {
        HStack(spacing: style == .compact ? 2 : 6) {
            if history.canPush(branch) {
                let title = branch.status == .requiresForce ? "Force Push" : "Push"
                action(title, help: history.isGitButler ? "\(title) with `but push`" : title) {
                    Image(systemName: "arrow.up").font(.system(size: style == .compact ? 11 : 12, weight: .semibold))
                } perform: {
                    history.requestPush(branch)
                }
            }
            if let pullRequest = history.pullRequest(of: branch) {
                PullRequestMenu(pullRequest: pullRequest, history: history, branch: branch.name, isCompact: style == .compact)
            } else if history.canOpenPullRequest(branch) {
                action("Pull Request…", help: "Create Pull Request…") {
                    PullRequestGlyph(size: style == .compact ? 11 : 12)
                } perform: {
                    history.requestPullRequestDraft(branch)
                }
            }
        }
        .disabled(history.branchActivity != nil)
    }

    /// Whether the branch has any action to show.
    static func hasActions(_ branch: HistoryBranch, in history: HistoryModel) -> Bool {
        history.canPush(branch) || history.pullRequest(of: branch) != nil || history.canOpenPullRequest(branch)
    }

    @ViewBuilder
    private func action(
        _ title: String, help: String, @ViewBuilder icon: () -> some View, perform: @escaping () -> Void
    ) -> some View {
        switch style {
        case .compact:
            Button(action: perform) {
                icon().frame(width: 22, height: 22)
            }
            .buttonStyle(.hoverCapsule())
            .focusEffectDisabled()
            .glassTooltip(help)
        case .bar:
            Button(action: perform) {
                HStack(spacing: 6) {
                    icon()
                    Text(title)
                }
            }
            .buttonStyle(.pill(title.hasPrefix("Pull") ? .prominent : .normal, height: 30))
            .focusEffectDisabled()
        }
    }
}

/// `#12 Open` as a menu: open it on GitHub, switch between draft and ready, or merge it.
struct PullRequestMenu: View {
    let pullRequest: PullRequest
    let history: HistoryModel
    let branch: String
    var isCompact = false

    var body: some View {
        Menu {
            Button { NSWorkspace.shared.open(pullRequest.url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right") }
            if pullRequest.state == .open {
                Divider()
                if pullRequest.isDraft {
                    Button { Task { await history.setDraft(false, pullRequest: pullRequest, branch: branch) } } label: {
                        Label("Mark Ready for Review", systemImage: "checkmark.circle")
                    }
                } else {
                    Button { Task { await history.setDraft(true, pullRequest: pullRequest, branch: branch) } } label: {
                        Label("Convert to Draft", systemImage: "pencil.circle")
                    }
                    Menu {
                        ForEach(MergeMethod.allCases, id: \.self) { method in
                            Button(method.title) { history.pendingMerge = (pullRequest, method, branch) }
                        }
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    }
                }
            }
            Divider()
            Button { Task { await history.loadPullRequest(for: branch, force: true) } } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                if pullRequest.state == .open, !pullRequest.isDraft {
                    PullRequestGlyph(size: isCompact ? 10 : 11)
                } else {
                    Image(systemName: icon)
                }
                Text("#\(pullRequest.number)").monospacedDigit()
                if !isCompact { Text(stateTitle) }
            }
            .font(isCompact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, isCompact ? 6 : 9)
            .frame(height: isCompact ? 20 : 26)
            .background(color.opacity(Theme.kindTintOpacity), in: .capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassTooltip("\(stateTitle): \(pullRequest.title)")
    }

    private var stateTitle: String {
        switch pullRequest.state {
        case .open: pullRequest.isDraft ? "Draft" : "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    private var icon: String {
        switch pullRequest.state {
        case .open: pullRequest.isDraft ? "circle.dashed" : "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    private var color: Color {
        switch pullRequest.state {
        case .open: pullRequest.isDraft ? .secondary : .green
        case .merged: .purple
        case .closed: .red
        }
    }
}

/// GitHub's pull request icon: two branch ends joined by a line, and an arrow from the right one back to the top.
struct PullRequestGlyph: View {
    var size: CGFloat = 12

    var body: some View {
        PullRequestShape()
            .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 0.13), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct PullRequestShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on a 16-point grid like GitHub's octicon.
        let scale = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        func circle(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            let radius = 2 * scale
            return CGRect(x: rect.minX + x * scale - radius, y: rect.minY + y * scale - radius, width: radius * 2, height: radius * 2)
        }
        var path = Path()
        path.addEllipse(in: circle(4, 3))
        path.addEllipse(in: circle(4, 13))
        path.addEllipse(in: circle(12, 13))
        path.move(to: point(4, 5))
        path.addLine(to: point(4, 11))
        path.move(to: point(12, 11))
        path.addLine(to: point(12, 6.5))
        path.addQuadCurve(to: point(9.5, 4), control: point(12, 4))
        path.addLine(to: point(7.5, 4))
        path.move(to: point(9.4, 2.1))
        path.addLine(to: point(7.5, 4))
        path.addLine(to: point(9.4, 5.9))
        return path
    }
}

/// The selected branch and its actions, floating over the bottom of the History list.
struct BranchActionBar: View {
    let branch: HistoryBranch
    let history: HistoryModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            if let activity = history.branchActivity {
                ProgressView().controlSize(.mini)
                Text(activity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(branch.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .glassTooltip(branch.name, edge: .top)
            }
            Spacer(minLength: 4)
            BranchActions(branch: branch, history: history, style: .bar)
                .fixedSize()
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
    }
}

extension View {
    /// The pull request sheet, force push and merge confirmations, and errors of History's branch actions.
    func branchActionPresentation(_ history: HistoryModel, suggestions: @escaping () async -> Suggestions?) -> some View {
        modifier(BranchActionPresentation(history: history, suggestions: suggestions))
    }
}

private struct BranchActionPresentation: ViewModifier {
    @Bindable var history: HistoryModel
    let suggestions: () async -> Suggestions?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { draft != nil }, set: { if !$0 { history.pullRequestDraftBranch = nil } })) {
                if let draft {
                    PullRequestSheet(branch: draft.branch, diffs: draft.diffs, suggestions: suggestions, history: history)
                }
            }
            .confirmationDialog(
                "Force push \(history.forcePushBranch?.name ?? "")?",
                isPresented: Binding(get: { history.forcePushBranch != nil }, set: { if !$0 { history.forcePushBranch = nil } }),
                titleVisibility: .visible, presenting: history.forcePushBranch
            ) { branch in
                Button("Force Push", role: .destructive) { Task { await history.push(branch) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The branch's history was rewritten. Its remote copy is replaced, unless someone else pushed to it meanwhile.")
            }
            .confirmationDialog(
                history.pendingMerge.map { "Merge #\($0.pullRequest.number) into \($0.pullRequest.baseRefName)?" } ?? "",
                isPresented: Binding(get: { history.pendingMerge != nil }, set: { if !$0 { history.pendingMerge = nil } }),
                titleVisibility: .visible
            ) {
                if let merge = history.pendingMerge {
                    Button(merge.method.title) { Task { await history.merge(merge.pullRequest, method: merge.method, branch: merge.branch) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The pull request is merged on the remote. Update from the upstream afterwards to bring it into your branches.")
            }
            .alert(
                "Action Failed",
                isPresented: Binding(get: { history.branchActionError != nil }, set: { if !$0 { history.branchActionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(history.branchActionError ?? "")
            }
    }

    /// The branch to draft for, once it is selected and its whole diff has loaded.
    private var draft: (branch: HistoryBranch, diffs: [FileDiff])? {
        guard let name = history.pullRequestDraftBranch, history.selection == .branch(name),
              let branch = history.selectedBranch, case .loaded(let diffs) = history.files
        else { return nil }
        return (branch, diffs)
    }
}
