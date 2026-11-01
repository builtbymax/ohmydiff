import AppKit
import SwiftUI

/// A key with its modifiers, as recorded in Settings → Shortcuts.
struct Shortcut: Hashable, Codable {
    /// A lowercased character, or a named key: `delete`, `up`, `down`, `left`, `right`, `return`, `tab`, `space`.
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    var hasModifier: Bool { command || option || control }

    var modifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "delete": .delete
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        case "return": .return
        case "tab": .tab
        case "space": .space
        default: KeyEquivalent(Character(key))
        }
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: modifiers) }

    /// `⇧⌘P`, `⌫`, `n`.
    var label: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        let name: String = switch key {
        case "delete": "⌫"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "return": "↩"
        case "tab": "⇥"
        case "space": "Space"
        default: text.isEmpty ? key : key.uppercased()
        }
        return text + name
    }

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// `⌘K` style shorthand for the defaults.
    init(_ key: String, _ modifiers: EventModifiers = []) {
        self.init(
            key: key, command: modifiers.contains(.command), shift: modifiers.contains(.shift), option: modifiers.contains(.option),
            control: modifiers.contains(.control))
    }

    /// A key press, or `nil` for keys that cannot be a shortcut, e.g. a modifier alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String? = switch event.keyCode {
        case 51, 117: "delete"
        case 126: "up"
        case 125: "down"
        case 123: "left"
        case 124: "right"
        case 36, 76: "return"
        case 48: "tab"
        case 49: "space"
        default: event.charactersIgnoringModifiers?.lowercased().first.map(String.init)
        }
        guard let key, !key.isEmpty, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) || key.count > 1 else { return nil }
        self.init(
            key: key, command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option),
            control: flags.contains(.control))
    }
}

/// Everything with a key, in the groups of Settings → Shortcuts.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // Move around
    case launcher, switchProject, nextHunk, previousHunk, changes, branches, pullRequests, history, refresh
    // Review
    case stageHunk, unstageHunk, discardHunk, explainHunk, splitDiff, fullFile, whitespace, openInEditor, openDiffWindow,
         copyPath, copyPrompt, explainInClaude
    // Branches & PRs
    case newBranch, fetch, updateWorkspace, addProject
    // Window
    case toggleFileList, focusDiff, toggleSidebar, inspector, activity, theme

    var id: Self { self }

    enum Group: String, CaseIterable {
        case moveAround = "Move around"
        case review = "Review"
        case branches = "Branches & PRs"
        case window = "Window"
    }

    var group: Group {
        switch self {
        case .launcher, .switchProject, .nextHunk, .previousHunk, .changes, .branches, .pullRequests, .history, .refresh: .moveAround
        case .stageHunk, .unstageHunk, .discardHunk, .explainHunk, .splitDiff, .fullFile, .whitespace, .openInEditor, .openDiffWindow,
             .copyPath, .copyPrompt, .explainInClaude: .review
        case .newBranch, .fetch, .updateWorkspace, .addProject: .branches
        case .toggleFileList, .focusDiff, .toggleSidebar, .inspector, .activity, .theme: .window
        }
    }

    var title: String {
        switch self {
        case .launcher: "Command launcher"
        case .switchProject: "Switch project"
        case .nextHunk: "Next hunk"
        case .previousHunk: "Previous hunk"
        case .changes: "Changes"
        case .branches: "Branches"
        case .pullRequests: "Pull requests"
        case .history: "History"
        case .refresh: "Refresh"
        case .stageHunk: "Commit or stage hunk"
        case .unstageHunk: "Unstage hunk"
        case .discardHunk: "Discard hunk"
        case .explainHunk: "Explain hunk"
        case .splitDiff: "Split / Unified"
        case .fullFile: "Changes / Full file"
        case .whitespace: "Whitespace changes"
        case .openInEditor: "Open in editor"
        case .openDiffWindow: "Open diff in new window"
        case .copyPath: "Copy file path"
        case .copyPrompt: "Copy prompt"
        case .explainInClaude: "Explain in Claude Code"
        case .newBranch: "New branch"
        case .fetch: "Fetch"
        case .updateWorkspace: "Update from remote"
        case .addProject: "Add project"
        case .toggleFileList: "Hide file list"
        case .focusDiff: "Focus diff"
        case .toggleSidebar: "Toggle sidebar"
        case .inspector: "Inspector"
        case .activity: "Activity"
        case .theme: "Theme"
        }
    }

    /// Keys the diff handles itself while it has focus; these may be single letters.
    var isDiffKey: Bool {
        [.nextHunk, .previousHunk, .stageHunk, .unstageHunk, .discardHunk, .explainHunk].contains(self)
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .launcher: Shortcut("k", .command)
        case .switchProject: Shortcut("p", .command)
        case .nextHunk: Shortcut("n")
        case .previousHunk: Shortcut("p")
        case .changes: Shortcut("1", .command)
        case .branches: Shortcut("2", .command)
        case .pullRequests: Shortcut("3", .command)
        case .history: Shortcut("4", .command)
        case .refresh: Shortcut("r", .command)
        case .stageHunk: Shortcut("s")
        case .unstageHunk: Shortcut("u")
        case .discardHunk: Shortcut("delete")
        case .explainHunk: Shortcut("e")
        case .splitDiff: Shortcut("\\", .command)
        case .fullFile: Shortcut("f", [.command, .option])
        case .whitespace: Shortcut("w", [.command, .option])
        case .openInEditor: Shortcut("o", .command)
        case .openDiffWindow: Shortcut("o", [.command, .option])
        case .copyPath: Shortcut("c", [.command, .shift])
        case .copyPrompt: Shortcut("c", [.command, .shift, .option])
        case .explainInClaude: Shortcut("e", [.command, .option])
        case .newBranch: Shortcut("b", .command)
        case .fetch: Shortcut("f", [.command, .shift])
        case .updateWorkspace: Shortcut("u", [.command, .shift])
        case .addProject: Shortcut("o", [.command, .shift])
        case .toggleFileList: Shortcut("0", .command)
        case .focusDiff: Shortcut(".", .command)
        case .toggleSidebar: Shortcut("s", [.command, .control])
        case .inspector: Shortcut("i", [.command, .option])
        case .activity: nil
        case .theme: Shortcut("t", [.command, .option])
        }
    }
}

