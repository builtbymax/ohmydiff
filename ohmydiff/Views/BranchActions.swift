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
                let title = branch.needsForcePush ? "Force Push" : "Push"
                action(title, help: history.isGitButler ? "\(title) with `but push`" : title) {
                    Image(systemName: "arrow.up").font(.system(size: style == .compact ? 11 : 12, weight: .semibold))
                } perform: {
                    history.requestPush(branch)
                }
            }
            if history.canChangeStack(branch) {
                StackMenu(branch: branch, history: history) {
                    switch style {
                    case .compact:
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(.capsule)
                    case .bar:
                        Label("Stack", systemImage: "square.stack.3d.up")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Color.primary.opacity(0.06), in: .capsule)
                            .contentShape(.capsule)
                    }
                }
                .glassTooltip("Stack or Unstack")
            }
            if history.canDelete(branch) {
                action("Delete", help: "Delete Branch…", isDestructive: true) {
                    Image(systemName: "trash").font(.system(size: style == .compact ? 10 : 11, weight: .semibold))
                } perform: {
                    history.pendingDeletion = [branch]
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
        history.canPush(branch) || history.pullRequest(of: branch) != nil || history.canOpenPullRequest(branch) || history.canDelete(branch)
            || history.canChangeStack(branch)
    }

    @ViewBuilder
    private func action(
        _ title: String, help: String, isDestructive: Bool = false, @ViewBuilder icon: () -> some View, perform: @escaping () -> Void
    ) -> some View {
        switch style {
        case .compact:
            Button(action: perform) {
                icon().frame(width: 22, height: 22)
            }
            .buttonStyle(.hoverCapsule())
            .foregroundStyle(isDestructive ? AnyShapeStyle(Theme.deletion) : AnyShapeStyle(.primary))
            .focusEffectDisabled()
            .glassTooltip(help)
        case .bar:
            Button(action: perform) {
                HStack(spacing: 6) {
                    icon()
                    Text(title)
                }
            }
            .buttonStyle(.pill(isDestructive ? .destructive : title.hasPrefix("Pull") ? .prominent : .normal, height: 30))
            .focusEffectDisabled()
        }
    }
}

/// GitButler: put a branch on top of another stack, or take it out of its own.
struct StackMenu<MenuLabel: View>: View {
    let branch: HistoryBranch
    let history: HistoryModel
    @ViewBuilder var label: MenuLabel

