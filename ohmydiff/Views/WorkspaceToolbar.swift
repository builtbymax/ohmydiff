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
                // The breadcrumb first, then the upstream controls, then the empty stretch: in a narrow window the
                // upstream controls turn compact before the branch name shortens. Everything else keeps its size.
                ProjectBreadcrumb(model: model, mode: mode)
                    .layoutPriority(2)
                if let session = model.selectedSession, session.phase == .ready {
                    UpstreamControls(model: model, session: session)
                        .layoutPriority(1)
                }
                UpdatingPill(isRefreshing: model.selectedSession?.isRefreshing == true)
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
                    .fixedSize()
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
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// `ohmydiff ⌄ / feature/x  GitButler · 3`; the project name opens the project menu.
private struct ProjectBreadcrumb: View {
    let model: AppModel
    let mode: WorkspaceMode

    var body: some View {
        HStack(spacing: 8) {
            ProjectMenu(model: model)
            if let session = model.selectedSession {
                if let location = location(in: session) {
                    // Never truncated: the branch name shortens instead.
                    Text("/").foregroundStyle(.tertiary).fixedSize()
                    Image(systemName: location.systemImage)
                    Text(location.title)
                        .fontWeight(.semibold)
                        .truncationMode(.middle)
                        .frame(minWidth: 56, alignment: .leading)
                        .layoutPriority(1)
                }
                KindPill(session: session)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .font(.callout)
        // 3 pt around the project button's hover, like above and below it; 12 pt after the kind pill.
        .padding(.leading, 3)
        .padding(.trailing, model.selectedSession == nil ? 3 : 12)
        .frame(height: 38)
        .glassEffect(.regular, in: .capsule)
    }

    /// The branch of the selected file in Changes mode (plain git: the checked-out one), or the selected branch in History mode.
    private func location(in session: ProjectSession) -> (title: String, systemImage: String)? {
        switch mode {
        case .changes:
            if session.project.kind != .gitButler { return session.currentBranch.map { ($0, "arrow.triangle.branch") } }
            guard let file = session.selectedFile else { return nil }
            if let branch = session.assignedBranch(of: file.path) { return (branch, "arrow.triangle.branch") }
            return ("Unassigned", "tray")
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
                    ProjectMonogram(project: project, size: 22)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Theme.glassSelection, in: .rect(cornerRadius: 6))
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
            .padding(5)
        }
        .buttonStyle(.hoverCapsule(isSelected: model.isProjectMenuPresented))
        .focusEffectDisabled()
        .fixedSize()
        .glassTooltip("Switch Project")
    }
}

/// `Updating ◌` in its own pill, shown only once a refresh takes a moment so quick ones do not flash it,
/// and then kept long enough to read.
private struct UpdatingPill: View {
    let isRefreshing: Bool
    @State private var shownAt: Date?

    private static let delay = Duration.milliseconds(400)
    private static let minimumShown: TimeInterval = 0.6

    var body: some View {
        ZStack {
            if shownAt != nil {
                HStack(spacing: 7) {
                    Text("Updating")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ProgressView().controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .task(id: isRefreshing) {
            if isRefreshing {
                guard shownAt == nil else { return }
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.2)) { shownAt = .now }
            } else if let shownAt {
                let remaining = Self.minimumShown - Date.now.timeIntervalSince(shownAt)
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.2)) { self.shownAt = nil }
            }
        }
    }
}

/// `Git` or `GitButler · 3` with the applied branch count, or `Missing`.
private struct KindPill: View {
    let session: ProjectSession

    var body: some View {
        if isGitButler {
            pill.glassTooltip(session.branchNames.count == 1 ? "1 branch applied" : "\(session.branchNames.count) branches applied")
        } else {
            pill
        }
    }

    private var pill: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(Theme.kindTintOpacity), in: .rect(cornerRadius: 7))
    }

    private var isGitButler: Bool { session.project.kind == .gitButler && session.phase != .missing }
    private var color: Color { Theme.kindColor(session.project.kind, isMissing: session.phase == .missing) }

    private var text: String {
        if session.phase == .missing { return "Missing" }
        guard isGitButler else { return "Git" }
        return "GitButler · \(session.branchNames.count)"
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