/// The user's keys: the defaults with their changes, stored as JSON in `shortcutsKey`.
enum Shortcuts {
    static let key = "shortcuts"
    /// Keys the system or fixed menu items own, so recording refuses them.
    static let reserved: [Shortcut: String] = [
        Shortcut(",", .command): "Settings",
        Shortcut("q", .command): "Quit",
        Shortcut("w", .command): "Close window",
        Shortcut("h", .command): "Hide",
        Shortcut("z", .command): "Undo",
        Shortcut("c", .command): "Copy",
        Shortcut("v", .command): "Paste",
        Shortcut("x", .command): "Cut",
        Shortcut("a", .command): "Select all",
    ]

    /// Changed actions, a `nil` value for one the user cleared.
    static func overrides(_ defaults: UserDefaults = .standard) -> [ShortcutAction: Shortcut?] {
        guard let data = defaults.string(forKey: key)?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Shortcut?].self, from: data)
        else { return [:] }
        var result: [ShortcutAction: Shortcut?] = [:]
        for (name, shortcut) in decoded {
            if let action = ShortcutAction(rawValue: name) { result[action] = shortcut }
        }
        return result
    }

    static func shortcut(_ action: ShortcutAction, _ defaults: UserDefaults = .standard) -> Shortcut? {
        if let changed = overrides(defaults)[action] { return changed }
        return action.defaultShortcut
    }

    static func keyboardShortcut(_ action: ShortcutAction, _ defaults: UserDefaults = .standard) -> KeyboardShortcut? {
        shortcut(action, defaults)?.keyboardShortcut
    }

    static func label(_ action: ShortcutAction) -> String { shortcut(action)?.label ?? "" }

    static func set(_ shortcut: Shortcut?, for action: ShortcutAction, _ defaults: UserDefaults = .standard) {
        var changed = overrides(defaults)
        if shortcut == action.defaultShortcut { changed[action] = nil } else { changed[action] = .some(shortcut) }
        save(changed, defaults)
    }

    static func reset(_ action: ShortcutAction? = nil, _ defaults: UserDefaults = .standard) {
        guard let action else { return save([:], defaults) }
        var changed = overrides(defaults)
        changed[action] = nil
        save(changed, defaults)
    }

    private static func save(_ changed: [ShortcutAction: Shortcut?], _ defaults: UserDefaults) {
        let encoded = Dictionary(uniqueKeysWithValues: changed.map { ($0.key.rawValue, $0.value) })
        if encoded.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(encoded), let text = String(data: data, encoding: .utf8) {
            defaults.set(text, forKey: key)
        }
    }

    /// What already uses a shortcut: another action, or a fixed key.
    static func owner(of shortcut: Shortcut, except action: ShortcutAction) -> String? {
        if let reserved = reserved[shortcut] { return reserved }
        // Diff keys only clash with diff keys, menu keys with menu keys.
        return ShortcutAction.allCases.first { other in
            other != action && other.isDiffKey == action.isDiffKey && self.shortcut(other) == shortcut
        }?.title
    }

    /// The diff key action an event triggers, if any.
    static func diffAction(for event: NSEvent) -> ShortcutAction? {
        guard let pressed = Shortcut(event: event) else { return nil }
        return ShortcutAction.allCases.first { $0.isDiffKey && shortcut($0) == pressed }
    }
}
