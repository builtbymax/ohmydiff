import OhMyDiffCore
import SwiftUI

/// Starts the app, or with `--mcp` (from `ohmydiff mcp`) the MCP server for coding agents, without any UI.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--mcp" {
            Task.detached {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                let server = MCPServer(
                    toolchain: try? await Toolchain.discover(),
                    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                    version: version)
                await server.serve()
                exit(0)
            }
            dispatchMain()
        }
        OhMyDiffApp.main()
    }
}

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
