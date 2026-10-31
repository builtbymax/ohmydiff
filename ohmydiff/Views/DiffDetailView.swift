import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The detail pane in Changes mode: the selected file's diff.
struct DiffDetailView: View {
    let session: ProjectSession
    @AppStorage(AppSettings.showsWhitespaceChangesKey) private var showsWhitespaceChanges = true

    var body: some View {
        diffBody
            .onChange(of: showsWhitespaceChanges) { session.reloadDiff() }
    }

    @ViewBuilder
    private var diffBody: some View {
        if let state = session.diff, let file = session.selectedFile {
            content(state.content, file: file)
        } else if session.phase == .ready && session.changeCount == 0 {
            EmptyState("No Changes", systemImage: "checkmark.circle")
        } else {
            EmptyState("No Selection", systemImage: "text.alignleft")
        }
    }

    @ViewBuilder
    private func content(_ content: ProjectSession.DiffState.Content, file: ChangedFile) -> some View {
        switch content {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noDifference:
            EmptyState("No Differences", systemImage: "equal", description: "\(file.path) matches the last commit.")
        case .failed(let message):
            EmptyState("Could Not Load Diff", systemImage: "exclamationmark.triangle", description: message) {
                Button("Try Again") { session.refresh() }
            }
        case .diff(let diff):
            FileDiffView(
                fileID: file.id, diff: diff, highlights: session.diff?.highlights, root: session.rootURL,
                popout: .change(projectID: session.project.id, path: file.path),
                promptContext: session.promptContext(forPath: file.path),
                reveal: session.fileReveal?.fileID == file.id ? session.fileReveal : nil,
                contents: { side in await session.contents(of: file, side: side) },
                hunkActions: session.diff?.ignoresWhitespace == true ? [] : ChangeAction.allCases.filter { action in
                    diff.hunks.first.map { session.supports(action, on: [ChangeTarget(file: file, hunk: $0)]) } ?? false
                },
                onHunkAction: { action, hunk in
                    guard diff.hunks.indices.contains(hunk) else { return }
                    session.request(action, on: [ChangeTarget(file: file, hunk: diff.hunks[hunk])])
                },
                confirmingHunk: confirmingHunk(in: diff))
        }
    }

    /// The hunk of this diff that a discard confirmation or the commit sheet is open for.
    private func confirmingHunk(in diff: FileDiff) -> HunkTarget? {
        guard let request = session.actionRequest, request.targets.count == 1,
              let hunk = request.targets.first?.hunk, let index = diff.hunks.firstIndex(of: hunk)
        else { return nil }
        return HunkTarget(index: index, isDestructive: request.action == .discard)
    }
}

/// One file's diff with its header: the table, or a placeholder for binary, empty and collapsed large diffs.
struct FileDiffView: View {
    /// Identifies the file across reloads, e.g. to keep a revealed large diff open.
    let fileID: String
    let diff: FileDiff
    let highlights: SyntaxHighlights?
    /// The repository root, to locate the file in the working tree.
    let root: URL
    /// What Open Diff in New Window shows; `nil` inside a diff window.
    var popout: DiffPopout? = nil
    /// What prompts to Claude Code say about this diff; `nil` leaves out the Claude Code actions.
    var promptContext: PromptContext? = nil
    /// A line to scroll to, e.g. from `ohmydiff show`.
    var reveal: FileReveal? = nil
    /// One side's contents, for image previews and the whole-file view.
    let contents: (Repository.FileSide) async -> Data?
    /// Actions in each hunk's context menu and the hunk bar; none in History mode.
    var hunkActions: [ChangeAction] = []
    var onHunkAction: (ChangeAction, Int) -> Void = { _, _ in }
    /// The hunk an open confirmation acts on, highlighted until it closes.
    var confirmingHunk: HunkTarget? = nil

