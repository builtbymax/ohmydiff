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
    @FocusState private var focus: Field?

    private enum Field { case branchName, message }

    private var targetBranch: String { isNewBranch ? newBranch.trimmingCharacters(in: .whitespaces) : branch }
    private var canCommit: Bool {
        !targetBranch.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isPerformingAction
    }

    /// The summed line counts, when every target is a whole file with known counts.
    private var stats: LineStats? {
        guard request.targets.allSatisfy({ $0.hunk == nil }) else { return nil }
        let all = request.targets.compactMap(\.file.stats)
        guard all.count == request.targets.count else { return nil }
        return LineStats(additions: all.reduce(0) { $0 + $1.additions }, deletions: all.reduce(0) { $0 + $1.deletions })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle("Branch")
                    Spacer()
                    SoftSegmented(
                        selection: $isNewBranch,
                        options: [(false, "Existing"), (true, "New")],
                        disabled: session.branchNames.isEmpty ? [false] : [])
                }
                if isNewBranch {
                    TextField("Branch name", text: $newBranch, prompt: Text("feature/name"))
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .focused($focus, equals: .branchName)
                        .onSubmit { focus = .message }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .fieldBackground(isFocused: focus == .branchName)
                } else {
                    branchList
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Message")
                TextEditor(text: $message)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .message)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text("Summary of the change")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(8)
                    .fieldBackground(isFocused: focus == .message)
            }

            footer
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            branch = session.suggestedBranch(for: request.targets)
            isNewBranch = session.branchNames.isEmpty
            focus = isNewBranch ? .branchName : .message
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Theme.logo, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Commit \(request.subject)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let stats { LineStatsLabel(stats: stats) }
                    Text("Only the selected changes are committed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var branchList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(session.branchNames, id: \.self) { name in
                    Button { branch = name } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(name)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            if name == branch {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.logoText)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.row(isSelected: name == branch))
                    .focusEffectDisabled()
                }
            }
            .padding(4)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 128)
        .fixedSize(horizontal: false, vertical: true)
        .fieldBackground(isFocused: false)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.deletion)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } else {
                HStack(spacing: 5) {
                    KeyCap("⌘↩")
                    Text("to commit with `but commit -b`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.pill(height: 32))
            Button { commit() } label: {
                if session.isPerformingAction {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Text("Commit")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.pill(.prominent, height: 32))
            .disabled(!canCommit)
        }
        .focusEffectDisabled()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func commit() {
        guard canCommit else { return }
        let branch = targetBranch
        error = nil
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

/// A small capsule segmented control on solid surfaces: the selected segment is a raised white pill.
private struct SoftSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var disabled: Set<Value> = []

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button { withAnimation(.snappy(duration: 0.18)) { selection = option.value } } label: {
                    Text(option.title)
                        .font(.caption.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.cardRow)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(disabled.contains(option.value))
                .opacity(disabled.contains(option.value) ? 0.4 : 1)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .focusEffectDisabled()
    }
}

private extension View {
    /// A soft rounded well for inputs; its edge turns lime while focused.
    func fieldBackground(isFocused: Bool) -> some View {
        background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? Theme.logoText.opacity(0.7) : Theme.hairline, lineWidth: isFocused ? 1.5 : 1))
            .animation(.snappy(duration: 0.15), value: isFocused)
    }
}
