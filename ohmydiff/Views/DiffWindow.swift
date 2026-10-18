import OhMyDiffCore
import SwiftUI

/// A diff shown in its own window.
enum DiffPopout: Equatable {
    /// An uncommitted file, followed live as the project refreshes.
    case change(projectID: Project.ID, path: String)
    /// A file of a commit or branch in History mode, which does not change.
    case snapshot(
        project: String, context: String, diff: FileDiff, highlights: SyntaxHighlights?, root: URL,
        sources: (old: RevisionFile?, new: RevisionFile?))

    static func == (lhs: DiffPopout, rhs: DiffPopout) -> Bool {
        switch (lhs, rhs) {
        case let (.change(lProject, lPath), .change(rProject, rPath)):
            lProject == rProject && lPath == rPath
        case let (.snapshot(lProject, lContext, lDiff, lHighlights, lRoot, lSources), .snapshot(rProject, rContext, rDiff, rHighlights, rRoot, rSources)):
            lProject == rProject && lContext == rContext && lDiff == rDiff && lHighlights == rHighlights && lRoot == rRoot
                && lSources == rSources
        default:
            false
        }
    }
}

extension FocusedValues {
    /// The diff the focused view can open in a new window.
    @Entry var diffPopout: DiffPopout?
}

/// A window with one file's diff, so it can be read at full size next to the main window.
struct DiffWindow: View {
    static let id = "diff"

    let model: AppModel
    let popoutID: UUID?

    @AppStorage(DiffSettings.layoutKey) private var layout: DiffLayoutMode = .unified

    var body: some View {
        Group {
            switch popoutID.flatMap({ model.popouts[$0] }) {
            case .change(let projectID, let path):
                LiveDiff(session: model.session(for: projectID), path: path)
            case .snapshot(let project, let context, let diff, let highlights, let root, let sources):
                FileDiffView(fileID: "\(context):\(diff.id)", diff: diff, highlights: highlights, root: root) { side in
                    guard let source = side == .old ? sources.old : sources.new, let toolchain = await model.toolchain() else { return nil }
                    let repository = Repository(root: root, kind: .git, toolchain: toolchain)
                    return try? await repository.contents(at: source.revision, path: source.path)
                }
                    .navigationTitle((diff.path as NSString).lastPathComponent)
                    .navigationSubtitle("\(project) · \(context)")
            case nil:
                ContentUnavailableView("Diff Unavailable", systemImage: "macwindow", description: Text("Open the diff again from the main window."))
            }
        }
        .background(Theme.panel, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline))
        .padding([.horizontal, .bottom], Theme.inset)
        .background { WindowTranslucency().ignoresSafeArea() }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
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

/// An uncommitted file's diff, reloaded whenever its project refreshes.
private struct LiveDiff: View {
    let session: ProjectSession
    let path: String

    @State private var state: ProjectSession.DiffState?
    @State private var isLoaded = false

    var body: some View {
        Group {
            if let state, case .diff(let diff) = state.content {
                FileDiffView(fileID: state.fileID, diff: diff, highlights: state.highlights, root: session.rootURL) { side in
                    await session.contents(ofPath: path, side: side)
                }
            } else if case .failed(let message)? = state?.content {
                ContentUnavailableView("Could Not Load Diff", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if isLoaded {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("\(path) no longer differs from the last commit."))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationSubtitle("\(session.project.displayName) · \((path as NSString).deletingLastPathComponent)")
        .task(id: session.lastRefreshed) {
            state = await session.diffState(forPath: path)
            isLoaded = true
        }
    }
}
