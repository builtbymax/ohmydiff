import OhMyDiffCore
import SwiftUI

struct ProjectCommands: Commands {
    let model: AppModel

    @AppStorage(DiffSettings.layoutKey) private var diffLayout: DiffLayoutMode = .unified
    @AppStorage(DiffSettings.wholeFileKey) private var showsWholeFile = false
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @FocusedValue(\.diffFile) private var diffFile
    @FocusedValue(\.diffPopout) private var diffPopout
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Project…") { model.isImporterPresented = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Open in Editor") { diffFile.map(model.openInEditor) }
                .keyboardShortcut("o")
                .disabled(diffFile?.exists != true)
            Button("Open Diff in New Window") {
                diffPopout.map { openWindow(id: DiffWindow.id, value: model.register($0)) }
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(diffPopout == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy File Path") { diffFile.map(model.copyPath) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(diffFile == nil)
        }

        CommandGroup(before: .sidebar) {
            Button(isListHidden ? "Show File List" : "Hide File List") {
                withAnimation(.snappy) { isListHidden.toggle() }
            }
            .keyboardShortcut("0")
            Toggle("Side-by-Side Diff", isOn: Binding(
                get: { diffLayout == .split },
                set: { diffLayout = $0 ? .split : .unified }))
                .keyboardShortcut("\\")
            Toggle("Show Whole File", isOn: $showsWholeFile)
                .keyboardShortcut("\\", modifiers: [.command, .shift])
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