    @AppStorage(DiffSettings.layoutKey) private var preferredLayout: DiffLayoutMode = .split
    @AppStorage(AppSettings.isHunkStripHiddenKey) private var isHunkStripHidden = false
    @AppStorage(AppSettings.showsLineNumbersKey) private var showsLineNumbers = true
    @AppStorage(AppSettings.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(AppSettings.showsSyntaxColorsKey) private var showsSyntaxColors = true
    @State private var isViewMenuShown = false
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(DiffMetrics.defaultFontSize)
    @AppStorage(DiffSettings.wholeFileKey) private var prefersWholeFile = false
    @AppStorage(AppSettings.lightCodeThemeKey) private var lightTheme = CodeTheme.default.rawValue
    @AppStorage(AppSettings.darkCodeThemeKey) private var darkTheme = CodeTheme.default.rawValue
    /// The diff expanded to the whole file, once loaded; `source` is the diff it was expanded from.
    @State private var wholeFile: (source: FileDiff, diff: FileDiff, highlights: SyntaxHighlights?)?
    /// Large diffs the user chose to show anyway.
    @State private var revealedFiles: Set<String> = []
    @State private var focusLine: Int?
    /// The hunk at the top of the visible rows, for the hunk bar.
    @State private var visibleHunk: Int?
    /// The hunk bar action under the pointer; its hunk is highlighted.
    @State private var hoveredAction: ChangeAction?
    /// Lines of the selected rows in the shown diff.
    @State private var selectedLines: [DiffPosition] = []
    @Environment(\.claudeCode) private var claudeCode

    var body: some View {
        VStack(spacing: 0) {
            FileHeader(
                diff: diff, root: root, layout: $preferredLayout,
                showsWholeFile: DiffSettings.canShowWholeFile(diff) ? $prefersWholeFile : nil,
                isViewMenuShown: $isViewMenuShown)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            if showsTable, !isHunkStripHidden, !diff.hunks.isEmpty {
                HunkStrip(hunks: diff.hunks, current: visibleHunk ?? 0)
                Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .overlay(alignment: .bottom) {
            if showsTable, !diff.hunks.isEmpty {
                HunkBar(
                    hunks: diff.hunks, current: visibleHunk ?? 0, actions: hunkActions,
                    onExplain: promptTarget == nil ? nil : { explain(visibleHunk ?? 0) },
                    onHoverAction: { hoveredAction = $0 }
                ) { action in
                    hoveredAction = nil
                    onHunkAction(action, visibleHunk ?? 0)
                }
                .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isViewMenuShown {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)
                        .onTapGesture { isViewMenuShown = false }
                    ViewMenu(dismiss: { isViewMenuShown = false })
                        .padding(.top, 44)
                        .padding(.trailing, 8)
                        .popoverTransition(anchor: .topTrailing)
                }
            }
        }
        .animation(Theme.popoverAnimation, value: isViewMenuShown)
        .focusedSceneValue(\.diffFile, DiffFileTarget(
            url: root.appending(path: diff.path), relativePath: diff.path, line: focusLine))
        .focusedSceneValue(\.diffPopout, popout)
        .focusedSceneValue(\.diffPrompt, promptTarget)
        .focusedSceneValue(\.diffHunk, hunkContext)
        .task(id: prefersWholeFile && DiffSettings.canShowWholeFile(diff) ? diff : nil) {
            guard prefersWholeFile, DiffSettings.canShowWholeFile(diff), wholeFile?.source != diff else { return }
            let old = await contents(.old)
            let new = await contents(.new)
            guard !Task.isCancelled, let expanded = await DiffHighlighting.wholeFile(for: diff, old: old, new: new),
                  !Task.isCancelled
            else { return }
            wholeFile = (diff, expanded.diff, expanded.highlights)
        }
    }

    private var hunkContext: DiffHunkContext? {
        guard showsTable, !diff.hunks.isEmpty else { return nil }
        let index = min(visibleHunk ?? 0, diff.hunks.count - 1)
        return DiffHunkContext(
            path: diff.path, index: index, hunk: diff.hunks[index], count: diff.hunks.count, actions: hunkActions,
            perform: { action in onHunkAction(action, index) },
            explain: promptTarget == nil ? nil : { explain(index) })
    }

    /// Asks the AI provider to explain a hunk in Claude Code.
    private func explain(_ hunk: Int) {
        guard let promptContext, diff.hunks.indices.contains(hunk) else { return }
        let positions = diff.hunks[hunk].lines.indices.map { DiffPosition(hunk: hunk, line: $0) }
        askClaude(ClaudeRequest(kind: .open, question: .explain, positions: positions))
        _ = promptContext
    }

    /// The hunk to highlight: the one a hovered hunk bar action would act on, else an open confirmation's.
    private var targetedHunk: HunkTarget? {
        if let hoveredAction { return HunkTarget(index: visibleHunk ?? 0, isDestructive: hoveredAction == .discard) }
        return confirmingHunk
    }

    /// Asks Claude Code about the selected lines, else about the hunk at the top of the diff.
    private var promptTarget: DiffPromptTarget? {
        guard let promptContext, showsTable else { return nil }
        let shown = shownWholeFile?.diff ?? diff
        return DiffPromptTarget(
            root: root, context: promptContext, diff: shown, selection: selectedLines,
            hunk: min(visibleHunk ?? 0, shown.hunks.count - 1))
    }

    private var askClaudeAction: ((ClaudeRequest) -> Void)? {
        promptContext == nil ? nil : { request in askClaude(request) }
    }

    private func askClaude(_ request: ClaudeRequest) {
        guard let promptContext else { return }
        let prompt = ClaudePrompt.make(
            question: request.question, context: promptContext, diff: shownWholeFile?.diff ?? diff, positions: request.positions)
        switch request.kind {
        case .open: claudeCode.open(prompt, root)
        case .copy: claudeCode.copy(prompt)
        }
    }

    /// The whole file when it is wanted and loaded for the current diff.
    private var shownWholeFile: (diff: FileDiff, highlights: SyntaxHighlights?)? {
        guard prefersWholeFile, let wholeFile, wholeFile.source == diff else { return nil }
        return (wholeFile.diff, wholeFile.highlights)
    }

    /// Whether the diff rows are shown, rather than a placeholder.
    private var showsTable: Bool {
        !diff.isBinary && !diff.hunks.isEmpty && (!DiffSettings.isLarge(diff) || revealedFiles.contains(fileID))
    }

    @ViewBuilder
    private var content: some View {
        if diff.isBinary, DiffSettings.isImage(diff.path) {
            ImageDiffView(fileID: fileID, contents: contents)
        } else if diff.isBinary {
            EmptyState("Binary file", systemImage: "doc.zipper", description: "Binary changes can’t be shown as text.")
        } else if diff.hunks.isEmpty {
            EmptyState(
                diff.isModeChange ? "Mode changed" : "Empty file", systemImage: "doc",
                description: diff.isModeChange ? "\(diff.oldMode ?? "") → \(diff.newMode ?? "")" : "The file has no content.")
        } else if DiffSettings.isLarge(diff), !revealedFiles.contains(fileID) {
            EmptyState("Large Diff", systemImage: "doc.text.magnifyingglass", description: "\(diff.additions + diff.deletions) changed lines are hidden to keep things fast.") {
                Button("Show Diff") { revealedFiles.insert(fileID) }
                    .buttonStyle(.pill(.prominent))
            }
        } else {
            GeometryReader { proxy in
                // Side by side needs room for two readable columns.
                let mode: DiffLayoutMode = preferredLayout == .split && proxy.size.width >= DiffSettings.minimumSplitWidth ? .split : .unified
                let wholeFile = shownWholeFile
                DiffTableView(
                    fileID: fileID, diff: wholeFile?.diff ?? diff,
                    highlights: showsSyntaxColors ? wholeFile.map(\.highlights) ?? highlights : nil, mode: mode,
                    fontSize: CGFloat(fontSize.clamped(to: AppSettings.fontSizes)),
                    theme: SyntaxTheme(light: CodeTheme.resolved(lightTheme, isDark: false), dark: CodeTheme.resolved(darkTheme, isDark: true)),
                    isWholeFile: wholeFile != nil,
                    showsLineNumbers: showsLineNumbers,
                    wrapsLines: wrapsLines,
                    bottomInset: Theme.hunkBarInset,
                    onFocusLine: { line in
                        if line != focusLine { focusLine = line }
                    },
                    onVisibleHunk: { hunk in
                        if hunk != visibleHunk { visibleHunk = hunk }
                    },
                    hunkActions: hunkActions, onHunkAction: onHunkAction,
                    targetedHunk: targetedHunk,
                    onSelectLines: { lines in
                        if lines != selectedLines { selectedLines = lines }
                    },
                    onAskClaude: askClaudeAction,
                    reveal: reveal,
                    currentHunk: visibleHunk,
                    onExplainHunk: promptContext == nil || wholeFile != nil ? nil : { explain($0) },
                    onExpand: DiffSettings.canShowWholeFile(diff) ? { prefersWholeFile = true } : nil)
            }
        }
    }
}

enum DiffSettings {
    static let layoutKey = "diffLayout"
    static let wholeFileKey = "diffWholeFile"
    /// Split cells wrap long lines, so two columns stay readable down to about this width.
    static let minimumSplitWidth: CGFloat = 480
    /// Diffs with more changed lines than this start collapsed.
    static let largeDiffLineCount = 25_000

    static func isLarge(_ diff: FileDiff) -> Bool {
        diff.hunks.reduce(0) { $0 + $1.lines.count } > largeDiffLineCount
    }

    /// Whether the diff leaves out unchanged lines that the whole-file view would add; added and
    /// deleted files are shown whole already.
    static func canShowWholeFile(_ diff: FileDiff) -> Bool {
        !diff.isBinary && !diff.hunks.isEmpty && ![.added, .deleted, .untracked].contains(diff.kind) && !isLarge(diff)
    }

    static func isImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }
}

/// `M  Views / DiffDetailView.swift ⧉ +24 −8` with the layout and scope switches, Open in Editor and the
/// View menu.
private struct FileHeader: View {
    let diff: FileDiff
    let root: URL
    @Binding var layout: DiffLayoutMode
    /// The Changes / Full file switch; `nil` when the file is shown whole anyway.
    let showsWholeFile: Binding<Bool>?
    @Binding var isViewMenuShown: Bool
    @FocusedValue(\.diffFile) private var diffFile
    @Environment(\.openEditor) private var openEditor

