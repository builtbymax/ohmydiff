import OhMyDiffCore
import SwiftUI

/// The left column: the project, the launcher, the pages, the branches of the project and the footer.
struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var isHidden: Bool
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleBar
            ProjectSwitcherButton(model: model)
            LauncherField(model: model)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ForEach(WorkspaceMode.available) { page in
                NavRow(page: page, count: count(for: page), isSelected: model.mode == page) { model.mode = page }
            }
            ScrollView {
                if let session = model.selectedSession, session.phase == .ready {
                    SidebarBranches(model: model, session: session)
                        .padding(.top, 10)
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { await model.addProjects(folders) }
            return true
        }
    }

    /// Room for the window controls, and the button that hides the sidebar.
    private var titleBar: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(WindowDragGesture())
            IconButton("Hide Sidebar  ⌃⌘S", systemImage: "sidebar.left") {
                withAnimation(.snappy(duration: 0.2)) { isHidden = true }
            }
        }
        .frame(height: 40)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            IconButton("Settings  ⌘,", systemImage: "slider.horizontal.3", tooltipEdge: .top) {
                SettingsWindow.open(with: openSettings)
            }
            IconButton(isDark ? "Paper Theme  ⌥⌘T" : "Graphite Theme  ⌥⌘T", systemImage: isDark ? "moon" : "sun.max", tooltipEdge: .top) {
                appearance = isDark ? .light : .dark
            }
            IconButton("Shortcuts", systemImage: "keyboard", tooltipEdge: .top) {
                SettingsWindow.open(.general, with: openSettings)
            }
            Spacer(minLength: 4)
            ToolVersionChip(model: model)
        }
        .frame(height: 32)
    }

    private var isDark: Bool { colorScheme == .dark }

    private func count(for page: WorkspaceMode) -> Int? {
        guard let session = model.selectedSession, session.phase == .ready else { return nil }
        switch page {
        case .changes: return session.changeCount
        case .branches: return session.history.groups.flatMap(\.branches).count
        case .pullRequests: return session.history.openPullRequestCount
        case .history: return nil
        }
    }
}

/// The selected project with its workspace and kind; opens the project switcher.
private struct ProjectSwitcherButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button { model.isProjectMenuPresented.toggle() } label: {
            HStack(spacing: 10) {
                if let project = model.selectedProject {
                    ProjectAvatar(name: project.displayName, isCurrent: true, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project.displayName)
                            .font(.projectName)
                            .foregroundStyle(Theme.textPrimary)
                        Text(model.workspace(of: project)?.name ?? "")
                            .font(.caption11)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    KindChip(kind: project.kind, isMissing: model.selectedSession?.phase == .missing)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Theme.hover, in: .rect(cornerRadius: 8))
                    Text("Add Project")
                        .font(.projectName)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 4)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 10, isSelected: model.isProjectMenuPresented))
        .focusEffectDisabled()
    }
}

/// `Search or run… ⌘K`: opens the launcher.
private struct LauncherField: View {
    @Bindable var model: AppModel

    var body: some View {
        Button { model.isSwitcherPresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                Text("Search or run…")
                    .font(.control)
                Spacer(minLength: 4)
                KeyCap("⌘K")
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.hover, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.lineSubtle))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

private struct NavRow: View {
    let page: WorkspaceMode
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 15, height: 15)
                Text(page.title)
                    .font(.row.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.detail)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.row(isSelected: isSelected))
        .focusEffectDisabled()
    }
}

/// GitButler: the applied branches and the unassigned changes. Plain git: the checked-out branch and the
/// other local branches.
private struct SidebarBranches: View {
    @Bindable var model: AppModel
    let session: ProjectSession

    var body: some View {
        let history = session.history
        if session.project.kind == .gitButler {
            VStack(alignment: .leading, spacing: 2) {
                SidebarSection(title: "Applied branches")
                ForEach(history.groups.filter { $0.kind == .stack }.flatMap(\.branches)) { branch in
                    BranchRow(
                        name: branch.name, systemImage: "arrow.triangle.branch", pullRequest: history.pullRequest(of: branch),
                        isSelected: isSelected(branch.name)
                    ) { select(branch.name) }
                }
                if let unassigned = session.groups.first(where: { $0.kind == .unassigned }) {
                    BranchRow(name: "Unassigned", systemImage: "tray", trailing: unassigned.files.isEmpty ? nil : "\(unassigned.files.count)", isSelected: false) {
                        model.mode = .changes
                        session.select(group: unassigned.id)
                    }
                }
            }
        } else {
            let branches = history.groups.flatMap(\.branches)
            let current = branches.first(where: \.isCurrent)
            VStack(alignment: .leading, spacing: 2) {
                if let current {
                    SidebarSection(title: "Current branch")
                    BranchRow(
                        name: current.name, systemImage: "checkmark", trailing: aheadBehind(current), pullRequest: history.pullRequest(of: current),
                        isSelected: true, isCurrent: true
                    ) { select(current.name) }
                }
                let others = branches.filter { !$0.isCurrent }
                if !others.isEmpty {
                    SidebarSection(title: "Local")
                        .padding(.top, 6)
                    ForEach(others.prefix(8)) { branch in
                        BranchRow(
                            name: branch.name, systemImage: "arrow.triangle.branch", trailing: age(branch), pullRequest: history.pullRequest(of: branch),
                            isSelected: false
                        ) { select(branch.name) }
                    }
                }
            }
        }
    }

