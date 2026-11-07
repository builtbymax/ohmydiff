import AppKit
import OhMyDiffCore
import SwiftUI

/// The ⌘K launcher. It opens with what you are looking at as context: the hunk, its branch and the view.
/// Every item previews what it does and the exact command it runs. `>` `@` `#` `/` `?` narrow it to
/// commands, files, branches and pull requests, projects, or a question for the AI.
struct CommandPalette: View {
    let model: AppModel

    @State private var query = ""
    @State private var scope = Scope.all
    @State private var highlighted = 0
    /// The item whose actions are shown after → .
    @State private var drilled: PaletteItem?
    @FocusState private var isSearchFocused: Bool
    @AppStorage("launcherRecent") private var recent = ""

    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .split
    @AppStorage(DiffSettings.wholeFileKey) private var showsWholeFile = false
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.isSidebarHiddenKey) private var isSidebarHidden = false
    @AppStorage(AppSettings.isHunkStripHiddenKey) private var isHunkStripHidden = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system
    @FocusedValue(\.diffFile) private var diffFile
    @FocusedValue(\.diffPopout) private var diffPopout
    @FocusedValue(\.diffPrompt) private var diffPrompt
    @FocusedValue(\.diffHunk) private var diffHunk
    @Environment(\.claudeCode) private var claudeCode
    @Environment(\.openWindow) private var openWindow

    enum Scope: CaseIterable {
        case all, commands, files, branches, projects, ai

        var title: String {
            switch self {
            case .all: "All"
            case .commands: "Commands"
            case .files: "Files"
            case .branches: "Branches & PRs"
            case .projects: "Projects"
            case .ai: "Ask AI"
            }
        }

        var prefix: Character? {
            switch self {
            case .all: nil
            case .commands: ">"
            case .files: "@"
            case .branches: "#"
            case .projects: "/"
            case .ai: "?"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            launcher
                .padding(.top, 110)
                .padding(.horizontal, 40)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
        .transition(.opacity)
    }

    private var launcher: some View {
        let sections = self.sections
        let items = sections.flatMap(\.items)
        let current = items.indices.contains(highlighted) ? items[highlighted] : nil
        return VStack(spacing: 0) {
            input
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            scopes
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                results(sections, items: items)
                    .frame(maxWidth: .infinity)
                if let current {
                    PalettePreview(item: current, model: model)
                        .frame(width: 300)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Theme.surface)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.lineSubtle).frame(width: 1) }
                }
            }
            .frame(height: 420)
            footer
        }
        .frame(maxWidth: 800)
        .background(Theme.raised, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.lineStrong))
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.raised)
                .shadow(color: Theme.popoverShadowNear, radius: 3, y: 2)
                .shadow(color: Theme.popoverShadowFar, radius: 24, y: 16)
        }
        .onAppear {
            // The field is not in the window yet while the launcher appears, so focusing it now is dropped.
            DispatchQueue.main.async { isSearchFocused = true }
        }
        .paletteKeys(
            up: { move(-1, count: items.count) }, down: { move(1, count: items.count) },
            choose: { current.map { run($0, keepOpen: false) } },
            dismiss: {
                if drilled != nil { drilled = nil } else { dismiss() }
            },
            right: {
                guard let current, !current.actions.isEmpty else { return false }
                drilled = current
                highlighted = 0
                return true
            },
            left: {
                guard drilled != nil else { return false }
                drilled = nil
                highlighted = 0
                return true
            },
            tab: {
                guard let edit = current?.edit else { return false }
                dismiss()
                edit()
                return true
            },
            chooseKeepingOpen: { current.map { run($0, keepOpen: true) } })
    }

    // MARK: Parts

    private var input: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18, height: 18)
            if let drilled {
                Chip(drilled.title, systemImage: "arrow.turn.down.right", isEmphasized: true)
            } else if let diffHunk, scope == .all || scope == .commands || scope == .ai {
                Chip("Hunk \(diffHunk.index + 1) · \(diffHunk.fileName)", systemImage: "doc", isEmphasized: true)
            }
            TextField("Type a command, or > @ # / ? to narrow", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .focused($isSearchFocused)
                .onChange(of: query) { _, text in
                    highlighted = 0
                    // A leading prefix picks its scope and is removed from the search.
                    if let first = text.first, let picked = Scope.allCases.first(where: { $0.prefix == first }), scope == .all {
                        scope = picked
                        query = String(text.dropFirst())
                    }
                }
                .onKeyPress(.delete) {
                    guard query.isEmpty, scope != .all else { return .ignored }
                    scope = .all
                    return .handled
                }
            KeyCap("esc")
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 56)
    }

    private var scopes: some View {
        HStack(spacing: 2) {
            ForEach(Scope.allCases, id: \.self) { item in
                Button {
                    scope = item
                    highlighted = 0
                    drilled = nil
                    isSearchFocused = true
                } label: {
                    HStack(spacing: 6) {
                        if item == .ai {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.infoFg)
                        }
                        Text(item.title)
                            .font(.control.weight(.medium))
                            .foregroundStyle(item == scope ? Theme.textPrimary : Theme.textSecondary)
                        if let prefix = item.prefix {
                            Text(String(prefix))
                                .font(.code(11.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(.hover(cornerRadius: 8, isSelected: item == scope))
                .focusEffectDisabled()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    @ViewBuilder
    private func results(_ sections: [PaletteSection], items: [PaletteItem]) -> some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                Text(scope == .ai && query.isEmpty ? "Type a question about this diff" : "No results for “\(query)”")
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Try a file, branch or project name, or type > for commands.")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.sectionLabel)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                            ForEach(section.items) { item in
                                let index = items.firstIndex { $0.id == item.id } ?? 0
                                Button {
                                    highlighted = index
                                    run(item, keepOpen: false)
                                } label: {
                                    PaletteRow(item: item, isHighlighted: index == highlighted)
                                }
                                .buttonStyle(.hover(cornerRadius: 9, isSelected: index == highlighted))
                                .focusEffectDisabled()
                                .onHover { if $0 { highlighted = index } }
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: highlighted) {
                    if items.indices.contains(highlighted) { proxy.scrollTo(items[highlighted].id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Move")
            hint("↩", "Run")
            hint("⌘↩", "Run, keep open")
            hint(drilled == nil ? "→" : "←", drilled == nil ? "Actions" : "Back")
            Spacer(minLength: 8)
            if !recentTitles.isEmpty {
                Text("Recent: " + recentTitles.joined(separator: " · "))
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(key)
            Text(title)
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Running

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func dismiss() {
        model.isSwitcherPresented = false
    }

    private func run(_ item: PaletteItem, keepOpen: Bool) {
        remember(item.title)
        if !keepOpen { dismiss() }
        item.action()
    }

    private var recentTitles: [String] {
        recent.split(separator: "\n").map(String.init)
    }

    private func remember(_ title: String) {
        var titles = recentTitles.filter { $0 != title }
        titles.insert(title, at: 0)
        recent = titles.prefix(3).joined(separator: "\n")
    }

    // MARK: Sections

    private var searchText: String { query.trimmingCharacters(in: .whitespaces) }

    private var sections: [PaletteSection] {
        if let drilled {
            return [PaletteSection(title: drilled.title, items: rank(drilled.actions))]
        }
        let text = searchText
        switch scope {
        case .all where text.isEmpty:
            return contextSections + [
                PaletteSection(title: "Projects", items: Array(projects.prefix(5))),
                PaletteSection(title: "Commands", items: commands),
            ].filter { !$0.items.isEmpty }
        case .all:
            return [
                PaletteSection(title: "Commands", items: Array(rank(contextSections.flatMap(\.items) + commands).prefix(8))),
                PaletteSection(title: "Files", items: Array(rank(files).prefix(6))),
                PaletteSection(title: "Branches & pull requests", items: Array(rank(branches).prefix(6))),
                PaletteSection(title: "Projects", items: Array(rank(projects).prefix(5))),
            ].filter { !$0.items.isEmpty }
        case .commands:
            return [PaletteSection(title: "Commands", items: rank(contextSections.flatMap(\.items) + commands))].filter { !$0.items.isEmpty }
        case .files:
            return [PaletteSection(title: "Changed files", items: rank(files))].filter { !$0.items.isEmpty }
        case .branches:
            return [PaletteSection(title: "Branches & pull requests", items: rank(branches))].filter { !$0.items.isEmpty }
        case .projects:
            return [PaletteSection(title: "Projects", items: rank(projects))].filter { !$0.items.isEmpty }
        case .ai:
            return [PaletteSection(title: diffPrompt.map { "About this \($0.scope.lowercased())" } ?? "Ask AI", items: askItems)]
                .filter { !$0.items.isEmpty }
        }
    }

    private func rank(_ items: [PaletteItem]) -> [PaletteItem] {
        let text = searchText
        guard !text.isEmpty else { return items }
        return FuzzyMatcher.rank(items, query: text) { $0.title }.map { result in
            var item = result.item
            item.indices = result.match.indices
            return item
        }
    }

    /// What can be done right here: with the hunk, with its branch, and with the view.
    private var contextSections: [PaletteSection] {
        var result: [PaletteSection] = []
        let session = model.selectedSession
        if let diffHunk, let session {
            var items: [PaletteItem] = []
            let isGitButler = session.project.kind == .gitButler
            let branch = session.assignedBranch(of: diffHunk.path) ?? session.currentBranch ?? session.branchNames.first
            let hunkID = "\(diffHunk.fileName):\(diffHunk.index + 1)"
            if let primary = diffHunk.actions.first(where: { $0 == .commit || $0 == .stage }) {
                let title = primary == .commit ? "Commit hunk" + (branch.map { " to \($0)" } ?? "") : "Stage hunk"
                items.append(PaletteItem(
                    id: "hunk:primary", title: title, icon: .symbol(primary.systemImage), shortcut: Shortcuts.label(.stageHunk).uppercased(),
                    preview: .command(
                        title: primary == .commit ? "Commit hunk" : "Stage hunk", branch: primary == .commit ? branch : nil,
                        pullRequest: branch.flatMap { pullRequest(of: $0, in: session) }, lines: diffHunk.hunk.lines,
                        message: session.commitDraft.hasMessage ? session.commitDraft.title : nil,
                        runs: primary == .commit
                            ? "but commit -b \(branch ?? "<branch>") -m \"…\" \(hunkID)"
                            : "git apply --cached  # hunk \(diffHunk.index + 1) of \(diffHunk.fileName)",
                        undo: isGitButler ? "Undo with but undo" : "Unstage with U"),
                    edit: { diffHunk.perform(primary) }
                ) { diffHunk.perform(primary) })
            }
            if diffHunk.actions.contains(.discard) {
                items.append(PaletteItem(
                    id: "hunk:discard", title: "Discard hunk", icon: .symbol("arrow.uturn.backward"), shortcut: Shortcuts.label(.discardHunk).uppercased(),
                    preview: .command(
                        title: "Discard hunk", branch: nil, pullRequest: nil, lines: diffHunk.hunk.lines, message: nil,
                        runs: isGitButler ? "but discard \(hunkID)" : "git apply -R  # hunk \(diffHunk.index + 1) of \(diffHunk.fileName)",
                        undo: isGitButler ? "Undo with but undo" : "Plain git cannot bring it back"))
                { diffHunk.perform(.discard) })
            }
            if let explain = diffHunk.explain {
                let lines = diffHunk.hunk.lines.count
                items.append(PaletteItem(
                    id: "hunk:explain", title: "Explain hunk", icon: .symbol("sparkles", Theme.infoFg), shortcut: Shortcuts.label(.explainHunk).uppercased(), isAI: true,
                    preview: .text(
                        title: "Explain hunk \(diffHunk.index + 1)",
                        detail: "Sends \(lines == 1 ? "1 line" : "\(lines) lines") of \(diffHunk.fileName) to \(AppSettings.aiProvider().displayName). Nothing else.")
                ) { explain() })
            }
            result.append(PaletteSection(title: "Hunk \(diffHunk.index + 1)", items: items))
        }
        if let session, let branch = contextBranch(in: session) {
            var items: [PaletteItem] = []
            let history = session.history
            if history.canPush(branch) {
                let count = branch.commits.count
                items.append(PaletteItem(
                    id: "branch:push", title: "Push", subtitle: count == 1 ? "1 commit" : "\(count) commits", icon: .symbol("arrow.up"),
                    shortcut: "⇧⌘P",
                    preview: .command(
                        title: branch.needsForcePush ? "Force push \(branch.name)" : "Push \(branch.name)", branch: branch.name,
                        pullRequest: history.pullRequest(of: branch), lines: nil, message: nil,
                        runs: session.project.kind == .gitButler ? "but push \(branch.name)" : "git push\(branch.needsForcePush ? " --force-with-lease" : "") origin \(branch.name)",
                        undo: nil)
                ) { history.requestPush(branch) })
            }
            if history.canOpenPullRequest(branch) {
                items.append(PaletteItem(
                    id: "branch:pr", title: "Draft PR description", icon: .symbol("sparkles", Theme.infoFg), isAI: true,
                    preview: .text(
                        title: "Draft PR description", detail: "Sends the commits and diff of \(branch.name) to \(AppSettings.aiProvider().displayName), then opens the draft.")
                ) {
                    model.mode = .branches
                    history.requestPullRequestDraft(branch)
                })
            }
            if !items.isEmpty { result.append(PaletteSection(title: "Branch \(branch.name)", items: items)) }
        }
        var view: [PaletteItem] = []
        if diffFile != nil {
            view.append(command("Switch to \(layout == .split ? "Unified" : "Split")", layout == .split ? "rectangle" : "rectangle.split.2x1", "⌘\\") {
                layout = layout == .split ? .unified : .split
            })
            view.append(command(showsWholeFile ? "Show changes only" : "Show full file", "arrow.up.and.line.horizontal.and.arrow.down", "⌥⌘F") {
                showsWholeFile.toggle()
            })
        }
        view.append(command(isListHidden ? "Show file list" : "Hide file list", isListHidden ? "eye" : "eye.slash", "⌘0") {
            withAnimation(.snappy) { isListHidden.toggle() }
        })
        result.append(PaletteSection(title: "View", items: view))
        return result
    }

    /// The branch of the hunk or selected file, else the checked-out one.
    private func contextBranch(in session: ProjectSession) -> HistoryBranch? {
        let name = diffHunk.flatMap { session.assignedBranch(of: $0.path) }
            ?? session.selectedFile.flatMap { session.assignedBranch(of: $0.path) }
            ?? session.currentBranch ?? session.branchNames.first
        guard let name else { return nil }
        return session.history.groups.lazy.flatMap(\.branches).first { $0.name == name }
    }

    private func pullRequest(of name: String, in session: ProjectSession) -> PullRequest? {
        session.history.groups.lazy.flatMap(\.branches).first { $0.name == name }.flatMap(session.history.pullRequest(of:))
    }

    private func command(_ title: String, _ symbol: String, _ shortcut: String? = nil, action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(id: "command:\(title)", title: title, icon: .symbol(symbol), shortcut: shortcut, action: action)
    }

    /// Projects of the shown workspace first, then the others; picking one of another workspace switches to it.
    private var projects: [PaletteItem] {
        let visible = model.visibleProjects
        let others = model.workspaces.filter { $0.id != model.selectedWorkspaceID }.flatMap { model.projects(in: $0.id) }
        return (visible + others).map { project in
            PaletteItem(
                id: "project:\(project.id)", title: project.displayName, icon: .project(project), preview: .project(project),
                actions: [
                    PaletteItem(id: "project:\(project.id):open", title: "Open \(project.displayName)", icon: .symbol("arrow.right")) {
                        model.selectedProjectID = project.id
                    },
                    PaletteItem(id: "project:\(project.id):finder", title: "Show in Finder", icon: .symbol("folder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                    },
                    PaletteItem(id: "project:\(project.id):remove", title: "Remove from ohmydiff", icon: .symbol("minus.circle")) {
                        model.remove(project.id)
                    },
                ]
            ) { model.selectedProjectID = project.id }
        }
    }

    private var files: [PaletteItem] {
        guard let session = model.selectedSession else { return [] }
        return session.groups.flatMap(\.files).map { file in
            let open = {
                model.mode = .branches
                session.reviewUncommitted()
                session.selectedFileID = file.id
            }
            let target = DiffFileTarget(url: session.rootURL.appending(path: file.path), relativePath: file.path, line: nil)
            var actions = [
                PaletteItem(id: "file:\(file.id):show", title: "Show diff", icon: .symbol("doc.text"), action: open),
                PaletteItem(id: "file:\(file.id):editor", title: "Open in editor", icon: .symbol("arrow.up.forward.square"), shortcut: "⌘O") {
                    model.openInEditor(target)
                },
                PaletteItem(id: "file:\(file.id):copy", title: "Copy path", icon: .symbol("doc.on.doc")) { model.copyPath(target) },
            ]
            if session.supports(.discard, on: [ChangeTarget(file: file)]) {
                actions.append(PaletteItem(id: "file:\(file.id):discard", title: "Discard changes…", icon: .symbol("arrow.uturn.backward")) {
                    session.request(.discard, on: [ChangeTarget(file: file)])
                })
            }
            return PaletteItem(
                id: "file:\(file.id)", title: (file.path as NSString).lastPathComponent,
                subtitle: (file.path as NSString).deletingLastPathComponent, icon: .badge(FileBadge(kind: file.kind).letter, Theme.changeColor(file.kind)),
                preview: .file(file), actions: actions, action: open)
        }
    }

    private var branches: [PaletteItem] {
        guard let session = model.selectedSession else { return [] }
        let history = session.history
        return history.groups.flatMap(\.branches).map { branch in
            let pullRequest = history.pullRequest(of: branch)
            var actions = [
                PaletteItem(id: "branch:\(branch.name):show", title: "Show in Branches", icon: .symbol("arrow.triangle.branch")) {
                    model.mode = .branches
                    history.selection = .branch(branch.name)
                },
                PaletteItem(id: "branch:\(branch.name):history", title: "Show history", icon: .symbol("clock.arrow.circlepath")) {
                    model.mode = .history
                    session.log.filter = .branch(branch.name)
                },
            ]
            if history.canPush(branch) {
                actions.append(PaletteItem(id: "branch:\(branch.name):push", title: "Push", icon: .symbol("arrow.up")) { history.requestPush(branch) })
            }
            if let pullRequest {
                actions.append(PaletteItem(id: "branch:\(branch.name):pr", title: "Open #\(pullRequest.number) on GitHub", icon: .symbol("arrow.up.forward.square")) {
                    NSWorkspace.shared.open(pullRequest.url)
                })
            }
            return PaletteItem(
                id: "branch:\(branch.name)", title: branch.name,
                subtitle: pullRequest.map { "#\($0.number)" } ?? (branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits"),
                icon: .symbol(pullRequest == nil ? "arrow.triangle.branch" : "arrow.triangle.pull"),
                preview: .branch(branch), actions: actions
            ) {
                model.mode = .branches
                history.selection = .branch(branch.name)
            }
        }
    }

    /// The questions for Claude Code about the hunk or selection, and the one typed in.
    private var askItems: [PaletteItem] {
        guard let diffPrompt else { return [] }
        var items: [PaletteItem] = []
        let provider = AppSettings.aiProvider().displayName
        let text = searchText
        if !text.isEmpty {
            items.append(PaletteItem(
                id: "ask:custom", title: "Ask “\(text)”", icon: .symbol("sparkles", Theme.infoFg), isAI: true,
                preview: .text(title: "Ask \(provider)", detail: "Starts \(provider) with your question and the \(diffPrompt.scope.lowercased()) as context.")
            ) { claudeCode.open(text + "\n\n" + diffPrompt.prompt(.none), diffPrompt.root) })
        }
        for question in PromptQuestion.asked {
            items.append(PaletteItem(
                id: "ask:\(question.rawValue)", title: question.title(for: diffPrompt.scope), icon: .symbol("sparkles", Theme.infoFg), isAI: true,
                preview: .text(title: question.title(for: diffPrompt.scope), detail: "Starts \(provider) in the terminal with the \(diffPrompt.scope.lowercased()) as context.")
            ) { claudeCode.open(diffPrompt.prompt(question), diffPrompt.root) })
        }
        items.append(PaletteItem(id: "ask:copy", title: "Copy \(diffPrompt.scope.lowercased()) as context", icon: .symbol("doc.on.clipboard"), shortcut: "⌥⇧⌘C") {
            claudeCode.copy(diffPrompt.prompt(.none))
        })
        return items
    }

    private var commands: [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ title: String, _ symbol: String, _ shortcut: String? = nil, action: @escaping () -> Void) {
            items.append(command(title, symbol, shortcut, action: action))
        }
        let session = model.selectedSession

        for page in WorkspaceMode.available where page != model.mode {
            add("Go to \(page.title)", page.systemImage, Shortcuts.label(page.shortcutAction)) { model.open(page) }
        }
        add("Switch project…", "chevron.up.chevron.down", "⌘P") { model.isProjectMenuPresented = true }
        if let session {
            add("Refresh", "arrow.clockwise", "⌘R") { model.refreshSelected() }
            add("Fetch from remote", "arrow.down", "⇧⌘F") { Task { await session.fetch() } }
            let gone = session.history.goneBranches
            if !gone.isEmpty {
                add("Delete \(gone.count == 1 ? "1 merged branch" : "\(gone.count) merged branches")…", "trash") {
                    model.mode = .branches
                    session.history.pendingDeletion = gone
                }
            }
            if session.upstream?.hasUpdates == true {
                add(session.project.kind == .gitButler ? "Update workspace…" : "Update branches…", "arrow.down.circle", "⇧⌘U") {
                    model.isUpstreamUpdatePresented = true
                }
            }
        }
        if let diffFile, diffFile.exists {
            add("Open in editor", "arrow.up.forward.square", "⌘O") { model.openInEditor(diffFile) }
        }
        if let diffPopout {
            add("Open diff in new window", "macwindow.badge.plus", "⌥⌘O") {
                openWindow(id: DiffWindow.id, value: model.register(diffPopout))
            }
        }
        if let diffFile {
            add("Copy file path", "doc.on.clipboard", "⇧⌘C") { model.copyPath(diffFile) }
        }
        add(isSidebarHidden ? "Show sidebar" : "Hide sidebar", "sidebar.left", "⌃⌘S") {
            withAnimation(.snappy(duration: 0.2)) { isSidebarHidden.toggle() }
        }
        add(isHunkStripHidden ? "Show hunk strip" : "Hide hunk strip", isHunkStripHidden ? "eye" : "eye.slash") { isHunkStripHidden.toggle() }
        if let remoteURL = session?.history.remoteURL {
            add("Open repository on \(RemoteHost(remoteURL).name)", "arrow.up.right") { NSWorkspace.shared.open(remoteURL) }
        }
        if let project = model.selectedProject, project.exists {
            add("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
        }
        add("Add project…", "plus", "⇧⌘O") { model.isImporterPresented = true }
        for workspace in model.workspaces where workspace.id != model.selectedWorkspaceID {
            add("Switch to \(workspace.name)", "square.grid.2x2") { model.selectWorkspace(workspace.id) }
        }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        add(isDark ? "Use Paper theme" : "Use Graphite theme", isDark ? "sun.max" : "moon", "⌥⌘T") { appearance = isDark ? .light : .dark }
        if Updater.shared.canCheck {
            add("Check for updates…", "arrow.clockwise") { Updater.shared.checkForUpdates() }
        }
        add("Settings…", "slider.horizontal.3", "⌘,") {
            // After the launcher has closed, so returning focus to the main window cannot push Settings behind it.
            DispatchQueue.main.async { SettingsWindow.open() }
        }
        return items
    }
}

private struct PaletteSection: Identifiable {
    let title: String
    let items: [PaletteItem]

    var id: String { title }
}

struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String, Color? = nil)
        case badge(String, Color)
        case project(Project)
    }

    /// What the preview pane shows for the item.
    enum Preview {
        case command(title: String, branch: String?, pullRequest: PullRequest?, lines: [DiffLine]?, message: String?, runs: String?, undo: String?)
        case text(title: String, detail: String)
        case file(ChangedFile)
        case branch(HistoryBranch)
        case project(Project)
    }

    let id: String
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    /// Sends something to the AI provider; marked with an AI chip.
    var isAI = false
    var preview: Preview?
    /// What → shows for the item.
    var actions: [PaletteItem] = []
    /// What Tab does, e.g. editing a commit before it runs.
    var edit: (() -> Void)?
    /// Characters of `title` matched by the query, for bold highlighting.
    var indices: [Int] = []
    let action: () -> Void
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
            // One weight, so the row does not reflow as the highlight follows the pointer.
            Text(highlightedTitle)
                .font(.row)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if item.isAI {
                Chip("AI", systemImage: "sparkles", tone: .info)
            }
            if !item.actions.isEmpty, isHighlighted {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let shortcut = item.shortcut { KeyCap(shortcut) }
            if isHighlighted {
                Image(systemName: "return")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 13)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(tint ?? Theme.textSecondary)
                .frame(width: 15, height: 15)
        case .badge(let letter, let color):
            Text(letter)
                .font(.statusLetter)
                .foregroundStyle(color)
                .frame(width: 15, height: 15)
        case .project(let project):
            ProjectAvatar(name: project.displayName, size: 18)
        }
    }

    private var highlightedTitle: AttributedString {
        var result = AttributedString()
        let matched = Set(item.indices)
        for (offset, character) in item.title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        return result
    }
}

/// The right side of the launcher: what the highlighted item does, on what, and the command it runs.
private struct PalettePreview: View {
    let item: PaletteItem
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch item.preview {
            case .command(let title, let branch, let pullRequest, let lines, let message, let runs, let undo):
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let branch {
                    HStack(spacing: 6) {
                        Text("to")
                            .font(.detail)
                            .foregroundStyle(Theme.textTertiary)
                        Chip(branch, systemImage: "arrow.triangle.branch", isEmphasized: true)
                        if let pullRequest {
                            Chip("#\(pullRequest.number)", systemImage: "arrow.triangle.pull", tone: .ok)
                        }
                    }
                }
                if let lines {
                    MiniDiff(lines: lines)
                }
                if let message {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.infoFg)
                            Text("Message")
                                .font(.caption11)
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Text("Tab to edit")
                                .font(.caption11)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(message)
                            .font(.control)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.hover, in: .rect(cornerRadius: 9))
                }
                Spacer(minLength: 0)
                if let runs {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Runs")
                            .font(.sectionLabel)
                            .foregroundStyle(Theme.textTertiary)
                        Text(runs)
                            .font(.code(11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let undo {
                            Text(undo)
                                .font(.caption11)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            case .text(let title, let detail):
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .file(let file):
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(file.path)
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                if let stats = file.stats { LineStatsLabel(stats: stats, font: .code(11.5)) }
                if let lines = model.selectedSession?.diff.flatMap({ state -> [DiffLine]? in
                    guard state.fileID == file.id, case .diff(let diff) = state.content else { return nil }
                    return diff.hunks.first?.lines
                }) {
                    MiniDiff(lines: lines)
                }
                Spacer(minLength: 0)
                Text("→ for actions")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            case .branch(let branch):
                Text(branch.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(branch.commits.prefix(6)) { commit in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.textTertiary).frame(width: 5, height: 5)
                        Text(commit.summary)
                            .font(.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(commit.shortSHA)
                            .font(.code(10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if branch.commits.isEmpty {
                    Text("No commits of its own yet")
                        .font(.detail)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            case .project(let project):
                HStack(spacing: 10) {
                    ProjectAvatar(name: project.displayName, isCurrent: project.id == model.selectedProjectID)
                    Text(project.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    KindChip(kind: project.kind)
                }
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
                if let workspace = model.workspace(of: project) {
                    Text(workspace.name)
                        .font(.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            case nil:
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let shortcut = item.shortcut {
                    HStack(spacing: 6) {
                        Text("Shortcut")
                            .font(.detail)
                            .foregroundStyle(Theme.textTertiary)
                        KeyCap(shortcut)
                    }
                }
            }
        }
        .padding(16)
        // Short previews start at the top left instead of floating in the middle of the column.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A few changed lines of a hunk, in the diff colours.
private struct MiniDiff: View {
    let lines: [DiffLine]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text((line.kind == .addition ? "+ " : line.kind == .deletion ? "− " : "  ") + line.text.trimmingCharacters(in: .whitespaces))
                    .font(.code(11.5))
                    .foregroundStyle(line.kind == .addition ? Theme.addFg : line.kind == .deletion ? Theme.delFg : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(line.kind == .addition ? Theme.addBg : line.kind == .deletion ? Theme.delBg : .clear)
            }
        }
        .clipShape(.rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.lineSubtle))
    }

    /// The first change with a line of context before it.
    private var shown: [DiffLine] {
        guard let first = lines.firstIndex(where: { $0.kind != .context }) else { return Array(lines.prefix(3)) }
        let start = max(first - 1, 0)
        return Array(lines[start..<min(start + 5, lines.count)])
    }
}
