import AppKit
import OhMyDiffCore
import SwiftUI

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

extension View {
    /// The pull request sheet, force push and merge confirmations, and errors of History's branch actions.
    func branchActionPresentation(_ history: HistoryModel, suggestions: @escaping () async -> Suggestions?) -> some View {
        modifier(BranchActionPresentation(history: history, suggestions: suggestions))
    }
}

private struct BranchActionPresentation: ViewModifier {
    @Bindable var history: HistoryModel
    let suggestions: () async -> Suggestions?
    @State private var newName = ""

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
                "Rename \(history.pendingRename?.name ?? "")",
                isPresented: Binding(get: { history.pendingRename != nil }, set: { if !$0 { history.pendingRename = nil } }),
                presenting: history.pendingRename
            ) { branch in
                TextField("Branch name", text: $newName)
                Button("Rename") { Task { await history.renameBranch(branch, to: newName) } }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { branch in
                Text(branch.status == nil || branch.status == .unpushed
                    ? "The new name for the branch."
                    : "Its remote copy keeps the old name until the branch is pushed again.")
            }
            .onChange(of: history.pendingRename?.name) { _, name in newName = name ?? "" }
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
        if history.isGitButler {
            let commits = branches.reduce(0) { $0 + $1.commits.count }
            lines.append(commits == 0
                ? "The branch has no commits. It is taken out of the workspace."
                : "Its \(commits == 1 ? "commit is" : "\(commits) commits are") deleted with it. Undo it from GitButler's operations history.")
            return lines.joined(separator: "\n\n")
        }
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

/// `GitHub`, `GitLab` or the host of other remotes.
struct RemoteHost {
    let name: String

    init(_ url: URL) {
        name = switch url.host() {
        case "github.com": "GitHub"
        case "gitlab.com": "GitLab"
        case "bitbucket.org": "Bitbucket"
        case let host: host ?? "Remote"
        }
    }
}
