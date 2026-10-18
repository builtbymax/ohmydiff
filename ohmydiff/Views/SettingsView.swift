import AppKit
import OhMyDiffCore
import SwiftUI

struct SettingsView: View {
    private enum Pane: Hashable { case general, diff, commandLine }

    @State private var pane = Pane.general
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

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
        .padding([.horizontal, .bottom], 20)
        .frame(width: 560, height: 460)
        .background { WindowTranslucency().ignoresSafeArea() }
        .background { TitlelessWindow() }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Also here, so the theme switches at once even while the main window is closed.
        .onChange(of: appearance) { appearance.apply() }
    }
}

/// Hides the window title and the title bar's background.
private struct TitlelessWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowObserver: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            SettingsWindow.window = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
        }
    }
}

/// Opens Settings and brings it to the front, also when it was already open behind other windows.
@MainActor
enum SettingsWindow {
    fileprivate static weak var window: NSWindow?

    static func open(with openSettings: OpenSettingsAction) {
        openSettings()
        NSApp.activate()
        // SwiftUI creates the window during this run loop pass on first open.
        DispatchQueue.main.async {
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
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

/// A selectable option shown as a picture with its name below, like System Settings' appearance picker.
private struct ChoiceTile<Preview: View>: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var preview: Preview

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.15 : 0)), lineWidth: 2.5)
                    }
                VStack(spacing: 0) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @AppStorage(AppSettings.editorKey) private var editor = AppSettings.defaultEditor
    @AppStorage(AppSettings.customEditorCommandKey) private var customCommand = ""

    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Appearance") {
                HStack(spacing: 14) {
                    ForEach(AppAppearance.allCases) { option in
                        ChoiceTile(title: option.title, isSelected: appearance == option, action: { appearance = option }) {
                            AppearancePreview(appearance: option)
                        }
                    }
                }
            }
            SettingsCard(title: "Open Files In") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    ForEach(EditorPreset.allCases) { preset in
                        let app = EditorApp(preset: preset)
                        ChoiceTile(title: preset.displayName, isSelected: editor == preset, action: { editor = preset }) {
                            app.icon
                                .frame(width: 44, height: 44)
                                .opacity(app.isInstalled ? 1 : 0.45)
                                .padding(4)
                        }
                    }
                }
                if editor == .custom {
                    TextField("Command", text: $customCommand, prompt: Text("myeditor --goto {file}:{line}"))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                Text(editor.template.map { "Runs `\($0)`. ⌘O opens the selected file at the selected line." }
                    ?? "`{file}` and `{line}` are replaced with the file path and line. ⌘O opens the selected file at the selected line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// An editor's app icon, or a symbol for a custom command or an editor that is not installed.
private struct EditorApp {
    let preset: EditorPreset
    let url: URL?

    init(preset: EditorPreset) {
        self.preset = preset
        url = Self.bundleIDs(preset).lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    var isInstalled: Bool { url != nil }

    @ViewBuilder var icon: some View {
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: preset == .custom ? "terminal" : "app.dashed")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 9))
        }
    }

    private static func bundleIDs(_ preset: EditorPreset) -> [String] {
        switch preset {
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .vscode: ["com.microsoft.VSCode"]
        case .zed: ["dev.zed.Zed"]
        case .xcode: ["com.apple.dt.Xcode"]
        case .sublime: ["com.sublimetext.4", "com.sublimetext.3"]
        case .custom: []
        }
    }
}

/// A tiny window with a diff in it, in light, dark, or split between both for System.
private struct AppearancePreview: View {
    let appearance: AppAppearance

    var body: some View {
        Group {
            switch appearance {
            case .light: MiniWindow(isDark: false)
            case .dark: MiniWindow(isDark: true)
            case .system:
                MiniWindow(isDark: false)
                    .overlay {
                        MiniWindow(isDark: true)
                            .mask {
                                GeometryReader { proxy in
                                    Path { path in
                                        path.move(to: CGPoint(x: proxy.size.width * 0.62, y: 0))
                                        path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                                        path.addLine(to: CGPoint(x: proxy.size.width * 0.38, y: proxy.size.height))
                                    }
                                }
                            }
                    }
            }
        }
        .frame(height: 74)
        .clipShape(.rect(cornerRadius: 9))
    }
}

private struct MiniWindow: View {
    let isDark: Bool

    var body: some View {
        let background = isDark ? Color(white: 0.17) : Color(white: 0.93)
        let panel = isDark ? Color(white: 0.11) : .white
        let line = isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.14)
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    Circle().fill(.red.opacity(0.85))
                    Circle().fill(.yellow.opacity(0.85))
                    Circle().fill(.green.opacity(0.85))
                }
                .frame(height: 5)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 16, height: 4)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 3.5) {
                Capsule().fill(line).frame(width: 34, height: 3.5)
                Capsule().fill(line).frame(width: 48, height: 3.5)
                Capsule().fill(Color.red.opacity(isDark ? 0.55 : 0.4)).frame(height: 5)
                Capsule().fill(Color.green.opacity(isDark ? 0.55 : 0.45)).frame(height: 5)
                Capsule().fill(line).frame(width: 40, height: 3.5)
                Capsule().fill(line).frame(width: 26, height: 3.5)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(panel, in: .rect(cornerRadius: 5))
        }
        .padding(6)
        .background(background)
    }
}

