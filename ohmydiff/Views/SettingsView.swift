import AppKit
import OhMyDiffCore
import SwiftUI

enum SettingsPane: String, Hashable {
    case general, appearance, ai, templates, tickets, commandLine
}

struct SettingsView: View {
    @AppStorage(AppSettings.settingsPaneKey) private var pane = SettingsPane.general
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        VStack(spacing: 18) {
            GlassSegmented(selection: $pane, options: [
                (.general, "General"), (.appearance, "Appearance"), (.ai, "AI"), (.templates, "Templates"), (.tickets, "Tickets"),
                (.commandLine, "Command Line"),
            ])
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
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
        private var escapeMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            escapeMonitor.map(NSEvent.removeMonitor)
            escapeMonitor = nil
            guard let window else { return }
            SettingsWindow.window = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            // Escape closes Settings, like a sheet.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
                guard let window, event.window === window, event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                window.performClose(nil)
                return nil
            }
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
        bringToFront()
    }

    /// Opens Settings through the app menu's Settings… item, for callers without a working `openSettings`,
    /// e.g. overlays that are gone by the time their command runs.
    static func open() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        appMenu.performActionForItem(at: index)
        bringToFront()
    }

    private static func bringToFront() {
        NSApp.activate()
        // SwiftUI creates the window during this run loop pass on first open.
        DispatchQueue.main.async {
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }
}

/// What the panes looked up last, so switching back to one shows it complete at once instead of growing
/// as its lookups finish.
@MainActor
private enum SettingsLookups {
    static var installedProviders: Set<AIProvider>?
    static var models: [AIProvider: [ModelOption]] = [:]
    static var forgeTools: Set<String>?
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
                        // An empty subtitle still takes its line, so tiles keep their height when one appears.
                        Text(subtitle.isEmpty ? " " : subtitle)
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
    @AppStorage(AppSettings.editorKey) private var editor = AppSettings.defaultEditor
    @AppStorage(AppSettings.customEditorCommandKey) private var customCommand = ""

    var body: some View {
        VStack(spacing: 14) {
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
                    DraftField(label: "Command", text: $customCommand, prompt: "myeditor --goto {file}:{line}", font: .callout.monospaced())
                }
                Text(editor.template.map { "Runs `\($0)`. ⌘O opens the selected file at the selected line." }
                    ?? "`{file}` and `{line}` are replaced with the file path and line. ⌘O opens the selected file at the selected line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            UpdateSettings(updater: .shared)
        }
    }
}

private struct UpdateSettings: View {
    @Bindable var updater: Updater

    var body: some View {
        SettingsCard(title: "Updates", badge: badge) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ohmydiff \(Updater.currentVersion)")
                        .font(.body.weight(.semibold))
                    Group {
                        if !updater.isAvailable {
                            Text("Build \(Updater.currentBuild). Development builds don’t update themselves.")
                        } else if let lastCheck = updater.lastCheck {
                            Text("Build \(Updater.currentBuild). Last checked \(lastCheck, format: .relative(presentation: .named)).")
                        } else {
                            Text("Build \(Updater.currentBuild). Not checked yet.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { updater.checkForUpdates() } label: {
                    if updater.phase == .checking {
                        Label { Text("Checking…") } icon: { ProgressView().controlSize(.mini) }
                    } else {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.pill(height: 32))
                .focusEffectDisabled()
                .disabled(!updater.canCheck)
            }
            if updater.isAvailable {
                Divider()
                toggle("Check for updates automatically", detail: "On launch and once a day", isOn: $updater.automaticallyChecks)
                toggle("Download and install automatically", detail: "Installs when you quit ohmydiff, or restart from the update bar",
                       isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
            }
        }
    }

    private var badge: Badge? {
        switch updater.phase {
        case .available(let update), .downloading(let update, _), .extracting(let update, _):
            Badge("\(update.version) available", systemImage: "arrow.down.circle.fill", color: .orange)
        case .ready(let update), .installing(let update):
            Badge("\(update.version) ready", systemImage: "arrow.down.circle.fill", color: .orange)
        case .failed:
            Badge("Check failed", systemImage: "exclamationmark.circle.fill", color: .red)
        case .upToDate:
            Badge("Up to date", systemImage: "checkmark.circle.fill", color: .green)
        case .idle, .checking:
            nil
        }
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.logoText)
        }
    }
}

