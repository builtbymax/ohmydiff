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

    @AppStorage(AppSettings.listWidthKey) private var listWidth = 340.0
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        HStack(spacing: Theme.inset) {
            RailView(model: model, mode: $mode)
                .padding(.top, Theme.titleBarHeight)
                // Above the panel, so its tooltips are not hidden behind it.
                .zIndex(1)

            HStack(spacing: 0) {
                if !isListHidden {
                    ListPaneView(model: model, mode: mode)
                        .frame(width: listWidth)
                        .background(Theme.column)
                        .overlay(alignment: .trailing) { ColumnResizer(width: $listWidth) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                DetailPaneView(model: model, mode: mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A bar, not an overlay: lists scrolled under it fade out instead of colliding with the controls.
            .safeAreaBar(edge: .top) {
                WorkspaceToolbar(model: model, mode: mode)
            }
            .background(Theme.panel)
            .clipShape(.rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
        }
        .padding(Theme.inset)
        .background { WindowTranslucency().ignoresSafeArea() }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            if model.isProjectMenuPresented {
                ProjectDropdown(model: model)
            }
        }
        .overlay {
            if model.isSwitcherPresented {
                ProjectSwitcher(model: model)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.isProjectMenuPresented)
        .animation(.snappy(duration: 0.2), value: model.isSwitcherPresented)
        .frame(minWidth: 900, minHeight: 560)
        .task(id: appearance) { appearance.apply() }
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

/// The hairline between the file list and the diff; drag it to resize the list.
private struct ColumnResizer: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(.rect)
                    .pointerStyle(.frameResize(position: .trailing))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = (start + value.translation.width).clamped(to: AppSettings.listWidths)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
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
