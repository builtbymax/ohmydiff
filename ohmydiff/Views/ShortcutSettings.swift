import AppKit
import SwiftUI

/// Settings → Shortcuts: every action with its key, recorded by clicking it, with clashes named.
struct ShortcutSettings: View {
    /// Re-read on every change, so rows and the Changed count follow.
    @AppStorage(Shortcuts.key) private var stored = ""
    @State private var search = ""
    @State private var showsChanged = false
    @State private var recording: ShortcutAction?

    var body: some View {
        let _ = stored
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                SettingsInput(placeholder: "Search actions or keys", text: $search, trailingImage: "magnifyingglass")
                    .frame(width: 232)
                Segmented(
                    selection: $showsChanged, options: [(false, "All"), (true, "Changed")],
                    counts: [false: "\(ShortcutAction.allCases.count)", true: "\(Shortcuts.overrides().count)"])
                Spacer(minLength: 8)
                Button {
                    Shortcuts.reset()
                    recording = nil
                } label: {
                    Label("Reset all", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.pill(.ghost))
                .disabled(Shortcuts.overrides().isEmpty)
            }
            ForEach([ShortcutAction.Group.moveAround, .review, .branches, .window], id: \.self) { group in
                let actions = visible(in: group)
                if !actions.isEmpty {
                    SettingsSection(title: group.rawValue) {
                        SettingsTable {
                            ForEach(actions) { action in
                                ShortcutRow(action: action, recording: $recording)
                            }
                        }
                    }
                }
            }
            Text("Project 1–9 (⌃1–⌃9), workspaces (⌃⌘1–⌃⌘9) and Settings (⌘,) keep their keys.")
                .font(.detail)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func visible(in group: ShortcutAction.Group) -> [ShortcutAction] {
        let changed = Shortcuts.overrides()
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return ShortcutAction.allCases.filter { action in
            guard action.group == group else { return false }
            if showsChanged, changed[action] == nil { return false }
            guard !query.isEmpty else { return true }
            return action.title.lowercased().contains(query) || Shortcuts.label(action).lowercased().contains(query)
        }
    }
}

/// One action in the settings row style: its title, and its key in a field that records a new one when clicked;
/// a changed key can be reset beside it.
private struct ShortcutRow: View {
    let action: ShortcutAction
    @Binding var recording: ShortcutAction?

    @State private var clash: (shortcut: Shortcut, owner: String)?
    @State private var monitor: Any?

    private var isRecording: Bool { recording == action }

    var body: some View {
        let isChanged = Shortcuts.overrides()[action] != nil
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.row)
                    .foregroundStyle(Theme.textPrimary)
                if isRecording {
                    Text(hint)
                        .font(.detail)
                        .foregroundStyle(clash == nil ? Theme.textTertiary : Theme.warnFg)
                        .lineLimit(1)
                } else if isChanged {
                    Text("Changed from \(action.defaultShortcut?.label ?? "none")")
                        .font(.detail)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isChanged, !isRecording {
                IconButton("Reset to \(action.defaultShortcut?.label ?? "None")", systemImage: "arrow.uturn.backward", size: 24) {
                    Shortcuts.reset(action)
                }
            }
            ShortcutField(label: Shortcuts.shortcut(action)?.label, isRecording: isRecording) {
                recording = isRecording ? nil : action
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: isRecording || isChanged ? 56 : 46)
        .contextMenu {
            Button("Record New Key") { recording = action }
            Button("Remove Key") { Shortcuts.set(nil, for: action) }
            Button("Reset to \(action.defaultShortcut?.label ?? "None")") { Shortcuts.reset(action) }
                .disabled(Shortcuts.overrides()[action] == nil)
        }
        .onChange(of: isRecording, initial: true) { _, isRecording in
            isRecording ? startRecording() : stopRecording()
        }
        .onDisappear(perform: stopRecording)
    }

    /// `⌘B is taken by New branch — press another`, or what kind of key fits.
    private var hint: String {
        if let clash { return "\(clash.shortcut.label) is taken by \(clash.owner) — press another" }
        return action.isDiffKey ? "Any key, single letters work while the diff has focus · esc cancels" : "Use ⌘, ⌥ or ⌃ with a key · esc cancels · ⌫ removes"
    }

    /// Catches the next key press in the Settings window while recording.
    private func startRecording() {
        stopRecording()
        clash = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        clash = nil
    }

    /// Whether the key press was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording == action else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 53, flags.isEmpty {
            recording = nil
            return true
        }
        guard let shortcut = Shortcut(event: event) else { return true }
        // Menu keys need a modifier; a bare ⌫ removes the key instead.
        if !action.isDiffKey, !shortcut.hasModifier {
            if shortcut.key == "delete" {
                Shortcuts.set(nil, for: action)
                recording = nil
            } else {
                NSSound.beep()
            }
            return true
        }
        if let owner = Shortcuts.owner(of: shortcut, except: action) {
            clash = (shortcut, owner)
            return true
        }
        Shortcuts.set(shortcut, for: action)
        recording = nil
        return true
    }
}

/// The key of an action as an editable field: its key cap and a pencil, `Add key` when it has none, and
/// `Press keys…` while recording.
private struct ShortcutField: View {
    let label: String?
    let isRecording: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isRecording {
                    Text("Press keys…")
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                } else if let label {
                    KeyCap(label)
                } else {
                    Text("Add key")
                        .font(.control)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: isRecording ? "record.circle" : "pencil")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isRecording ? Theme.infoFg : isHovered ? Theme.textSecondary : Theme.textTertiary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(width: 128, height: 28)
            .background(isHovered && !isRecording ? Theme.hover : Theme.canvas, in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isRecording ? Theme.infoFg : isHovered ? Theme.lineStrong : Theme.line))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .help(isRecording ? "Press the new keys, or esc to cancel" : "Click to record a new key")
    }
}
