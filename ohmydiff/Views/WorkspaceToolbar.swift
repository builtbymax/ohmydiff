import OhMyDiffCore
import SwiftUI

/// The glass controls floating over the top of the content panel: where you are on the left,
/// the diff layout, mode and actions on the right.
struct WorkspaceToolbar: View {
    let model: AppModel
    @Binding var mode: WorkspaceMode

    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified
    @FocusedValue(\.diffFile) private var diffFile

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if let session = model.selectedSession {
                    Breadcrumb(session: session, mode: mode)
                }
                Spacer(minLength: 12)
                GlassSegmented(selection: $layout, options: [(.unified, "Unified"), (.split, "Split")])
                    .help("Side-by-Side Diff (⌘\\)")
                GlassSegmented(selection: $mode, options: WorkspaceMode.allCases.map { ($0, $0.rawValue) })
                HStack(spacing: 2) {
                    ToolbarIconButton(title: "Refresh (⌘R)", systemImage: "arrow.clockwise") { model.refreshSelected() }
                        .disabled(model.selectedProjectID == nil)
                    ToolbarIconButton(title: "Open in Editor (⌘O)", systemImage: "arrow.up.forward.square") {
                        diffFile.map(model.openInEditor)
                    }
                    .disabled(diffFile?.exists != true)
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

/// `ohmydiff / feature/x  GitButler · 3 branches`
private struct Breadcrumb: View {
    let session: ProjectSession
    let mode: WorkspaceMode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.phase == .missing ? "questionmark.folder" : "folder")
                .foregroundStyle(.secondary)
            Text(session.project.displayName)
                .foregroundStyle(location == nil ? .primary : .secondary)
                .fontWeight(location == nil ? .semibold : .regular)
            if let location {
                Text("/").foregroundStyle(.tertiary)
                Image(systemName: location.systemImage)
                Text(location.title)
                    .fontWeight(.semibold)
                    .truncationMode(.middle)
            }
            Text(kind)
                .font(.caption.weight(.semibold))
                .foregroundStyle(session.project.kind == .gitButler ? Color.green : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((session.project.kind == .gitButler ? Color.green : Color.secondary).opacity(0.15), in: .rect(cornerRadius: 7))
            if session.isRefreshing {
                ProgressView().controlSize(.mini)
            }
        }
        .lineLimit(1)
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .glassEffect(.regular, in: .capsule)
        .help(session.project.path)
    }

    /// The branch of the selected file in Changes mode, or the selected branch in History mode.
    private var location: (title: String, systemImage: String)? {
        switch mode {
        case .changes:
            guard let file = session.selectedFile else { return nil }
            if let branch = session.assignedBranch(of: file.path) { return (branch, "arrow.triangle.branch") }
            return session.project.kind == .gitButler ? ("Unassigned", "tray") : nil
        case .history:
            return session.history.selectedBranch.map { ($0.name, "arrow.triangle.branch") }
        }
    }

    private var kind: String {
        if session.phase == .missing { return "Missing" }
        guard session.project.kind == .gitButler else { return "Git" }
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
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
