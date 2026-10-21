import AppKit
import OhMyDiffCore
import SwiftUI

/// The dropdown below the breadcrumb's project name: the workspace's projects, then project actions.
struct ProjectDropdown: View {
    @Bindable var model: AppModel
    @State private var highlighted: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .onTapGesture(perform: dismiss)
            // From the window's top edge, like the toolbar: 6 pt below its 38 pt bar, which sits 10 pt into the panel.
            panel
                .padding(.leading, Theme.inset * 2 + Theme.railWidth + 12)
                .padding(.top, Theme.inset + 10 + 38 + 6)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
        .ignoresSafeArea()
    }

    private var panel: some View {
        let projects = model.visibleProjects
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(model.selectedWorkspace?.name ?? "Projects")
                Spacer()
                Text("\(projects.count)").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            ForEach(Array(projects.enumerated()), id: \.element.id) { offset, project in
                Button { select(project) } label: {
                    ProjectRow(model: model, project: project, isCurrent: project.id == model.selectedProjectID, showsShortcut: true)
                }
                .buttonStyle(.hover(cornerRadius: 10, isSelected: offset == highlighted))
                .focusEffectDisabled()
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 10)
            action("Switch Project…", systemImage: "magnifyingglass", shortcut: "⌘K") { model.isSwitcherPresented = true }
            action("Add Project…", systemImage: "plus", shortcut: "⇧⌘O") { model.isImporterPresented = true }
            if let project = model.selectedProject {
                action("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                    .disabled(!project.exists)
                if model.workspaces.count > 1 {
                    moveMenu(project)
                }
                action("Remove \(project.displayName)", systemImage: "minus.circle", role: .destructive) { model.remove(project.id) }
            }
        }
        .padding(6)
        .frame(width: 360)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 18))
        .shadow(color: Theme.overlayShadow, radius: 24, y: 10)
        .paletteKeys(up: { move(-1) }, down: { move(1) }, choose: chooseHighlighted, dismiss: dismiss)
        .onAppear { highlighted = projects.firstIndex { $0.id == model.selectedProjectID } }
    }

    /// The other workspaces to sort the project into; the view follows it there.
    private func moveMenu(_ project: Project) -> some View {
        Menu {
            ForEach(model.workspaces.filter { $0.id != project.workspaceID }) { workspace in
                Button(workspace.name) {
                    dismiss()
                    model.move(project.id, to: workspace.id)
                }
            }
        } label: {
            actionLabel("Move to Workspace", systemImage: "arrow.right.square", trailing: Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hover(cornerRadius: 10))
        .focusEffectDisabled()
    }

    private func action(
        _ title: String, systemImage: String, shortcut: String? = nil, role: ButtonRole? = nil, perform: @escaping () -> Void
    ) -> some View {
        let tint: Color = role == .destructive ? .red : .primary
        return Button(role: role) {
            dismiss()
            perform()
        } label: {
            actionLabel(title, systemImage: systemImage, tint: tint, trailing: shortcut.map { KeyCap($0) })
        }
        .buttonStyle(.hover(cornerRadius: 10, tint: tint))
        .focusEffectDisabled()
    }

    private func actionLabel(_ title: String, systemImage: String, tint: Color = .primary, trailing: (some View)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28)
                .foregroundStyle(tint == .primary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            Text(title)
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(.rect)
    }

    private func move(_ delta: Int) {
        let count = model.visibleProjects.count
        guard count > 0 else { return }
        highlighted = ((highlighted ?? (delta > 0 ? -1 : 0)) + delta + count) % count
    }

    private func chooseHighlighted() {
        let projects = model.visibleProjects
        guard let highlighted, projects.indices.contains(highlighted) else { return }
        select(projects[highlighted])
    }

    private func select(_ project: Project) {
        model.selectedProjectID = project.id
        dismiss()
    }

    private func dismiss() {
        model.isProjectMenuPresented = false
    }
}

/// A project in the palette or the dropdown: monogram, name, kind, path, change count and ⌘ shortcut, or
/// its workspace when that is not the one shown.
struct ProjectRow: View {
    let model: AppModel
    let project: Project
    var nameIndices: [Int] = []
    var isCurrent = false
    var showsShortcut = false
    var showsWorkspace = false

    var body: some View {
        let session = model.session(for: project.id)
        HStack(spacing: 10) {
            ProjectMonogram(project: project)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(highlightedName)
                        .fontWeight(isCurrent ? .semibold : .medium)
                        .lineLimit(1)
                    KindTag(kind: project.kind, isMissing: session.phase == .missing)
                }
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if session.changeCount > 0 {
                Text("\(session.changeCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .fixedSize()
            }
            if showsWorkspace, let workspace = model.workspace(of: project), workspace.id != model.selectedWorkspaceID {
                Text(workspace.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else if showsShortcut, let position = model.visibleProjects.firstIndex(where: { $0.id == project.id }), position < 9 {
                KeyCap("⌘\(position + 1)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    private var highlightedName: AttributedString {
        var result = AttributedString()
        let matched = Set(nameIndices)
        for (offset, character) in project.displayName.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        return result
    }
}

/// A project's two letters on its Pantone color.
struct ProjectMonogram: View {
    let project: Project
    var size: CGFloat = 30

    var body: some View {
        ColorMonogram(name: project.displayName, color: project.color ?? ProjectColor.allCases[0], size: size)
    }
}

/// A workspace's two letters on its Pantone color, rounder than a project's.
struct WorkspaceMonogram: View {
    let workspace: Workspace
    var size: CGFloat = 30

    var body: some View {
        ColorMonogram(name: workspace.name, color: workspace.color, size: size, cornerRatio: 0.5)
    }
}

private struct ColorMonogram: View {
    let name: String
    let color: ProjectColor
    let size: CGFloat
    var cornerRatio: CGFloat = 0.28

    var body: some View {
        Text(projectMonogram(name))
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(color.isLight ? Color.black.opacity(0.8) : .white)
            .frame(width: size, height: size)
            .background(Theme.projectColor(color).gradient, in: .rect(cornerRadius: size * cornerRatio))
    }
}

/// `GitButler`, `Git` or `Missing` as a small tag.
struct KindTag: View {
    let kind: RepositoryKind
    var isMissing = false

    var body: some View {
        let text = isMissing ? "Missing" : kind == .gitButler ? "GitButler" : "Git"
        let color = Theme.kindColor(kind, isMissing: isMissing)
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(Theme.kindTintOpacity), in: .capsule)
            .fixedSize()
    }
}
