import AppKit
import OhMyDiffCore
import SwiftUI

enum SettingsPane: String, Hashable {
    case general, diff, ai, templates, tickets, commandLine
}

struct SettingsView: View {
    @AppStorage(AppSettings.settingsPaneKey) private var pane = SettingsPane.general
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        VStack(spacing: 18) {
            GlassSegmented(selection: $pane, options: [
                (.general, "General"), (.diff, "Diff"), (.ai, "AI"), (.templates, "Templates"), (.tickets, "Tickets"),
                (.commandLine, "Command Line"),
            ])
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .diff: DiffSettingsPane()
                case .ai: AISettings()
                case .templates: TemplateSettings()
                case .tickets: TicketSettings()
                case .commandLine: CommandLineSettings()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding([.horizontal, .bottom], 20)
        .frame(width: 640, height: 520)
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

    /// Opens Settings at `pane`.
    static func open(_ pane: SettingsPane, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(pane.rawValue, forKey: AppSettings.settingsPaneKey)
        open(with: openSettings)
    }

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
    /// A status shown at the end of the header, e.g. Connected.
    var badge: Badge?
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            HStack {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                badge
            }
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
    @AppStorage(AppSettings.suggestionProviderKey) private var suggestionProvider = ""
    @AppStorage(AppSettings.suggestionModelKey) private var model = ""
    /// Providers found on the login shell PATH; `nil` until looked up.
    @State private var installed: Set<AIProvider>?

    private static func columns(_ count: Int) -> [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: count) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "Ask About Diffs") {
                    LazyVGrid(columns: Self.columns(AIProvider.allCases.count), spacing: 10) {
                        ForEach(AIProvider.allCases) { option in
                            providerTile(option, isSelected: provider == option) { provider = option }
                        }
                    }
                    Divider()
                    HStack {
                        Text("Open in")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        SoftSegmented(selection: $terminal, options: TerminalApp.allCases.map { ($0, $0.displayName) }, disabled: missingTerminals)
                    }
                    caption("Right-clicking diff lines, the ✦↗ button on the hunk bar or ⌥⌘E open a new \(terminal.displayName) window in the repository and run `\(provider.executable)` with the selected lines as the prompt. ⌥⇧⌘C copies the prompt instead.")
                }

