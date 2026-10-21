import AppKit
import Foundation
import Observation
import SwiftUI
import OhMyDiffCore

/// The project list, the workspaces it is sorted into, the selection and one cached session per project.
@Observable
final class AppModel {
    /// Every project, in every workspace, in the order they were added.
    private(set) var projects: [Project] = []
    private(set) var workspaces: [Workspace] = []
    /// The workspace shown on the rail; it follows the selected project.
    private(set) var selectedWorkspaceID: Workspace.ID? {
        didSet { defaults.set(selectedWorkspaceID?.uuidString, forKey: Self.workspaceKey) }
    }
    var selectedProjectID: Project.ID? {
        didSet {
            guard oldValue != selectedProjectID else { return }
            selectionDidChange(from: oldValue)
        }
    }

    /// Changes or History, chosen on the rail or from the command palette.
    var mode: WorkspaceMode = .changes

    /// The ⌘K command palette.
    var isSwitcherPresented = false {
        didSet {
            if isSwitcherPresented {
                isProjectMenuPresented = false
                isWorkspaceMenuPresented = false
            }
        }
    }
    /// The project dropdown below the breadcrumb.
    var isProjectMenuPresented = false {
        didSet { if isProjectMenuPresented { isWorkspaceMenuPresented = false } }
    }
    /// The workspace dropdown beside the rail.
    var isWorkspaceMenuPresented = false {
        didSet { if isWorkspaceMenuPresented { isProjectMenuPresented = false } }
    }
    /// An empty workspace the user asked to delete, until they confirm.
    var pendingWorkspaceDeletion: Workspace?
    var isImporterPresented = false
    /// The sheet that updates the selected project from its remote.
    var isUpstreamUpdatePresented = false
    var errorMessage: String?
    /// An `ohmydiff://…` request for a repository that is not a project yet, until the user agrees to add it.
    var pendingURLRequest: CLIRequest?
    /// What each open diff window shows, by the ID its window was opened with.
    private(set) var popouts: [UUID: DiffPopout] = [:]

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var sessions: [Project.ID: ProjectSession] = [:]
    @ObservationIgnored private var toolchainTask: Task<Toolchain?, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let selectionKey = "selectedProjectID"
    private static let workspaceKey = "selectedWorkspaceID"

