import OhMyDiffCore
import SwiftUI

struct ProjectCommands: Commands {
    let model: AppModel

    @AppStorage(DiffSettings.layoutKey) private var diffLayout: DiffLayoutMode = .unified
    @AppStorage(DiffSettings.wholeFileKey) private var showsWholeFile = false
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @FocusedValue(\.diffFile) private var diffFile
    @FocusedValue(\.diffPopout) private var diffPopout
    @FocusedValue(\.diffPrompt) private var diffPrompt
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.canCheck)
        }

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
            Button(AppSettings.copyPromptTitle()) { diffPrompt.map { model.copyPrompt($0.prompt(.none)) } }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(diffPrompt == nil)
            Menu(AppSettings.openClaudeCodeTitle()) {
                ForEach(PromptQuestion.asked) { question in
                    Button(question.title(for: diffPrompt?.scope ?? "Selection")) {
                        diffPrompt.map { model.openInClaudeCode(prompt: $0.prompt(question), root: $0.root) }
                    }
                    .keyboardShortcut(question == .explain ? KeyboardShortcut("e", modifiers: [.command, .option]) : nil)
                }
            }
            .disabled(diffPrompt == nil)
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

        CommandMenu("Repository") {
            let session = model.selectedSession
            Button("Commit Staged Changes…") { model.commitStaged() }
                .keyboardShortcut(.return)
                .disabled(model.stagedTargets.isEmpty || session?.actionRequest != nil || model.isUpstreamUpdatePresented)
            Divider()
            Button("Fetch from Remote") { Task { await session?.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(session == nil || session?.isFetching == true)
            Button(session?.project.kind == .gitButler ? "Update Workspace…" : "Update Branches…") { model.isUpstreamUpdatePresented = true }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(session?.upstream?.hasUpdates != true)
        }

        CommandMenu("Go") {
            Button("Switch Project…") { model.isSwitcherPresented = true }
                .keyboardShortcut("k")
                .disabled(model.projects.isEmpty)

            Divider()

            let projects = model.visibleProjects
            ForEach(0..<9, id: \.self) { position in
                Button(projects.indices.contains(position) ? projects[position].displayName : "Project \(position + 1)") {
                    model.select(position: position)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")))
                .disabled(!projects.indices.contains(position))
            }

            Divider()

            ForEach(0..<9, id: \.self) { position in
                let workspace = model.workspaces.indices.contains(position) ? model.workspaces[position] : nil
                Button(workspace?.name ?? "Workspace \(position + 1)") {
                    workspace.map { model.selectWorkspace($0.id) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")), modifiers: [.command, .control])
                .disabled(workspace == nil)
            }

            Divider()

            Button("Refresh") { model.refreshSelected() }
                .keyboardShortcut("r")
                .disabled(model.selectedProjectID == nil)
        }
    }
}
