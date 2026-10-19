import OhMyDiffCore
import SwiftUI

/// A diff shown in its own window.
enum DiffPopout: Equatable {
    /// An uncommitted file, followed live as the project refreshes.
    case change(projectID: Project.ID, path: String)
    /// A file of a commit or branch in History mode, which does not change, with the other files of it.
    case snapshot(DiffSnapshot)
}

/// The files of a commit or branch for a diff window, and the one it opens on.
struct DiffSnapshot: Equatable {
    struct File: Equatable, Identifiable {
        var diff: FileDiff
        var sources: (old: RevisionFile?, new: RevisionFile?)

        var id: FileDiff.ID { diff.id }

        static func == (lhs: File, rhs: File) -> Bool {
            lhs.diff == rhs.diff && lhs.sources == rhs.sources
        }
    }

    var project: String
    var context: String
    var root: URL
    var files: [File]
    var selectedID: FileDiff.ID
    /// Syntax colors already worked out in the main window; the rest load when a file is shown.
    var highlights: [FileDiff.ID: SyntaxHighlights]
    var promptContext: PromptContext?
}

extension FocusedValues {
    /// The diff the focused view can open in a new window.
    @Entry var diffPopout: DiffPopout?
}

/// A window with one file's diff, so it can be read at full size next to the main window, and a collapsible
/// sidebar with the other files of the commit, branch or working tree.
struct DiffWindow: View {
    static let id = "diff"
    static let sidebarHiddenKey = "diffWindowSidebarHidden"

    let model: AppModel
    let popoutID: UUID?

    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified
    @AppStorage(Self.sidebarHiddenKey) private var isSidebarHidden = false

    var body: some View {
        Group {
            switch popoutID.flatMap({ model.popouts[$0] }) {
            case .change(let projectID, let path):
                LiveDiff(session: model.session(for: projectID), initialPath: path, isSidebarHidden: isSidebarHidden)
            case .snapshot(let snapshot):
                SnapshotDiff(model: model, snapshot: snapshot, isSidebarHidden: isSidebarHidden)
            case nil:
                EmptyState("Diff Unavailable", systemImage: "macwindow", description: "Open the diff again from the main window.")
            }
        }
        .background(Theme.panel, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline))
        .padding(Theme.inset)
        .background { WindowTranslucency().ignoresSafeArea() }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy) { isSidebarHidden.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(isSidebarHidden ? "Show Files" : "Hide Files")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Layout", selection: $layout) {
                    Text("Unified").tag(DiffLayoutMode.unified)
                    Text("Split").tag(DiffLayoutMode.split)
                }
                .pickerStyle(.segmented)
            }
        }
        .onDisappear { popoutID.map(model.closePopout) }
    }
}