    init(store: ProjectStore = AppVariant.projectStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        var list = ProjectList()
        var loaded = false
        do {
            list = try store.load()
            loaded = true
        } catch {
            errorMessage = "Could not read the project list: \(error.localizedDescription)"
        }
        // Not saved after a failed read, so the unreadable file is not replaced by an empty list.
        let recolored = list.projects.assignMissingColors()
        let sorted = list.assignWorkspaces()
        projects = list.projects
        workspaces = list.workspaces
        if loaded, recolored || sorted { save() }
        toolchainTask = Task { try? await Toolchain.discover() }

        let saved = defaults.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:))
        let restored = projects.first { $0.id == saved }
        let savedWorkspace = defaults.string(forKey: Self.workspaceKey).flatMap(UUID.init(uuidString:))
        selectedWorkspaceID = restored?.workspaceID ?? workspaces.first { $0.id == savedWorkspace }?.id ?? workspaces.first?.id
        // `didSet` runs here too and activates the restored selection.
        selectedProjectID = restored?.id ?? visibleProjects.first?.id
        warmUp()
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// The selected workspace's projects, the most recently opened first.
    var visibleProjects: [Project] {
        projects.inWorkspace(selectedWorkspaceID)
    }

    func projects(in workspace: Workspace.ID) -> [Project] {
        projects.inWorkspace(workspace)
    }

    func workspace(of project: Project) -> Workspace? {
        workspaces.first { $0.id == project.workspaceID }
    }

    var selectedSession: ProjectSession? {
        selectedProjectID.map(session(for:))
    }

    func toolchain() async -> Toolchain? {
        await toolchainTask?.value
    }

    /// The session for a project, created on first use.
    func session(for id: Project.ID) -> ProjectSession {
        if let session = sessions[id] { return session }
        let project = projects.first { $0.id == id } ?? Project(id: id, path: "")
        let session = ProjectSession(project: project) { [weak self] in await self?.toolchain() }
        session.onKindChange = { [weak self] kind in self?.update(id) { $0.kind = kind } }
        session.onRevealFailure = { [weak self] message in self?.errorMessage = message }
        sessions[id] = session
        return session
    }

    // MARK: - Selection

    /// Selects a project of the selected workspace by its ⌘ number.
    func select(position: Int) {
        let visible = visibleProjects
        guard visible.indices.contains(position) else { return }
        selectedProjectID = visible[position].id
    }

    /// Shows a workspace with the project last opened in it, if any.
    func selectWorkspace(_ id: Workspace.ID) {
        guard workspaces.contains(where: { $0.id == id }), id != selectedWorkspaceID else { return }
        selectedWorkspaceID = id
        selectedProjectID = visibleProjects.first?.id
        warmUp()
    }

    private func selectionDidChange(from oldID: Project.ID?) {
        if let oldID { sessions[oldID]?.deactivate() }
        if let selectedProjectID {
            session(for: selectedProjectID).activate()
            defaults.set(selectedProjectID.uuidString, forKey: Self.selectionKey)
            update(selectedProjectID) { $0.lastOpenedAt = .now }
            // Opening a project of another workspace, e.g. from the palette or a link, shows that workspace.
            if let workspaceID = selectedProject?.workspaceID, workspaceID != selectedWorkspaceID {
                selectedWorkspaceID = workspaceID
                warmUp()
            }
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }

    /// Loads the selected workspace's other projects once in the background so the first switch to one is instant.
    private func warmUp() {
        let others = visibleProjects.map(\.id).filter { $0 != selectedProjectID }
        Task {
            for id in others where sessions[id]?.phase ?? .idle == .idle {
                session(for: id).refresh()
                // One at a time, so the selected project keeps priority.
                while sessions[id]?.isRefreshing == true { try? await Task.sleep(for: .milliseconds(20)) }
            }
        }
    }

    // MARK: - Editing

    /// Adds the repositories containing the given folders and selects the last one added.
    func addProjects(_ urls: [URL]) async {
        guard let toolchain = await toolchain() else {
            errorMessage = "git was not found on your login shell PATH."
            return
        }
        var failures: [String] = []
        var lastID: Project.ID?

        for url in urls {
            do {
                lastID = try await addProject(containing: url, toolchain: toolchain)
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        save()
        if let lastID { selectedProjectID = lastID }
        if !failures.isEmpty {
            errorMessage = "Not a git repository: \(failures.joined(separator: ", "))"
        }
    }

    /// The project of the repository containing `url`, added to the list (unsaved) when it is new.
    private func addProject(containing url: URL, toolchain: Toolchain) async throws -> Project.ID {
        let repository = try await Repository.open(url, toolchain: toolchain)
        let path = repository.root.standardizedFileURL.path
        if let existing = projects.first(where: { $0.url.standardizedFileURL.path == path }) { return existing.id }
        let project = Project(
            path: path, kind: repository.kind, color: ProjectColor.pick(avoiding: projects.compactMap(\.color)),
            workspaceID: selectedWorkspaceID)
        projects.append(project)
        return project.id
    }

    func remove(_ id: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects.remove(at: index)
        sessions.removeValue(forKey: id)?.close()
        save()
        if selectedProjectID == id {
            selectedProjectID = visibleProjects.first?.id
        }
    }

    /// Sorts a project into another workspace; the selected project takes the workspace view along.
    func move(_ id: Project.ID, to workspaceID: Workspace.ID) {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return }
        update(id) { $0.workspaceID = workspaceID }
        if id == selectedProjectID { selectedWorkspaceID = workspaceID }
    }

    // MARK: - Workspaces

    /// Adds a workspace and shows it, empty.
    func addWorkspace(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let workspace = Workspace(name: name, color: ProjectColor.pick(avoiding: workspaces.map(\.color)))
        workspaces.append(workspace)
        save()
        selectWorkspace(workspace.id)
    }

    func renameWorkspace(_ id: Workspace.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = name
        save()
    }

    /// Only an empty workspace can be deleted, and never the last one.
    func canDelete(_ workspace: Workspace) -> Bool {
        workspaces.count > 1 && !projects.contains { $0.workspaceID == workspace.id }
    }

    func deleteWorkspace(_ id: Workspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), canDelete(workspaces[index]) else { return }
        workspaces.remove(at: index)
        save()
        if selectedWorkspaceID == id {
            selectWorkspace(workspaces[min(index, workspaces.count - 1)].id)
        }
    }

    /// Points a moved or missing project at a new folder.
    func relocate(_ id: Project.ID, to url: URL) async {
        guard let toolchain = await toolchain() else { return }
        do {
            let repository = try await Repository.open(url, toolchain: toolchain)
            let oldName = projects.first { $0.id == id }.map { $0.url.lastPathComponent }
            update(id) { project in
                if project.displayName == oldName { project.displayName = repository.root.lastPathComponent }
                project.path = repository.root.standardizedFileURL.path
                project.kind = repository.kind
            }
            if let project = projects.first(where: { $0.id == id }) {
                sessions[id]?.relocate(to: project)
            }
        } catch {
            errorMessage = "Not a git repository: \(url.lastPathComponent)"
        }
    }

    /// Plain git: the selected project's staged files.
    var stagedTargets: [ChangeTarget] {
        selectedSession?.groups.first { $0.kind == .staged }?.files.map { ChangeTarget(file: $0) } ?? []
    }

    /// Opens the commit sheet for everything staged, in Changes mode where the sheet lives.
    func commitStaged() {
        guard let session = selectedSession, !stagedTargets.isEmpty else { return }
        mode = .changes
        session.request(.commit, on: stagedTargets)
    }

    func refreshSelected() {
        selectedSession?.refresh()
    }

    /// Keeps a diff for a new window and returns the ID to open the window with.
    func register(_ popout: DiffPopout) -> UUID {
        let id = UUID()
        popouts[id] = popout
        return id
    }

    func closePopout(_ id: UUID) {
        popouts[id] = nil
    }

    // MARK: - Integration

    /// Handles the `ohmydiff://…` URLs of the `ohmydiff` command and the MCP server: selects the repository,
    /// adding it if it is new, and shows the file, branch or commit asked for.
    func handle(_ url: URL) {
        guard let request = CLIRequest(url: url) else { return }
        NSApp.activate()
        isSwitcherPresented = false
        isProjectMenuPresented = false
        // Any web page or app can open these URLs, and adding a project runs git and but in its folder, so
        // a repository that is not a project yet is only added once the user agrees.
        guard Project.containing(request.folder, in: projects) != nil else {
            pendingURLRequest = request
            return
        }
        Task { await perform(request) }
    }

    /// Adds the repository of a request the user agreed to, then shows what it asked for.
    func confirm(_ request: CLIRequest) {
        pendingURLRequest = nil
        Task { await perform(request) }
    }

    private func perform(_ request: CLIRequest) async {
        switch request {
        case .open(let path):
            await addProjects([URL(fileURLWithPath: path, isDirectory: true)])
        case .show(let path, let line):
            let file = URL(fileURLWithPath: path)
            guard let session = await focusProject(containing: file.deletingLastPathComponent()) else { return }
            // Compare without symlinks, e.g. /var and /private/var; the file itself may be deleted.
            let root = session.project.url.resolvingSymlinksInPath().path + "/"
            let directory = file.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
            guard directory.hasPrefix(root) else { return }
            mode = .changes
            session.reveal(path: String(directory.dropFirst(root.count)) + file.lastPathComponent, line: line)
        case .branch(let path, let name):
            guard let session = await focusProject(containing: URL(fileURLWithPath: path, isDirectory: true)) else { return }
            mode = .history
            session.history.reveal(.branch(name))
            await session.refreshHistory()
        case .commit(let path, let sha):
            guard let session = await focusProject(containing: URL(fileURLWithPath: path, isDirectory: true)) else { return }
            mode = .history
            session.history.reveal(.commit(sha))
            await session.refreshHistory()
        }
    }

    /// Selects the project of the repository containing `url`, adding it when it is new.
    private func focusProject(containing url: URL) async -> ProjectSession? {
        guard let toolchain = await toolchain() else {
            errorMessage = "git was not found on your login shell PATH."
            return nil
        }
        do {
            let id = try await addProject(containing: url, toolchain: toolchain)
            save()
            selectedProjectID = id
            return session(for: id)
        } catch {
            errorMessage = "Not a git repository: \(url.path)"
            return nil
        }
    }

    /// Opens the file at its line with the editor chosen in Settings.
    func openInEditor(_ target: DiffFileTarget) {
        guard let template = AppSettings.editorTemplate() else {
            errorMessage = EditorError.emptyCommand.description
            return
        }
        Task {
            guard let toolchain = await toolchain() else { return }
            do {
                try await EditorCommand.open(template: template, file: target.url.path, line: target.line ?? 1, toolchain: toolchain)
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    /// Starts the AI provider in the terminal chosen in Settings, in the repository, with the prompt.
    func openInClaudeCode(prompt: String, root: URL) {
        Task {
            guard let toolchain = await toolchain() else { return }
            do {
                try await ClaudeCodeLauncher.open(
                    prompt: prompt, in: root, provider: AppSettings.aiProvider(), terminal: AppSettings.terminal(), toolchain: toolchain)
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    func copyPrompt(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    var claudeCodeActions: ClaudeCodeActions {
        ClaudeCodeActions(open: { [weak self] in self?.openInClaudeCode(prompt: $0, root: $1) }, copy: { [weak self] in self?.copyPrompt($0) })
    }

    func copyPath(_ target: DiffFileTarget) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.relativePath, forType: .string)
    }

    private func update(_ id: Project.ID, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[index])
        save()
    }

    private func save() {
        do {
            try store.save(ProjectList(projects: projects, workspaces: workspaces))
        } catch {
            errorMessage = "Could not save the project list: \(error.localizedDescription)"
        }
    }
}
