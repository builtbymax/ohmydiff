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
    /// `rebase`, `squash` or `merge`, for pull requests merged from ohmydiff.
    static let mergeMethodKey = "mergeMethod"
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
    /// The Branches page's layout, cards or columns beside the diff, and the width of its files column.
    static let branchesLayoutKey = "branchesLayout"
    static let branchListWidthKey = "branchFilesWidth"
    static let branchFilesWidths: ClosedRange<Double> = 200...400
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
    /// General.
    static let reopensLastProjectKey = "reopensLastProject"
    static let groupsWorkspacesKey = "groupsWorkspaces"
    static let controlSwitchesProjectsKey = "controlSwitchesProjects"
    static let watchesFilesKey = "watchesFiles"
    /// Minutes between background fetches; 0 for never.
    static let fetchIntervalKey = "fetchIntervalMinutes"
    static let discardConfirmationKey = "discardConfirmation"
    static let confirmsForcePushKey = "confirmsForcePush"
    /// Appearance.
    static let lineHeightKey = "diffLineHeight"
    static let densityKey = "density"
    static let reducesMotionKey = "reducesMotion"
    static let usesOpusSyntaxKey = "usesOpusSyntax"
    /// AI: what is sent besides the selected diff, and whether Explain hands off to a terminal.
    static let aiSendsCommitsKey = "aiSendsCommits"
    static let aiSendsTicketKey = "aiSendsTicket"
    static let explainsInTerminalKey = "explainsInTerminal"
    /// Commit format, checked before committing and followed by the AI.
    static let commitStyleKey = "commitStyle"
    static let titleLimitKey = "commitTitleLimit"
    static let addsTicketToTitleKey = "addsTicketToTitle"
    /// When an agent last connected to `ohmydiff mcp`, and which one.
    static let mcpLastUsedKey = "mcpLastUsed"
    static let mcpLastClientKey = "mcpLastClient"
    /// Tickets.
    static let linearTeamKey = "linearTeam"
    static let ticketPatternKey = "ticketPattern"
    /// The Settings pane, so other windows can open Settings at a pane.
    static let settingsPaneKey = "settingsPane"

    static let defaultEditor = EditorPreset.cursor

    /// A Bool setting that is on unless turned off.
    static func isOn(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func fetchInterval(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: fetchIntervalKey) as? Int ?? 10
    }

    static func discardConfirmation(_ defaults: UserDefaults = .standard) -> DiscardConfirmation {
        defaults.string(forKey: discardConfirmationKey).flatMap(DiscardConfirmation.init(rawValue:)) ?? .filesAndHunks
    }

    static func ticketPattern(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: ticketPatternKey) ?? "{type}/{ticket}-{words}"
    }

    static func titleLimit(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: titleLimitKey) as? Int ?? 72
    }

    static func commitStyle(_ defaults: UserDefaults = .standard) -> CommitStyle {
        defaults.string(forKey: commitStyleKey).flatMap(CommitStyle.init(rawValue:)) ?? .conventional
    }

    /// The model a task runs with; empty for the provider's default. Falls back to the one model of earlier versions.
    static func model(for task: AITask, _ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: task.modelKey) ?? defaults.string(forKey: suggestionModelKey) ?? ""
    }

    static func isEnabled(_ task: AITask, _ defaults: UserDefaults = .standard) -> Bool {
        isOn(task.enabledKey, defaults)
    }

    /// Whether a task runs on Apple's on-device model rather than the CLI provider; off unless chosen.
    static func runsOnDevice(_ task: AITask, _ defaults: UserDefaults = .standard) -> Bool {
        task.supportsOnDevice && defaults.bool(forKey: task.onDeviceKey)
    }

    /// What a task runs with, e.g. `Apple Intelligence` or `Claude Code · haiku`; `nil` when nothing is chosen.
    static func runnerTitle(for task: AITask, _ defaults: UserDefaults = .standard) -> String? {
        if runsOnDevice(task, defaults) { return "Apple Intelligence" }
        guard let provider = suggestionProvider(defaults) else { return nil }
        let model = model(for: task, defaults)
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }
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
    /// The suggester for a task, or `nil` when no provider is chosen or the task is turned off.
    static func suggester(for task: AITask, toolchain: Toolchain, _ defaults: UserDefaults = .standard) -> Suggester? {
        guard isEnabled(task, defaults), let provider = suggestionProvider(defaults) else { return nil }
        return Suggester(provider: provider, model: model(for: task, defaults), toolchain: toolchain)
    }

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
            providers.append(LinearTickets(apiKey: key, team: defaults.string(forKey: linearTeamKey) ?? ""))
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

