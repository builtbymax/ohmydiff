import AppKit
import OhMyDiffCore
import SwiftUI

/// The popover below the sidebar's project row (⌘P): a search field, the workspaces as tabs, the
/// workspace's projects, matches from other workspaces, and adding projects and managing workspaces.
struct ProjectSwitcher: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var shownWorkspaceID: Workspace.ID?
    @State private var highlighted: Project.ID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .onTapGesture(perform: dismiss)
            panel
                .padding(.leading, 14)
                .padding(.top, 96)
                .popoverTransition(anchor: .topLeading)
        }
        .ignoresSafeArea()
    }

    private var panel: some View {
        let (projects, others) = lists
        return VStack(alignment: .leading, spacing: 2) {
            search
            if query.isEmpty, model.workspaces.count > 1, AppSettings.isOn(AppSettings.groupsWorkspacesKey) {
                workspaceTabs
            }
            ForEach(projects) { project in
                row(project)
            }
            if projects.isEmpty, others.isEmpty {
                Text(query.isEmpty ? "No projects in this workspace" : "No matching projects")
                    .font(.control)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            if !others.isEmpty {
                divider
                Text("Other workspaces")
                    .font(.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                ForEach(others) { project in
                    row(project)
                }
            }
            divider
            action("Add project…", systemImage: "plus", shortcut: "⇧⌘O") { model.isImporterPresented = true }
            action("Manage workspaces", systemImage: "square.grid.2x2") { model.isWorkspaceMenuPresented = true }
        }
        .padding(6)
        .frame(width: 330)
        .popoverSurface(in: .rect(cornerRadius: 14))
        .paletteKeys(up: { move(-1) }, down: { move(1) }, choose: chooseHighlighted, dismiss: dismiss)
        .onAppear {
            shownWorkspaceID = model.selectedWorkspaceID
            highlighted = model.selectedProjectID
            isSearchFocused = true
        }
        .onChange(of: query) { highlighted = lists.projects.first?.id ?? lists.others.first?.id }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14, height: 14)
            TextField("Switch project…", text: $query)
                .textFieldStyle(.plain)
                .font(.row)
                .focused($isSearchFocused)
            KeyCap("⌘P")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    /// `Personal 4 | Client 2 | OSS 5  +`
    private var workspaceTabs: some View {
        HStack(spacing: 6) {
            MagneticSegments(
                selection: Binding(get: { shownWorkspaceID ?? model.selectedWorkspaceID }, set: { shownWorkspaceID = $0 }),
                options: model.workspaces.map { (Optional($0.id), $0.name) },
                counts: Dictionary(uniqueKeysWithValues: model.workspaces.map { (Optional($0.id), "\(model.projects(in: $0.id).count)") }),
                isEqualWidth: true, font: .detail, horizontalPadding: 8, height: 24
            ) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.raised)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
            }
            .padding(2)
            .frame(maxWidth: .infinity)
            .background(Theme.hover, in: .rect(cornerRadius: 9))
            IconButton("New Workspace…", systemImage: "plus", size: 26) {
                model.isWorkspaceMenuPresented = true
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func row(_ project: Project) -> some View {
        Button { select(project) } label: {
            ProjectRow(model: model, project: project, isCurrent: project.id == model.selectedProjectID, showsShortcut: true, showsWorkspace: true)
        }
        .buttonStyle(.hover(cornerRadius: 9, isSelected: project.id == highlighted))
        .focusEffectDisabled()
        .contextMenu { ProjectMenuItems(model: model, project: project) }
    }

    private var divider: some View {
        Rectangle().fill(Theme.lineSubtle).frame(height: 1)
    }

    private func action(_ title: String, systemImage: String, shortcut: String? = nil, perform: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            perform()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.control)
                Spacer()
                if let shortcut { KeyCap(shortcut) }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 8))
        .focusEffectDisabled()
    }

    /// The shown workspace's projects, and, while searching, matches from the other workspaces.
    private var lists: (projects: [Project], others: [Project]) {
        guard AppSettings.isOn(AppSettings.groupsWorkspacesKey) else {
            return (query.isEmpty ? model.projects : FuzzyMatcher.rank(model.projects, query: query) { $0.displayName }.map(\.item), [])
        }
        let workspaceID = shownWorkspaceID ?? model.selectedWorkspaceID
        if query.isEmpty {
            return (workspaceID.map(model.projects(in:)) ?? model.visibleProjects, [])
        }
        let ranked = FuzzyMatcher.rank(model.projects, query: query) { $0.displayName }.map(\.item)
        return (ranked.filter { $0.workspaceID == workspaceID }, ranked.filter { $0.workspaceID != workspaceID })
    }

    private func move(_ delta: Int) {
        let all = lists.projects + lists.others
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : 0)
        highlighted = all[(index + delta + all.count) % all.count].id
    }

    private func chooseHighlighted() {
        guard let project = (lists.projects + lists.others).first(where: { $0.id == highlighted }) else { return }
        select(project)
    }

    private func select(_ project: Project) {
        model.selectedProjectID = project.id
        dismiss()
    }

    private func dismiss() {
        model.isProjectMenuPresented = false
    }
}