/// A tiny unified or side-by-side diff.
private struct LayoutPreview: View {
    let layout: DiffLayoutMode

    var body: some View {
        HStack(spacing: 4) {
            switch layout {
            case .unified:
                column(rows: [.context, .deletion, .addition, .addition, .context, .context])
            case .split:
                column(rows: [.context, .deletion, .empty, .context, .context])
                column(rows: [.context, .addition, .addition, .context, .context])
            }
        }
        .padding(7)
        .frame(height: 74)
        .background(Theme.cardRow, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }

    private enum Row { case context, addition, deletion, empty }

    private func column(rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(row))
                    .frame(maxWidth: row == .context ? CGFloat(30 + (index * 17) % 40) : .infinity)
                    .frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ row: Row) -> Color {
        switch row {
        case .context: Color.primary.opacity(0.12)
        case .addition: Theme.addition.opacity(0.45)
        case .deletion: Theme.deletion.opacity(0.4)
        case .empty: Color.primary.opacity(0.04)
        }
    }
}

private struct DiffSettingsPane: View {
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(DiffMetrics.defaultFontSize)
    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified

    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Layout") {
                HStack(spacing: 14) {
                    ChoiceTile(title: "Unified", isSelected: layout == .unified, action: { layout = .unified }) {
                        LayoutPreview(layout: .unified)
                    }
                    ChoiceTile(title: "Side by Side", isSelected: layout == .split, action: { layout = .split }) {
                        LayoutPreview(layout: .split)
                    }
                }
                Text("Side by side wraps long lines; very narrow diffs fall back to unified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(title: "Font Size") {
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                    Slider(value: $fontSize, in: AppSettings.fontSizes, step: 1)
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary)
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                // A sample line at the chosen size.
                HStack(spacing: 0) {
                    Text("+")
                        .foregroundStyle(Theme.addition)
                        .frame(width: 22)
                    Text("let greeting = \"Hello, diff\"")
                }
                .font(.system(size: CGFloat(fontSize), design: .monospaced))
                .lineLimit(1)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.addition.opacity(0.1), in: .rect(cornerRadius: 6))
            }
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

    private static let pathExport = "export PATH=\"$HOME/.local/bin:$PATH\""

    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Command Line") {
                HStack(spacing: 14) {
                    Image(systemName: "apple.terminal.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 48, height: 48)
                        .background(Theme.logo.gradient, in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("ohmydiff").font(.body.monospaced().weight(.semibold))
                            StatusPill(isInstalled: isInstalled)
                        }
                        Text("Open any repository from your terminal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { install() } label: {
                        Label(isInstalled ? "Reinstall" : "Install", systemImage: isInstalled ? "arrow.clockwise" : "arrow.down")
                    }
                    .buttonStyle(.pill(isInstalled ? .normal : .prominent, height: 32))
                    .focusEffectDisabled()
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            SettingsCard(title: "Usage") {
                VStack(alignment: .leading, spacing: 6) {
                    TerminalLine(command: "ohmydiff", comment: "the current folder")
                    TerminalLine(command: "ohmydiff ~/code/project", comment: "any repository")
                }
                Text("Installs to \(directory). Each run opens the repository here, adding it as a project if it is new.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isOnPath == false {
                SettingsCard(title: "Add to PATH") {
                    Label("\(directory) is not on your shell's PATH yet. Add this line to your shell profile:", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    TerminalLine(command: Self.pathExport, prompt: false)
                }
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

/// `Installed` in green or `Not installed` in gray.
private struct StatusPill: View {
    let isInstalled: Bool

    var body: some View {
        Label(isInstalled ? "Installed" : "Not installed", systemImage: isInstalled ? "checkmark.circle.fill" : "circle.dashed")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isInstalled ? Theme.addition : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((isInstalled ? Theme.addition : Color.secondary).opacity(0.14), in: .capsule)
    }
}

/// A shell command on a terminal-like strip, with a copy button.
private struct TerminalLine: View {
    let command: String
    var comment: String?
    var prompt = true

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                if prompt {
                    Text("$ ").foregroundStyle(Theme.logoText)
                }
                Text(command).foregroundStyle(.primary)
                if let comment {
                    Text("  # \(comment)").foregroundStyle(.tertiary)
                }
            }
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? AnyShapeStyle(Theme.logoText) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .glassTooltip(copied ? "Copied" : "Copy")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.terminal, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