/// When a discard asks first.
nonisolated enum DiscardConfirmation: String, CaseIterable, Identifiable, Sendable {
    case filesAndHunks, filesOnly, never

    var id: Self { self }

    var title: String {
        switch self {
        case .filesAndHunks: "Files and hunks"
        case .filesOnly: "Files only"
        case .never: "Never"
        }
    }
}

/// How commit messages are written: freely, as Conventional Commits, or with a gitmoji.
nonisolated enum CommitStyle: String, CaseIterable, Identifiable, Sendable {
    case free, conventional, gitmoji

    var id: Self { self }

    var title: String {
        switch self {
        case .free: "Free"
        case .conventional: "Conventional"
        case .gitmoji: "Gitmoji"
        }
    }

    /// What the AI is told about the style.
    var instruction: String? {
        switch self {
        case .free: nil
        case .conventional: "Write the title as a Conventional Commit: `type(scope): title`."
        case .gitmoji: "Start the title with the gitmoji that fits the change."
        }
    }

    /// An emoji first, also one that is text by default and made an emoji by U+FE0F, e.g. ♻️.
    private static func startsWithEmoji(_ title: String) -> Bool {
        let scalars = Array(title.unicodeScalars.prefix(2))
        guard let first = scalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && scalars.dropFirst().first == "\u{FE0F}")
    }

    /// Why a title does not follow the style; `nil` when it does.
    func problem(with title: String) -> String? {
        switch self {
        case .free: nil
        case .conventional:
            title.firstMatch(of: /^[a-z]+(\([^)]+\))?!?: \S/) == nil ? "Not a Conventional Commit: type(scope): title" : nil
        case .gitmoji:
            Self.startsWithEmoji(title) || title.hasPrefix(":") ? nil : "Starts without a gitmoji"
        }
    }
}

/// The AI's jobs, each with its own model and switch in Settings.
nonisolated enum AITask: String, CaseIterable, Identifiable, Sendable {
    case commitMessage, branchName, pullRequest, explain, review

    var id: Self { self }
    var modelKey: String { "aiModel.\(rawValue)" }
    var enabledKey: String { "aiEnabled.\(rawValue)" }
    var onDeviceKey: String { "aiOnDevice.\(rawValue)" }

    /// Small enough for Apple's on-device model.
    var supportsOnDevice: Bool { self == .commitMessage || self == .branchName }

    var title: String {
        switch self {
        case .commitMessage: "Commit messages"
        case .branchName: "Branch names"
        case .pullRequest: "Pull request drafts"
        case .explain: "Explain & ask about hunks"
        case .review: "Review for bugs"
        }
    }

    var detail: String {
        switch self {
        case .commitMessage: "From the changes you selected · ✦ in the composer"
        case .branchName: "Suggested when you commit to a new branch"
        case .pullRequest: "From commits, diff, linked ticket and your PR template"
        case .explain: "Answers inline under the hunk; follow-ups stay in that card"
        case .review: "Findings show on their lines; advisory, nothing is changed"
        }
    }

    var systemImage: String {
        switch self {
        case .commitMessage: "circle.and.line.horizontal"
        case .branchName: "arrow.triangle.branch"
        case .pullRequest: "arrow.triangle.pull"
        case .explain: "bubble.left"
        case .review: "checklist"
        }
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
    /// Asks the AI provider for a one-off answer for a task, with its model from Settings.
    @Entry var askAI: (AITask, String) async throws -> String = { _, _ in throw SuggestionUnavailable.noProvider }
    /// The project's review findings, shown under their lines; `nil` where diffs show none, e.g. a diff window.
    @Entry var reviewFindings: ReviewFindings?
}


extension MergeMethod {
    /// How pull requests merge from the Branches page and Merge when green: rebase unless changed.
    static var preferred: MergeMethod {
        UserDefaults.standard.string(forKey: AppSettings.mergeMethodKey).flatMap(MergeMethod.init(rawValue:)) ?? .rebase
    }
}
