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
    /// The terminal Claude Code is started in.
    static let terminalKey = "terminalApp"

    static let defaultEditor = EditorPreset.cursor
    static let fontSizes: ClosedRange<Double> = 9...20

    /// The chosen terminal, else the first installed of Ghostty, iTerm and Terminal.
    static func terminal(_ defaults: UserDefaults = .standard) -> TerminalApp {
        if let saved = defaults.string(forKey: terminalKey).flatMap(TerminalApp.init(rawValue:)) { return saved }
        return [TerminalApp.ghostty, .iterm].first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil } ?? .terminal
    }

    /// Titles for the actions that leave the app: they start `claude` in the chosen terminal rather than
    /// answering in ohmydiff.
    static func openClaudeCodeTitle(_ defaults: UserDefaults = .standard) -> String {
        "Open Claude Code in \(terminal(defaults).displayName)"
    }

    static func openClaudeCodeNote(scope: String, _ defaults: UserDefaults = .standard) -> String {
        "Starts claude in a new \(terminal(defaults).displayName) window with the \(scope.lowercased())"
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
struct DiffPromptTarget {
    /// The repository root, where Claude Code starts.
    var root: URL
    /// "Selection" or "Hunk", for menu titles.
    var scope: String
    var prompt: (PromptQuestion) -> String
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
