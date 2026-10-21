import OhMyDiffCore
import SwiftUI

/// The dropdown beside the rail's workspace button: every workspace, then creating, renaming and deleting
/// them inline.
struct WorkspaceDropdown: View {
    @Bindable var model: AppModel
    @State private var highlighted: Int?
    @State private var editing: Editing?
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    private enum Editing: Equatable {
        case new
        case rename(Workspace.ID)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .onTapGesture(perform: dismiss)
            // Beside the rail, level with its workspace button.
            panel
                .padding(.leading, Theme.inset + Theme.railWidth + 8)
                .padding(.top, Theme.inset + Theme.titleBarHeight + 12)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
        .ignoresSafeArea()
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Workspaces")
                Spacer()
                Text("\(model.workspaces.count)").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { offset, workspace in
                if editing == .rename(workspace.id) {
                    nameField(WorkspaceMonogram(workspace: workspace, size: 26))
                } else {
                    Button { select(workspace) } label: {
                        WorkspaceRow(model: model, workspace: workspace, position: offset)
                    }
                    .buttonStyle(.hover(cornerRadius: 10, isSelected: offset == highlighted))
                    .focusEffectDisabled()
                    .contextMenu {
                        Button("Rename") { startEditing(.rename(workspace.id), name: workspace.name) }
                        Button("Delete…", role: .destructive) { confirmDeletion(workspace) }
                            .disabled(!model.canDelete(workspace))
                    }
                }
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 10)
            if editing == .new {
                nameField(Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Theme.glassSelection, in: .circle))
            } else {
                action("New Workspace…", systemImage: "plus") { startEditing(.new, name: "") }
            }
            if let workspace = model.selectedWorkspace {
                action("Rename \(workspace.name)", systemImage: "pencil") { startEditing(.rename(workspace.id), name: workspace.name) }
                deleteAction(workspace)
            }
        }
        .padding(6)
        .frame(width: 300)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 18))
        .shadow(color: Theme.overlayShadow, radius: 24, y: 10)
        .paletteKeys(up: { move(-1) }, down: { move(1) }, choose: choose, dismiss: cancel)
        .onAppear { highlighted = model.workspaces.firstIndex { $0.id == model.selectedWorkspaceID } }
    }

    /// The inline name editor; Return saves it and Escape cancels.
    private func nameField(_ icon: some View) -> some View {
        HStack(spacing: 10) {
            icon
            TextField(editing == .new ? "Workspace Name" : "Name", text: $name)
                .textFieldStyle(.plain)
                .fontWeight(.medium)
                .focused($isNameFocused)
                .onAppear { isNameFocused = true }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Theme.glassSelection, in: .rect(cornerRadius: 10))
    }

    /// Deleting asks first, and only an empty workspace that is not the last one can be deleted.
    private func deleteAction(_ workspace: Workspace) -> some View {
        let reason: String? = model.workspaces.count == 1
            ? "Last workspace"
            : model.canDelete(workspace) ? nil : "Not empty"
        return Button(role: .destructive) { confirmDeletion(workspace) } label: {
            label("Delete \(workspace.name)…", systemImage: "trash", tint: reason == nil ? .red : .secondary) {
                if let reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.hover(cornerRadius: 10, tint: .red))
        .focusEffectDisabled()
        .disabled(reason != nil)
    }

    private func action(_ title: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            label(title, systemImage: systemImage) { EmptyView() }
        }
        .buttonStyle(.hover(cornerRadius: 10))
        .focusEffectDisabled()
    }

    private func label(
        _ title: String, systemImage: String, tint: Color = .primary, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26)
                .foregroundStyle(tint == .primary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            Text(title)
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(.rect)
    }

    // MARK: Actions

    private func startEditing(_ mode: Editing, name: String) {
        self.name = name
        editing = mode
    }

    private func choose() {
        switch editing {
        case .new:
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                editing = nil
            } else {
                model.addWorkspace(named: name)
                dismiss()
            }
        case .rename(let id):
            model.renameWorkspace(id, to: name)
            editing = nil
        case nil:
            guard let highlighted, model.workspaces.indices.contains(highlighted) else { return }
            select(model.workspaces[highlighted])
        }
    }

    /// Escape ends editing first, then closes the dropdown.
    private func cancel() {
        if editing != nil {
            editing = nil
        } else {
            dismiss()
        }
    }

    private func move(_ delta: Int) {
        let count = model.workspaces.count
        guard editing == nil, count > 0 else { return }
        highlighted = ((highlighted ?? (delta > 0 ? -1 : 0)) + delta + count) % count
    }

    private func select(_ workspace: Workspace) {
        model.selectWorkspace(workspace.id)
        dismiss()
    }

    private func confirmDeletion(_ workspace: Workspace) {
        guard model.canDelete(workspace) else { return }
        dismiss()
        model.pendingWorkspaceDeletion = workspace
    }

    private func dismiss() {
        model.isWorkspaceMenuPresented = false
    }
}

/// A workspace in the dropdown: monogram, name, project count and ⌃⌘ shortcut.
private struct WorkspaceRow: View {
    let model: AppModel
    let workspace: Workspace
    let position: Int

    var body: some View {
        let isCurrent = workspace.id == model.selectedWorkspaceID
        let count = model.projects(in: workspace.id).count
        HStack(spacing: 10) {
            WorkspaceMonogram(workspace: workspace, size: 26)
            Text(workspace.name)
                .fontWeight(isCurrent ? .semibold : .medium)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(count == 1 ? "1 project" : "\(count) projects")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            if position < 9 {
                KeyCap("⌃⌘\(position + 1)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
