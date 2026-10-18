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

    var isSwitcherPresented = false {
        didSet { if isSwitcherPresented { isProjectMenuPresented = false } }
    }
    /// The project dropdown below the breadcrumb.
    var isProjectMenuPresented = false
    var isImporterPresented = false
    var errorMessage: String?
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
                let repository = try await Repository.open(url, toolchain: toolchain)
                let path = repository.root.standardizedFileURL.path
                if let existing = projects.first(where: { $0.url.standardizedFileURL.path == path }) {
                    lastID = existing.id
                    continue
                }
                let project = Project(path: path, kind: repository.kind)
                projects.append(project)
                lastID = project.id
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

    /// Handles `ohmydiff://open?path=…` from the `ohmydiff` command: adds the folder's repository if it
    /// is new and selects it.
    func handle(_ url: URL) {
        guard let path = CLILauncher.openRequestPath(url) else { return }
        NSApp.activate()
        Task { await addProjects([URL(fileURLWithPath: path, isDirectory: true)]) }
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
