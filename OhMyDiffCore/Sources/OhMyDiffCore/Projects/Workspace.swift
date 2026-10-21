import Foundation

/// A named group of projects, switched on the rail. Every project belongs to exactly one.
public struct Workspace: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ProjectColor

    public init(id: UUID = UUID(), name: String, color: ProjectColor) {
        self.id = id
        self.name = name
        self.color = color
    }

    /// The workspace that lists created before workspaces existed are moved into.
    public static let defaultName = "Projects"

    private enum CodingKeys: String, CodingKey {
        case id, name, color
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Like a project's, an unknown color is replaced instead of failing the whole list.
        color = (try? container.decodeIfPresent(ProjectColor.self, forKey: .color)) ?? ProjectColor.allCases[0]
    }
}

/// The projects and the workspaces they are sorted into, as saved.
public struct ProjectList: Sendable, Hashable {
    public var projects: [Project]
    public var workspaces: [Workspace]

    public init(projects: [Project] = [], workspaces: [Workspace] = []) {
        self.projects = projects
        self.workspaces = workspaces
    }

    /// Makes sure there is a workspace and every project is in one that exists: a list from before workspaces
    /// gets a single workspace holding every project. `true` when anything changed.
    @discardableResult
    public mutating func assignWorkspaces() -> Bool {
        var changed = false
        if workspaces.isEmpty {
            workspaces = [Workspace(name: Workspace.defaultName, color: ProjectColor.pick(avoiding: []))]
            changed = true
        }
        let known = Set(workspaces.map(\.id))
        for index in projects.indices where projects[index].workspaceID.map(known.contains) != true {
            projects[index].workspaceID = workspaces[0].id
            changed = true
        }
        return changed
    }
}

extension [Project] {
    /// The projects of a workspace, the most recently opened first; never opened ones keep their order at the end.
    public func inWorkspace(_ id: Workspace.ID?) -> [Project] {
        enumerated()
            .filter { $0.element.workspaceID == id }
            .sorted { lhs, rhs in
                switch (lhs.element.lastOpenedAt, rhs.element.lastOpenedAt) {
                case let (left?, right?) where left != right: left > right
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}
