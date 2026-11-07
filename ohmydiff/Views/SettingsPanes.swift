import AppKit
import OhMyDiffCore
import SwiftUI

// MARK: - Building blocks

/// A titled settings section: the title with an optional accessory, then its content.
struct SettingsSection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.row.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// Rows in a bordered table, divided by hairlines.
struct SettingsTable<Content: View>: View {
    var background: Color = .clear
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 {
                        Rectangle().fill(Theme.lineSubtle).frame(height: 1)
                    }
                }
            }
        }
        .background(background, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

/// A row: its title and detail on the left, its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.row)
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.detail)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .frame(minHeight: detail == nil ? 46 : 56)
    }
}

extension SettingsRow where Control == SettingsSwitch {
    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, detail: detail) { SettingsSwitch(isOn: isOn) }
    }
}

/// The 30 × 18 switch of the design: light track with a dark knob when on.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(Theme.hoverAnimation) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.inverse : Theme.selected)
                Circle()
                    .fill(isOn ? Theme.canvas : Theme.textTertiary)
                    .frame(width: 12, height: 12)
                    .padding(3)
            }
            .frame(width: 30, height: 18)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A pop-up menu styled as the design's select: soft fill, hairline, and ⌃⌄ at the end.
struct SettingsSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// An icon per option, e.g. the app's, shown in the menu and next to the choice.
    var icon: ((Value) -> NSImage?)?

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    if let image = icon?(option.value) {
                        Label { Text(option.title) } icon: { Image(nsImage: image) }
                    } else if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            SelectLabel(title: options.first { $0.value == selection }?.title ?? "", icon: icon?(selection))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

struct SelectLabel: View {
    let title: String
    var icon: NSImage? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
            }
            Text(title)
                .font(.control)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 12, height: 12)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(Theme.hover, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .contentShape(.rect)
    }
}

/// A selectable tile: raised with a strong edge when chosen.
struct SettingsTile<Content: View>: View {
    let isSelected: Bool
    var isDimmed = false
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12).fill(Theme.surface).shadow(color: Theme.cardShadow, radius: 2.5, y: 3)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Theme.lineStrong : Theme.line))
                .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(isDimmed ? 0.55 : 1)
    }
}

/// A letter on a small tile: inverse when chosen.
struct LetterMark: View {
    let letter: String
    var isSelected = false
    var size: CGFloat = 28