/// The window's file sidebar beside its diff; the sidebar slides away when hidden.
private struct SidebarLayout<Sidebar: View, Detail: View>: View {
    let isSidebarHidden: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    @AppStorage("diffWindowSidebarWidth") private var width = 260.0

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarHidden {
                sidebar
                    .frame(width: width.clamped(to: 200...420))
                    .background(Theme.column)
                    .overlay(alignment: .trailing) { ColumnResizer(width: $width, range: 200...420) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A list of files in the main window's card style; selecting one shows its diff in this window.
private struct FileSidebar: View {
    struct Section: Identifiable {
        var id: String
        var title: String
        var systemImage: String?
        var files: [(id: String, path: String, previousPath: String?, kind: FileChangeKind, stats: LineStats?)]
    }

    let sections: [Section]
    @Binding var selection: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(sections) { section in
                        Card {
                            HStack(spacing: 7) {
                                if let systemImage = section.systemImage {
                                    Image(systemName: systemImage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(section.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text("\(section.files.count)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary.opacity(0.8))
                        } content: {
                            LazyVStack(spacing: 3) {
                                ForEach(section.files, id: \.id) { file in
                                    Button { selection = file.id } label: {
                                        FileRow(
                                            path: file.path, previousPath: file.previousPath, kind: file.kind, stats: file.stats,
                                            isSelected: selection == file.id)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 7)
                                    }
                                    .buttonStyle(.row(isSelected: selection == file.id))
                                    .id(file.id)
                                }
                            }
                            .padding(4)
                        }
                    }
                }
                .padding(12)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy: proxy) }
            .onAppear { selection.map { proxy.scrollTo($0, anchor: .center) } }
        }
    }

    private func move(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = sections.flatMap { $0.files.map(\.id) }
        guard !ids.isEmpty else { return .ignored }
        let current = ids.firstIndex { $0 == selection }
        let next = current.map { min(max($0 + offset, 0), ids.count - 1) } ?? 0
        selection = ids[next]
        proxy.scrollTo(ids[next])
        return .handled
    }
}

/// A commit's or branch's files: one diff at a time, picked from the sidebar.
private struct SnapshotDiff: View {
    let model: AppModel
    let snapshot: DiffSnapshot
    let isSidebarHidden: Bool

    @State private var selection: String?
    @State private var highlights: [FileDiff.ID: SyntaxHighlights] = [:]

    var body: some View {
        let selected = snapshot.files.first { $0.id == (selection ?? snapshot.selectedID) } ?? snapshot.files.first
        SidebarLayout(isSidebarHidden: isSidebarHidden) {
            FileSidebar(
                sections: [FileSidebar.Section(
                    id: "files", title: "Files", systemImage: "doc.on.doc",
                    files: snapshot.files.map { file in
                        let diff = file.diff
                        return (diff.id, diff.path, diff.oldPath == diff.newPath ? nil : diff.oldPath, diff.kind,
                                diff.isBinary ? nil : LineStats(additions: diff.additions, deletions: diff.deletions))
                    })],
                selection: Binding(get: { selection ?? snapshot.selectedID }, set: { selection = $0 }))
        } detail: {
            if let selected {
                FileDiffView(
                    fileID: "\(snapshot.context):\(selected.id)", diff: selected.diff, highlights: highlights[selected.id],
                    root: snapshot.root, promptContext: snapshot.promptContext
                ) { side in
                    await contents(of: selected, side: side)
                }
                .navigationTitle((selected.diff.path as NSString).lastPathComponent)
                .navigationSubtitle("\(snapshot.project) · \(snapshot.context)")
                .task(id: selected.id) { await loadHighlights(selected) }
            } else {
                EmptyState("No Files", systemImage: "doc")
            }
        }
        .onAppear { highlights = snapshot.highlights }
    }

    private func contents(of file: DiffSnapshot.File, side: Repository.FileSide) async -> Data? {
        guard let source = side == .old ? file.sources.old : file.sources.new, let toolchain = await model.toolchain() else { return nil }
        let repository = Repository(root: snapshot.root, kind: .git, toolchain: toolchain)
        return try? await repository.contents(at: source.revision, path: source.path, limit: SyntaxHighlighter.maximumLength)
    }

    private func loadHighlights(_ file: DiffSnapshot.File) async {
        guard highlights[file.id] == nil, !file.diff.isBinary, let language = SyntaxLanguage(path: file.diff.path),
              let toolchain = await model.toolchain()
        else { return }
        let root = snapshot.root
        let sources = file.sources
        let result = await DiffHighlighting.highlights(for: file.diff, language: language) { side in
            guard let source = side == .old ? sources.old : sources.new else { return nil }
            return try? await Repository(root: root, kind: .git, toolchain: toolchain)
                .contents(at: source.revision, path: source.path, limit: SyntaxHighlighter.maximumLength)
        }
        guard !Task.isCancelled else { return }
        highlights[file.id] = result
    }
}

/// An uncommitted file's diff, reloaded whenever its project refreshes, beside the project's changed files.
private struct LiveDiff: View {
    let session: ProjectSession
    let initialPath: String
    let isSidebarHidden: Bool

    @State private var selectedPath: String?
    @State private var state: ProjectSession.DiffState?
    @State private var isLoaded = false

    private var path: String { selectedPath ?? initialPath }

    var body: some View {
        SidebarLayout(isSidebarHidden: isSidebarHidden) {
            FileSidebar(
                sections: session.groups.filter { !$0.files.isEmpty }.map { group in
                    FileSidebar.Section(
                        id: group.id, title: group.title, systemImage: Self.icon(group.kind),
                        files: group.files.map { ($0.path, $0.path, $0.previousPath, $0.kind, $0.stats) })
                },
                selection: Binding(get: { path }, set: { $0.map { selectedPath = $0 } }))
        } detail: {
            Group {
                if let state, case .diff(let diff) = state.content {
                    FileDiffView(
                        fileID: state.fileID, diff: diff, highlights: state.highlights, root: session.rootURL,
                        promptContext: session.promptContext(forPath: path)
                    ) { side in
                        await session.contents(ofPath: path, side: side)
                    }
                } else if case .failed(let message)? = state?.content {
                    EmptyState("Could Not Load Diff", systemImage: "exclamationmark.triangle", description: message)
                } else if isLoaded {
                    EmptyState("No Changes", systemImage: "checkmark.circle", description: "\(path) no longer differs from the last commit.")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationSubtitle("\(session.project.displayName) · \((path as NSString).deletingLastPathComponent)")
        .task(id: "\(path)|\(session.lastRefreshed?.timeIntervalSince1970 ?? 0)") {
            state = await session.diffState(forPath: path)
            isLoaded = true
        }
    }

    static func icon(_ kind: ChangeGroup.Kind) -> String {
        switch kind {
        case .stack(_, let branches): branches.count > 1 ? "square.stack.3d.up" : "arrow.triangle.branch"
        case .unassigned: "tray"
        case .staged: "checkmark.circle"
        case .unstaged: "pencil"
        case .untracked: "questionmark.circle"
        case .conflicted: "exclamationmark.triangle"
        }
    }
}
