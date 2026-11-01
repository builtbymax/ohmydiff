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
        VStack(alignment: .leading, spacing: 18) {
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
            HStack(alignment: .top, spacing: 12) {
                column([.moveAround, .review])
                column([.branches, .window])
            }
            Text("Project 1–9 (⌃1–⌃9), workspaces (⌃⌘1–⌃⌘9) and Settings (⌘,) keep their keys.")
                .font(.detail)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func column(_ groups: [ShortcutAction.Group]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.self) { group in
                let actions = visible(in: group)
                if !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.rawValue)
                            .font(.sectionLabel)
                            .foregroundStyle(Theme.textTertiary)
                        SettingsTable(background: Theme.surface) {
                            ForEach(actions) { action in
                                ShortcutRow(action: action, recording: $recording)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
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

/// One action: its title, a dot when changed, and its key; clicking records a new one.
private struct ShortcutRow: View {
    let action: ShortcutAction
    @Binding var recording: ShortcutAction?

    @State private var clash: (shortcut: Shortcut, owner: String)?
    @State private var monitor: Any?

    private var isRecording: Bool { recording == action }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(isRecording ? .row.weight(.medium) : .row)
                    .foregroundStyle(Theme.textPrimary)
                if isRecording {
                    Text(hint)
                        .font(.caption11)
                        .foregroundStyle(clash == nil ? Theme.textTertiary : Theme.warnFg)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if Shortcuts.overrides()[action] != nil, !isRecording {
                Circle().fill(Theme.infoFg).frame(width: 5, height: 5)
                    .help("Changed from \(action.defaultShortcut?.label ?? "none")")
            }
            if isRecording {
                Text("Press keys…")
                    .font(.control.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.raised, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.infoFg))
            } else if let shortcut = Shortcuts.shortcut(action) {
                KeyCap(shortcut.label)
            } else {
                Text("None")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: isRecording ? 46 : 28)
        .background(isRecording ? Theme.infoBg : .clear)
        .contentShape(.rect)
        .onTapGesture { recording = isRecording ? nil : action }
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
