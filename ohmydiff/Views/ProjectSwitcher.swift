import AppKit
import OhMyDiffCore
import SwiftUI

/// ⌘K palette floating over the window: fuzzy-filter projects by name and jump with Return.
struct ProjectSwitcher: View {
    let model: AppModel

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool

    private var results: [(item: Project, match: FuzzyMatcher.Match)] {
        FuzzyMatcher.rank(model.projects, query: query) { $0.displayName }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            palette
                .padding(.top, 90)
        }
        .transition(.opacity)
    }

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to project…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(results.enumerated()), id: \.element.item.id) { offset, result in
                            Button {
                                highlighted = offset
                                choose()
                            } label: {
                                ProjectRow(model: model, project: result.item, nameIndices: result.match.indices, showsShortcut: true)
                            }
                            .buttonStyle(.hover(cornerRadius: 12, isSelected: offset == highlighted))
                            .id(offset)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                if results.isEmpty {
                    Text(model.projects.isEmpty ? "No projects yet" : "No matching projects")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 520)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear { isSearchFocused = true }
        .paletteKeys(up: { moveHighlight(-1) }, down: { moveHighlight(1) }, choose: choose, dismiss: dismiss)
    }

    private func dismiss() {
        model.isSwitcherPresented = false
    }

    private func moveHighlight(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    private func choose() {
        guard results.indices.contains(highlighted) else { return }
        model.selectedProjectID = results[highlighted].item.id
        dismiss()
    }
}

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
            Text("Projects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(Array(model.projects.enumerated()), id: \.element.id) { offset, project in
                Button { select(project) } label: {
                    ProjectRow(model: model, project: project, isCurrent: project.id == model.selectedProjectID, showsShortcut: true)
                }
                .buttonStyle(.hover(cornerRadius: 12, isSelected: offset == highlighted))
            }
            Divider().padding(.vertical, 5).padding(.horizontal, 6)
            action("Switch Project…", systemImage: "magnifyingglass", shortcut: "⌘K") { model.isSwitcherPresented = true }
            action("Add Project…", systemImage: "plus", shortcut: "⇧⌘O") { model.isImporterPresented = true }
            if let project = model.selectedProject {
                action("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                    .disabled(!project.exists)
                action("Remove \(project.displayName)", systemImage: "minus.circle", role: .destructive) { model.remove(project.id) }
            }
        }
        .padding(8)
        .frame(width: 380)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        .paletteKeys(up: { move(-1) }, down: { move(1) }, choose: chooseHighlighted, dismiss: dismiss)
        .onAppear { highlighted = model.projects.firstIndex { $0.id == model.selectedProjectID } }
    }

    private func action(
        _ title: String, systemImage: String, shortcut: String? = nil, role: ButtonRole? = nil, perform: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            dismiss()
            perform()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 32)
                    .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Text(title)
                    .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .buttonStyle(.hover(cornerRadius: 10))
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

/// A project in the switcher or the dropdown: monogram, name, kind, path, change count and ⌘ shortcut.
struct ProjectRow: View {
    let model: AppModel
    let project: Project
    var nameIndices: [Int] = []
    var isCurrent = false
    var showsShortcut = false

    var body: some View {
        let session = model.session(for: project.id)
        HStack(spacing: 12) {
            Text(projectMonogram(project.displayName))
                .font(.system(size: 12, weight: .bold))
                .frame(width: 32, height: 32)
                .background(isCurrent ? AnyShapeStyle(Theme.logo.opacity(0.85)) : AnyShapeStyle(Theme.glassSelection), in: .rect(cornerRadius: 9))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(highlightedName)
                        .fontWeight(isCurrent ? .semibold : .regular)
                    Text(session.phase == .missing ? "Missing" : project.kind == .gitButler ? "GitButler" : "Git")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(session.phase == .missing ? Color.orange : project.kind == .gitButler ? Color.green : Color.secondary)
                }
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if session.changeCount > 0 {
                Text(session.changeCount == 1 ? "1 change" : "\(session.changeCount) changes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if showsShortcut, let position = model.projects.firstIndex(of: project), position < 9 {
                Text("⌘\(position + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
