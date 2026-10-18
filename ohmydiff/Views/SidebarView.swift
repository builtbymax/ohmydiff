import AppKit
import OhMyDiffCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedProjectID) {
            Section("Projects") {
                ForEach(model.projects) { project in
                    ProjectRow(project: project, session: model.session(for: project.id))
                        .tag(project.id)
                        .contextMenu { contextMenu(for: project) }
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let id = model.selectedProjectID { model.remove(id) }
        }
        .overlay {
            if model.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a git repository or drop a folder here.")
                } actions: {
                    Button("Add Project…") { model.isImporterPresented = true }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { await model.addProjects(folders) }
            return true
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Add Project", systemImage: "plus") { model.isImporterPresented = true }
                    .help("Add Project (⇧⌘O)")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        .disabled(!project.exists)
        Button("Refresh") { model.session(for: project.id).refresh() }
        Divider()
        Button("Remove from Sidebar", role: .destructive) { model.remove(project.id) }
    }
}

private struct ProjectRow: View {
    let project: Project
    let session: ProjectSession

    var body: some View {
        Label {
            Text(project.displayName)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(session.phase == .missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
        }
        .badge(session.changeCount > 0 ? session.changeCount : 0)
        .help(project.path)
    }

    private var icon: String {
        switch session.phase {
        case .missing: "exclamationmark.triangle"
        default: project.kind == .gitButler ? "square.stack.3d.up" : "folder"
        }
    }
}
