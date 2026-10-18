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

    var body: some View {
        ZStack(alignment: .topLeading) {
            Backdrop()

            HStack(spacing: 0) {
                ListPaneView(model: model, mode: mode)
                    .frame(width: 340)
                    .background(Theme.column)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                DetailPaneView(model: model, mode: mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                WorkspaceToolbar(model: model, mode: $mode)
            }
            .background(Theme.panel)
            .clipShape(.rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline))
            .padding(.leading, Theme.railWidth + Theme.inset + 8)
            .padding([.top, .bottom, .trailing], 8)

            RailView(model: model, mode: $mode)
                .padding(Theme.inset)
        }
        .ignoresSafeArea()
        .frame(minWidth: 1040, minHeight: 620)
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
            ContentUnavailableView {
                Label("No Projects", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a git repository or drop a folder on the rail.")
            } actions: {
                Button("Add Project…") { model.isImporterPresented = true }
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
            ContentUnavailableView("No Selection", systemImage: "text.alignleft")
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
