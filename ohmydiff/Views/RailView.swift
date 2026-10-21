import OhMyDiffCore
import SwiftUI

/// The glass rail on the left: the workspace switcher, Changes / History, the project switcher and Settings.
/// Projects are switched from the breadcrumb in the toolbar.
struct RailView: View {
    @Bindable var model: AppModel
    @Binding var mode: WorkspaceMode
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 6) {
            WorkspaceButton(model: model)
            Divider()
                .frame(width: 24)
                .padding(.vertical, 2)
            RailButton(title: "Changes", systemImage: "plusminus", isSelected: mode == .changes) { mode = .changes }
            RailButton(title: "History", systemImage: "clock", isSelected: mode == .history) { mode = .history }
            RailButton(title: "Switch Project  ⌘K", systemImage: "magnifyingglass", isSelected: model.isSwitcherPresented) {
                model.isSwitcherPresented = true
            }
            .disabled(model.projects.isEmpty)

            Spacer(minLength: 8)

            Button { SettingsWindow.open(with: openSettings) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.hover(cornerRadius: 13))
            .focusEffectDisabled()
            .glassTooltip("Settings  ⌘,", edge: .trailing)
        }
        .padding(.vertical, 12)
        .frame(width: Theme.railWidth)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .gesture(WindowDragGesture())
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { await model.addProjects(folders) }
            return true
        }
    }
}

/// The selected workspace's monogram; opens the workspace dropdown.
private struct WorkspaceButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button { model.isWorkspaceMenuPresented.toggle() } label: {
            Group {
                if let workspace = model.selectedWorkspace {
                    WorkspaceMonogram(workspace: workspace, size: 30)
                } else {
                    Image(systemName: "square.stack")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 42, height: 42)
        }
        .buttonStyle(.hover(cornerRadius: 13, isSelected: model.isWorkspaceMenuPresented))
        .focusEffectDisabled()
        .glassTooltip(model.selectedWorkspace.map { "\($0.name) — Switch Workspace" } ?? "Switch Workspace", edge: .trailing)
    }
}

private struct RailButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.hover(cornerRadius: 13, isSelected: isSelected))
        .focusEffectDisabled()
        .glassTooltip(title, edge: .trailing)
    }
}

/// A project as a two-letter monogram: `ohmydiff-large-diff` → `od`, `family` → `fa`.
func projectMonogram(_ name: String) -> String {
    let words = name.split { !$0.isLetter && !$0.isNumber }
    guard words.count > 1, let first = words.first?.first, let last = words.last?.first else {
        return String(name.prefix(2)).lowercased()
    }
    return String([first, last]).lowercased()
}
