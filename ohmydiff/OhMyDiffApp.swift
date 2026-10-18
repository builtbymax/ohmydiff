import SwiftUI

@main
struct OhMyDiffApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ohmydiff", id: "main") {
            ContentView(model: model)
                .onOpenURL { model.handle($0) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            ProjectCommands(model: model)
        }

        Settings {
            SettingsView()
        }
    }
}
