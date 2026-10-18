import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The detail pane in Changes mode: the selected file's diff.
struct DiffDetailView: View {
    let session: ProjectSession

    @AppStorage(DiffSettings.layoutKey) private var preferredLayout: DiffLayoutMode = .unified
    /// Large diffs the user chose to show anyway.
    @State private var revealedFiles: Set<ChangedFile.ID> = []

    var body: some View {
        if let state = session.diff, let file = session.selectedFile {
            content(state.content, file: file)
        } else if session.phase == .ready && session.changeCount == 0 {
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle")
                .backgroundExtensionEffect()
        } else {
            ContentUnavailableView("No Selection", systemImage: "text.alignleft")
                .backgroundExtensionEffect()
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
            ContentUnavailableView("No Differences", systemImage: "equal", description: Text("\(file.path) matches the last commit."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { session.refresh() }
            }
        case .diff(let diff):
            body(for: diff, file: file)
                .safeAreaInset(edge: .top, spacing: 0) {
                    DiffHeader(file: file, diff: diff)
                }
        }
    }

    @ViewBuilder
    private func body(for diff: FileDiff, file: ChangedFile) -> some View {
        if diff.isBinary, DiffSettings.isImage(file.path) {
            ImageDiffView(session: session, file: file)
        } else if diff.isBinary {
            ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("Binary changes cannot be shown."))
        } else if diff.hunks.isEmpty {
            ContentUnavailableView(
                diff.isModeChange ? "Mode Changed" : "Empty File", systemImage: "doc",
                description: Text(diff.isModeChange ? "\(diff.oldMode ?? "") → \(diff.newMode ?? "")" : "The file has no content."))
        } else if DiffSettings.isLarge(diff), !revealedFiles.contains(file.id) {
            ContentUnavailableView {
                Label("Large Diff", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("\(diff.additions + diff.deletions) changed lines are hidden to keep things fast.")
            } actions: {
                Button("Show Diff") { revealedFiles.insert(file.id) }
            }
        } else {
            GeometryReader { proxy in
                // Side by side needs room for two readable columns.
                let mode: DiffLayoutMode = preferredLayout == .split && proxy.size.width >= DiffSettings.minimumSplitWidth ? .split : .unified
                DiffTableView(fileID: file.id, diff: diff, highlights: session.diff?.highlights, mode: mode)
            }
        }
    }
}

enum DiffSettings {
    static let layoutKey = "diffLayout"
    static let minimumSplitWidth: CGFloat = 760
    /// Diffs with more changed lines than this start collapsed.
    static let largeDiffLineCount = 25_000

    static func isLarge(_ diff: FileDiff) -> Bool {
        diff.hunks.reduce(0) { $0 + $1.lines.count } > largeDiffLineCount
    }

    static func isImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }
}

private struct DiffHeader: View {
    let file: ChangedFile
    let diff: FileDiff

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            if diff.isModeChange, !diff.hunks.isEmpty {
                Text("\(diff.oldMode ?? "") → \(diff.newMode ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            LineStatsLabel(stats: LineStats(additions: diff.additions, deletions: diff.deletions))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: String {
        if let oldPath = diff.oldPath, let newPath = diff.newPath, oldPath != newPath {
            return "\(oldPath) → \(newPath)"
        }
        return file.path
    }
}

/// Before and after previews of a changed image.
private struct ImageDiffView: View {
    let session: ProjectSession
    let file: ChangedFile

    @State private var images: (old: NSImage?, new: NSImage?)?

    var body: some View {
        Group {
            if let images {
                HStack(spacing: 24) {
                    if let old = images.old { preview(old, title: "Before") }
                    if let new = images.new { preview(new, title: "After") }
                    if images.old == nil && images.new == nil {
                        ContentUnavailableView("Image Unavailable", systemImage: "photo")
                    }
                }
                .padding(24)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file) {
            async let old = session.contents(of: file, side: .old)
            async let new = session.contents(of: file, side: .new)
            images = (await old.flatMap(NSImage.init(data:)), await new.flatMap(NSImage.init(data:)))
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
