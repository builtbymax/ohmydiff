import OhMyDiffCore
import SwiftUI

struct ProjectCommands: Commands {
    let model: AppModel

    @AppStorage(DiffSettings.layoutKey) private var diffLayout: DiffLayoutMode = .unified

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Project…") { model.isImporterPresented = true }
                .keyboardShortcut("o")
        }

        CommandGroup(before: .sidebar) {
            Toggle("Side-by-Side Diff", isOn: Binding(
                get: { diffLayout == .split },
                set: { diffLayout = $0 ? .split : .unified }))
                .keyboardShortcut("\\")
            Divider()
        }

        CommandMenu("Go") {
            Button("Switch Project…") { model.isSwitcherPresented = true }
                .keyboardShortcut("k")
                .disabled(model.projects.isEmpty)

            Divider()

            ForEach(0..<9, id: \.self) { position in
                Button(model.projects.indices.contains(position) ? model.projects[position].displayName : "Project \(position + 1)") {
                    model.select(position: position)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")))
                .disabled(!model.projects.indices.contains(position))
            }

            Divider()

            Button("Refresh") { model.refreshSelected() }
                .keyboardShortcut("r")
                .disabled(model.selectedProjectID == nil)
        }
    }
}