                SettingsCard(title: "Commit Messages & Branch Names", badge: suggestionBadge) {
                    LazyVGrid(columns: Self.columns(AIProvider.allCases.count + 1), spacing: 10) {
                        ChoiceTile(title: "Off", isSelected: suggestionProvider.isEmpty, action: { suggestionProvider = "" }) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
                                .frame(width: 44, height: 44)
                                .padding(4)
                        }
                        ForEach(AIProvider.allCases) { option in
                            providerTile(option, isSelected: suggestionProvider == option.rawValue) { suggestionProvider = option.rawValue }
                        }
                    }
                    if let selected = AIProvider(rawValue: suggestionProvider) {
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            Text("Model")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(height: 30)
                            ModelField(provider: selected, model: $model)
                        }
                        caption("Runs `\(selected.executable)` once per suggestion, in the repository. Leave the model empty for its default; Templates decide what it is asked.")
                    } else {
                        caption("Pick a provider to generate commit messages and branch names in the commit sheet, and pull request drafts in History.")
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .focusEffectDisabled()
        .task {
            let path = await Toolchain.loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            installed = Set(AIProvider.allCases.filter { ClaudeCodeLauncher.locate($0, environment: ["PATH": path]) != nil })
        }
    }

    private func providerTile(_ option: AIProvider, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let isMissing = installed.map { !$0.contains(option) } ?? false
        return ChoiceTile(title: option.displayName, subtitle: isMissing ? "Not installed" : nil, isSelected: isSelected, action: action) {
            ProviderIcon(provider: option)
                .frame(width: 44, height: 44)
                .opacity(isMissing ? 0.45 : 1)
                .padding(4)
        }
    }

    private var missingTerminals: Set<TerminalApp> {
        Set(TerminalApp.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) == nil && $0 != terminal })
    }

    private var suggestionBadge: Badge? {
        guard let selected = AIProvider(rawValue: suggestionProvider) else { return Badge("Off", systemImage: "circle.dashed", color: .secondary) }
        if installed.map({ !$0.contains(selected) }) == true { return Badge("Not installed", systemImage: "exclamationmark.circle.fill", color: .orange) }
        return Badge("On", systemImage: "sparkles", color: .green)
    }

    private func caption(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A free-text model name with the provider's known models as a menu and as quick picks matching what is typed.
private struct ModelField: View {
    let provider: AIProvider
    @Binding var model: String

    /// `nil` while loading.
    @State private var options: [ModelOption]?
    @FocusState private var isFocused: Bool

    /// Quick picks: models matching the text, hidden once it names one exactly.
    private var suggestions: [ModelOption] {
        guard let options, !options.contains(where: { $0.id == model }) else { return [] }
        return Array(ModelCatalog.matching(model, in: options).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                TextField("Model", text: $model, prompt: Text("Default"))
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .focused($isFocused)
                if !model.isEmpty {
                    Button { model = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Use the provider's default model")
                }
                Menu {
                    Button("Default") { model = "" }
                    if let options, !options.isEmpty {
                        Divider()
                        ForEach(options) { option in
                            Button { model = option.id } label: {
                                Text(option.id == model ? "✓ \(option.name)" : option.name)
                                if !option.detail.isEmpty || option.name != option.id {
                                    Text([option.name != option.id ? option.id : nil, option.detail.isEmpty ? nil : option.detail].compactMap(\.self).joined(separator: " · "))
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Known \(provider.displayName) models")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 30)
            .fieldBackground(isFocused: isFocused)

            if options == nil {
                Text("Looking up \(provider.displayName) models…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !suggestions.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(suggestions) { option in
                        Button { model = option.id } label: {
                            Text(option.id)
                                .font(.caption.monospaced().weight(.medium))
                                .foregroundStyle(Theme.logoText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.logo.opacity(0.14), in: .capsule)
                                .overlay(Capsule().strokeBorder(Theme.logoText.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                        .help(option.detail.isEmpty ? option.name : "\(option.name): \(option.detail)")
                    }
                }
            } else if let match = options?.first(where: { $0.id == model }), !match.detail.isEmpty {
                Text(match.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: provider) {
            options = nil
            let toolchain = provider == .opencode ? try? await Toolchain.discover() : nil
            options = await ModelCatalog.models(for: provider, toolchain: toolchain)
        }
    }
}

/// The editable commit and pull request templates.
private struct TemplateSettings: View {
    private enum Kind: Hashable { case commit, pullRequest }

    @State private var kind = Kind.commit
    @AppStorage(AppSettings.commitTemplateKey) private var commitTemplate = PromptTemplate.defaultCommit
    @AppStorage(AppSettings.pullRequestTemplateKey) private var pullRequestTemplate = PromptTemplate.defaultPullRequest
    @State private var copied: String?

    private var text: Binding<String> { kind == .commit ? $commitTemplate : $pullRequestTemplate }
    private var defaultText: String { kind == .commit ? PromptTemplate.defaultCommit : PromptTemplate.defaultPullRequest }
    private var isEdited: Bool { text.wrappedValue != defaultText }

    var body: some View {
        VStack(spacing: 14) {
            Card {
                HStack(spacing: 8) {
                    SoftSegmented(selection: $kind, options: [(.commit, "Commit Message"), (.pullRequest, "Pull Request")])
                    if isEdited {
                        Badge("Edited", systemImage: "pencil", color: Theme.logoText)
                    }
                    Spacer()
                    Button { text.wrappedValue = defaultText } label: {
                        Label("Reset to Default", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.pill(height: 24))
                    .font(.caption.weight(.semibold))
                    .disabled(!isEdited)
                    .focusEffectDisabled()
                }
            } content: {
                TextEditor(text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(maxHeight: .infinity)
            }

            SettingsCard(title: "Placeholders") {
                FlowRow(spacing: 6) {
                    ForEach(TemplateContext.placeholders, id: \.name) { placeholder in
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("{{\(placeholder.name)}}", forType: .string)
                            copied = placeholder.name
                        } label: {
                            Text(copied == placeholder.name ? "Copied" : "{{\(placeholder.name)}}")
                                .font(.caption.monospaced().weight(.medium))
                                .foregroundStyle(Theme.logoText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.logo.opacity(0.14), in: .capsule)
                                .overlay(Capsule().strokeBorder(Theme.logoText.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                        .help("\(placeholder.description). Click to copy.")
                    }
                }
                Text("Click one to copy it. Ticket placeholders are empty when no ticket is linked; `{{commits}}` lists the branch's commits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .focusEffectDisabled()
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = nil
        }
    }
}

/// Lays out its children left to right, wrapping to new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(subview)
            x += size.width + spacing
        }
        return rows
    }
}

/// The trackers tickets are looked up in.
private struct TicketSettings: View {
    @AppStorage(AppSettings.jiraSiteKey) private var jiraSite = ""
    @AppStorage(AppSettings.jiraEmailKey) private var jiraEmail = ""
    @AppStorage(AppSettings.githubTicketsKey) private var github = false
    @AppStorage(AppSettings.gitlabTicketsKey) private var gitlab = false
    @State private var linearKey = Keychain.read(.linear) ?? ""
    @State private var jiraToken = Keychain.read(.jira) ?? ""
    /// `gh` and `glab` found on the login shell PATH; `nil` until looked up.
    @State private var tools: Set<String>?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "Linear", badge: .connection(!linearKey.isEmpty)) {
                    SettingsField(label: "API key", text: $linearKey, prompt: "lin_api_…", isSecure: true)
                        .onChange(of: linearKey) { Keychain.write(linearKey.trimmingCharacters(in: .whitespaces), for: .linear) }
                    note("Create a personal API key in Linear under Settings → Security & access. It is stored in your Keychain.")
                }
                SettingsCard(title: "Jira", badge: .connection(isJiraConnected)) {
                    SettingsField(label: "Site", text: $jiraSite, prompt: "example.atlassian.net")
                    SettingsField(label: "Email", text: $jiraEmail, prompt: "you@example.com")
                    SettingsField(label: "API token", text: $jiraToken, prompt: "Token", isSecure: true)
                        .onChange(of: jiraToken) { Keychain.write(jiraToken.trimmingCharacters(in: .whitespaces), for: .jira) }
                    note("Create an API token at id.atlassian.com under Security. It is stored in your Keychain.")
                }
                SettingsCard(title: "GitHub & GitLab") {
                    forgeRow("GitHub Issues", tool: "gh", isOn: $github)
                    Divider()
                    forgeRow("GitLab Issues", tool: "glab", isOn: $gitlab)
                    note("Uses the repository's remote and the account the CLI is signed in with (`gh auth login`, `glab auth login`).")
                }
                Label("Branches like `feature/hal-128` or `fix/42-crash` link their ticket in the commit sheet, where you can also search for one. Templates use it through the `{{ticket.…}}` placeholders.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .scrollIndicators(.automatic)
        .focusEffectDisabled()
        .task {
            let path = await Toolchain.loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            tools = Set(["gh", "glab"].filter { Toolchain.locate($0, in: path) != nil })
        }
    }

    private var isJiraConnected: Bool {
        JiraTickets.siteURL(jiraSite) != nil && !jiraEmail.isEmpty && !jiraToken.isEmpty
    }

    private func forgeRow(_ title: String, tool: String, isOn: Binding<Bool>) -> some View {
        let isMissing = tools.map { !$0.contains(tool) } ?? false
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(isMissing ? "`\(tool)` is not installed" : "Through the `\(tool)` CLI")
                    .font(.caption)
                    .foregroundStyle(isMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.logoText)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A label on the left and a soft input well on the right.
private struct SettingsField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var isSecure = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Group {
                if isSecure {
                    SecureField(label, text: $text, prompt: Text(prompt))
                } else {
                    TextField(label, text: $text, prompt: Text(prompt))
                }
            }
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .fieldBackground(isFocused: isFocused)
        }
    }
}

/// A small status capsule, e.g. `Installed` or `Connected`.
private struct Badge: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    static func connection(_ isConnected: Bool) -> Badge {
        isConnected
            ? Badge("Connected", systemImage: "checkmark.circle.fill", color: Theme.addition)
            : Badge("Not connected", systemImage: "circle.dashed", color: .secondary)
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
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
        switch state {
        case .current: Badge("Installed", systemImage: "checkmark.circle.fill", color: Theme.addition)
        case .outdated: Badge("Outdated", systemImage: "exclamationmark.circle.fill", color: .orange)
        case .missing: Badge("Not installed", systemImage: "circle.dashed", color: .secondary)
        }
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