private struct AISettings: View {
    @AppStorage(AppSettings.aiProviderKey) private var provider = AIProvider.claude
    @AppStorage(AppSettings.terminalKey) private var terminal = AppSettings.terminal()
    @AppStorage(AppSettings.suggestionProviderKey) private var suggestionProvider = ""
    @AppStorage(AppSettings.suggestionModelKey) private var model = ""
    /// Providers found on the login shell PATH; `nil` until looked up.
    @State private var installed = SettingsLookups.installedProviders

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
            let found = Set(AIProvider.allCases.filter { ClaudeCodeLauncher.locate($0, environment: ["PATH": path]) != nil })
            SettingsLookups.installedProviders = found
            if installed != found { installed = found }
        }
    }

    private func providerTile(_ option: AIProvider, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let isMissing = installed.map { !$0.contains(option) } ?? false
        return ChoiceTile(title: option.displayName, subtitle: isMissing ? "Not installed" : "", isSelected: isSelected, action: action) {
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
    /// What is typed; saved to `model` with Return or the checkmark.
    @State private var draft: String
    @State private var isPickerPresented = false
    @FocusState private var isFocused: Bool

    init(provider: AIProvider, model: Binding<String>) {
        self.provider = provider
        _model = model
        _draft = State(initialValue: model.wrappedValue)
        _options = State(initialValue: SettingsLookups.models[provider])
    }

    /// Quick picks: models matching the text, hidden once it names one exactly.
    private var suggestions: [ModelOption] {
        guard let options, !options.contains(where: { $0.id == draft }) else { return [] }
        return Array(ModelCatalog.matching(draft, in: options).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                TextField("Model", text: $draft, prompt: Text("Default"))
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .focused($isFocused)
                    .onSubmit { choose(draft.trimmingCharacters(in: .whitespaces)) }
                if !draft.isEmpty {
                    Button { choose("") } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Use the provider's default model")
                }
                Button { isPickerPresented.toggle() } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.hover(cornerRadius: 6, isSelected: isPickerPresented))
                .help("Known \(provider.displayName) models")
                .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
                    ModelPicker(provider: provider, options: options, selection: model, dismiss: { isPickerPresented = false }) {
                        isPickerPresented = false
                        choose($0)
                    }
                }
                SaveButton(isSaved: draft == model) { choose(draft.trimmingCharacters(in: .whitespaces)) }
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
                        Button { choose(option.id) } label: {
                            Text(option.id)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: .capsule)
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
        .onChange(of: model) { draft = model }
        .task(id: provider) {
            // Models looked up before show at once, so the field keeps its height; the lookup only refreshes them.
            options = SettingsLookups.models[provider]
            let toolchain = provider == .opencode ? try? await Toolchain.discover() : nil
            let found = await ModelCatalog.models(for: provider, toolchain: toolchain)
            SettingsLookups.models[provider] = found
            if options != found { options = found }
        }
    }

    /// Saves `id` as the model; picks from the menu and quick picks save at once.
    private func choose(_ id: String) {
        model = id
        draft = id
    }
}

/// The provider's known models in a panel like the hunk bar's: the default first, then each model with its ID
/// and what it is for. Arrow keys and Return pick one.
private struct ModelPicker: View {
    let provider: AIProvider
    /// `nil` while loading.
    let options: [ModelOption]?
    let selection: String
    let dismiss: () -> Void
    let choose: (String) -> Void

    @State private var highlighted = 0