    var body: some View {
        Text(letter)
            .font(.system(size: size >= 28 ? 12.5 : 12, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.textInverse : Theme.textSecondary)
            .frame(width: size, height: size)
            .background(isSelected ? Theme.inverse : Theme.hover, in: .rect(cornerRadius: 8))
    }
}

/// `+` and `−` around a value, e.g. `12 pt`.
struct SettingsStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Button { value = max(value - 1, range.lowerBound) } label: { Image(systemName: "minus") }
                .disabled(value <= range.lowerBound)
            Text("\(Int(value)) \(unit)")
                .font(.control.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .frame(minWidth: 34)
            Button { value = min(value + 1, range.upperBound) } label: { Image(systemName: "plus") }
                .disabled(value >= range.upperBound)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

/// A single-line input well in the design's style.
struct SettingsInput: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .control
    var trailingImage: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Theme.textPrimary)
            if let trailingImage {
                Image(systemName: trailingImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

/// Versions and sign-in states looked up for Settings, kept for the session so panes show them at once.
@MainActor
enum ToolLookups {
    static var providerVersions: [AIProvider: String] = [:]
    static var tools: [String: (version: String, path: String)] = [:]
    static var ghUser: String?

    /// `claude 2.1`, from `<cli> --version`.
    static func version(of executable: URL, name: String, environment: [String: String]) async -> String? {
        guard let output = try? await ProcessRunner().run(executable, arguments: ["--version"], environment: environment, timeout: .seconds(8)),
              output.exitCode == 0,
              let version = ButVersion(output.stdoutString + output.stderrString)
        else { return nil }
        return "\(name) \(version.components.prefix(name == "but" ? 3 : 2).map(String.init).joined(separator: "."))"
    }

    static func environment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = await Toolchain.loginShellPath() { environment["PATH"] = path }
        return environment
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(AppSettings.editorKey) private var editor = AppSettings.defaultEditor
    @AppStorage(AppSettings.customEditorCommandKey) private var customCommand = ""
    @AppStorage(AppSettings.reopensLastProjectKey) private var reopensLastProject = true
    @AppStorage(AppSettings.groupsWorkspacesKey) private var groupsWorkspaces = true
    @AppStorage(AppSettings.controlSwitchesProjectsKey) private var controlSwitchesProjects = true
    @AppStorage(AppSettings.watchesFilesKey) private var watchesFiles = true
    @AppStorage(AppSettings.fetchIntervalKey) private var fetchInterval = 10
    @AppStorage(AppSettings.discardConfirmationKey) private var discardConfirmation = DiscardConfirmation.filesAndHunks
    @AppStorage(AppSettings.confirmsForcePushKey) private var confirmsForcePush = true
    @AppStorage(AppSettings.mergeMethodKey) private var mergeMethod = MergeMethod.rebase.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Open files in") {
                KeyCap("⌘O")
            } content: {
                HStack(spacing: 8) {
                    // Installed editors first, then the missing ones, Custom last.
                    let apps = EditorPreset.allCases.map(EditorApp.init(preset:))
                        .sorted { rank($0) < rank($1) }
                    ForEach(apps, id: \.preset) { app in
                        let preset = app.preset
                        SettingsTile(isSelected: editor == preset, isDimmed: !app.isInstalled && preset != .custom) {
                            editor = preset
                        } content: {
                            VStack(alignment: .leading, spacing: 10) {
                                if preset == .custom {
                                    LetterMark(letter: ">_", isSelected: editor == preset)
                                } else {
                                    app.icon.frame(width: 28, height: 28)
                                }
                                Text(preset.displayName)
                                    .font(.control)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(12)
                        }
                    }
                }
                if editor == .custom {
                    DraftField(label: "Command", text: $customCommand, prompt: "myeditor --goto {file}:{line}", font: .code(12))
                }
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                    Text("Opens at the selected line: \(example)")
                        .font(.code(11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Theme.textTertiary)
            }
            SettingsSection(title: "Projects") {
                SettingsTable {
                    SettingsRow("Reopen last project on launch", isOn: $reopensLastProject)
                    SettingsRow("Group projects into workspaces", detail: "Personal, Client, OSS in the switcher", isOn: $groupsWorkspaces)
                    SettingsRow("Switch projects with ⌃1–9", isOn: $controlSwitchesProjects)
                }
            }
            SettingsSection(title: "Refresh") {
                SettingsTable {
                    SettingsRow("Watch files", detail: "Changes appear as you save; ⌘R refreshes by hand", isOn: $watchesFiles)
                    SettingsRow(title: "Fetch remotes", detail: "Keeps ahead/behind and PR status current") {
                        SettingsSelect(selection: $fetchInterval, options: [
                            (0, "Never"), (1, "Every minute"), (5, "Every 5 minutes"), (10, "Every 10 minutes"), (30, "Every 30 minutes"),
                        ])
                    }
                }
            }
            SettingsSection(title: "Pull requests") {
                SettingsTable {
                    SettingsRow(title: "Merge with", detail: "Used by Merge, Merge when green and the menu command") {
                        SettingsSelect(selection: $mergeMethod, options: [
                            (MergeMethod.rebase.rawValue, "Rebase"), (MergeMethod.squash.rawValue, "Squash"), (MergeMethod.merge.rawValue, "Merge commit"),
                        ])
                    }
                }
            }
            SettingsSection(title: "Safety") {
                SettingsTable {
                    SettingsRow(title: "Ask before discarding", detail: "GitButler can undo with `but undo`; plain git cannot") {
                        SettingsSelect(selection: $discardConfirmation, options: DiscardConfirmation.allCases.map { ($0, $0.title) })
                    }
                    SettingsRow("Ask before force pushing", isOn: $confirmsForcePush)
                }
            }
        }
    }

    /// Installed editors, then missing ones, then Custom; `sorted` keeps each group in its listed order.
    private func rank(_ app: EditorApp) -> Int {
        app.preset == .custom ? 2 : app.isInstalled ? 0 : 1
    }

    /// The editor command filled in for an example file.
    private var example: String {
        let template = editor == .custom ? customCommand : editor.template ?? ""
        guard !template.isEmpty else { return "set a command with {file} and {line}" }
        return template.replacingOccurrences(of: "{file}", with: "Views/DiffDetailView.swift").replacingOccurrences(of: "{line}", with: "121")
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(DiffMetrics.defaultFontSize)
    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .split
    @AppStorage(DiffSettings.wholeFileKey) private var showsWholeFile = false
    @AppStorage(AppSettings.lineHeightKey) private var lineHeight = LineHeight.standard
    @AppStorage(AppSettings.showsSyntaxColorsKey) private var showsSyntaxColors = true
    @AppStorage(AppSettings.showsWhitespaceChangesKey) private var showsWhitespaceChanges = true
    @AppStorage(AppSettings.densityKey) private var density = Density.comfortable
    @AppStorage(AppSettings.reducesMotionKey) private var reducesMotion = false
    @AppStorage(AppSettings.lightCodeThemeKey) private var lightTheme = CodeTheme.default.rawValue
    @AppStorage(AppSettings.darkCodeThemeKey) private var darkTheme = CodeTheme.default.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Theme") {
                KeyCap("⌥⌘T")
            } content: {
                HStack(spacing: 10) {
                    ForEach([AppAppearance.system, .light, .dark]) { option in
                        SettingsTile(isSelected: appearance == option) { appearance = option } content: {
                            VStack(alignment: .leading, spacing: 10) {
                                ThemePreview(appearance: option)
                                HStack(spacing: 8) {
                                    Circle()
                                        .strokeBorder(appearance == option ? Color.clear : Theme.lineStrong, lineWidth: 1.5)
                                        .background(appearance == option ? Theme.inverse : .clear, in: .circle)
                                        .frame(width: 14, height: 14)
                                    Text(Self.title(option))
                                        .font(.control)
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
            }
            SettingsSection(title: "Diff") {
                SettingsTable {
                    SettingsRow(title: "Default layout", detail: "New projects start here; ⌘\\ switches any time") {
                        Segmented(selection: $layout, options: [(.split, "Split"), (.unified, "Unified")],
                                  systemImages: [.split: "rectangle.split.2x1", .unified: "rectangle"])
                    }
                    SettingsRow(title: "Default scope", detail: "Full file always shows every line, even far from a hunk") {
                        Segmented(selection: $showsWholeFile, options: [(false, "Changes"), (true, "Full file")],
                                  systemImages: [false: "arrow.down.and.line.horizontal.and.arrow.up", true: "arrow.up.and.line.horizontal.and.arrow.down"])
                    }
                    SettingsRow(title: "Code size") {
                        SettingsStepper(value: $fontSize, range: AppSettings.fontSizes, unit: "pt")
                    }
                    SettingsRow(title: "Line height") {
                        Segmented(selection: $lineHeight, options: LineHeight.allCases.map { ($0, $0.title) })
                    }
                    SettingsRow(title: "Syntax colours", detail: "Muted greys and one warm tone for strings") {
                        HStack(spacing: 10) {
                            if showsSyntaxColors {
                                SettingsSelect(selection: Binding(get: { lightTheme == darkTheme ? lightTheme : darkTheme }, set: {
                                    lightTheme = $0
                                    darkTheme = $0
                                }), options: CodeTheme.allCases.map { ($0.rawValue, $0.name(isDark: true)) })
                            }
                            SettingsSwitch(isOn: $showsSyntaxColors)
                        }
                    }
                    SettingsRow("Whitespace changes", detail: "Hidden changes still count in the hunk strip", isOn: $showsWhitespaceChanges)
                }
            }
            SettingsSection(title: "Interface") {
                SettingsTable {
                    SettingsRow(title: "Density") {
                        Segmented(selection: $density, options: Density.allCases.map { ($0, $0.title) })
                    }
                    SettingsRow("Reduce motion", detail: "Popovers and tabs appear without movement", isOn: $reducesMotion)
                }
            }
        }
    }

    static func title(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .system: "System"
        case .light: "Paper"
        case .dark: "Graphite"
        }
    }
}

/// A tiny ohmydiff window in Paper, Graphite, or both side by side for System.
private struct ThemePreview: View {
    let appearance: AppAppearance

    var body: some View {
        HStack(spacing: 4) {
            switch appearance {
            case .system:
                mini(isDark: false)
                mini(isDark: true)
            case .light: mini(isDark: false)
            case .dark: mini(isDark: true)
            }
        }
        .frame(height: 80)
    }

    private func mini(isDark: Bool) -> some View {
        let sidebar = isDark ? Color(white: 0.07) : Color(red: 0.94, green: 0.94, blue: 0.93)
        let canvas = isDark ? Color(white: 0.055) : Color(red: 0.97, green: 0.97, blue: 0.965)
        let line = isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.14)
        return HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(index == 1 ? line.opacity(2) : line).frame(width: 14, height: 2.5)
                }
            }
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(line).frame(width: 40, height: 2.5)
                Capsule().fill(Color(red: 0.89, green: 0.6, blue: 0.56).opacity(isDark ? 0.8 : 0.9)).frame(height: 2.5)
                Capsule().fill(Color(red: 0.55, green: 0.78, blue: 0.61).opacity(isDark ? 0.8 : 0.9)).frame(height: 2.5)
                Capsule().fill(Color(red: 0.55, green: 0.78, blue: 0.61).opacity(isDark ? 0.8 : 0.9)).frame(width: 50, height: 2.5)
                Capsule().fill(line).frame(width: 46, height: 2.5)
                Capsule().fill(line).frame(width: 30, height: 2.5)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(canvas, in: .rect(cornerRadius: 4))
        }
        .padding(5)
        .background(sidebar, in: .rect(cornerRadius: 7))
    }
}

