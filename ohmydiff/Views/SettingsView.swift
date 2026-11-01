import AppKit
import OhMyDiffCore
import SwiftUI

enum SettingsPane: String, Hashable, CaseIterable, Identifiable {
    case general, appearance, ai, templates, tickets, commandLine, shortcuts, updates

    var id: Self { self }

    /// The panes built so far, in sidebar order.
    static let available: [SettingsPane] = [.general, .appearance, .ai, .templates, .tickets, .commandLine, .shortcuts, .updates]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .ai: "AI"
        case .templates: "Templates"
        case .tickets: "Tickets"
        case .commandLine: "Command line"
        case .shortcuts: "Shortcuts"
        case .updates: "Updates"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Where files open, how projects behave, and what ohmydiff asks before it changes anything."
        case .appearance: "Two themes, one switch. Diff colours stay the same meaning in both."
        case .ai: "ohmydiff uses an AI command line tool you already have. Nothing is sent until you press a ✦ action, and you always see what it sends."
        case .templates: "The prompts behind ✦ actions and the shape your commits take. Placeholders fill in from what you selected."
        case .tickets: "Link branches to tickets so commits and pull requests can use their title and description. Keys stay in your Keychain."
        case .commandLine: "Open ohmydiff from a terminal, and let coding agents read your changes or point you at a line."
        case .shortcuts: "Everything has a key. Click a shortcut to record a new one; single letters only work while the diff has focus."
        case .updates: "New releases install when you quit, or right away from the update bar."
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .ai: "sparkles"
        case .templates: "doc.text"
        case .tickets: "ticket"
        case .commandLine: "apple.terminal"
        case .shortcuts: "keyboard"
        case .updates: "arrow.clockwise"
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.settingsPaneKey) private var pane = SettingsPane.general
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            SettingsNav(pane: $pane, search: $search)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pane.title)
                            .font(.settingsTitle)
                            .foregroundStyle(Theme.textPrimary)
                        Text(pane.subtitle)
                            .font(.row)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Group {
                        switch pane {
                        case .general: GeneralSettings()
                        case .appearance: AppearanceSettings()
                        case .ai: AISettings()
                        case .templates: TemplateSettings()
                        case .tickets: TicketSettings()
                        case .commandLine: CommandLineSettings()
                        case .updates: UpdateSettings(updater: .shared)
                        case .shortcuts: ShortcutSettings()
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .background(Theme.canvas)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.lineSubtle))
            .padding([.vertical, .trailing], 8)
        }
        .frame(width: 1040, height: 700)
        .containerBackground(Theme.sidebar, for: .window)
        .background(Theme.sidebar.ignoresSafeArea())
        .background { TitlelessWindow() }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .ignoresSafeArea()
        // Also here, so the theme switches at once even while the main window is closed.
        .onChange(of: appearance) { appearance.apply() }
    }
}

/// The settings sidebar: search, the panes and the versions in use.
private struct SettingsNav: View {
    @Binding var pane: SettingsPane
    @Binding var search: String
    @FocusState private var isSearchFocused: Bool
    @State private var toolVersions = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Color.clear.frame(height: 40)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                TextField("Search settings", text: $search)
                    .textFieldStyle(.plain)
                    .font(.control)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($isSearchFocused)
                    .onSubmit { matches.first.map { pane = $0 } }
                KeyCap("⌘F")
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.hover, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.lineSubtle))
            .padding(.top, 6)
            .padding(.bottom, 10)
            .background {
                Button("") { isSearchFocused = true }
                    .keyboardShortcut("f")
                    .hidden()
            }
            ForEach(matches) { item in
                Button { pane = item } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(item == pane ? Theme.textPrimary : Theme.textSecondary)
                            .frame(width: 15, height: 15)
                        Text(item.title)
                            .font(.row.weight(item == pane ? .medium : .regular))
                            .foregroundStyle(item == pane ? Theme.textPrimary : Theme.textSecondary)
                        Spacer(minLength: 4)
                        trailing(item)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(.rect)
                }
                .buttonStyle(.row(isSelected: item == pane))
                .focusEffectDisabled()
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("ohmydiff \(Updater.currentVersion)")
                if !toolVersions.isEmpty { Text(toolVersions) }
            }
            .font(.caption11)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            let environment = await ToolLookups.environment()
            var parts: [String] = []
            for name in ["but", "git"] {
                if let url = Toolchain.locate(name, in: environment["PATH"] ?? ""),
                   let version = await ToolLookups.version(of: url, name: name, environment: environment) {
                    parts.append(version)
                }
            }
            toolVersions = parts.joined(separator: " · ")
        }
    }

    /// Panes whose title or text matches the search.
    private var matches: [SettingsPane] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SettingsPane.available }
        return SettingsPane.available.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func trailing(_ item: SettingsPane) -> some View {
        switch item {
        case .updates:
            if let version = Updater.shared.pendingVersion {
                Text(version)
                    .font(.caption11)
                    .foregroundStyle(Theme.infoFg)
            }
        case .tickets:
            let count = AppSettings.connectedTicketTrackers()
            if count > 0 {
                Text("\(count)")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
        default:
            EmptyView()
        }
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
enum SettingsLookups {
    static var installedProviders: Set<AIProvider>?
    static var models: [AIProvider: [ModelOption]] = [:]
    static var forgeTools: Set<String>?
}

/// The provider's known models in a panel like the hunk bar's: the default first, then each model with its ID
/// and what it is for. Arrow keys and Return pick one.
struct ModelPicker: View {
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

/// Lays out its children left to right, wrapping to new lines.
struct FlowRow: Layout {
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

/// A Keychain secret that is replaced or removed but never shown, so opening Settings never reads it.
struct SecretField: View {
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
struct DraftField: View {
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
struct SaveButton: View {
    let isSaved: Bool
    /// Nothing is saved yet, so there is nothing to confirm either.
    var isEmpty = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "checkmark.circle.fill" : "checkmark")
                .font(.system(size: isSaved ? 13 : 11, weight: .bold))
                .foregroundStyle(isSaved ? (isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.green)) : AnyShapeStyle(Theme.textPrimary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 6, tint: isSaved ? .primary : Theme.textPrimary))
        .allowsHitTesting(!isSaved)
        .animation(.snappy(duration: 0.2), value: isSaved)
        .help(isSaved ? (isEmpty ? "Nothing saved" : "Saved") : "Save (↩)")
        .accessibilityLabel(isSaved ? "Saved" : "Save")
    }
}

/// A small status capsule, e.g. `Installed` or `Connected`.
struct Badge: View {
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
struct ProviderIcon: View {
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

/// An editor's app icon, or a symbol for a custom command or an editor that is not installed.
struct EditorApp {
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

struct MiniWindow: View {
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
