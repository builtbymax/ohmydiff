import AppKit
import Foundation
import Observation
import SwiftUI
import OhMyDiffCore

/// The project list, the selection and one cached session per project.
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
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
        didSet { if isSwitcherPresented { isProjectMenuPresented = false } }
    }
    /// The project dropdown below the breadcrumb.
    var isProjectMenuPresented = false
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

    init(store: ProjectStore = ProjectStore(fileURL: ProjectStore.defaultFileURL), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        do {
            projects = try store.load()
            if projects.assignMissingColors() { save() }
        } catch {
            errorMessage = "Could not read the project list: \(error.localizedDescription)"
        }
        toolchainTask = Task { try? await Toolchain.discover() }

        let saved = defaults.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:))
        // `didSet` runs here too and activates the restored selection.
        selectedProjectID = projects.first { $0.id == saved }?.id ?? projects.first?.id
        warmUp()
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
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

    func select(position: Int) {
        guard projects.indices.contains(position) else { return }
        selectedProjectID = projects[position].id
    }

    private func selectionDidChange(from oldID: Project.ID?) {
        if let oldID { sessions[oldID]?.deactivate() }
        if let selectedProjectID {
            session(for: selectedProjectID).activate()
            defaults.set(selectedProjectID.uuidString, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }

    /// Loads every other project once in the background so the first switch to it is instant.
    private func warmUp() {
        let others = projects.map(\.id).filter { $0 != selectedProjectID }
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
        let project = Project(path: path, kind: repository.kind, color: ProjectColor.pick(avoiding: projects.compactMap(\.color)))
        projects.append(project)
        return project.id
    }

    func remove(_ id: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects.remove(at: index)
        sessions.removeValue(forKey: id)?.close()
        save()
        if selectedProjectID == id {
            selectedProjectID = projects.isEmpty ? nil : projects[min(index, projects.count - 1)].id
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        save()
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
            try store.save(projects)
        } catch {
            errorMessage = "Could not save the project list: \(error.localizedDescription)"
        }
    }
}
