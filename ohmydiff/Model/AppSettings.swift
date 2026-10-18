import AppKit
import OhMyDiffCore
import SwiftUI

/// `UserDefaults` keys and defaults for the Settings window.
enum AppSettings {
    static let editorKey = "editorPreset"
    static let customEditorCommandKey = "customEditorCommand"
    static let fontSizeKey = "diffFontSize"
    static let appearanceKey = "appearance"
    /// Width of the file list column, and whether it is hidden to give the diff the whole panel.
    static let listWidthKey = "listWidth"
    static let isListHiddenKey = "isListHidden"
    static let listWidths: ClosedRange<Double> = 240...560
    /// Width of the file list beside a commit's or branch's diff in History mode.
    static let historyFilesWidthKey = "historyFilesWidth"
    static let historyFilesWidths: ClosedRange<Double> = 200...420
    /// The terminal the AI provider is started in, and which provider.
    static let terminalKey = "terminalApp"
    static let aiProviderKey = "aiProvider"

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

extension FocusedValues {
    @Entry var diffFile: DiffFileTarget?
    @Entry var diffPrompt: DiffPromptTarget?
}

/// Copies a prompt or starts Claude Code with it; set on each window's root view.
struct ClaudeCodeActions {
    var open: (_ prompt: String, _ root: URL) -> Void = { _, _ in }
    var copy: (_ prompt: String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var claudeCode = ClaudeCodeActions()
}
