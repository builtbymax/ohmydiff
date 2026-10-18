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
    @State private var mode: WorkspaceMode = .changes
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ListPaneView(model: model, mode: mode)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            DetailPaneView(model: model, mode: mode)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $model.isSwitcherPresented) {
            ProjectSwitcher(model: model)
        }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addProjects(urls) }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
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
            ContentUnavailableView("No Project Selected", systemImage: "folder")
                .navigationTitle(mode.rawValue)
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
            case .history: HistoryDetailView(history: session.history)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "text.alignleft")
                .backgroundExtensionEffect()
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