    var body: some View {
        HStack(spacing: 8) {
            Text(FileBadge(kind: diff.kind).letter)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.changeColor(diff.kind))
            HStack(spacing: 4) {
                if !directory.isEmpty {
                    Text("\(directory) /")
                        .foregroundStyle(Theme.textTertiary)
                        .truncationMode(.head)
                }
                Text(name)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textPrimary)
                    .layoutPriority(1)
            }
            .font(.row)
            .lineLimit(1)
            .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diff.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .glassTooltip("Copy Path  ⇧⌘C")
            if diff.isModeChange, !diff.hunks.isEmpty {
                Text("\(diff.oldMode ?? "") → \(diff.newMode ?? "")")
                    .font(.code(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            LineStatsLabel(stats: LineStats(additions: diff.additions, deletions: diff.deletions), font: .code(11.5))
            Spacer(minLength: 8)
            Segmented(
                selection: $layout, options: [(.split, "Split"), (.unified, "Unified")],
                systemImages: [.split: "rectangle.split.2x1", .unified: "rectangle"])
            Segmented(
                selection: Binding(get: { showsWholeFile?.wrappedValue ?? true }, set: { showsWholeFile?.wrappedValue = $0 }),
                options: [(false, "Changes"), (true, "Full file")],
                systemImages: [false: "arrow.down.and.line.horizontal.and.arrow.up", true: "arrow.up.and.line.horizontal.and.arrow.down"],
                disabled: showsWholeFile == nil ? [false] : [])
            if let diffFile {
                IconButton("Open in Editor  ⌘O", systemImage: "arrow.up.forward.square") { openEditor(diffFile) }
                    .disabled(!diffFile.exists)
            }
            IconButton("View  ⋯", systemImage: "ellipsis", isSelected: isViewMenuShown) { isViewMenuShown.toggle() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 46)
    }

    private var directory: String {
        if let oldPath = diff.oldPath, let newPath = diff.newPath, oldPath != newPath { return "from \(oldPath)" }
        return (diff.path as NSString).deletingLastPathComponent.replacingOccurrences(of: "/", with: " / ")
    }

    private var name: String { (diff.path as NSString).lastPathComponent }
}

/// `3 hunks  [1 +18 −6] [2 +1 −1 •] [3 +5 −1]   ▬ ▪ ▬  p n`: every hunk at its size, the file map, and the keys.
private struct HunkStrip: View {
    let hunks: [Hunk]
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(hunks.count == 1 ? "1 hunk" : "\(hunks.count) hunks")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .padding(.trailing, 4)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                        pill(index, hunk)
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            FileMap(hunks: hunks, current: current)
                .frame(width: 120, height: 6)
                .padding(.trailing, 8)
            KeyCap("p")
            KeyCap("n")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func pill(_ index: Int, _ hunk: Hunk) -> some View {
        let isCurrent = index == min(current, hunks.count - 1)
        let added = hunk.lines.lazy.filter { $0.kind == .addition }.count
        let deleted = hunk.lines.lazy.filter { $0.kind == .deletion }.count
        return Button {
            NotificationCenter.default.post(name: .jumpToHunkIndex, object: index)
        } label: {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption11.weight(.medium))
                    .foregroundStyle(isCurrent ? Theme.textPrimary : Theme.textTertiary)
                LineStatsLabel(stats: LineStats(additions: added, deletions: deleted))
                if hunk.isOneLineChange {
                    Circle().fill(Theme.warnFg).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(isCurrent ? Theme.raised : .clear, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isCurrent ? Theme.lineStrong : Theme.lineSubtle))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glassTooltip(hunk.section.trimmingCharacters(in: .whitespaces).isEmpty ? "Hunk \(index + 1)" : hunk.section.trimmingCharacters(in: .whitespaces))
    }
}

/// Where the hunks sit in the file, each mark as wide as its hunk; the current one stands out and
/// one-line hunks are amber.
private struct FileMap: View {
    let hunks: [Hunk]
    let current: Int

    var body: some View {
        GeometryReader { proxy in
            let total = CGFloat(max(hunks.map { $0.newStart + $0.newCount }.max() ?? 1, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.hover)
                ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                    let x = CGFloat(hunk.newStart) / total * proxy.size.width
                    let width = max(CGFloat(max(hunk.newCount, hunk.oldCount)) / total * proxy.size.width, hunk.isOneLineChange ? 3 : 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(index, hunk))
                        .frame(width: min(width, 24), height: 6)
                        .offset(x: min(x, proxy.size.width - min(width, 24)))
                        .onTapGesture { NotificationCenter.default.post(name: .jumpToHunkIndex, object: index) }
                }
            }
        }
    }

    private func color(_ index: Int, _ hunk: Hunk) -> Color {
        if hunk.isOneLineChange { return Theme.warnFg }
        return index == current ? Theme.textSecondary : Theme.textTertiary
    }
}

/// The floating bar over the diff: which hunk, its actions with their keys, and moving between hunks.
private struct HunkBar: View {
    let hunks: [Hunk]
    let current: Int
    let actions: [ChangeAction]
    let onExplain: (() -> Void)?
    /// The action under the pointer, or `nil` once it leaves.
    let onHoverAction: (ChangeAction?) -> Void
    let perform: (ChangeAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("Hunk \(min(current, hunks.count - 1) + 1) of \(hunks.count)")
                .font(.detail.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .padding(.trailing, 6)
            if !actions.isEmpty || onExplain != nil {
                divider
            }
            if let primary = actions.first(where: { $0 == .commit || $0 == .stage }) ?? actions.first(where: { $0 == .unstage }) {
                action(primary, title: Self.title(for: primary), key: primary == .unstage ? "U" : "S", isPrimary: true)
            }
            if actions.contains(.unstage), actions.contains(where: { $0 == .stage || $0 == .commit }) {
                action(.unstage, title: "Unstage", key: "U", isPrimary: false)
            }
            if actions.contains(.discard) {
                action(.discard, title: "Discard", key: "⌫", isPrimary: false)
            }
            if let onExplain {
                Button(action: onExplain) {
                    label("Explain", systemImage: "sparkles", key: "E", isPrimary: false)
                }
                .buttonStyle(.hover(cornerRadius: 8))
                .focusEffectDisabled()
            }
            divider
            IconButton("Previous Hunk  P", systemImage: "chevron.up", tooltipEdge: .top) {
                NotificationCenter.default.post(name: .jumpToHunk, object: -1)
            }
            IconButton("Next Hunk  N", systemImage: "chevron.down", tooltipEdge: .top) {
                NotificationCenter.default.post(name: .jumpToHunk, object: 1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
        .fixedSize()
        .floatingBar(in: .rect(cornerRadius: 12))
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 18)
    }

    private func action(_ action: ChangeAction, title: String, key: String, isPrimary: Bool) -> some View {
        Button { perform(action) } label: {
            label(title, systemImage: action.systemImage, key: key, isPrimary: isPrimary)
        }
        .buttonStyle(.hover(cornerRadius: 8))
        .focusEffectDisabled()
        .onHover { onHoverAction($0 ? action : nil) }
    }

    private func label(_ title: String, systemImage: String, key: String, isPrimary: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(systemImage == "sparkles" ? Theme.infoFg : isPrimary ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 14, height: 14)
            Text(title)
                .font(.control.weight(.medium))
                .foregroundStyle(isPrimary ? Theme.textPrimary : Theme.textSecondary)
            KeyCap(key)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(.rect)
    }

    private static func title(for action: ChangeAction) -> String {
        switch action {
        case .stage: "Stage"
        case .unstage: "Unstage"
        case .commit: "Commit"
        case .discard: "Discard"
        }
    }
}

/// The View menu: which panels show, how the diff is drawn, and focusing the diff.
struct ViewMenu: View {
    let dismiss: () -> Void

    @AppStorage(AppSettings.isSidebarHiddenKey) private var isSidebarHidden = false
    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false
    @AppStorage(AppSettings.isHunkStripHiddenKey) private var isHunkStripHidden = false
    @AppStorage(AppSettings.showsLineNumbersKey) private var showsLineNumbers = true
    @AppStorage(AppSettings.showsWhitespaceChangesKey) private var showsWhitespaceChanges = true
    @AppStorage(AppSettings.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(AppSettings.showsSyntaxColorsKey) private var showsSyntaxColors = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            section("Panels")
            toggle("Sidebar", isOn: Binding(get: { !isSidebarHidden }, set: { isSidebarHidden = !$0 }), key: "⌃⌘S")
            toggle("File list", isOn: Binding(get: { !isListHidden }, set: { isListHidden = !$0 }), key: "⌘0")
            toggle("Hunk strip", isOn: Binding(get: { !isHunkStripHidden }, set: { isHunkStripHidden = !$0 }))
            divider
            section("Diff")
            toggle("Line numbers", isOn: $showsLineNumbers)
            toggle("Whitespace changes", isOn: $showsWhitespaceChanges, key: "⌥⌘W")
            toggle("Wrap long lines", isOn: $wrapsLines)
            toggle("Syntax colors", isOn: $showsSyntaxColors)
            divider
            Button {
                let focus = !(isSidebarHidden && isListHidden)
                withAnimation(.snappy(duration: 0.2)) {
                    isSidebarHidden = focus
                    isListHidden = focus
                }
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .frame(width: 14, height: 14)
                    Text(isSidebarHidden && isListHidden ? "Leave focus" : "Focus diff")
                        .font(.control)
                    Spacer()
                    KeyCap("⌘.")
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.hover(cornerRadius: 8))
            .focusEffectDisabled()
        }
        .padding(6)
        .frame(width: 268)
        .popoverSurface(in: .rect(cornerRadius: 14))
        .paletteKeys(up: {}, down: {}, choose: {}, dismiss: dismiss)
    }

    private var divider: some View {
        Rectangle().fill(Theme.lineSubtle).frame(height: 1).padding(.vertical, 2)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.sectionLabel)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 26)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, key: String? = nil) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { isOn.wrappedValue.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn.wrappedValue ? "eye" : "eye.slash")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isOn.wrappedValue ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.control)
                    .foregroundStyle(isOn.wrappedValue ? Theme.textPrimary : Theme.textTertiary)
                Spacer()
                if let key { KeyCap(key) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 8))
        .focusEffectDisabled()
    }
}

/// Before and after previews of a changed image.
private struct ImageDiffView: View {
    let fileID: String
    let contents: (Repository.FileSide) async -> Data?

    @State private var images: (old: NSImage?, new: NSImage?)?

    var body: some View {
        Group {
            if let images {
                HStack(spacing: 24) {
                    if let old = images.old { preview(old, title: "Before") }
                    if let new = images.new { preview(new, title: "After") }
                    if images.old == nil && images.new == nil {
                        EmptyState("Image Unavailable", systemImage: "photo")
                    }
                }
                .padding(24)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: fileID) {
            let old = await contents(.old)
            let new = await contents(.new)
            images = (old.flatMap(NSImage.init(data:)), new.flatMap(NSImage.init(data:)))
        }
    }

    private func preview(_ image: NSImage, title: String) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .background(.quinary)
                .border(.separator)
            Text("\(title) · \(Int(image.size.width))×\(Int(image.size.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