    /// The default as `""`, then the models.
    private var ids: [String] { [""] + (options ?? []).map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(id: "", title: "Default", subtitle: "Whatever `\(provider.executable)` uses", index: 0)
            Divider().padding(.vertical, 4).padding(.horizontal, 10)
            if let options {
                if options.isEmpty {
                    Text("No known models; type one in the field.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                                    row(id: option.id, title: option.name, subtitle: subtitle(for: option), index: offset + 1)
                                        .id(option.id)
                                }
                            }
                        }
                        .scrollIndicators(.automatic)
                        .frame(maxHeight: 340)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: highlighted) { proxy.scrollTo(ids[highlighted]) }
                        .onAppear { if !selection.isEmpty { proxy.scrollTo(selection, anchor: .center) } }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up \(provider.displayName) models…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .padding(6)
        .frame(width: 300)
        .focusEffectDisabled()
        .onAppear { highlighted = ids.firstIndex(of: selection) ?? 0 }
        .paletteKeys(
            up: { move(-1) }, down: { move(1) },
            choose: { choose(ids[highlighted]) },
            dismiss: dismiss)
    }

    private func row(id: String, title: String, subtitle: String?, index: Int) -> some View {
        Button { choose(id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if id == selection {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 10, isSelected: index == highlighted))
        .onHover { if $0 { highlighted = index } }
    }

    private func subtitle(for option: ModelOption) -> String? {
        let parts = [option.name != option.id ? "`\(option.id)`" : nil, option.detail.isEmpty ? nil : option.detail].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func move(_ delta: Int) {
        highlighted = (highlighted + delta + ids.count) % ids.count
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
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: .capsule)
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
    /// Only whether the secrets are saved: reading them could ask for Keychain access on every visit.
    @State private var hasLinearKey = Keychain.contains(.linear)
    @State private var hasJiraToken = Keychain.contains(.jira)
    /// `gh` and `glab` found on the login shell PATH; `nil` until looked up.
    @State private var tools = SettingsLookups.forgeTools

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "Linear", badge: .connection(hasLinearKey)) {
                    SecretField(label: "API key", item: .linear, prompt: "lin_api_…", isSaved: $hasLinearKey)
                    note("Create a personal API key in Linear under Settings → Security & access. It is stored in your Keychain.")
                }
                SettingsCard(title: "Jira", badge: .connection(isJiraConnected)) {
                    SettingsField(label: "Site", text: $jiraSite, prompt: "example.atlassian.net")
                    SettingsField(label: "Email", text: $jiraEmail, prompt: "you@example.com")
                    SecretField(label: "API token", item: .jira, prompt: "Token", isSaved: $hasJiraToken)
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
            let found = Set(["gh", "glab"].filter { Toolchain.locate($0, in: path) != nil })
            SettingsLookups.forgeTools = found
            if tools != found { tools = found }
        }
    }

    private var isJiraConnected: Bool {
        JiraTickets.siteURL(jiraSite) != nil && !jiraEmail.isEmpty && hasJiraToken
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

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            DraftField(label: label, text: $text, prompt: prompt)
        }
    }
}

/// A Keychain secret that is replaced or removed but never shown, so opening Settings never reads it.
private struct SecretField: View {
    let label: String
    let item: Keychain.Item
    var prompt = ""
    @Binding var isSaved: Bool
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            HStack(spacing: 4) {
                SecureField(label, text: $draft, prompt: Text(isSaved ? "Saved in Keychain" : prompt))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isFocused)
                    .onSubmit(save)
                if isSaved, draft.isEmpty {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.hover(cornerRadius: 6, tint: .primary))
                    .help("Remove from Keychain")
                }
                SaveButton(isSaved: draft.isEmpty, isEmpty: !isSaved, action: save)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 30)
            .fieldBackground(isFocused: isFocused)
        }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if Keychain.write(value, for: item) { isSaved = true }
        draft = ""
    }

    private func remove() {
        if Keychain.write("", for: item) { isSaved = false }
    }
}

/// A soft input well whose edits stay a draft until saved with Return or its checkmark.
private struct DraftField: View {
    let label: String
    /// The saved value, written only on save.
    @Binding var text: String
    var prompt = ""
    var font: Font = .callout
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(label: String, text: Binding<String>, prompt: String = "", font: Font = .callout) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.font = font
        _draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $draft, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(font)
                .focused($isFocused)
                .onSubmit(save)
            SaveButton(isSaved: draft == text, isEmpty: text.isEmpty, action: save)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .fieldBackground(isFocused: isFocused)
        .onChange(of: text) { draft = text }
    }

    private func save() {
        text = draft.trimmingCharacters(in: .whitespaces)
        draft = text
    }
}

/// A ghost checkmark at the end of a field: saves its pending edit, and shows when there is none.
private struct SaveButton: View {
    let isSaved: Bool
    /// Nothing is saved yet, so there is nothing to confirm either.
    var isEmpty = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "checkmark.circle.fill" : "checkmark")
                .font(.system(size: isSaved ? 13 : 11, weight: .bold))
                .foregroundStyle(isSaved ? (isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.green)) : AnyShapeStyle(Theme.logoText))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 6, tint: isSaved ? .primary : Theme.logoText))
        .allowsHitTesting(!isSaved)
        .animation(.snappy(duration: 0.2), value: isSaved)
        .help(isSaved ? (isEmpty ? "Nothing saved" : "Saved") : "Save (↩)")
        .accessibilityLabel(isSaved ? "Saved" : "Save")
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
            ? Badge("Connected", systemImage: "checkmark.circle.fill", color: .green)
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

