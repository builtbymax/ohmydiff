import AppKit
import OhMyDiffCore
import SwiftUI

/// ⌘K palette floating over the window: fuzzy-search projects, changed files, branches and commands,
/// and run the highlighted one with Return. A leading `>` searches commands only.
struct CommandPalette: View {
    let model: AppModel

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool

    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified
    @AppStorage(DiffSettings.wholeFileKey) private var showsWholeFile = false
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @FocusedValue(\.diffFile) private var diffFile
    @FocusedValue(\.diffPopout) private var diffPopout
    @FocusedValue(\.diffPrompt) private var diffPrompt
    @Environment(\.claudeCode) private var claudeCode
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.1)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            palette
                .padding(.top, 90)
        }
        .transition(.opacity)
    }

    private var palette: some View {
        let sections = self.sections
        let items = sections.flatMap(\.items)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isCommandQuery ? "chevron.right" : "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField("Search projects, files, branches and commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            Divider().opacity(0.6)

            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(sections) { section in
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                                ForEach(section.items) { item in
                                    let index = items.firstIndex { $0.id == item.id } ?? 0
                                    Button {
                                        highlighted = index
                                        run(item)
                                    } label: {
                                        row(for: item)
                                    }
                                    .buttonStyle(.hover(cornerRadius: 10, isSelected: index == highlighted))
                                    .focusEffectDisabled()
                                    .id(item.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlighted) {
                        if items.indices.contains(highlighted) { proxy.scrollTo(items[highlighted].id) }
                    }
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.6)
            footer
        }
        .frame(width: 580)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 22))
        .shadow(color: Theme.overlayShadow, radius: 30, y: 12)
        .onAppear { isSearchFocused = true }
        .paletteKeys(
            up: { move(-1, count: items.count) }, down: { move(1, count: items.count) },
            choose: { if items.indices.contains(highlighted) { run(items[highlighted]) } },
            dismiss: dismiss)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.projects.isEmpty && query.isEmpty ? "No projects yet" : "No results for “\(query)”")
                .font(.callout.weight(.medium))
            Text("Try a project, file or branch name, or type > for commands.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Navigate")
            hint("↩", "Open")
            hint(">", "Commands")
            Spacer()
            hint("esc", "Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(for item: PaletteItem) -> some View {
        if case .project(let project) = item.icon {
            ProjectRow(model: model, project: project, nameIndices: item.indices,
                       isCurrent: project.id == model.selectedProjectID, showsShortcut: true)
        } else {
            HStack(spacing: 10) {
                icon(for: item.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlighted(item.title, indices: item.indices))
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut = item.shortcut { KeyCap(shortcut) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, item.subtitle == nil ? 7 : 5)
            .contentShape(.rect)
        }
    }

    @ViewBuilder
    private func icon(for icon: PaletteItem.Icon) -> some View {
        switch icon {
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
        case .badge(let letter, let color):
            Text(letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .badgeTile(color, cornerRadius: 8)
        case .project(let project):
            ProjectMonogram(project: project)
        }
    }

    private func highlighted(_ text: String, indices: [Int]) -> AttributedString {
        var result = AttributedString()
        let matched = Set(indices)
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        return result
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func dismiss() {
        model.isSwitcherPresented = false
    }

    private func run(_ item: PaletteItem) {
        dismiss()
        item.action()
    }

    // MARK: Items

    private var isCommandQuery: Bool { query.hasPrefix(">") }

    private var searchText: String {
        (isCommandQuery ? String(query.dropFirst()) : query).trimmingCharacters(in: .whitespaces)
    }

    /// With an empty query: projects and commands. Otherwise every kind, best matches first within each.
    private var sections: [PaletteSection] {
        let text = searchText
        let all: [(PaletteSection.Kind, [PaletteItem], Int)] = isCommandQuery
            ? [(.commands, commands, 50)]
            : text.isEmpty
                ? [(.projects, projects, 9), (.commands, commands, 50)]
                : [(.projects, projects, 6), (.files, files, 8), (.branches, branches, 6), (.commands, commands, 10)]
        return all.compactMap { kind, items, limit in
            let ranked: [PaletteItem] = text.isEmpty
                ? items
                : FuzzyMatcher.rank(items, query: text) { $0.title }.map { result in
                    var item = result.item
                    item.indices = result.match.indices
                    return item
                }
            let shown = Array(ranked.prefix(limit))
            return shown.isEmpty ? nil : PaletteSection(kind: kind, items: shown)
        }
    }

    private var projects: [PaletteItem] {
        model.projects.map { project in
            PaletteItem(id: "project:\(project.id)", title: project.displayName, icon: .project(project)) {
                model.selectedProjectID = project.id
            }
        }
    }

    private var files: [PaletteItem] {
        guard let session = model.selectedSession else { return [] }
        return session.groups.flatMap(\.files).map { file in
            let badge = FileBadge(kind: file.kind)
            return PaletteItem(
                id: "file:\(file.id)", title: (file.path as NSString).lastPathComponent,
                subtitle: (file.path as NSString).deletingLastPathComponent, icon: .badge(badge.letter, badge.color)
            ) {
                model.mode = .changes
                session.selectedFileID = file.id
            }
        }
    }

    private var branches: [PaletteItem] {
        guard let session = model.selectedSession else { return [] }
        return session.history.groups.flatMap(\.branches).map { branch in
            PaletteItem(
                id: "branch:\(branch.name)", title: branch.name,
                subtitle: branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits",
                icon: .symbol("arrow.triangle.branch", .secondary)
            ) {
                model.mode = .history
                session.history.selection = .branch(branch.name)
            }
        }
    }

    private var commands: [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ title: String, _ symbol: String, _ shortcut: String? = nil, tint: Color = .secondary, action: @escaping () -> Void) {
            items.append(PaletteItem(id: "command:\(title)", title: title, icon: .symbol(symbol, tint), shortcut: shortcut, action: action))
        }
        let session = model.selectedSession

        if model.mode == .changes {
            add("Go to History", "clock") { model.mode = .history }
        } else {
            add("Go to Changes", "plusminus") { model.mode = .changes }
        }
        if session != nil {
            add("Refresh", "arrow.clockwise", "⌘R") { model.refreshSelected() }
        }
        if let diffFile, diffFile.exists {
            add("Open in Editor", "arrow.up.forward.square", "⌘O") { model.openInEditor(diffFile) }
        }
        if let diffPopout {
            add("Open Diff in New Window", "macwindow.badge.plus", "⌥⌘O") {
                openWindow(id: DiffWindow.id, value: model.register(diffPopout))
            }
        }
        if let diffFile {
            add("Copy File Path", "doc.on.clipboard", "⇧⌘C") { model.copyPath(diffFile) }
        }
        if let diffPrompt {
            for question in PromptQuestion.asked {
                add("\(AppSettings.openClaudeCodeTitle()): \(question.title(for: diffPrompt.scope))", "apple.terminal", question == .explain ? "⌥⌘E" : nil) {
                    claudeCode.open(diffPrompt.prompt(question), diffPrompt.root)
                }
            }
            add("Copy \(AppSettings.aiProvider().displayName) Prompt for \(diffPrompt.scope)", "doc.on.clipboard", "⌥⇧⌘C") { claudeCode.copy(diffPrompt.prompt(.none)) }
        }
        if layout == .unified {
            add("Show Side-by-Side Diff", "rectangle.split.2x1", "⌘\\") { layout = .split }
        } else {
            add("Show Unified Diff", "rectangle", "⌘\\") { layout = .unified }
        }
        if showsWholeFile {
            add("Show Changes Only", "rectangle.compress.vertical", "⇧⌘\\") { showsWholeFile = false }
        } else {
            add("Show Whole File", "rectangle.expand.vertical", "⇧⌘\\") { showsWholeFile = true }
        }
        add(isListHidden ? "Show File List" : "Hide File List", "sidebar.left", "⌘0") {
            withAnimation(.snappy) { isListHidden.toggle() }
        }
        if let remoteURL = session?.history.remoteURL {
            add("Open Repository on \(RemoteHost(remoteURL).name)", "arrow.up.right") { NSWorkspace.shared.open(remoteURL) }
        }
        if let project = model.selectedProject, project.exists {
            add("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
        }
        add("Add Project…", "plus", "⇧⌘O") { model.isImporterPresented = true }
        for option in AppAppearance.allCases where option != appearance {
            let symbol = switch option {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
            add("Use \(option.title) Appearance", symbol) { appearance = option }
        }
        add("Settings…", "gearshape", "⌘,") {
            // After the palette has closed, so returning focus to the main window cannot push Settings behind it.
            DispatchQueue.main.async { SettingsWindow.open() }
        }
        return items
    }
}

private struct PaletteSection: Identifiable {
    enum Kind: String {
        case projects = "Projects"
        case files = "Changed Files"
        case branches = "Branches"
        case commands = "Commands"
    }

    let kind: Kind
    let items: [PaletteItem]

    var id: Kind { kind }
    var title: String { kind.rawValue }
}

private struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String, Color)
        case badge(String, Color)
        case project(Project)
    }

    let id: String
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    /// Characters of `title` matched by the query, for bold highlighting.
    var indices: [Int] = []
    let action: () -> Void
}