    private func isSelected(_ branch: String) -> Bool {
        switch model.mode {
        case .history, .branches: session.history.selectedBranch?.name == branch
        case .changes, .pullRequests: session.selectedFile.flatMap { session.assignedBranch(of: $0.path) } == branch
        }
    }

    /// Changes: the branch's files; elsewhere its commits in History.
    private func select(_ branch: String) {
        if model.mode == .changes, let group = session.groups.first(where: {
            if case .stack(_, let branches) = $0.kind { return branches.contains(branch) }
            return false
        }) {
            session.select(group: group.id)
        } else {
            if model.mode != .branches { model.mode = .history }
            session.history.reveal(.branch(branch))
        }
    }

    private func aheadBehind(_ branch: HistoryBranch) -> String? {
        guard case .tracking(let ahead, let behind)? = branch.status else { return nil }
        return "↑\(ahead) ↓\(behind)"
    }

    private func age(_ branch: HistoryBranch) -> String? {
        branch.commits.first?.date.map { RelativeAge.short($0) }
    }
}

/// `Applied branches  +`
struct SidebarSection: View {
    let title: String
    var actionImage: String?
    var actionTitle = ""
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.sectionLabel)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 4)
            if let actionImage {
                Button(action: action) {
                    Image(systemName: actionImage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.hover(cornerRadius: 6))
                .focusEffectDisabled()
                .glassTooltip(actionTitle)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }
}

private struct BranchRow: View {
    let name: String
    let systemImage: String
    var trailing: String?
    var pullRequest: PullRequest?
    let isSelected: Bool
    var isCurrent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: isCurrent ? 12 : 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.okFg : isSelected ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 15, height: 15)
                Text(name)
                    .font(.row.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let pullRequest {
                    PullRequestNumber(pullRequest: pullRequest, isSelected: isSelected)
                } else if let trailing {
                    Text(trailing)
                        .font(.caption11)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.row(isSelected: isSelected))
        .focusEffectDisabled()
    }
}

/// `⇅ #142`: green while open, grey as a draft, violet once merged.
struct PullRequestNumber: View {
    let pullRequest: PullRequest
    var isSelected = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: pullRequest.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                .font(.system(size: 9.5, weight: .medium))
                .frame(width: 12, height: 12)
            Text("#\(pullRequest.number)")
                .font(.sectionLabel)
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .fixedSize()
    }

    private var color: Color {
        if pullRequest.state == .merged { return Theme.mergedFg }
        if pullRequest.isDraft || !isSelected && pullRequest.state != .open { return Theme.textTertiary }
        return isSelected ? Theme.okFg : Theme.textTertiary
    }
}

/// `but 0.23.1` or `git 2.47`: green when the release was tested, amber when it was not.
private struct ToolVersionChip: View {
    let model: AppModel

    var body: some View {
        if let session = model.selectedSession, session.project.kind == .gitButler {
            let isUntested = session.butVersionMismatch != nil || session.butIncompatibility != nil
            Chip(
                "but \(model.butVersion?.description ?? "")", systemImage: isUntested ? "exclamationmark.circle" : "checkmark.circle",
                tone: isUntested ? .warn : .ok)
                .glassTooltip(session.butIncompatibility?.description ?? session.butVersionMismatch?.description ?? "Tested GitButler release", edge: .top)
        } else if let git = model.gitVersion {
            Chip("git \(git)", systemImage: "checkmark.circle", tone: .ok)
        }
    }
}

/// `but` in blue for GitButler projects, a grey `git` otherwise.
struct KindChip: View {
    let kind: RepositoryKind
    var isMissing = false

    var body: some View {
        if isMissing {
            Chip("missing", systemImage: "questionmark.folder", tone: .warn)
        } else if kind == .gitButler {
            Chip("but", systemImage: "square.3.layers.3d", tone: .info)
        } else {
            Chip("git", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
    }
}

/// A project's first letter: inverse for the open project, a soft tile otherwise.
struct ProjectAvatar: View {
    let name: String
    var isCurrent = false
    var size: CGFloat = 24

    var body: some View {
        Text(name.first.map { String($0).lowercased() } ?? "?")
            .font(.system(size: size >= 26 ? 13 : 12, weight: .semibold))
            .foregroundStyle(isCurrent ? Theme.textInverse : Theme.textSecondary)
            .frame(width: size, height: size)
            .background(isCurrent ? Theme.inverse : Theme.hover, in: .rect(cornerRadius: size >= 26 ? 8 : 7))
    }
}

/// `now`, `4s`, `12m`, `2h`, `3d`: the compact ages of lists.
enum RelativeAge {
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        case ..<(86_400 * 30): return "\(seconds / 86_400)d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
