import Foundation

/// A project the user added to the sidebar.
public struct Project: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// The repository root.
    public var path: String
    public var displayName: String
    /// Last detected kind; re-detected whenever the project is opened.
    public var kind: RepositoryKind
    /// Set when the project is added; older lists get one on load.
    public var color: ProjectColor?
    /// The workspace the project is sorted into; lists from before workspaces get one on load.
    public var workspaceID: Workspace.ID?
    /// When the project was last selected, to list the most recent first.
    public var lastOpenedAt: Date?

    public init(
        id: UUID = UUID(), path: String, displayName: String? = nil, kind: RepositoryKind = .git, color: ProjectColor? = nil,
        workspaceID: Workspace.ID? = nil, lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.kind = kind
        self.color = color
        self.workspaceID = workspaceID
        self.lastOpenedAt = lastOpenedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, kind, color, workspaceID, lastOpenedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(RepositoryKind.self, forKey: .kind)
        // A color a newer or older version no longer knows is reassigned instead of failing the whole list.
        color = try? container.decodeIfPresent(ProjectColor.self, forKey: .color)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Whether the folder still exists at its saved path.
    public var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The project whose repository contains `folder`, found without running git: walking up from `folder`, a
    /// `.git` before a project's root means another repository, e.g. one nested inside a project.
    public static func containing(_ folder: URL, in projects: [Project]) -> Project? {
        let roots = Dictionary(projects.map { ($0.url.resolvingSymlinksInPath().path, $0) }) { first, _ in first }
        var url = folder.resolvingSymlinksInPath().standardizedFileURL
        while true {
            if let project = roots[url.path] { return project }
            if url.path == "/" || FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return nil }
            url.deleteLastPathComponent()
        }
    }
}

/// Persists the projects and workspaces as JSON.
public struct ProjectStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/ohmydiff/projects.json`.
    public static var defaultFileURL: URL { fileURL(folder: "ohmydiff") }

    /// `~/Library/Application Support/<folder>/projects.json`.
    public static func fileURL(folder: String) -> URL {
        URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory).appending(path: "projects.json")
    }

    /// Version 2 added workspaces; version 1 files have none.
    private struct File: Codable {
        var version = 2
        var projects: [Project]
        var workspaces: [Workspace]?
    }

    /// Returns the saved list, or an empty one when nothing has been saved yet. Projects keep the workspace
    /// they were saved with, even an unknown one: `ProjectList.assignWorkspaces()` sorts them out.
    public func load() throws -> ProjectList {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ProjectList() }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: data)
        return ProjectList(projects: file.projects, workspaces: file.workspaces ?? [])
    }

    public func save(_ list: ProjectList) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(projects: list.projects, workspaces: list.workspaces)).write(to: fileURL, options: .atomic)
    }
}
