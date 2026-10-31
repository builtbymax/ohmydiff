import AppKit
import OhMyDiffCore
import SwiftUI

/// `UserDefaults` keys and defaults for the Settings window.
enum AppSettings {
    static let editorKey = "editorPreset"
    static let customEditorCommandKey = "customEditorCommand"
    static let fontSizeKey = "diffFontSize"
    static let appearanceKey = "appearance"
    /// The code themes for light and dark appearance.
    static let lightCodeThemeKey = "codeThemeLight"
    static let darkCodeThemeKey = "codeThemeDark"
    /// Width of the file list column, and whether it is hidden to give the diff the whole panel.
    static let listWidthKey = "listWidth"
    static let isListHiddenKey = "isListHidden"
    /// The View menu's panels and diff options.
    static let isSidebarHiddenKey = "isSidebarHidden"
    static let isHunkStripHiddenKey = "isHunkStripHidden"
    static let isActivityHiddenKey = "isActivityHidden"
    static let isInspectorShownKey = "isInspectorShown"
    static let showsLineNumbersKey = "showsLineNumbers"
    static let showsWhitespaceChangesKey = "showsWhitespaceChanges"
    static let wrapsLinesKey = "wrapsLines"
    static let showsSyntaxColorsKey = "showsSyntaxColors"
    /// The file list's grouping by branch (or staged/unstaged), and collapsing lockfiles and other generated files.
    static let groupsChangesKey = "groupsChanges"
    static let collapsesGeneratedFilesKey = "collapsesGeneratedFiles"
    /// The untested GitButler version whose note was dismissed, as `<installed>/<tested>`.
    static let dismissedButMismatchKey = "dismissedButVersionMismatch"
    static let listWidths: ClosedRange<Double> = 240...480
    /// Width of the file list beside a commit's or branch's diff in History mode.
    static let historyFilesWidthKey = "historyFilesWidth"
    static let historyFilesWidths: ClosedRange<Double> = 200...420
    /// The terminal the AI provider is started in, and which provider.
    static let terminalKey = "terminalApp"
    static let aiProviderKey = "aiProvider"
    /// The provider and model that suggest commit messages, branch names and pull requests; empty for none.
    static let suggestionProviderKey = "suggestionProvider"
    static let suggestionModelKey = "suggestionModel"
    /// Edited templates; absent or blank for the defaults.
    static let commitTemplateKey = "commitTemplate"
    static let pullRequestTemplateKey = "pullRequestTemplate"
    /// Ticket trackers. API keys and tokens live in the Keychain.
    static let jiraSiteKey = "jiraSite"
    static let jiraEmailKey = "jiraEmail"
    static let githubTicketsKey = "githubTickets"
    static let gitlabTicketsKey = "gitlabTickets"
    /// The Settings pane, so other windows can open Settings at a pane.
    static let settingsPaneKey = "settingsPane"

    static let defaultEditor = EditorPreset.cursor
    static let fontSizes: ClosedRange<Double> = 9...20

