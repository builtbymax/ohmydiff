import OhMyDiffCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Command Line", systemImage: "terminal") { CommandLineSettings() }
        }
        .frame(width: 500)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.editorKey) private var editor = AppSettings.defaultEditor
    @AppStorage(AppSettings.customEditorCommandKey) private var customCommand = ""
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(DiffMetrics.defaultFontSize)
    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified

    var body: some View {
        Form {
            Section {
                Picker("Editor", selection: $editor) {
                    ForEach(EditorPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                if editor == .custom {
                    TextField("Command", text: $customCommand, prompt: Text("myeditor --goto {file}:{line}"))
                        .font(.body.monospaced())
                }
                Text(editor.template.map { "Runs `\($0)`." } ?? "`{file}` and `{line}` are replaced with the file path and line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("⌘O opens the selected file at the selected line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diff") {
                Picker("Default layout", selection: $layout) {
                    Text("Unified").tag(DiffLayoutMode.unified)
                    Text("Side by Side").tag(DiffLayoutMode.split)
                }
                LabeledContent("Font size") {
                    Stepper(value: $fontSize, in: AppSettings.fontSizes, step: 1) {
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CommandLineSettings: View {
    @State private var isInstalled = CLILauncher.isInstalled()
    @State private var isOnPath: Bool?
    @State private var error: String?

    private var directory: String {
        (CLILauncher.defaultDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("ohmydiff command") {
                    HStack {
                        if isInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Button(isInstalled ? "Reinstall" : "Install") { install() }
                    }
                }
                Text("Installs `ohmydiff [path]` to \(directory). Run it in a repository to open it here; the path defaults to the current folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isOnPath == false {
                    Label("\(directory) is not on your shell's PATH. Add `export PATH=\"$HOME/.local/bin:$PATH\"` to your shell profile.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            isOnPath = await Toolchain.loginShellPath().map { CLILauncher.searchPath($0, contains: CLILauncher.defaultDirectory) }
        }
    }

    private func install() {
        do {
            try CLILauncher.install()
            error = nil
        } catch {
            self.error = "Could not install: \(error.localizedDescription)"
        }
        isInstalled = CLILauncher.isInstalled()
    }
}
