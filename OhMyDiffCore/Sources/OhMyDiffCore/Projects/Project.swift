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

    public init(id: UUID = UUID(), path: String, displayName: String? = nil, kind: RepositoryKind = .git, color: ProjectColor? = nil) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.kind = kind
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, kind, color
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(RepositoryKind.self, forKey: .kind)
        // A color a newer or older version no longer knows is reassigned instead of failing the whole list.
        color = try? container.decodeIfPresent(ProjectColor.self, forKey: .color)
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

/// Persists the project list as JSON.
public struct ProjectStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/ohmydiff/projects.json`.
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ohmydiff", directoryHint: .isDirectory).appending(path: "projects.json")
    }

    private struct File: Codable {
        var version = 1
        var projects: [Project]
    }

    /// Returns the saved projects, or an empty list when nothing has been saved yet.
    public func load() throws -> [Project] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(File.self, from: data).projects
    }

    public func save(_ projects: [Project]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(File(projects: projects)).write(to: fileURL, options: .atomic)
    }
}
