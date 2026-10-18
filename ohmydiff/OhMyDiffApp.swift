import SwiftUI

@main
struct OhMyDiffApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ohmydiff", id: "main") {
            ContentView(model: model)
                .environment(\.claudeCode, model.claudeCodeActions)
                .onOpenURL { model.handle($0) }
        }
        // The rail and the glass toolbar replace the title bar; the window controls sit on the rail.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            ProjectCommands(model: model)
        }

        WindowGroup("Diff", id: DiffWindow.id, for: UUID.self) { $popoutID in
            DiffWindow(model: model, popoutID: popoutID)
                .environment(\.claudeCode, model.claudeCodeActions)
        }
        .defaultSize(width: 1100, height: 760)
        .commandsRemoved()

        Settings {
            SettingsView()
        }
    }
}