    var body: some View {
        Menu {
            StackMenuItems(branch: branch, history: history)
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The items of the stack menu, also used in a branch's context menu.
struct StackMenuItems: View {
    let branch: HistoryBranch
    let history: HistoryModel

    var body: some View {
        let targets = history.stackTargets(for: branch)
        if !targets.isEmpty {
            Section("Stack \(branch.name) on") {
                ForEach(targets) { stack in
                    // The top branch, so the moved branch builds on the whole stack.
                    if let top = stack.branches.first {
                        Button {
                            Task { await history.stack(branch, onto: top.name) }
                        } label: {
                            Text(stack.branches.count > 1 ? "\(top.name)  (+\(stack.branches.count - 1) below)" : top.name)
                        }
                    }
                }
            }
        }
        if history.isStacked(branch) {
            Button {
                Task { await history.unstack(branch) }
            } label: {
                Label("Remove from Stack", systemImage: "square.stack.3d.down.forward")
            }
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
                if pullRequest.state == .open, let status = history.pullRequestStatuses[pullRequest.number] {
                    Circle()
                        .fill(PullRequestSummary(pullRequest, status: status).color)
                        .frame(width: 6, height: 6)
                }
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

    private var color: Color { history.color(of: pullRequest) }
}

extension HistoryModel {
    /// An open pull request takes its status color, e.g. orange while checks run, once the status is known.
    func color(of pullRequest: PullRequest) -> Color {
        switch pullRequest.state {
        case .open:
            if let status = pullRequestStatuses[pullRequest.number] { PullRequestSummary(pullRequest, status: status).color }
            else { .secondary }
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
                    .frame(minWidth: 72, alignment: .leading)
                    .glassTooltip(branch.name, edge: .top)
            }
            Spacer(minLength: 4)
            // Labeled pills while they fit next to the name, icons in a narrow list.
            ViewThatFits(in: .horizontal) {
                BranchActions(branch: branch, history: history, style: .bar)
                    .fixedSize()
                BranchActions(branch: branch, history: history, style: .compact)
                    .fixedSize()
            }
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
            } message: { branch in
                if case .tracking(_, let behind) = branch.status {
                    Text("The branch and its remote copy have diverged, e.g. after an amend or rebase. The remote's \(behind == 1 ? "commit" : "\(behind) commits") not in the branch \(behind == 1 ? "is" : "are") replaced, unless someone else pushed to it since the last fetch.")
                } else if history.isGitButler {
                    Text("The branch's history was rewritten, e.g. by an amend or an update. but push replaces its remote copy with it.")
                } else {
                    Text("The branch's history was rewritten. Its remote copy is replaced, unless someone else pushed to it meanwhile.")
                }
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
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(get: { history.pendingDeletion != nil }, set: { if !$0 { history.pendingDeletion = nil } }),
                titleVisibility: .visible, presenting: history.pendingDeletion
            ) { branches in
                Button(branches.count == 1 ? "Delete Branch" : "Delete \(branches.count) Branches", role: .destructive) {
                    Task { await history.deleteBranches(branches) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { branches in
                Text(deletionMessage(branches))
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

    private var deletionTitle: String {
        guard let branches = history.pendingDeletion else { return "" }
        return branches.count == 1 ? "Delete \(branches[0].name)?" : "Delete \(branches.count) merged or gone branches?"
    }

    /// Names the branches and warns about commits the main line does not have, e.g. after a squash merge.
    private func deletionMessage(_ branches: [HistoryBranch]) -> String {
        var lines: [String] = []
        if branches.count > 1 { lines.append(branches.map(\.name).joined(separator: ", ")) }
        let unmerged = branches.filter { !$0.commits.isEmpty }
        if unmerged.isEmpty {
            lines.append("Every commit is on the main line.")
        } else {
            let names = unmerged.map { "\($0.name) (\($0.commits.count))" }.joined(separator: ", ")
            lines.append("Commits not on the main line: \(names). This is expected after a squash merge; "
                + "otherwise they are only recoverable from the reflog.")
        }
        return lines.joined(separator: "\n\n")
    }

    /// The branch to draft for, once it is selected and its whole diff has loaded.
    private var draft: (branch: HistoryBranch, diffs: [FileDiff])? {
        guard let name = history.pullRequestDraftBranch, history.selection == .branch(name),
              let branch = history.selectedBranch, case .loaded(let diffs) = history.files
        else { return nil }
        return (branch, diffs)
    }
}

/// What an open pull request's status says, from the most pressing problem down to ready to merge.
struct PullRequestSummary {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color

    /// `conflictHint` says how to resolve merge conflicts in this workspace; a generic hint otherwise.
    init(_ pullRequest: PullRequest, status: PullRequestStatus, conflictHint: String? = nil) {
        let base = pullRequest.baseRefName
        let checks: String = switch status.checks {
        case .none: "No checks"
        case .pending(let done, let total): "\(done) of \(total) checks done"
        case .failed(let names, _): names.count == 1 ? "\(names[0]) failed" : "\(names.count) checks failed: \(names.joined(separator: ", "))"
        case .passed(let total): total == 1 ? "1 check passed" : "\(total) checks passed"
        }
        switch (status, status.checks) {
        case (_, .failed) where pullRequest.isDraft:
            (title, detail, systemImage, color) = ("Draft · Checks Failed", checks, "xmark.octagon.fill", .red)
        case (_, .pending) where pullRequest.isDraft:
            (title, detail, systemImage, color) = ("Draft · Checks Running", checks, "clock.fill", .orange)
        case _ where pullRequest.isDraft:
            (title, detail, systemImage, color) = ("Draft", "\(checks) · Mark it ready for review to merge", "circle.dashed", .secondary)
        case _ where status.isMergeable == false || status.mergeState == "DIRTY":
            (title, detail, systemImage, color) = ("Merge Conflicts", "Conflicts with \(base) · \(conflictHint ?? "Resolve them before merging")", "exclamationmark.triangle.fill", .red)
        case (_, .failed):
            (title, detail, systemImage, color) = ("Checks Failed", checks, "xmark.octagon.fill", .red)
        case (_, .pending):
            (title, detail, systemImage, color) = ("Checks Running", checks, "clock.fill", .orange)
        case _ where status.review == .changesRequested:
            (title, detail, systemImage, color) = ("Changes Requested", checks, "exclamationmark.bubble.fill", .orange)
        case _ where status.review == .required || status.mergeState == "BLOCKED":
            (title, detail, systemImage, color) = ("Waiting for Review", checks, "person.crop.circle.badge.clock", .secondary)
        case _ where status.mergeState == "BEHIND":
            (title, detail, systemImage, color) = ("Behind \(base)", "\(checks) · Update the branch before merging", "arrow.down.circle.fill", .orange)
        default:
            (title, detail, systemImage, color) = ("Ready to Merge", status.review == .approved ? "Approved · \(checks)" : checks, "checkmark.circle.fill", Theme.changeAdded)
        }
    }
}

/// A banner under the branch header with the open pull request's state, polled while its checks run.
struct PullRequestBanner: View {
    let pullRequest: PullRequest
    let branch: HistoryBranch
    let history: HistoryModel

    var body: some View {
        HStack(spacing: 10) {
            if let status = history.pullRequestStatuses[pullRequest.number] {
                let summary = PullRequestSummary(pullRequest, status: status, conflictHint: conflictHint)
                Image(systemName: summary.systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(summary.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title).font(.callout.weight(.semibold))
                    Text(summary.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Link(destination: pullRequest.url.appending(path: "checks")) {
                    Label("Checks", systemImage: "arrow.up.right")
                }
                .buttonStyle(.pill(height: 26))
                .focusEffectDisabled()
            } else {
                ProgressView().controlSize(.small)
                Text("Loading pull request #\(pullRequest.number)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25)))
        .animation(.snappy(duration: 0.2), value: history.pullRequestStatuses[pullRequest.number])
        .task(id: pullRequest) {
            // Every 20 seconds while checks run, else every minute, as long as the branch is shown.
            while !Task.isCancelled {
                await history.loadStatus(of: pullRequest)
                let pending = history.pullRequestStatuses[pullRequest.number]?.hasPendingChecks ?? false
                try? await Task.sleep(for: .seconds(pending ? 20 : 60))
            }
        }
    }

    private var tint: Color {
        history.pullRequestStatuses[pullRequest.number].map { PullRequestSummary(pullRequest, status: $0).color } ?? .secondary
    }

    /// GitButler rebases onto the target when updating, which leaves conflicted commits to resolve; plain git's update
    /// only pulls the branch's own upstream, so the base has to be brought in by hand.
    private var conflictHint: String {
        if !history.isGitButler { return "Merge or rebase \(pullRequest.baseRefName) into the branch" }
        return branch.isConflicted ? "Resolve its conflicted commits with but resolve, then push" : "Update the workspace to rebase onto it"
    }
}

/// A ring of eight small blocks with one bright block circling it and a fading trail, after loading.dev's
/// spinner. Drawn in the foreground style.
struct BlockSpinner: View {
    var size: CGFloat = 12
    /// One full turn.
    var duration: Double = 1

    /// The ring's cells on a 3×3 grid, clockwise from the top left.
    private static let cells: [(x: Int, y: Int)] = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]

    var body: some View {
        TimelineView(.animation(minimumInterval: duration / 24)) { context in
            let head = Int(context.date.timeIntervalSinceReferenceDate / duration * Double(Self.cells.count)) % Self.cells.count
            Canvas { canvas, canvasSize in
                let cell = canvasSize.width / 3
                let block = cell * 0.78
                for (index, position) in Self.cells.enumerated() {
                    let behind = (head - index + Self.cells.count) % Self.cells.count
                    let opacity = [1, 0.6, 0.35].indices.contains(behind) ? [1, 0.6, 0.35][behind] : 0.15
                    let rect = CGRect(
                        x: CGFloat(position.x) * cell + (cell - block) / 2, y: CGFloat(position.y) * cell + (cell - block) / 2,
                        width: block, height: block)
                    canvas.opacity = opacity
                    canvas.fill(Path(roundedRect: rect, cornerRadius: block * 0.25), with: .foreground)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Running")
    }
}
