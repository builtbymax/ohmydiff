import OhMyDiffCore
import SwiftUI

/// Context menu items for files or a whole group; only the actions every target supports appear.
struct ChangeActionMenu: View {
    let session: ProjectSession
    let targets: [ChangeTarget]
    /// Group menus offer no discard, so a whole section is never thrown away by one click.
    let isGroup: Bool

    var body: some View {
        let suffix = isGroup ? " All" : ""
        if session.supports(.stage, on: targets) {
            Button("Stage\(suffix)") { session.request(.stage, on: targets) }
        }
        if session.supports(.unstage, on: targets) {
            Button("Unstage\(suffix)") { session.request(.unstage, on: targets) }
        }
        if session.supports(.commit, on: targets) {
            Button(session.project.kind == .gitButler ? "Commit\(suffix) to Branch…" : "Commit\(suffix)…") { session.request(.commit, on: targets) }
        }
        if !isGroup, session.supports(.discard, on: targets) {
            Divider()
            Button("Discard Changes…", role: .destructive) { session.request(.discard, on: targets) }
        }
    }
}

extension View {
    /// Action errors for a project; the discard and commit cards show over the page.
    func changeActionPresentation(_ session: ProjectSession) -> some View {
        modifier(ChangeActionPresentation(session: session))
    }
}

private struct ChangeActionPresentation: ViewModifier {
    @Bindable var session: ProjectSession

    func body(content: Content) -> some View {
        content
            .alert(
                "Action Failed",
                isPresented: Binding(get: { session.actionError != nil }, set: { if !$0 { session.actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.actionError ?? "")
            }
    }
}

/// The discard confirmation: a small card over the diff, never a modal. It names what goes and how to get
/// it back.
struct DiscardConfirmCard: View {
    let session: ProjectSession
    let request: ProjectSession.ActionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Discard \(session.toastSubject(request.targets))?")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.control)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    session.actionRequest = nil
                } label: {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyCap("esc")
                    }
                }
                .buttonStyle(.pill(.ghost))
                .keyboardShortcut(.cancelAction)
                Button {
                    session.actionRequest = nil
                    Task { await session.perform(.discard, on: request.targets) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                        Text("Discard")
                        KeyCap("↩")
                    }
                }
                .buttonStyle(.pill(.destructive))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340, alignment: .leading)
        .popoverSurface(in: .rect(cornerRadius: 14))
    }

    /// "Removes 1 line in DiffDetailView.swift. GitButler keeps it in the oplog, so but undo brings it back."
    private var message: String {
        let removes: String
        if request.targets.count == 1, let target = request.targets.first {
            let name = (target.file.path as NSString).lastPathComponent
            if let hunk = target.hunk {
                removes = "Removes \(hunk.size == 1 ? "1 line" : "\(hunk.size) lines") in \(name)."
            } else if target.file.source == .untracked {
                removes = "Removes \(name)."
            } else {
                removes = "Removes all changes to \(name)."
            }
        } else {
            removes = "Removes the changes to \(request.targets.count) files."
        }
        if session.project.kind == .gitButler {
            return removes + " GitButler keeps it in the oplog, so but undo brings it back."
        }
        if request.targets.allSatisfy({ $0.file.source == .untracked }) {
            return removes + " Untracked files go to the Trash."
        }
        return removes + " Plain git can’t bring it back."
    }
}

/// A small capsule segmented control on solid surfaces: the selected segment is a raised white pill.
struct SoftSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var disabled: Set<Value> = []

    var body: some View {
        // Animated, so what the choice shows or hides around the control animates with it.
        let animated = Binding { selection } set: { value in withAnimation(.snappy(duration: 0.18)) { selection = value } }
        MagneticSegments(selection: animated, options: options, disabled: disabled, font: .caption, horizontalPadding: 11, height: 22) {
            Capsule()
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.line))
        .focusEffectDisabled()
    }
}

extension View {
    /// A soft rounded well for inputs; its edge turns lime while focused.
    func fieldBackground(isFocused: Bool) -> some View {
        background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? Theme.textPrimary.opacity(0.7) : Theme.line, lineWidth: isFocused ? 1.5 : 1))
            .animation(.snappy(duration: 0.15), value: isFocused)
    }
}
