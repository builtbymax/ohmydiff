import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The detail pane in Changes mode: the selected file's diff.
struct DiffDetailView: View {
    let session: ProjectSession

    var body: some View {
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
                contents: { side in await session.contents(of: file, side: side) },
                hunkActions: ChangeAction.allCases.filter { action in
                    diff.hunks.first.map { session.supports(action, on: [ChangeTarget(file: file, hunk: $0)]) } ?? false
                },
                onHunkAction: { action, hunk in
                    guard diff.hunks.indices.contains(hunk) else { return }
                    session.request(action, on: [ChangeTarget(file: file, hunk: diff.hunks[hunk])])
                })
        }
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
    /// One side's contents, for image previews and the whole-file view.
    let contents: (Repository.FileSide) async -> Data?
    /// Actions in each hunk's context menu and the hunk bar; none in History mode.
    var hunkActions: [ChangeAction] = []
    var onHunkAction: (ChangeAction, Int) -> Void = { _, _ in }

    @AppStorage(DiffSettings.layoutKey) private var preferredLayout: DiffLayoutMode = .unified
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(DiffMetrics.defaultFontSize)
    @AppStorage(DiffSettings.wholeFileKey) private var prefersWholeFile = false
    /// The diff expanded to the whole file, once loaded; `source` is the diff it was expanded from.
    @State private var wholeFile: (source: FileDiff, diff: FileDiff, highlights: SyntaxHighlights?)?
    /// Large diffs the user chose to show anyway.
    @State private var revealedFiles: Set<String> = []
    @State private var focusLine: Int?
    /// The hunk at the top of the visible rows, for the hunk bar.
    @State private var visibleHunk: Int?
    /// Lines of the selected rows in the shown diff.
    @State private var selectedLines: [DiffPosition] = []
    @Environment(\.claudeCode) private var claudeCode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DiffTitle(diff: diff, showsWholeFile: DiffSettings.canShowWholeFile(diff) ? $prefersWholeFile : nil)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            if showsTable, !diff.hunks.isEmpty {
                HunkBar(hunks: diff.hunks, current: visibleHunk ?? 0, actions: hunkActions, claude: promptTarget) { action in
                    onHunkAction(action, visibleHunk ?? 0)
                }
                .padding(.bottom, 24)
            }
        }
        .focusedSceneValue(\.diffFile, DiffFileTarget(
            url: root.appending(path: diff.path), relativePath: diff.path, line: focusLine))
        .focusedSceneValue(\.diffPopout, popout)
        .focusedSceneValue(\.diffPrompt, promptTarget)
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
            EmptyState("Binary File", systemImage: "doc.zipper", description: "Binary changes cannot be shown.")
        } else if diff.hunks.isEmpty {
            EmptyState(
                diff.isModeChange ? "Mode Changed" : "Empty File", systemImage: "doc",
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
                    fileID: fileID, diff: wholeFile?.diff ?? diff, highlights: wholeFile.map(\.highlights) ?? highlights, mode: mode,
                    fontSize: CGFloat(fontSize.clamped(to: AppSettings.fontSizes)),
                    isWholeFile: wholeFile != nil,
                    bottomInset: Theme.hunkBarInset,
                    onFocusLine: { line in
                        if line != focusLine { focusLine = line }
                    },
                    onVisibleHunk: { hunk in
                        if hunk != visibleHunk { visibleHunk = hunk }
                    },
                    hunkActions: hunkActions, onHunkAction: onHunkAction,
                    onSelectLines: { lines in
                        if lines != selectedLines { selectedLines = lines }
                    },
                    onAskClaude: askClaudeAction)
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

/// The file's directory, name and line counts above its diff.
private struct DiffTitle: View {
    let diff: FileDiff
    /// The whole-file toggle; `nil` hides it.
    let showsWholeFile: Binding<Bool>?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if !directory.isEmpty {
                    Text(directory)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                HStack(alignment: .center, spacing: 10) {
                    Text(name)
                        .font(.system(size: 22, weight: .bold))
                        .kerning(-0.3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let tag = LanguageTag(path: diff.path) { tag }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if diff.isModeChange, !diff.hunks.isEmpty {
                Text("\(diff.oldMode ?? "") → \(diff.newMode ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            LineStatsLabel(stats: LineStats(additions: diff.additions, deletions: diff.deletions), font: .callout)
            if let showsWholeFile {
                let isOn = showsWholeFile.wrappedValue
                Button { showsWholeFile.wrappedValue.toggle() } label: {
                    Image(systemName: isOn ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.hoverCapsule(isSelected: isOn))
                .focusEffectDisabled()
                .glassTooltip(isOn ? "Show Changes Only  ⇧⌘\\" : "Show Whole File  ⇧⌘\\")
            }
        }
    }

    private var directory: String {
        if let oldPath = diff.oldPath, let newPath = diff.newPath, oldPath != newPath { return "Renamed from \(oldPath)" }
        return (diff.path as NSString).deletingLastPathComponent
    }

    private var name: String { (diff.path as NSString).lastPathComponent }
}

/// Floating glass controls for the hunk at the top of the diff: move between hunks and act on it.
private struct HunkBar: View {
    let hunks: [Hunk]
    let current: Int
    let actions: [ChangeAction]
    let claude: DiffPromptTarget?
    let perform: (ChangeAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                jumpButton("Previous Hunk  P", systemImage: "chevron.up", direction: -1)
                jumpButton("Next Hunk  N", systemImage: "chevron.down", direction: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Hunk \(min(current, hunks.count - 1) + 1) of \(hunks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260, alignment: .leading)
            if let claude {
                ClaudePromptMenu(target: claude)
            }
            if !actions.isEmpty {
                Divider().frame(height: 22)
                HStack(spacing: 6) {
                    ForEach(actions.filter { $0 != .discard }, id: \.self) { action in
                        Button { perform(action) } label: {
                            Label(Self.title(for: action), systemImage: Self.systemImage(for: action))
                        }
                        .buttonStyle(.pill(action == .commit ? .prominent : .normal, height: 32))
                        .focusEffectDisabled()
                    }
                    if actions.contains(.discard) {
                        Button { perform(.discard) } label: {
                            Image(systemName: Self.systemImage(for: .discard))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.pill(.destructive, height: 32))
                        .focusEffectDisabled()
                        .glassTooltip("Discard Hunk…", edge: .top)
                    }
                }
                .fixedSize()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, actions.isEmpty && claude == nil ? 16 : 8)
        .frame(height: 48)
        .glassEffect(Theme.barGlass, in: .capsule)
    }

    private var hunk: Hunk { hunks[min(current, hunks.count - 1)] }

    private var title: String {
        let section = hunk.section.trimmingCharacters(in: .whitespaces)
        return section.isEmpty ? "@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@" : section
    }

    private static func title(for action: ChangeAction) -> String {
        switch action {
        case .stage: "Stage"
        case .unstage: "Unstage"
        case .commit: "Commit…"
        case .discard: "Discard Hunk…"
        }
    }

    private static func systemImage(for action: ChangeAction) -> String {
        switch action {
        case .stage: "plus"
        case .unstage: "minus"
        case .commit: "checkmark"
        case .discard: "trash"
        }
    }

    private func jumpButton(_ title: String, systemImage: String, direction: Int) -> some View {
        Button {
            NotificationCenter.default.post(name: .jumpToHunk, object: direction)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.hoverCapsule())
        .focusEffectDisabled()
        .glassTooltip(title, edge: .top)
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
