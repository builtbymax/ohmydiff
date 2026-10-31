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
                    projects: AppVariant.projectStore,
                    version: version,
                    onConnect: { client in
                        // Shared with the app, which runs under the same bundle identifier.
                        UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: "mcpLastUsed")
                        UserDefaults.standard.set(client, forKey: "mcpLastClient")
                    })
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

    init() {
        Updater.shared.start()
        // After an update replaced the app in place, the command it installed may be from the old version.
        if let app = Bundle.main.executableURL?.path { _ = try? CLILauncher.refresh(app: app) }
    }

    var body: some Scene {
        Window("ohmydiff", id: "main") {
            ContentView(model: model)
                .environment(\.claudeCode, model.claudeCodeActions)
                .environment(\.openEditor, model.openInEditor)
                .environment(\.askAI, model.askAI)
                .onOpenURL { model.handle($0) }
        }
        // The sidebar and the page bars replace the title bar; the window controls sit on the sidebar.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            ProjectCommands(model: model)
        }

        WindowGroup("Diff", id: DiffWindow.id, for: UUID.self) { $popoutID in
            DiffWindow(model: model, popoutID: popoutID)
                .environment(\.claudeCode, model.claudeCodeActions)
                .environment(\.openEditor, model.openInEditor)
                .environment(\.askAI, model.askAI)
        }
        .defaultSize(width: 1100, height: 760)
        .commandsRemoved()

        Settings {
            SettingsView()
        }
    }
}