// MARK: - AI

struct AISettings: View {
    @AppStorage(AppSettings.aiProviderKey) private var provider = AIProvider.claude
    @AppStorage(AppSettings.suggestionProviderKey) private var suggestionProvider = ""
    @AppStorage(AppSettings.terminalKey) private var terminal = AppSettings.terminal()
    @AppStorage(AppSettings.explainsInTerminalKey) private var explainsInTerminal = false
    @AppStorage(AppSettings.aiSendsCommitsKey) private var sendsCommits = true
    @AppStorage(AppSettings.aiSendsTicketKey) private var sendsTicket = true
    @State private var installed = SettingsLookups.installedProviders
    @State private var versions = ToolLookups.providerVersions
    @State private var detection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Provider") {
                Button { detection += 1 } label: { Label("Re-detect", systemImage: "arrow.clockwise") }
                    .buttonStyle(.pill(.ghost))
            } content: {
                HStack(spacing: 10) {
                    // Installed tools first, once detected.
                    let sorted = AIProvider.allCases.filter { installed?.contains($0) ?? true }
                        + AIProvider.allCases.filter { !(installed?.contains($0) ?? true) }
                    ForEach(sorted) { option in
                        providerTile(option)
                    }
                }
            }
            SettingsSection(title: "What it does") {
                SettingsTable {
                    ForEach(AITask.allCases) { task in
                        TaskRow(task: task, provider: chosenProvider)
                    }
                    HStack(spacing: 12) {
                        TaskIcon(systemImage: "apple.terminal")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open in \(provider.displayName)")
                                .font(.row.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Hands the hunk to a terminal session instead of inline")
                                .font(.detail)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SettingsSelect(selection: $terminal, options: terminals.map { ($0, $0.displayName) }) { AppIcons.icon($0.bundleIDs, size: 16) }
                        SettingsSwitch(isOn: $explainsInTerminal)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 58)
                }
            }
            SettingsSection(title: "What gets sent") {
                SettingsTable(background: Theme.surface) {
                    sentRow("doc", "Selected diff", "Only the hunks or files the action is about") { Chip("Always") }
                    sentRow("circle.and.line.horizontal", "Commit list & branch name", "For pull request drafts") { SettingsSwitch(isOn: $sendsCommits) }
                    sentRow("ticket", "Linked ticket", "Title and description from Linear, Jira, GitHub or GitLab") { SettingsSwitch(isOn: $sendsTicket) }
                    sentRow("checkmark.shield", "Your repository", "Never. The CLI runs in an empty folder with its tools, hooks and plugins off") {
                        Chip("Isolated", systemImage: "checkmark", tone: .ok)
                    }
                }
            }
        }
        .task(id: detection) { await detect() }
    }

    /// The provider suggestions run with; the terminal one when none is chosen yet.
    private var chosenProvider: AIProvider { AIProvider(rawValue: suggestionProvider) ?? provider }

    private func providerTile(_ option: AIProvider) -> some View {
        let isMissing = installed.map { !$0.contains(option) } ?? false
        let isSelected = AIProvider(rawValue: suggestionProvider) == option
        return SettingsTile(isSelected: isSelected, isDimmed: isMissing) {
            suggestionProvider = option.rawValue
            provider = option
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProviderIcon(provider: option, size: 28)
                    Spacer()
                    Circle()
                        .strokeBorder(isSelected ? Color.clear : Theme.lineStrong, lineWidth: 1.5)
                        .background(isSelected ? Theme.inverse : .clear, in: .circle)
                        .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .font(.row.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(isMissing ? "Not installed" : versions[option] ?? option.executable)
                        .font(.caption11)
                        .foregroundStyle(isMissing ? Theme.textTertiary : Theme.textSecondary)
                }
            }
            .padding(14)
        }
        .disabled(isMissing)
    }

    private func sentRow(_ image: String, _ title: String, _ detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 15, height: 15)
            Text(title)
                .font(.control)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
            Text(detail)
                .font(.detail)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func detect() async {
        let environment = await ToolLookups.environment()
        var found = Set<AIProvider>()
        for option in AIProvider.allCases {
            guard let executable = ClaudeCodeLauncher.locate(option, environment: environment) else { continue }
            found.insert(option)
            if let version = await ToolLookups.version(of: executable, name: option.executable, environment: environment) {
                versions[option] = version
            }
        }
        SettingsLookups.installedProviders = found
        ToolLookups.providerVersions = versions
        installed = found
    }

    /// Installed terminals first, in their listed order.
    private var terminals: [TerminalApp] {
        TerminalApp.allCases.filter { AppIcons.icon($0.bundleIDs) != nil } + TerminalApp.allCases.filter { AppIcons.icon($0.bundleIDs) == nil }
    }
}

