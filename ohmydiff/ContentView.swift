import AppKit
import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The pages of the sidebar.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case branches = "Branches"
    case pullRequests = "Pull requests"
    case history = "History"

    var id: Self { self }
    var title: String { rawValue }

    /// The pages built so far, in sidebar order.
    static let available: [WorkspaceMode] = [.changes, .history]

    var systemImage: String {
        switch self {
        case .changes: "tray"
        case .branches: "arrow.triangle.branch"
        case .pullRequests: "arrow.triangle.pull"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// ⌘1–⌘4.
    var shortcut: KeyEquivalent {
        switch self {
        case .changes: "1"
        case .branches: "2"
        case .pullRequests: "3"
        case .history: "4"
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    @AppStorage(AppSettings.listWidthKey) private var listWidth = 300.0
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.isSidebarHiddenKey) private var isSidebarHidden = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarHidden {
                SidebarView(model: model, isHidden: $isSidebarHidden)
                    .padding(.top, Theme.inset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            panel
                .padding(.vertical, Theme.inset)
                .padding(.trailing, Theme.inset)
                .padding(.leading, isSidebarHidden ? Theme.inset : 1)
        }
        .background(Theme.sidebar)
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if model.isProjectMenuPresented {
                    ProjectSwitcher(model: model)
                }
                if model.isWorkspaceMenuPresented {
                    WorkspaceDropdown(model: model)
                }
            }
            .animation(Theme.popoverAnimation, value: model.isProjectMenuPresented)
            .animation(Theme.popoverAnimation, value: model.isWorkspaceMenuPresented)
        }
        .overlay {
            ZStack {
                if model.isSwitcherPresented {
                    CommandPalette(model: model)
                }
            }
            .animation(Theme.launcherAnimation, value: model.isSwitcherPresented)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task(id: appearance) { appearance.apply() }
        .task(id: model.selectedSession?.lastRefreshed) {
            // The sidebar lists the project's branches and pull requests on every page.
            await model.selectedSession?.refreshHistory()
        }
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
        .onChange(of: isSidebarHidden) { model.isProjectMenuPresented = false }
    }

    /// The content panel: the page's top bar over its body.
    private var panel: some View {
        VStack(spacing: 0) {
            PageTopBar(model: model, mode: model.mode, leadingInset: isSidebarHidden ? 72 : 0, isSidebarHidden: $isSidebarHidden)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            pageBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .updateBar(Updater.shared)
        .background(Theme.canvas)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.lineSubtle))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }

    @ViewBuilder
    private var pageBody: some View {
        if let session = model.selectedSession {
            switch model.mode {
            case .changes, .branches, .pullRequests:
                HStack(spacing: 0) {
                    if !isListHidden {
                        ChangesListView(model: model, session: session)
                            .frame(width: listWidth)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                            }
                            .overlay(alignment: .trailing) { ColumnResizer(width: $listWidth, range: AppSettings.listWidths) }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    DiffDetailView(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .history:
                HStack(spacing: 0) {
                    HistoryListView(session: session)
                        .frame(width: listWidth)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.lineSubtle).frame(width: 1) }
                        .overlay(alignment: .trailing) { ColumnResizer(width: $listWidth, range: AppSettings.listWidths) }
                    HistoryDetailView(history: session.history, root: session.rootURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            let title = model.projects.isEmpty ? "No projects yet" : "No projects in \(model.selectedWorkspace?.name ?? "this workspace")"
            EmptyState(title, systemImage: "folder", description: "Add a git repository, or drop a folder on the sidebar.") {
                Button("Add project…") { model.isImporterPresented = true }
                    .buttonStyle(.pill(.prominent))
            }
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
