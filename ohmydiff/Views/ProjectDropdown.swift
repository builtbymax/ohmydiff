import AppKit
import OhMyDiffCore
import SwiftUI

/// The dropdown below the breadcrumb's project name: every project, then project actions.
struct ProjectDropdown: View {
    @Bindable var model: AppModel
    @State private var highlighted: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            panel
                .padding(.leading, Theme.inset * 2 + Theme.railWidth + 12)
                .padding(.top, Theme.inset + 52)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Projects")
                Spacer()
                Text("\(model.projects.count)").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            ForEach(Array(model.projects.enumerated()), id: \.element.id) { offset, project in
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
                action("Remove \(project.displayName)", systemImage: "minus.circle", role: .destructive) { model.remove(project.id) }
            }
        }
        .padding(6)
        .frame(width: 360)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 18))
        .shadow(color: Theme.overlayShadow, radius: 24, y: 10)
        .paletteKeys(up: { move(-1) }, down: { move(1) }, choose: chooseHighlighted, dismiss: dismiss)
        .onAppear { highlighted = model.projects.firstIndex { $0.id == model.selectedProjectID } }
    }

    private func action(
        _ title: String, systemImage: String, shortcut: String? = nil, role: ButtonRole? = nil, perform: @escaping () -> Void
    ) -> some View {
        let tint: Color = role == .destructive ? .red : .primary
        return Button(role: role) {
            dismiss()
            perform()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28)
                    .foregroundStyle(role == .destructive ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                Text(title)
                    .foregroundStyle(role == .destructive ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer()
                if let shortcut { KeyCap(shortcut) }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 10, tint: tint))
        .focusEffectDisabled()
    }

    private func move(_ delta: Int) {
        guard !model.projects.isEmpty else { return }
        let count = model.projects.count
        highlighted = ((highlighted ?? (delta > 0 ? -1 : 0)) + delta + count) % count
    }

    private func chooseHighlighted() {
        guard let highlighted, model.projects.indices.contains(highlighted) else { return }
        select(model.projects[highlighted])
    }

    private func select(_ project: Project) {
        model.selectedProjectID = project.id
        dismiss()
    }

    private func dismiss() {
        model.isProjectMenuPresented = false
    }
}

/// A project in the palette or the dropdown: monogram, name, kind, path, change count and ⌘ shortcut.
struct ProjectRow: View {
    let model: AppModel
    let project: Project
    var nameIndices: [Int] = []
    var isCurrent = false
    var showsShortcut = false

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
            if showsShortcut, let position = model.projects.firstIndex(of: project), position < 9 {
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
        let color = project.color ?? ProjectColor.allCases[0]
        Text(projectMonogram(project.displayName))
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(color.isLight ? Color.black.opacity(0.8) : .white)
            .frame(width: size, height: size)
            .background(Theme.projectColor(color).gradient, in: .rect(cornerRadius: size * 0.28))
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