private struct TaskIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 30, height: 30)
            .background(Theme.hover, in: .rect(cornerRadius: 8))
    }
}

/// An AI task: what it does, its model, and whether it is on.
private struct TaskRow: View {
    let task: AITask
    let provider: AIProvider
    @AppStorage private var model: String
    @AppStorage private var isEnabled: Bool
    @AppStorage private var runsOnDevice: Bool
    @State private var isPicking = false

    init(task: AITask, provider: AIProvider) {
        self.task = task
        self.provider = provider
        _model = AppStorage(wrappedValue: AppSettings.model(for: task), task.modelKey)
        _isEnabled = AppStorage(wrappedValue: true, task.enabledKey)
        _runsOnDevice = AppStorage(wrappedValue: false, task.onDeviceKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            TaskIcon(systemImage: task.systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(task.detail)
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { isPicking.toggle() } label: {
                SelectLabel(title: modelTitle)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                ModelPicker(
                    provider: provider, options: SettingsLookups.models[provider],
                    selection: runsOnDevice ? ModelPicker.onDeviceID : model,
                    onDevice: (task.supportsOnDevice, OnDeviceModel.unavailableReason), dismiss: { isPicking = false }
                ) { id in
                    // The keyboard can reach the row even when it is not available.
                    if id == ModelPicker.onDeviceID, !OnDeviceModel.isAvailable, !runsOnDevice { return }
                    runsOnDevice = id == ModelPicker.onDeviceID
                    if !runsOnDevice { model = id }
                    isPicking = false
                }
            }
            SettingsSwitch(isOn: $isEnabled)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .task(id: provider) {
            guard SettingsLookups.models[provider] == nil else { return }
            let toolchain = provider == .opencode ? try? await Toolchain.discover() : nil
            SettingsLookups.models[provider] = await ModelCatalog.models(for: provider, toolchain: toolchain)
        }
    }

    private var modelTitle: String {
        if task.supportsOnDevice, runsOnDevice { return "Apple Intelligence" }
        guard !model.isEmpty else { return "Default" }
        return SettingsLookups.models[provider]?.first { $0.id == model }?.name ?? model
    }
}

// MARK: - Templates

extension Notification.Name {
    /// Asks the commit composer to generate a message with the current template.
    static let tryCommitTemplate = Notification.Name("ohmydiff.tryCommitTemplate")
}

struct TemplateSettings: View {
    private enum Kind: Hashable { case commit, pullRequest }

    @State private var kind = Kind.commit
    @AppStorage(AppSettings.commitTemplateKey) private var commitTemplate = PromptTemplate.defaultCommit
    @AppStorage(AppSettings.pullRequestTemplateKey) private var pullRequestTemplate = PromptTemplate.defaultPullRequest
    @AppStorage(AppSettings.commitStyleKey) private var style = CommitStyle.conventional
    @AppStorage(AppSettings.titleLimitKey) private var titleLimit = 72
    @AppStorage(AppSettings.addsTicketToTitleKey) private var addsTicketToTitle = true
    @State private var insertAtCursor: ((String) -> Void)?

    private var text: Binding<String> { kind == .commit ? $commitTemplate : $pullRequestTemplate }
    private var defaultText: String { kind == .commit ? PromptTemplate.defaultCommit : PromptTemplate.defaultPullRequest }
    private var isEdited: Bool { text.wrappedValue != defaultText }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Segmented(selection: $kind, options: [(.commit, "Commit message"), (.pullRequest, "Pull request")],
                      systemImages: [.commit: "circle.and.line.horizontal", .pullRequest: "arrow.triangle.pull"])
            HStack(alignment: .top, spacing: 12) {
                editor
                placeholders
                    .frame(width: 204)
            }
            if kind == .commit {
                SettingsSection(title: "Commit format") {
                    SettingsTable {
                        SettingsRow(title: "Style", detail: "Checked before you commit; the AI follows it too") {
                            Segmented(selection: $style, options: CommitStyle.allCases.map { ($0, $0.title) })
                        }
                        SettingsRow(title: "Title limit") {
                            HStack(spacing: 6) {
                                TextField("72", value: $titleLimit, format: .number)
                                    .textFieldStyle(.plain)
                                    .font(.control.weight(.medium))
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 28)
                                Text("characters")
                                    .font(.control)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                        }
                        SettingsRow("Add ticket id to the title", detail: "fix(diff): keep other hunks (HAL-128)", isOn: $addsTicketToTitle)
                    }
                }
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text(kind == .commit ? "Commit message prompt" : "Pull request prompt")
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if isEdited { Chip("Edited", tone: .warn) }
                Spacer(minLength: 4)
                Button { text.wrappedValue = defaultText } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.pill(.ghost))
                    .disabled(!isEdited)
                if kind == .commit {
                    Button {
                        NotificationCenter.default.post(name: .tryCommitTemplate, object: nil)
                    } label: {
                        Label { Text("Try on current changes") } icon: { Image(systemName: "sparkles").foregroundStyle(Theme.infoFg) }
                    }
                    .buttonStyle(.pill())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(1...max(lineCount, 1), id: \.self) { number in
                        Text("\(number)")
                            .font(.code(11))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(height: TemplateEditor.lineHeight, alignment: .bottom)
                            .offset(y: -2)
                    }
                }
                .frame(width: 32, alignment: .trailing)
                TemplateEditor(text: text, insert: $insertAtCursor)
                    .id(kind)
                    .frame(height: CGFloat(max(lineCount, 8)) * TemplateEditor.lineHeight + 16)
                    .padding(.leading, 12)
            }
            .padding(.vertical, 10)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            HStack {
                Text("About \(estimatedTokens) tokens of instructions · \(providerTitle)")
                Spacer()
                Text("Saved")
            }
            .font(.caption11)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    private var placeholders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Placeholders")
                .font(.row.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(height: 30, alignment: .bottom)
            SettingsTable {
                ForEach(TemplateContext.placeholders, id: \.name) { placeholder in
                    Button { insert("{{\(placeholder.name)}}") } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("{{\(placeholder.name)}}")
                                .font(.code(11))
                                .foregroundStyle(Theme.infoFg)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Theme.infoBg, in: .rect(cornerRadius: 4))
                            Text(placeholder.description)
                                .font(.caption11)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Click one to insert it at the cursor.")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var lineCount: Int { text.wrappedValue.split(separator: "\n", omittingEmptySubsequences: false).count }

    private var estimatedTokens: String {
        let tokens = text.wrappedValue.count / 4
        return tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
    }

    private var providerTitle: String {
        AppSettings.runnerTitle(for: kind == .commit ? .commitMessage : .pullRequest) ?? "No provider"
    }

    /// Inserts at the cursor, or at the end before the editor was used.
    private func insert(_ token: String) {
        if let insertAtCursor {
            insertAtCursor(token)
        } else {
            text.wrappedValue += token
        }
    }
}

// MARK: - Tickets

struct TicketSettings: View {
    @AppStorage(AppSettings.jiraSiteKey) private var jiraSite = ""
    @AppStorage(AppSettings.jiraEmailKey) private var jiraEmail = ""
    @AppStorage(AppSettings.githubTicketsKey) private var github = false
    @AppStorage(AppSettings.gitlabTicketsKey) private var gitlab = false
    @AppStorage(AppSettings.linearTeamKey) private var linearTeam = ""
    @AppStorage(AppSettings.ticketPatternKey) private var pattern = "{type}/{ticket}-{words}"
    @State private var hasLinearKey = Keychain.contains(.linear)
    @State private var hasJiraToken = Keychain.contains(.jira)
    @State private var linearKey = ""
    @State private var jiraToken = ""
    @State private var linear: (name: String, teams: [LinearTickets.Team])?
    @State private var linearError: String?
    @State private var tools = SettingsLookups.forgeTools
    @State private var ghUser = ToolLookups.ghUser

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            linearCard
            jiraCard
            forgeCard
            SettingsSection(title: "Find the ticket in a branch name") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pattern")
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                    SettingsInput(placeholder: "{type}/{ticket}-{words}", text: $pattern, font: .code(12))
                    ForEach(["feature/hal-128-diff-modes", "fix/42-crash", "fix/encoding"], id: \.self) { branch in
                        HStack(spacing: 8) {
                            Text(branch).font(.code(11.5)).foregroundStyle(Theme.textSecondary)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                            if let key = TicketKey.keys(inBranch: branch, pattern: pattern).first {
                                Chip(Self.title(key), systemImage: "ticket", tone: .ok)
                            } else {
                                Text("no ticket, search in the commit sheet")
                                    .font(.caption11)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            }
        }
        .task { await lookUp() }
    }

    private static func title(_ key: TicketKey) -> String {
        switch key {
        case .key(let id): id
        case .number(let number): "#\(number)"
        }
    }

    private func card(letter: String, source: TicketSource? = nil, title: String, subtitle: String, @ViewBuilder trailing: () -> some View, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppIconView(bundleIDs: source?.bundleIDs ?? [], size: 28) { LetterMark(letter: letter, isSelected: true) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.row.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.caption11).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .background(Theme.surface)
            content()
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    private var linearCard: some View {
        card(
            letter: "L", source: .linear, title: "Linear",
            subtitle: hasLinearKey ? [linear.map { "Workspace \($0.name)" }, "API key in Keychain"].compactMap(\.self).joined(separator: " · ") : "Not connected"
        ) {
            if hasLinearKey {
                Chip("Connected", systemImage: "checkmark", tone: .ok)
                Button("Disconnect") {
                    if Keychain.write("", for: .linear) { hasLinearKey = false }
                    linear = nil
                }
                .buttonStyle(.pill(.ghost))
            } else {
                Chip("Optional")
            }
        } content: {
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            if hasLinearKey {
                HStack {
                    Text("Default team for search").font(.control).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    SettingsSelect(selection: $linearTeam, options: [("", "All teams")] + (linear?.teams ?? []).map { ($0.key, "\($0.key) · \($0.name)") })
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
            } else {
                HStack(spacing: 8) {
                    SecureField("Paste a personal API key (lin_api_…)", text: $linearKey)
                        .textFieldStyle(.plain)
                        .font(.control)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                    Button("Connect") {
                        if Keychain.write(linearKey.trimmingCharacters(in: .whitespaces), for: .linear) { hasLinearKey = true }
                        linearKey = ""
                        Task { await lookUp() }
                    }
                    .buttonStyle(.pill(.prominent))
                    .disabled(linearKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
            if let linearError {
                Text(linearError).font(.caption11).foregroundStyle(Theme.delFg).padding([.horizontal, .bottom], 12)
            }
        }
    }

    private var jiraCard: some View {
        let isConnected = JiraTickets.siteURL(jiraSite) != nil && !jiraEmail.isEmpty && hasJiraToken
        return card(letter: "J", source: .jira, title: "Jira", subtitle: isConnected ? "\(jiraSite) · token in Keychain" : "Not connected") {
            if isConnected {
                Chip("Connected", systemImage: "checkmark", tone: .ok)
                Button("Disconnect") { if Keychain.write("", for: .jira) { hasJiraToken = false } }
                    .buttonStyle(.pill(.ghost))
            } else {
                Chip("Optional")
            }
        } content: {
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    labeled("Site") { SettingsInput(placeholder: "https://acme.atlassian.net", text: $jiraSite) }
                    labeled("Email") { SettingsInput(placeholder: "you@company.com", text: $jiraEmail) }
                }
                labeled("API token") {
                    HStack(spacing: 8) {
                        HStack {
                            SecureField(hasJiraToken ? "Saved in Keychain" : "Paste a token from id.atlassian.com", text: $jiraToken)
                                .textFieldStyle(.plain)
                                .font(.control)
                            Image(systemName: "key").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                        Button("Connect") {
                            if Keychain.write(jiraToken.trimmingCharacters(in: .whitespaces), for: .jira) { hasJiraToken = true }
                            jiraToken = ""
                        }
                        .buttonStyle(.pill(.prominent))
                        .disabled(jiraToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(12)
        }
    }

    private var forgeCard: some View {
        card(letter: "G", source: .github, title: "GitHub & GitLab", subtitle: "Uses the command line tools you already sign in with") {
            EmptyView()
        } content: {
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            forgeRow("GitHub issues", tool: "gh", detail: ghUser.map { "via gh · signed in as \($0)" } ?? "via gh", isOn: $github)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            forgeRow("GitLab issues", tool: "glab", detail: "via glab", isOn: $gitlab)
        }
    }

    private func forgeRow(_ title: String, tool: String, detail: String, isOn: Binding<Bool>) -> some View {
        let isMissing = tools.map { !$0.contains(tool) } ?? false
        return HStack(spacing: 10) {
            Text(title).font(.row).foregroundStyle(Theme.textPrimary)
            Text(isMissing ? "\(tool) is not installed" : detail).font(.caption11).foregroundStyle(Theme.textTertiary)
            Spacer()
            if isMissing {
                Button { NSWorkspace.shared.open(URL(string: tool == "gh" ? "https://cli.github.com" : "https://gitlab.com/gitlab-org/cli")!) } label: {
                    Label("How to install", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.pill(.ghost))
            } else {
                SettingsSwitch(isOn: isOn)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func labeled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption11).foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func lookUp() async {
        let environment = await ToolLookups.environment()
        let path = environment["PATH"] ?? ""
        let found = Set(["gh", "glab"].filter { Toolchain.locate($0, in: path) != nil })
        SettingsLookups.forgeTools = found
        tools = found
        if let gh = Toolchain.locate("gh", in: path),
           let output = try? await ProcessRunner().run(gh, arguments: ["api", "user", "--jq", ".login"], environment: environment, timeout: .seconds(8)),
           output.exitCode == 0 {
            let user = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            ToolLookups.ghUser = user.isEmpty ? nil : user
            ghUser = ToolLookups.ghUser
        }
        guard hasLinearKey, let key = Keychain.read(.linear), !key.isEmpty else { return }
        do {
            linear = try await LinearTickets(apiKey: key).workspace()
            linearError = nil
        } catch {
            linearError = String(describing: error)
        }
    }
}

// MARK: - Command line

struct CommandLineSettings: View {
    @State private var state = CLILauncher.installState(app: Self.app)
    @State private var isOnPath: Bool?
    @State private var error: String?
    @State private var expanded: String?
    @State private var tools: [(name: String, version: String, path: String)] = []
    @State private var butMismatch = false
    @State private var detection = 0
    @State private var ghUser = ToolLookups.ghUser
    @AppStorage(AppSettings.mcpLastUsedKey) private var mcpLastUsed: Double = 0
    @AppStorage(AppSettings.mcpLastClientKey) private var mcpLastClient = ""

    private static var app: String { Bundle.main.executableURL?.path ?? "" }
    private static let addCommand = "claude mcp add ohmydiff -- ohmydiff mcp"

    private static let examples: [(command: String, detail: String, more: String)] = [
        ("ohmydiff", "Open the repository you are in", "Adds it as a project the first time, then brings ohmydiff to the front."),
        ("ohmydiff show Views/Diff.swift:118", "Jump to a file and line", "Selects the changed file and scrolls its diff to line 118 of the new file."),
        ("ohmydiff branch feat/diff-modes", "Show a branch in Branches", "Selects the branch with its commits and pull request."),
        ("ohmydiff commit a41c9e2", "Show a commit in History", "Selects the commit in the log with its files."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "ohmydiff command") {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "apple.terminal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textInverse)
                            .frame(width: 32, height: 32)
                            .background(Theme.inverse, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stateTitle).font(.row.weight(.medium)).foregroundStyle(Theme.textPrimary)
                            Text("\((CLILauncher.defaultDirectory.appending(path: "ohmydiff").path as NSString).abbreviatingWithTildeInPath) · \(Updater.currentVersion)")
                                .font(.code(11.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if state != .missing, let isOnPath {
                            Chip(isOnPath ? "On PATH" : "Not on PATH", systemImage: isOnPath ? "checkmark" : "exclamationmark.triangle", tone: isOnPath ? .ok : .warn)
                        }
                        Button(state == .missing ? "Install" : "Reinstall") { install() }
                            .buttonStyle(.pill(state == .current ? .normal : .prominent))
                            .disabled(AppVariant.isDev)
                        if state != .missing {
                            Button("Remove") { remove() }
                                .buttonStyle(.pill(.ghost))
                                .foregroundStyle(Theme.delFg)
                                .disabled(AppVariant.isDev)
                        }
                    }
                    .padding(12)
                    .background(Theme.surface)
                    if let note {
                        Text(note).font(.caption11).foregroundStyle(Theme.warnFg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            .background(Theme.surface)
                    }
                    ForEach(Self.examples, id: \.command) { example in
                        Rectangle().fill(Theme.lineSubtle).frame(height: 1)
                        exampleRow(example)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            }
            SettingsSection(title: "MCP server for coding agents") {
                if mcpLastUsed > 0 {
                    let date = Date(timeIntervalSinceReferenceDate: mcpLastUsed)
                    Chip("Last used \(RelativeAge.short(date)) ago" + (mcpLastClient.isEmpty ? "" : " by \(Self.clientName(mcpLastClient))"),
                         systemImage: "checkmark.circle", tone: .ok)
                }
            } content: {
                SettingsTable {
                    HStack(spacing: 8) {
                        Text("$").foregroundStyle(Theme.textTertiary)
                        Text(Self.addCommand).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                        Spacer()
                        SettingsCopyButton(text: Self.addCommand, title: "Copy")
                    }
                    .font(.code(12))
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(Theme.surface)
                    toolGroup("Read only", detail: "answer from git and but without the app", tools: ["list_projects", "list_changes", "get_diff", "list_branches"], tone: .neutral)
                    toolGroup("Bring the app forward", detail: "at that file, line, branch or commit", tools: ["open_project", "show_file", "show_branch", "show_commit"], tone: .info)
                }
            }
            SettingsSection(title: "Tools ohmydiff calls") {
                Button { detection += 1 } label: { Label("Re-detect", systemImage: "arrow.clockwise") }
                    .buttonStyle(.pill(.ghost))
            } content: {
                SettingsTable {
                    ForEach(tools, id: \.name) { tool in
                        HStack(spacing: 12) {
                            ToolIcon(name: tool.name)
                            Text(tool.name).font(.code(12.5)).foregroundStyle(Theme.textPrimary).frame(width: 52, alignment: .leading)
                            Text(tool.name == "gh" ? [tool.version, ghUser.map { "signed in as \($0)" }].compactMap(\.self).joined(separator: " · ") : "\(tool.version) · \(tool.path)")
                                .font(.detail)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            switch tool.name {
                            case "but": Chip(butMismatch ? "Untested version" : "Tested version", systemImage: butMismatch ? "exclamationmark.triangle" : "checkmark", tone: butMismatch ? .warn : .ok)
                            case "gh": Chip("Pull requests", systemImage: "arrow.triangle.pull")
                            default: Chip("OK", systemImage: "checkmark", tone: .ok)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                    }
                }
            }
            if let error {
                Text(error).font(.detail).foregroundStyle(Theme.delFg)
            }
        }
        .task(id: detection) { await detect() }
    }

    private var stateTitle: String {
        switch state {
        case .current: "Installed"
        case .outdated: "Installed · outdated"
        case .missing: "Not installed"
        }
    }

    private var note: String? {
        if AppVariant.isDev { return "ohmydiff Dev does not install the command, which belongs to the installed app." }
        if state == .outdated { return "The installed command is from an older version or another copy of the app. Reinstall it." }
        if isOnPath == false, state != .missing { return "Add this to your shell profile: export PATH=\"$HOME/.local/bin:$PATH\"" }
        return nil
    }

    private func exampleRow(_ example: (command: String, detail: String, more: String)) -> some View {
        let isExpanded = expanded == example.command
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy(duration: 0.15)) { expanded = isExpanded ? nil : example.command } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(example.command).font(.code(12)).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(example.detail).font(.detail).foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                SettingsCopyButton(text: example.command)
            }
            if isExpanded {
                Text(example.more).font(.detail).foregroundStyle(Theme.textSecondary).padding(.leading, 19)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .padding(.vertical, isExpanded ? 6 : 0)
    }

    private func toolGroup(_ title: String, detail: String, tools: [String], tone: Chip.Tone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.control.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.caption11).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 6) {
                ForEach(tools, id: \.self) { tool in
                    Text(tool)
                        .font(.code(11))
                        .foregroundStyle(tone == .info ? Theme.infoFg : Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tone == .info ? Theme.infoBg : Theme.hover, in: .capsule)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func clientName(_ client: String) -> String {
        switch client.lowercased() {
        case let name where name.contains("claude"): "Claude Code"
        case let name where name.contains("codex"): "Codex"
        case let name where name.contains("cursor"): "Cursor"
        default: client
        }
    }

    private func detect() async {
        let environment = await ToolLookups.environment()
        isOnPath = (environment["PATH"]).map { CLILauncher.searchPath($0, contains: CLILauncher.defaultDirectory) }
        var found: [(name: String, version: String, path: String)] = []
        for name in ["but", "git", "gh"] {
            guard let url = Toolchain.locate(name, in: environment["PATH"] ?? "") else { continue }
            let version = await ToolLookups.version(of: url, name: name, environment: environment).map { String($0.dropFirst(name.count + 1)) } ?? ""
            found.append((name, version, (url.path as NSString).abbreviatingWithTildeInPath))
        }
        if let but = found.first(where: { $0.name == "but" }) {
            butMismatch = ButCompatibility.mismatch(version: ButVersion(but.version)) != nil
        }
        tools = found
        ghUser = ToolLookups.ghUser
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

    private func remove() {
        do {
            try CLILauncher.uninstall(app: Self.app)
            error = nil
        } catch {
            self.error = "Could not remove: \(error.localizedDescription)"
        }
        state = CLILauncher.installState(app: Self.app)
    }
}

/// A small copy button that shows a checkmark for a moment after copying.
struct SettingsCopyButton: View {
    let text: String
    var title: String?
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            if let title {
                Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(title == nil ? AnyButtonStyle(.hover(cornerRadius: 6)) : AnyButtonStyle(.pill()))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Picks a button style at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Updates

struct UpdateSettings: View {
    @Bindable var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "ohmydiff \(Updater.currentVersion)") {
                if let version = updater.pendingVersion {
                    Chip("\(version) available", systemImage: "arrow.down.circle", tone: .info)
                } else if updater.phase == .upToDate {
                    Chip("Up to date", systemImage: "checkmark", tone: .ok)
                }
            } content: {
                SettingsTable {
                    SettingsRow(title: "Build \(Updater.currentBuild)", detail: statusDetail) {
                        if updater.pendingVersion == nil {
                            Button { updater.checkForUpdates() } label: {
                                if updater.phase == .checking {
                                    Label { Text("Checking…") } icon: { ProgressView().controlSize(.mini) }
                                } else {
                                    Label("Check now", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.pill())
                            .disabled(!updater.canCheck)
                        }
                    }
                    if updater.pendingVersion != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            UpdateStatus(updater: updater)
                            UpdateActions(updater: updater).fixedSize()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if updater.isAvailable {
                        SettingsRow("Check for updates automatically", detail: "On launch and once a day", isOn: $updater.automaticallyChecks)
                        SettingsRow("Download and install automatically", detail: "Installs when you quit, or restart from the update bar", isOn: $updater.automaticallyDownloads)
                            .disabled(!updater.automaticallyChecks)
                    }
                }
            }
        }
    }

    private var statusDetail: String {
        if !updater.isAvailable { return "Development builds don’t update themselves." }
        if case .failed(let message) = updater.phase { return "The last check failed: \(message)" }
        if let lastCheck = updater.lastCheck { return "Last checked \(lastCheck.formatted(.relative(presentation: .named)))." }
        return "Not checked yet."
    }
}

/// A template editor: monospaced, one line per row so the line numbers line up, and `{{placeholders}}` marked.
struct TemplateEditor: NSViewRepresentable {
    @Binding var text: String
    /// Inserts at the cursor; set by the editor for the placeholders list.
    @Binding var insert: ((String) -> Void)?
    static let lineHeight: CGFloat = 18

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as! NSTextView
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        // No wrapping: lines scroll sideways, so each line is one row next to its number.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.highlight()
        DispatchQueue.main.async {
            insert = { [weak coordinator = context.coordinator] token in coordinator?.insert(token) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        textView.string = text
        context.coordinator.highlight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            highlight()
        }

        func insert(_ token: String) {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.insertText(token, replacementRange: textView.selectedRange())
        }

        /// Monospaced text at a fixed line height, placeholders in the info colours.
        func highlight() {
            guard let storage = textView?.textStorage else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = TemplateEditor.lineHeight
            paragraph.maximumLineHeight = TemplateEditor.lineHeight
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: Theme.textPrimaryColor,
                .paragraphStyle: paragraph,
            ], range: full)
            let regex = try? NSRegularExpression(pattern: "\\{\\{[a-z.]+\\}\\}")
            for match in regex?.matches(in: storage.string, range: full) ?? [] {
                storage.addAttributes([
                    .foregroundColor: Theme.dynamicNSColor(light: 0x2F68B0, dark: 0x8FB4E3),
                    .backgroundColor: Theme.dynamicNSColor(light: 0x2F68B0, dark: 0x8FB4E3, lightAlpha: 0.08, darkAlpha: 0.12),
                ], range: match.range)
            }
            storage.endEditing()
            textView?.typingAttributes = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: Theme.textPrimaryColor,
                .paragraphStyle: paragraph,
            ]
        }
    }
}


/// A tool's mark in Settings → Command line: the AI CLIs' logos, GitButler's app icon, symbols for git and gh.
private struct ToolIcon: View {
    let name: String

    var body: some View {
        Group {
            if let provider = AIProvider.allCases.first(where: { $0.executable == name }) {
                ProviderIcon(provider: provider, size: 22)
            } else if name == "but" {
                AppIconView(bundleIDs: ["com.gitbutler.app", "com.gitbutler.app.nightly"], size: 22) { symbol("square.3.layers.3d") }
            } else {
                symbol(name == "gh" ? "arrow.triangle.pull" : "arrow.triangle.branch")
            }
        }
        .frame(width: 22, height: 22)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 22, height: 22)
            .background(Theme.hover, in: .rect(cornerRadius: 6))
    }
}