/// Show in Finder, Move to Workspace and Remove, for a project's context menu.
private struct ProjectMenuItems: View {
    let model: AppModel
    let project: Project

    var body: some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            .disabled(!project.exists)
        if model.workspaces.count > 1 {
            Menu("Move to Workspace") {
                ForEach(model.workspaces.filter { $0.id != project.workspaceID }) { workspace in
                    Button(workspace.name) { model.move(project.id, to: workspace.id) }
                }
            }
        }
        Divider()
        Button("Remove \(project.displayName)", role: .destructive) { model.remove(project.id) }
    }
}

/// A project in the switcher or the launcher: its letter, name, what is going on in it, its kind and
/// ⌃ shortcut.
struct ProjectRow: View {
    let model: AppModel
    let project: Project
    var nameIndices: [Int] = []
    var isCurrent = false
    var showsShortcut = false
    var showsWorkspace = false

    var body: some View {
        let session = model.session(for: project.id)
        let isOtherWorkspace = project.workspaceID != model.selectedWorkspaceID
        HStack(spacing: 10) {
            ProjectAvatar(name: project.displayName, isCurrent: isCurrent)
            VStack(alignment: .leading, spacing: 0) {
                Text(highlightedName)
                    .font(.row)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle(session, isOtherWorkspace: isOtherWorkspace && showsWorkspace))
                    .font(.caption11)
                    .foregroundStyle(isBehind(session) ? Theme.warnFg : Theme.textTertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            KindChip(kind: project.kind, isMissing: session.phase == .missing)
            if showsShortcut, let position = model.projects.firstIndex(where: { $0.id == project.id }), position < 9 {
                KeyCap("⌃\(position + 1)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .contentShape(.rect)
    }

    /// `3 branches · 12 changes`, `main · 2 behind`, `main · clean`, or `Client · feature/x` from another workspace.
    private func subtitle(_ session: ProjectSession, isOtherWorkspace: Bool) -> String {
        if session.phase == .missing { return (project.path as NSString).abbreviatingWithTildeInPath }
        let branch = session.currentBranch ?? session.branchNames.first
        if isOtherWorkspace {
            return [model.workspace(of: project)?.name, branch].compactMap(\.self).joined(separator: " · ")
        }
        guard session.phase == .ready else { return (project.path as NSString).abbreviatingWithTildeInPath }
        let changes = switch session.changeCount {
        case 0: "no changes"
        case 1: "1 change"
        default: "\(session.changeCount) changes"
        }
        if project.kind == .gitButler {
            let count = session.branchNames.count
            return "\(count == 1 ? "1 branch" : "\(count) branches") · \(changes)"
        }
        let state = isBehind(session) ? "\(session.upstream?.incoming.count ?? 0) behind" : session.changeCount == 0 ? "clean" : changes
        return [branch, state].compactMap(\.self).joined(separator: " · ")
    }

    private func isBehind(_ session: ProjectSession) -> Bool {
        project.kind != .gitButler && (session.upstream?.incoming.isEmpty == false)
    }

    private var highlightedName: AttributedString {
        var result = AttributedString()
        let matched = Set(nameIndices)
        for (offset, character) in project.displayName.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        return result
    }
}
