import AppKit
import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case history = "History"

    var id: Self { self }
}

struct ContentView: View {
    @Bindable var model: AppModel

    @AppStorage(AppSettings.listWidthKey) private var listWidth = 340.0
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        HStack(spacing: Theme.inset) {
            RailView(model: model, mode: $model.mode)
                .padding(.top, Theme.titleBarHeight)
                // Above the panel, so its tooltips are not hidden behind it.
                .zIndex(1)

            HStack(spacing: 0) {
                if !isListHidden {
                    ListPaneView(model: model, mode: model.mode)
                        .frame(width: listWidth)
                        .background(Theme.column)
                        .overlay(alignment: .trailing) { ColumnResizer(width: $listWidth, range: AppSettings.listWidths) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                DetailPaneView(model: model, mode: model.mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A bar, not an overlay: lists scrolled under it fade out instead of colliding with the controls.
            .safeAreaBar(edge: .top) {
                WorkspaceToolbar(model: model, mode: model.mode)
            }
            .updateBar(Updater.shared)
            .background(Theme.panel)
            .clipShape(.rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
        }
        .padding(Theme.inset)
        .background { WindowTranslucency().ignoresSafeArea() }
        .ignoresSafeArea()
        // The animations apply to the overlays only: what a palette command changes while the palette
        // closes, e.g. the mode or the list's visibility, must not animate the whole window with it.
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if model.isProjectMenuPresented {
                    ProjectDropdown(model: model)
                }
                if model.isWorkspaceMenuPresented {
                    WorkspaceDropdown(model: model)
                }
            }
            .animation(.snappy(duration: 0.2), value: model.isProjectMenuPresented)
            .animation(.snappy(duration: 0.2), value: model.isWorkspaceMenuPresented)
        }
        .overlay {
            ZStack {
                if model.isSwitcherPresented {
                    CommandPalette(model: model)
                }
            }
            .animation(.snappy(duration: 0.2), value: model.isSwitcherPresented)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task(id: appearance) { appearance.apply() }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addProjects(urls) }
        }
        .sheet(isPresented: $model.isUpstreamUpdatePresented) {
            if let session = model.selectedSession {
                UpstreamUpdateSheet(session: session)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Add this repository?",
            isPresented: Binding(get: { model.pendingURLRequest != nil }, set: { if !$0 { model.pendingURLRequest = nil } }),
            presenting: model.pendingURLRequest
        ) { request in
            Button("Add Project") { model.confirm(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("A link or another app asked ohmydiff to open \(request.folder.path). Adding it runs git and but in that folder, so only add repositories you trust.")
        }
        .alert(
            "Delete “\(model.pendingWorkspaceDeletion?.name ?? "")”?",
            isPresented: Binding(get: { model.pendingWorkspaceDeletion != nil }, set: { if !$0 { model.pendingWorkspaceDeletion = nil } }),
            presenting: model.pendingWorkspaceDeletion
        ) { workspace in
            Button("Delete", role: .destructive) { model.deleteWorkspace(workspace.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The workspace is empty. Deleting it cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Catch up on anything the watcher cannot see, e.g. changes made while the Mac slept.
            model.refreshSelected()
        }
    }
}

private struct ListPaneView: View {
    let model: AppModel
    let mode: WorkspaceMode

    var body: some View {
        if let session = model.selectedSession {
            switch mode {
            case .changes:
                ChangesListView(model: model, session: session)
            case .history:
                HistoryListView(session: session)
            }
        } else {
            let title = model.projects.isEmpty ? "No Projects" : "No Projects in \(model.selectedWorkspace?.name ?? "This Workspace")"
            EmptyState(title, systemImage: "folder.badge.plus", description: "Add a git repository or drop a folder on the rail.") {
                Button("Add Project…") { model.isImporterPresented = true }
                    .buttonStyle(.pill(.prominent))
            }
        }
    }
}

private struct DetailPaneView: View {
    let model: AppModel
    let mode: WorkspaceMode

    var body: some View {
        if let session = model.selectedSession {
            switch mode {
            case .changes: DiffDetailView(session: session)
            case .history: HistoryDetailView(history: session.history, root: session.rootURL)
            }
        } else {
            EmptyState("No Selection", systemImage: "text.alignleft")
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
