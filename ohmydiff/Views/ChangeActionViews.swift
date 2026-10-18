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
            Button("Commit\(suffix) to Branch…") { session.request(.commit, on: targets) }
        }
        if !isGroup, session.supports(.discard, on: targets) {
            Divider()
            Button("Discard Changes…", role: .destructive) { session.request(.discard, on: targets) }
        }
    }
}

extension View {
    /// The discard confirmation, the commit sheet and action errors for a project.
    func changeActionPresentation(_ session: ProjectSession) -> some View {
        modifier(ChangeActionPresentation(session: session))
    }
}

private struct ChangeActionPresentation: ViewModifier {
    @Bindable var session: ProjectSession

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                discardTitle, isPresented: isPresented(.discard), titleVisibility: .visible, presenting: session.actionRequest
            ) { request in
                Button("Discard", role: .destructive) {
                    Task { await session.perform(.discard, on: request.targets) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(discardMessage(request))
            }
            .sheet(isPresented: isPresented(.commit)) {
                if let request = session.actionRequest {
                    CommitSheet(session: session, request: request)
                }
            }
            .alert(
                "Action Failed",
                isPresented: Binding(get: { session.actionError != nil }, set: { if !$0 { session.actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.actionError ?? "")
            }
    }

    private func isPresented(_ action: ChangeAction) -> Binding<Bool> {
        Binding(
            get: { session.actionRequest?.action == action },
            set: { if !$0, session.actionRequest?.action == action { session.actionRequest = nil } })
    }

    private var discardTitle: String {
        "Discard changes to \(session.actionRequest?.subject ?? "")?"
    }

    private func discardMessage(_ request: ProjectSession.ActionRequest) -> String {
        if session.project.kind == .gitButler {
            let branches = Set(request.targets.compactMap { session.assignedBranch(of: $0.file.path) }).sorted()
            let assigned = branches.isEmpty ? "" : "Assigned to \(branches.joined(separator: ", ")). "
            return assigned + "You can bring them back with `but undo`."
        }
        if request.targets.allSatisfy({ $0.file.source == .untracked }) {
            return "The file is moved to the Trash."
        }
        return "This cannot be undone."
    }
}

/// Commits the requested changes to an applied branch or a new one.
private struct CommitSheet: View {
    let session: ProjectSession
    let request: ProjectSession.ActionRequest

    @Environment(\.dismiss) private var dismiss
    @State private var branch = ""
    @State private var isNewBranch = false
    @State private var newBranch = ""
    @State private var message = ""
    @State private var error: String?
    @FocusState private var isMessageFocused: Bool

    private var targetBranch: String { isNewBranch ? newBranch.trimmingCharacters(in: .whitespaces) : branch }
    private var canCommit: Bool {
        !targetBranch.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isPerformingAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit \(request.subject)")
                .font(.headline)
            Form {
                Picker("Branch", selection: $isNewBranch) {
                    Text("Existing Branch").tag(false)
                    Text("New Branch").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if isNewBranch {
                    TextField("Name", text: $newBranch, prompt: Text("feature/name"))
                } else {
                    Picker("Branch", selection: $branch) {
                        ForEach(session.branchNames, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(session.branchNames.isEmpty)
                }
            }
            .formStyle(.columns)

            TextEditor(text: $message)
                .font(.body.monospaced())
                .focused($isMessageFocused)
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Commit message")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .border(.separator)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                Text("Only the selected changes are committed, with `but commit -b`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Commit") { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            branch = session.suggestedBranch(for: request.targets)
            isNewBranch = session.branchNames.isEmpty
            isMessageFocused = true
        }
    }

    private func commit() {
        guard canCommit else { return }
        let branch = targetBranch
        Task {
            do {
                try await session.run(.commit, on: request.targets, branch: branch, message: message)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
