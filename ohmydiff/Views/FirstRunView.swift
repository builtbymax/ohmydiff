import OhMyDiffCore
import SwiftUI

/// No project yet: one drop zone, and the repositories ohmydiff found on this Mac.
struct FirstRunView: View {
    let model: AppModel

    @State private var found: [FoundRepository] = []
    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dropZone
                if !found.isEmpty {
                    Text("Found on this Mac")
                        .font(.sectionLabel)
                        .foregroundStyle(Theme.textTertiary)
                    VStack(spacing: 2) {
                        ForEach(found) { repository in
                            FoundRepositoryRow(repository: repository) {
                                found.removeAll { $0.id == repository.id }
                                Task { await model.addProjects([repository.url]) }
                            }
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .task { found = await FoundRepository.scan(excluding: Set(model.projects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath() })) }
    }

    private var dropZone: some View {
        Button { model.isImporterPresented = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                Text("Drop a repository here")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    Text("or choose a folder")
                        .font(.control)
                        .foregroundStyle(Theme.textTertiary)
                    KeyCap("⇧⌘O")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(isTargeted ? Theme.hover : Theme.surface, in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isTargeted ? Theme.textTertiary : Theme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addProjects(urls) }
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
    }
}

private struct FoundRepositoryRow: View {
    let repository: FoundRepository
    let add: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text(repository.name.prefix(1).lowercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(Theme.hover, in: .rect(cornerRadius: 6))
            Text(repository.name)
                .font(.row.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(repository.displayPath)
                .font(.code(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if repository.isGitButler {
                Chip("but", systemImage: "square.3.layers.3d", tone: .info)
            } else {
                Chip("git", systemImage: "circle.and.line.horizontal")
            }
            Button("Add", action: add)
                .buttonStyle(.pill(height: 26))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(isHovered ? Theme.hover : .clear, in: .rect(cornerRadius: 9))
        .onHover { isHovered = $0 }
    }
}

/// A git repository in one of the usual code folders.
struct FoundRepository: Identifiable, Hashable {
    let url: URL
    let isGitButler: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// e.g. `~/Developer/yab`.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Looks two levels deep in `~/Developer`, `~/Projects` and similar folders, newest first, at most 8.
    nonisolated static func scan(excluding added: Set<URL>) async -> [FoundRepository] {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let home = fileManager.homeDirectoryForCurrentUser
            let roots = ["Developer", "Projects", "Code", "code", "src", "GitHub", "Documents/GitHub", "Sites", "repos"]
                .map { home.appending(path: $0, directoryHint: .isDirectory) }
            var found: [(FoundRepository, Date)] = []
            var seen = Set<URL>()

            func visit(_ folder: URL, depth: Int) {
                guard let children = try? fileManager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                else { return }
                for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let url = child.standardizedFileURL.resolvingSymlinksInPath()
                    guard seen.insert(url).inserted else { continue }
                    let git = url.appending(path: ".git")
                    if fileManager.fileExists(atPath: git.path) {
                        guard !added.contains(url), !added.contains(child.standardizedFileURL) else { continue }
                        let isGitButler = fileManager.fileExists(atPath: git.appending(path: "gitbutler").path)
                        let modified = (try? git.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        found.append((FoundRepository(url: url, isGitButler: isGitButler), modified))
                    } else if depth > 0 {
                        visit(child, depth: depth - 1)
                    }
                }
            }

            for root in roots { visit(root, depth: 1) }
            return found.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
        }.value
    }
}
