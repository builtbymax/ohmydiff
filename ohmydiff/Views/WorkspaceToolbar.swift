import AppKit
import OhMyDiffCore
import SwiftUI

/// The glass controls over the top of the content panel: the project and where you are on the left,
/// the file list, diff layout and actions on the right. Changes / History live on the rail.
struct WorkspaceToolbar: View {
    let model: AppModel
    let mode: WorkspaceMode

    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @FocusedValue(\.diffFile) private var diffFile
    @FocusedValue(\.diffPopout) private var diffPopout
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ProjectBreadcrumb(model: model, mode: mode)
                // The empty stretch moves the window, like a title bar.
                Color.clear
                    .frame(minWidth: 12, maxWidth: .infinity, maxHeight: 38)
                    .contentShape(.rect)
                    .gesture(WindowDragGesture())
                ToolbarIconButton(
                    title: isListHidden ? "Show File List  ⌘0" : "Hide File List  ⌘0",
                    systemImage: isListHidden ? "sidebar.left" : "rectangle.leadinghalf.inset.filled"
                ) {
                    withAnimation(.snappy) { isListHidden.toggle() }
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
                GlassSegmented(selection: $layout, options: [(.unified, "Unified"), (.split, "Split")])
                HStack(spacing: 2) {
                    ToolbarIconButton(title: "Refresh  ⌘R", systemImage: "arrow.clockwise") { model.refreshSelected() }
                        .disabled(model.selectedProjectID == nil)
                    ToolbarIconButton(title: "Open in Editor  ⌘O", systemImage: "arrow.up.forward.square") {
                        diffFile.map(model.openInEditor)
                    }
                    .disabled(diffFile?.exists != true)
                    ToolbarIconButton(title: "Open Diff in New Window  ⌥⌘O", systemImage: "macwindow.badge.plus") {
                        diffPopout.map { openWindow(id: DiffWindow.id, value: model.register($0)) }
                    }
                    .disabled(diffPopout == nil)
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// `ohmydiff ⌄ / feature/x  GitButler · 3 branches`; the project name opens the project menu.
private struct ProjectBreadcrumb: View {
    let model: AppModel
    let mode: WorkspaceMode

    var body: some View {
        HStack(spacing: 8) {
            ProjectMenu(model: model)
            if let session = model.selectedSession {
                if let location = location(in: session) {
                    Text("/").foregroundStyle(.tertiary)
                    Image(systemName: location.systemImage)
                    Text(location.title)
                        .fontWeight(.semibold)
                        .truncationMode(.middle)
                }
                KindPill(session: session)
                if session.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .lineLimit(1)
        .font(.callout)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 38)
        .glassEffect(.regular, in: .capsule)
    }

    /// The branch of the selected file in Changes mode, or the selected branch in History mode.
    private func location(in session: ProjectSession) -> (title: String, systemImage: String)? {
        switch mode {
        case .changes:
            guard let file = session.selectedFile else { return nil }
            if let branch = session.assignedBranch(of: file.path) { return (branch, "arrow.triangle.branch") }
            return session.project.kind == .gitButler ? ("Unassigned", "tray") : nil
        case .history:
            return session.history.selectedBranch.map { ($0.name, "arrow.triangle.branch") }
        }
    }
}

/// The selected project; opens the project dropdown.
private struct ProjectMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Button { model.isProjectMenuPresented.toggle() } label: {
            HStack(spacing: 7) {
                if let project = model.selectedProject {
                    ProjectMonogram(name: project.displayName, isCurrent: true, size: 26)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Theme.glassSelection, in: .rect(cornerRadius: 8))
                }
                Text(model.selectedProject?.displayName ?? "Add Project")
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(model.isProjectMenuPresented ? 180 : 0))
                    .animation(.snappy(duration: 0.2), value: model.isProjectMenuPresented)
                    .padding(.trailing, 6)
            }
            .padding(3)
        }
        .buttonStyle(.hover(cornerRadius: 11, isSelected: model.isProjectMenuPresented))
        .focusEffectDisabled()
        .fixedSize()
        .glassTooltip("Switch Project")
    }
}

/// `Git` or `GitButler · 3 branches`, or `Missing`.
private struct KindPill: View {
    let session: ProjectSession

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .rect(cornerRadius: 7))
    }

    private var isGitButler: Bool { session.project.kind == .gitButler && session.phase != .missing }
    private var color: Color { session.phase == .missing ? .orange : isGitButler ? .green : .secondary }

    private var text: String {
        if session.phase == .missing { return "Missing" }
        guard isGitButler else { return "Git" }
        let count = session.branchNames.count
        return count == 1 ? "GitButler · 1 branch" : "GitButler · \(count) branches"
    }
}

private struct ToolbarIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.hoverCapsule())
        .focusEffectDisabled()
        .glassTooltip(title)
    }
}
