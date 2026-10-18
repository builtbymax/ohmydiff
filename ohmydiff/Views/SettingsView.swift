import OhMyDiffCore
import SwiftUI

struct SettingsView: View {
    private enum Pane: Hashable { case general, diff, commandLine }

    @State private var pane = Pane.general

    var body: some View {
        VStack(spacing: 18) {
            GlassSegmented(selection: $pane, options: [(.general, "General"), (.diff, "Diff"), (.commandLine, "Command Line")])
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .diff: DiffSettingsPane()
                case .commandLine: CommandLineSettings()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .frame(width: 520, height: 400)
        .background { WindowTranslucency().ignoresSafeArea() }
    }
}

/// A titled settings card with its rows.
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } content: {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A label on the left, its control on the right.
private struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            control
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @AppStorage(AppSettings.editorKey) private var editor = AppSettings.defaultEditor
    @AppStorage(AppSettings.customEditorCommandKey) private var customCommand = ""

    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Appearance") {
                SettingsRow(label: "Theme") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsCard(title: "Editor") {
                SettingsRow(label: "Open files in") {
                    Picker("Editor", selection: $editor) {
                        ForEach(EditorPreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if editor == .custom {
                    TextField("Command", text: $customCommand, prompt: Text("myeditor --goto {file}:{line}"))
                        .font(.body.monospaced())
                }
                Text(editor.template.map { "Runs `\($0)`. ⌘O opens the selected file at the selected line." }
                    ?? "`{file}` and `{line}` are replaced with the file path and line. ⌘O opens the selected file at the selected line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DiffSettingsPane: View {
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(DiffMetrics.defaultFontSize)
    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified

    var body: some View {
        SettingsCard(title: "Diff") {
            SettingsRow(label: "Layout") {
                Picker("Layout", selection: $layout) {
                    Text("Unified").tag(DiffLayoutMode.unified)
                    Text("Side by Side").tag(DiffLayoutMode.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            SettingsRow(label: "Font size") {
                Stepper(value: $fontSize, in: AppSettings.fontSizes, step: 1) {
                    Text("\(Int(fontSize)) pt").monospacedDigit()
                }
            }
            Text("Side by side needs a wide diff; narrower windows fall back to unified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
        SettingsCard(title: "Command Line") {
            SettingsRow(label: "ohmydiff command") {
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