    /// The chosen terminal, else the first installed of Ghostty, iTerm and Terminal.
    static func terminal(_ defaults: UserDefaults = .standard) -> TerminalApp {
        if let saved = defaults.string(forKey: terminalKey).flatMap(TerminalApp.init(rawValue:)) { return saved }
        return [TerminalApp.ghostty, .iterm].first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil } ?? .terminal
    }

    static func aiProvider(_ defaults: UserDefaults = .standard) -> AIProvider {
        defaults.string(forKey: aiProviderKey).flatMap(AIProvider.init(rawValue:)) ?? .claude
    }

    static func suggestionProvider(_ defaults: UserDefaults = .standard) -> AIProvider? {
        defaults.string(forKey: suggestionProviderKey).flatMap(AIProvider.init(rawValue:))
    }

    static func commitTemplate(_ defaults: UserDefaults = .standard) -> String {
        template(commitTemplateKey, default: PromptTemplate.defaultCommit, defaults)
    }

    static func pullRequestTemplate(_ defaults: UserDefaults = .standard) -> String {
        template(pullRequestTemplateKey, default: PromptTemplate.defaultPullRequest, defaults)
    }

    private static func template(_ key: String, default template: String, _ defaults: UserDefaults) -> String {
        let saved = defaults.string(forKey: key) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? template : saved
    }

    /// The suggester for the chosen provider; `nil` when suggestions are off.
    static func suggester(toolchain: Toolchain, _ defaults: UserDefaults = .standard) -> Suggester? {
        suggestionProvider(defaults).map {
            Suggester(provider: $0, model: defaults.string(forKey: suggestionModelKey) ?? "", toolchain: toolchain)
        }
    }

    /// How many ticket trackers are connected, for the Tickets item in Settings.
    static func connectedTicketTrackers(_ defaults: UserDefaults = .standard) -> Int {
        var count = 0
        if Keychain.read(.linear).map({ !$0.isEmpty }) == true { count += 1 }
        if Keychain.read(.jira).map({ !$0.isEmpty }) == true, defaults.string(forKey: jiraSiteKey)?.isEmpty == false { count += 1 }
        if defaults.bool(forKey: githubTicketsKey) { count += 1 }
        if defaults.bool(forKey: gitlabTicketsKey) { count += 1 }
        return count
    }

    /// The connected ticket trackers, Linear and Jira first.
    static func ticketResolver(root: URL, toolchain: Toolchain, _ defaults: UserDefaults = .standard) -> TicketResolver {
        var providers: [any TicketProvider] = []
        if let key = Keychain.read(.linear), !key.isEmpty {
            providers.append(LinearTickets(apiKey: key))
        }
        if let site = JiraTickets.siteURL(defaults.string(forKey: jiraSiteKey) ?? ""),
           let email = defaults.string(forKey: jiraEmailKey), !email.isEmpty,
           let token = Keychain.read(.jira), !token.isEmpty {
            providers.append(JiraTickets(site: site, email: email, token: token))
        }
        if defaults.bool(forKey: githubTicketsKey) { providers.append(ForgeTickets(source: .github, root: root, toolchain: toolchain)) }
        if defaults.bool(forKey: gitlabTicketsKey) { providers.append(ForgeTickets(source: .gitlab, root: root, toolchain: toolchain)) }
        return TicketResolver(providers: providers)
    }

    /// Titles for the actions that leave the app: they start the provider in the chosen terminal rather than
    /// answering in ohmydiff.
    static func openClaudeCodeTitle(_ defaults: UserDefaults = .standard) -> String {
        "Open \(aiProvider(defaults).displayName) in \(terminal(defaults).displayName)"
    }

    static func openClaudeCodeNote(scope: String, _ defaults: UserDefaults = .standard) -> String {
        "Starts \(aiProvider(defaults).executable) in a new \(terminal(defaults).displayName) window with the \(scope.lowercased())"
    }

    static func askTitle(_ defaults: UserDefaults = .standard) -> String {
        "Ask \(aiProvider(defaults).displayName)"
    }

    static func copyPromptTitle(_ defaults: UserDefaults = .standard) -> String {
        "Copy Prompt for \(aiProvider(defaults).displayName)"
    }

    /// The command template for the chosen editor; `nil` when a custom command is chosen but empty.
    static func editorTemplate(_ defaults: UserDefaults = .standard) -> String? {
        let preset = defaults.string(forKey: editorKey).flatMap(EditorPreset.init(rawValue:)) ?? defaultEditor
        if let template = preset.template { return template }
        let custom = defaults.string(forKey: customEditorCommandKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? nil : custom
    }
}

/// Light, dark or following the system.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applies to every window, including Settings and diff windows.
    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The file shown in the focused diff, published for the Open in Editor and Copy File Path commands.
struct DiffFileTarget: Equatable {
    /// Absolute path in the working tree.
    var url: URL
    /// Path relative to the repository root.
    var relativePath: String
    /// The line the diff selection points at.
    var line: Int?

    /// Deleted files and paths that only exist in history cannot be opened.
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Lines of the focused diff to ask Claude Code about: the selection, else the hunk at the top.
///
/// Plain data rather than a closure, so publishing it as a focused value only updates menus when it changes.
struct DiffPromptTarget: Equatable {
    /// The repository root, where Claude Code starts.
    var root: URL
    var context: PromptContext
    var diff: FileDiff
    /// The selected lines; empty to ask about `hunk`.
    var selection: [DiffPosition]
    var hunk: Int

    /// "Selection" or "Hunk", for menu titles.
    var scope: String { selection.isEmpty ? "Hunk" : "Selection" }

    func prompt(_ question: PromptQuestion) -> String {
        let positions = selection.isEmpty && diff.hunks.indices.contains(hunk)
            ? diff.hunks[hunk].lines.indices.map { DiffPosition(hunk: hunk, line: $0) }
            : selection
        return ClaudePrompt.make(question: question, context: context, diff: diff, positions: positions)
    }
}

/// The hunk the diff is at, for the launcher: what it is and what can be done with it.
struct DiffHunkContext {
    var path: String
    var index: Int
    var hunk: Hunk
    var count: Int
    var actions: [ChangeAction]
    var perform: (ChangeAction) -> Void
    /// `nil` when the diff cannot be explained, e.g. in a diff window.
    var explain: (() -> Void)?

    var fileName: String { (path as NSString).lastPathComponent }
}

extension FocusedValues {
    @Entry var diffFile: DiffFileTarget?
    @Entry var diffPrompt: DiffPromptTarget?
    @Entry var diffHunk: DiffHunkContext?
}

/// Copies a prompt or starts Claude Code with it; set on each window's root view.
struct ClaudeCodeActions {
    var open: (_ prompt: String, _ root: URL) -> Void = { _, _ in }
    var copy: (_ prompt: String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var claudeCode = ClaudeCodeActions()
    /// Opens a file at its line in the editor chosen in Settings.
    @Entry var openEditor: (DiffFileTarget) -> Void = { _ in }
}
