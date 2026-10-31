import AppKit
import SwiftUI

/// Short notes after something the user did, e.g. a commit or a push, at the top right of the panel. Each
/// can carry one action, usually Undo, and goes away by itself.
@MainActor @Observable
final class Toasts {
    static let shared = Toasts()

    struct Toast: Identifiable {
        struct Action {
            var title: String
            /// Shown as a key cap and caught while the toast is the newest, e.g. ⌘Z for Undo.
            var shortcut: Shortcut?
            var run: () -> Void
        }

        let id = UUID()
        var systemImage: String
        var tint: Color
        var message: String
        var action: Action?
    }

    /// Newest first.
    private(set) var items: [Toast] = []

    /// How long a toast stays.
    static let lifetime: Duration = .seconds(6)

    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    /// Runs the newest toast's action for its key, unless a text field has focus: there ⌘Z undoes typing.
    private func handle(_ event: NSEvent) -> Bool {
        guard let toast = items.first, let action = toast.action, let shortcut = action.shortcut,
              Shortcut(event: event) == shortcut, !(event.window?.firstResponder is NSText)
        else { return false }
        action.run()
        dismiss(toast.id)
        return true
    }

    func show(_ message: String, systemImage: String, tint: Color = Theme.textSecondary, action: Toast.Action? = nil) {
        let toast = Toast(systemImage: systemImage, tint: tint, message: message, action: action)
        ActivityLog.shared.record(message)
        items.insert(toast, at: 0)
        if items.count > 3 { items.removeLast(items.count - 3) }
        Task { [id = toast.id] in
            try? await Task.sleep(for: Self.lifetime)
            dismiss(id)
        }
    }

    func dismiss(_ id: Toast.ID) {
        items.removeAll { $0.id == id }
    }

    /// An Undo action on ⌘Z.
    static func undo(_ run: @escaping () -> Void) -> Toast.Action {
        Toast.Action(title: "Undo", shortcut: Shortcut("z", .command), run: run)
    }
}

/// The toasts, stacked newest first at the top right.
struct ToastStack: View {
    let toasts: Toasts

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(toasts.items) { toast in
                ToastView(toast: toast, isNewest: toast.id == toasts.items.first?.id) { toasts.dismiss(toast.id) }
                    .popoverTransition(anchor: .topTrailing)
            }
        }
        .animation(Theme.popoverAnimation, value: toasts.items.map(\.id))
    }
}

private struct ToastView: View {
    let toast: Toasts.Toast
    let isNewest: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(toast.tint)
                .frame(width: 14, height: 14)
            Text(toast.message)
                .font(.control)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let action = toast.action {
                Button {
                    action.run()
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Text(action.title)
                        if isNewest, let shortcut = action.shortcut {
                            KeyCap(shortcut.label)
                        }
                    }
                }
                .buttonStyle(.pill(.ghost, height: 26))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, toast.action == nil ? 12 : 8)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .popoverSurface(in: .rect(cornerRadius: 12))
        .onTapGesture(perform: dismiss)
    }
}

extension KeyboardShortcut {
    /// e.g. `⌘Z`.
    var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .return: return text + "↩"
        case .escape: return text + "esc"
        default: return text + String(key.character).uppercased()
        }
    }
}
