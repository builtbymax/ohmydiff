import OhMyDiffCore
import SwiftUI

struct ProjectCommands: Commands {
    let model: AppModel

    @AppStorage(DiffSettings.layoutKey) private var diffLayout: DiffLayoutMode = .split
    @AppStorage(DiffSettings.wholeFileKey) private var showsWholeFile = false
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.isSidebarHiddenKey) private var isSidebarHidden = false
    @AppStorage(AppSettings.showsWhitespaceChangesKey) private var showsWhitespaceChanges = true
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true
    @AppStorage(AppSettings.isActivityHiddenKey) private var isActivityHidden = false
    /// Read so the menus pick up keys changed in Settings → Shortcuts.
    @AppStorage(Shortcuts.key) private var shortcuts = ""
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
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
                .keyboardShortcut(Shortcuts.keyboardShortcut(.addProject))
            Divider()
            Button("Open in Editor") { diffFile.map(model.openInEditor) }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.openInEditor))
                .disabled(diffFile?.exists != true)
            Button("Open Diff in New Window") {
                diffPopout.map { openWindow(id: DiffWindow.id, value: model.register($0)) }
            }
            .keyboardShortcut(Shortcuts.keyboardShortcut(.openDiffWindow))
            .disabled(diffPopout == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy File Path") { diffFile.map(model.copyPath) }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.copyPath))
                .disabled(diffFile == nil)
            Button(AppSettings.copyPromptTitle()) { diffPrompt.map { model.copyPrompt($0.prompt(.none)) } }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.copyPrompt))
                .disabled(diffPrompt == nil)
            Menu(AppSettings.openClaudeCodeTitle()) {
                ForEach(PromptQuestion.asked) { question in
                    Button(question.title(for: diffPrompt?.scope ?? "Selection")) {
                        diffPrompt.map { model.openInClaudeCode(prompt: $0.prompt(question), root: $0.root) }
                    }
                    .keyboardShortcut(question == .explain ? Shortcuts.keyboardShortcut(.explainInClaude) : nil)
                }
            }
            .disabled(diffPrompt == nil)
        }

        CommandGroup(before: .sidebar) {
            Button(isSidebarHidden ? "Show Sidebar" : "Hide Sidebar") {
                withAnimation(.snappy(duration: 0.2)) { isSidebarHidden.toggle() }
            }
            .keyboardShortcut(Shortcuts.keyboardShortcut(.toggleSidebar))
            Button(isListHidden ? "Show File List" : "Hide File List") {
                withAnimation(.snappy) { isListHidden.toggle() }
            }
            .keyboardShortcut(Shortcuts.keyboardShortcut(.toggleFileList))
            Divider()
            Toggle("Split Diff", isOn: Binding(
                get: { diffLayout == .split },
                set: { diffLayout = $0 ? .split : .unified }))
                .keyboardShortcut(Shortcuts.keyboardShortcut(.splitDiff))
            Toggle("Show Full File", isOn: $showsWholeFile)
                .keyboardShortcut(Shortcuts.keyboardShortcut(.fullFile))
            Toggle("Show Activity", isOn: Binding(get: { !isActivityHidden }, set: { isActivityHidden = !$0 }))
                .keyboardShortcut(Shortcuts.keyboardShortcut(.activity))
            Toggle("Show Inspector", isOn: $isInspectorShown)
                .keyboardShortcut(Shortcuts.keyboardShortcut(.inspector))
            Toggle("Show Whitespace Changes", isOn: $showsWhitespaceChanges)
                .keyboardShortcut(Shortcuts.keyboardShortcut(.whitespace))
            Button(isSidebarHidden && isListHidden ? "Leave Focus" : "Focus Diff") {
                let focus = !(isSidebarHidden && isListHidden)
                withAnimation(.snappy(duration: 0.2)) {
                    isSidebarHidden = focus
                    isListHidden = focus
                }
            }
            .keyboardShortcut(Shortcuts.keyboardShortcut(.focusDiff))
            Divider()
            Button(isDark ? "Use Paper Theme" : "Use Graphite Theme") { appearance = isDark ? .light : .dark }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.theme))
            Divider()
        }

        CommandMenu("Repository") {
            let session = model.selectedSession
            Button("Commit Staged Changes…") { model.commitStaged() }
                .disabled(model.stagedTargets.isEmpty || session?.actionRequest != nil || model.isUpstreamUpdatePresented)
            Button("New Branch…") {
                model.mode = .branches
                model.isNewBranchPresented = true
            }
            .keyboardShortcut(Shortcuts.keyboardShortcut(.newBranch))
            .disabled(session == nil)
            Divider()
            Button("Fetch from Remote") { Task { await session?.fetch() } }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.fetch))
                .disabled(session == nil || session?.isFetching == true)
            Button(session?.project.kind == .gitButler ? "Update Workspace…" : "Update Branches…") { model.isUpstreamUpdatePresented = true }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.updateWorkspace))
                .disabled(session?.upstream?.hasUpdates != true)
        }

        CommandMenu("Go") {
            Button("Command Launcher…") { model.isSwitcherPresented = true }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.launcher))
            Button("Switch Project…") { model.isProjectMenuPresented = true }
                .keyboardShortcut(Shortcuts.keyboardShortcut(.switchProject))

            Divider()

            ForEach(WorkspaceMode.available) { page in
                Button(page.title) { model.mode = page }
                    .keyboardShortcut(Shortcuts.keyboardShortcut(page.shortcutAction))
            }

            Divider()

            ForEach(0..<9, id: \.self) { position in
                let projects = model.projects
                Button(projects.indices.contains(position) ? projects[position].displayName : "Project \(position + 1)") {
                    model.select(position: position)
                }
                .keyboardShortcut(
                    AppSettings.isOn(AppSettings.controlSwitchesProjectsKey) ? KeyboardShortcut(KeyEquivalent(Character("\(position + 1)")), modifiers: .control) : nil)
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
                .keyboardShortcut(Shortcuts.keyboardShortcut(.refresh))
                .disabled(model.selectedProjectID == nil)
        }
    }

    /// The theme in effect, also when it follows the system.
    private var isDark: Bool {
        switch appearance {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}