private struct AppearanceSettings: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(DiffMetrics.defaultFontSize)
    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified
    @AppStorage(AppSettings.lightCodeThemeKey) private var lightTheme = CodeTheme.default.rawValue
    @AppStorage(AppSettings.darkCodeThemeKey) private var darkTheme = CodeTheme.default.rawValue
    /// Which appearance's theme the tiles pick; starts at the current one.
    @State private var editsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "Theme") {
                    HStack(spacing: 14) {
                        ForEach(AppAppearance.allCases) { option in
                            ChoiceTile(title: option.title, isSelected: appearance == option, action: { appearance = option }) {
                                AppearancePreview(appearance: option)
                            }
                        }
                    }
                }
                SettingsCard(title: "Diff Layout") {
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
                SettingsCard(title: "Diff Theme") {
                    HStack {
                        Text("Colors for")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        SoftSegmented(selection: $editsDark, options: [(false, "Light Appearance"), (true, "Dark Appearance")])
                    }
                    let selected = CodeTheme.resolved(editsDark ? darkTheme : lightTheme, isDark: editsDark)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(CodeTheme.available(isDark: editsDark)) { theme in
                            ChoiceTile(title: theme.name(isDark: editsDark), isSelected: theme == selected, action: { choose(theme) }) {
                                CodeThemePreview(theme: theme, isDark: editsDark)
                            }
                        }
                    }
                    Text("Light and dark appearance each keep their own theme, and diffs switch with the appearance.")
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
        .scrollIndicators(.automatic)
    }

    private func choose(_ theme: CodeTheme) {
        if editsDark { darkTheme = theme.rawValue } else { lightTheme = theme.rawValue }
    }
}

/// A few lines of a diff in a theme's colors, on the diff background of its appearance.
private struct CodeThemePreview: View {
    let theme: CodeTheme
    let isDark: Bool

    private typealias Part = (text: String, token: SyntaxToken?)

    private static let lines: [(kind: DiffLine.Kind, parts: [Part])] = [
        (.context, [("func", .keyword), (" ", nil), ("greet", .function), ("(n: ", nil), ("Int", .type), (") {", nil)]),
        (.deletion, [("    ", nil), ("print", .function), ("(", nil), ("\"Hi\"", .string), (")", nil)]),
        (.addition, [("    ", nil), ("let", .keyword), (" count = ", nil), ("42", .number)]),
        (.addition, [("    ", nil), ("print", .function), ("(", nil), ("\"Hi ", .string), ("\\(", .escape), ("n", nil), (")", .escape),
                     ("\"", .string), (")", nil)]),
        (.context, [("    ", nil), ("// Done", .comment)]),
    ]

    var body: some View {
        let palette = theme.palette(isDark: isDark) ?? [:]
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Self.lines.indices, id: \.self) { index in
                let line = Self.lines[index]
                Text(text(line.kind, line.parts, palette: palette))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 11, alignment: .leading)
                    .background(DiffRowFormatter.tint(for: line.kind).map { Color(nsColor: $0) } ?? .clear)
            }
        }
        .padding(.vertical, 7)
        .frame(height: 74, alignment: .top)
        .background(Theme.panel)
        .clipShape(.rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    private func text(_ kind: DiffLine.Kind, _ parts: [Part], palette: [SyntaxToken: UInt32]) -> AttributedString {
        var marker = AttributedString(kind == .addition ? "+ " : kind == .deletion ? "− " : "  ")
        marker.foregroundColor = kind == .addition ? Theme.addition : Theme.deletion
        return parts.reduce(into: marker) { result, part in
            var run = AttributedString(part.text)
            if let value = part.token.flatMap({ palette[$0] }) { run.foregroundColor = Color(nsColor: CodeTheme.rgb(value)) }
            result += run
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
                        .disabled(AppVariant.isDev)
                    }
                    if AppVariant.isDev {
                        Label("ohmydiff Dev does not install the command, which belongs to the installed app.", systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if state == .outdated {
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
        case .current: Badge("Installed", systemImage: "checkmark.circle.fill", color: .green)
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
