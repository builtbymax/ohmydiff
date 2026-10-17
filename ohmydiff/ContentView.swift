import OhMyDiffCore
import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case history = "History"

    var id: Self { self }
}

struct ContentView: View {
    @State private var mode: WorkspaceMode = .changes
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ListPaneView(mode: mode)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            DetailPaneView()
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
    }
}

private struct SidebarView: View {
    var body: some View {
        List {
            Section("Branches") {}
        }
        .listStyle(.sidebar)
        .overlay {
            ContentUnavailableView("No Repository", systemImage: "folder")
        }
    }
}

private struct ListPaneView: View {
    let mode: WorkspaceMode

    var body: some View {
        ContentUnavailableView(
            mode == .changes ? "No Changes" : "No History",
            systemImage: mode == .changes ? "doc.badge.plus" : "clock"
        )
        .navigationTitle(mode.rawValue)
    }
}

private struct DetailPaneView: View {
    var body: some View {
        ContentUnavailableView("No Selection", systemImage: "text.alignleft")
            .backgroundExtensionEffect()
    }
}

#Preview {
    ContentView()
}
