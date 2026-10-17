import SwiftUI

@main
struct OhMyDiffApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ohmydiff", id: "main") {
            ContentView(model: model)
        }
        .windowToolbarStyle(.unified)
        .commands {
            ProjectCommands(model: model)
        }
    }
}
