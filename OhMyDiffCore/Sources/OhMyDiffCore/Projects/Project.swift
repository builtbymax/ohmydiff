import Foundation

/// A project the user added to the sidebar.
public struct Project: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// The repository root.
    public var path: String
    public var displayName: String
    /// Last detected kind; re-detected whenever the project is opened.
    public var kind: RepositoryKind

    public init(id: UUID = UUID(), path: String, displayName: String? = nil, kind: RepositoryKind = .git) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.kind = kind
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Whether the folder still exists at its saved path.
    public var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
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
