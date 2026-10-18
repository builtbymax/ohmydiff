import AppKit
import OhMyDiffCore
import SwiftUI

struct SettingsView: View {
    private enum Pane: Hashable { case general, diff, ai, commandLine }

    @State private var pane = Pane.general
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        VStack(spacing: 18) {
            GlassSegmented(selection: $pane, options: [(.general, "General"), (.diff, "Diff"), (.ai, "AI"), (.commandLine, "Command Line")])
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .diff: DiffSettingsPane()
                case .ai: AISettings()
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

private struct AISettings: View {
    @AppStorage(AppSettings.aiProviderKey) private var provider = AIProvider.claude
    @AppStorage(AppSettings.terminalKey) private var terminal = AppSettings.terminal()
    /// Providers found on the login shell PATH; `nil` until looked up.
    @State private var installed: Set<AIProvider>?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Provider") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(AIProvider.allCases) { option in
                        let isMissing = installed.map { !$0.contains(option) } ?? false
                        ChoiceTile(title: option.displayName, subtitle: isMissing ? "Not installed" : nil, isSelected: provider == option, action: { provider = option }) {
                            ProviderIcon(provider: option)
                                .frame(width: 44, height: 44)
                                .opacity(isMissing ? 0.45 : 1)
                                .padding(4)
                        }
                    }
                }
            }
            SettingsCard(title: "Open In") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TerminalApp.allCases) { app in
                        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)
                        ChoiceTile(title: app.displayName, subtitle: url == nil ? "Not installed" : nil, isSelected: terminal == app, action: { terminal = app }) {
                            AppIcon(url: url, fallback: "terminal")
                                .frame(width: 44, height: 44)
                                .opacity(url != nil ? 1 : 0.45)
                                .padding(4)
                        }
                    }
                }
            }
            Label {
                Text("\(provider.displayName) answers in the terminal, not in ohmydiff: right-clicking diff lines, the ✦↗ button on the hunk bar or ⌥⌘E open a new \(terminal.displayName) window in the repository and run `\(provider.executable)` with the selected lines as the prompt. ⌥⇧⌘C copies the prompt instead.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
        .task {
            let path = await Toolchain.loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            installed = Set(AIProvider.allCases.filter { ClaudeCodeLauncher.locate($0, environment: ["PATH": path]) != nil })
        }
    }
}

/// A provider's logo on a tile in its brand colors; a symbol for providers without a bundled logo.
private struct ProviderIcon: View {
    let provider: AIProvider

    var body: some View {
        mark
            .frame(width: 40, height: 40)
            .background(background, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    @ViewBuilder private var mark: some View {
        switch provider {
        case .claude:
            Image("ClaudeLogo").resizable().scaledToFit().padding(8)
        case .codex:
            Image("CodexLogo").resizable().scaledToFit().foregroundStyle(.white).padding(9)
        case .gemini:
            Image(systemName: "sparkle").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
        case .opencode:
            Image(systemName: "curlybraces").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
        }
    }

    private var background: LinearGradient {
        let colors: [Color] = switch provider {
        case .claude: [Color(red: 0.98, green: 0.97, blue: 0.95), Color(red: 0.93, green: 0.91, blue: 0.87)]
        case .codex: [Color(white: 0.22), Color(white: 0.05)]
        case .gemini: [Color(red: 0.29, green: 0.53, blue: 0.98), Color(red: 0.62, green: 0.40, blue: 0.93)]
        case .opencode: [Color(white: 0.28), Color(white: 0.12)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// An app's icon, or a symbol when it is not installed.
private struct AppIcon: View {
    let url: URL?
    let fallback: String

    var body: some View {
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: fallback)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 9))
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
    @State private var state = CLILauncher.installState(app: Self.app)
    @State private var isOnPath: Bool?
    @State private var error: String?

    /// The app's executable, which `ohmydiff mcp` runs.
    private static var app: String { Bundle.main.executableURL?.path ?? "" }

    private var directory: String {
        (CLILauncher.defaultDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    private static let pathExport = "export PATH=\"$HOME/.local/bin:$PATH\""

    var body: some View {
        ScrollView {
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
                                StatusPill(state: state)
                            }
                            Text("Open repositories, files, branches and commits from your terminal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { install() } label: {
                            Label(state == .missing ? "Install" : "Reinstall", systemImage: state == .missing ? "arrow.down" : "arrow.clockwise")
                        }
                        .buttonStyle(.pill(state == .current ? .normal : .prominent, height: 32))
                        .focusEffectDisabled()
                    }
                    if state == .outdated {
                        Label("The installed command is from an older version or another copy of the app. Reinstall it.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                SettingsCard(title: "Usage") {
                    VStack(alignment: .leading, spacing: 6) {
                        TerminalLine(command: "ohmydiff", comment: "the current repository")
                        TerminalLine(command: "ohmydiff show src/app.ts:42", comment: "a changed file at a line")
                        TerminalLine(command: "ohmydiff branch feature/login", comment: "a branch in History")
                        TerminalLine(command: "ohmydiff commit 1a2b3c4", comment: "a commit in History")
                    }
                    Text("Installs to \(directory). Each run brings ohmydiff to the front, adding the repository as a project if it is new.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard(title: "Coding Agents") {
                    VStack(alignment: .leading, spacing: 6) {
                        TerminalLine(command: "claude mcp add ohmydiff -- ohmydiff mcp", comment: "Claude Code")
                        TerminalLine(command: "codex mcp add ohmydiff -- ohmydiff mcp", comment: "Codex")
                    }
                    Text("`ohmydiff mcp` is a local MCP server. Agents can list changes, branches and commits, read diffs, and point ohmydiff at the exact file, line, branch or commit for you to review.")
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
        }
        .scrollIndicators(.automatic)
        .task {
            isOnPath = await Toolchain.loginShellPath().map { CLILauncher.searchPath($0, contains: CLILauncher.defaultDirectory) }
        }
    }

    private func install() {
        do {
            try CLILauncher.install(app: Self.app)
            error = nil
        } catch {
            self.error = "Could not install: \(error.localizedDescription)"
        }
        state = CLILauncher.installState(app: Self.app)
    }
}

/// `Installed` in green, `Outdated` in orange or `Not installed` in gray.
private struct StatusPill: View {
    let state: CLILauncher.InstallState

    var body: some View {
        let (title, symbol, color): (String, String, Color) = switch state {
        case .current: ("Installed", "checkmark.circle.fill", Theme.addition)
        case .outdated: ("Outdated", "exclamationmark.circle.fill", .orange)
        case .missing: ("Not installed", "circle.dashed", .secondary)
        }
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
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
