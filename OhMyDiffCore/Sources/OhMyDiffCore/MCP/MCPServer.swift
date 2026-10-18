import Foundation

/// A Model Context Protocol server on stdin and stdout, run by `ohmydiff mcp`, so coding agents can read a
/// repository's changes and point the app at a file, branch or commit.
///
/// Read-only tools answer from git and `but` directly; the app does not need to run. Focus tools open an
/// `ohmydiff://…` URL, which starts the app when needed.
public struct MCPServer: Sendable {
    public typealias URLOpener = @Sendable (URL) async throws -> Void

    /// Newest first; an initialize request asking for another version gets the first.
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Diff text beyond this many characters is cut, so one call cannot flood the agent's context.
    static let diffCharacterLimit = 200_000

    let toolchain: Toolchain?
    /// Relative `repository` and `path` arguments resolve against this folder, where the agent started the server.
    let workingDirectory: URL
    let projects: ProjectStore
    let version: String
    let openURL: URLOpener

    public init(
        toolchain: Toolchain?, workingDirectory: URL, projects: ProjectStore = ProjectStore(fileURL: ProjectStore.defaultFileURL),
        version: String = "1.0", openURL: @escaping URLOpener = MCPServer.openWithLaunchServices
    ) {
        self.toolchain = toolchain
        self.workingDirectory = workingDirectory
        self.projects = projects
        self.version = version
        self.openURL = openURL
    }

    /// Opens a URL with `/usr/bin/open`, which brings the app to the front.
    public static let openWithLaunchServices: URLOpener = { url in
        let output = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [url.absoluteString], timeout: .seconds(15))
        guard output.exitCode == 0 else {
            throw MCPToolError("Could not open ohmydiff: \(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Answers newline-delimited JSON-RPC messages until stdin closes.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        var line: [UInt8] = []
        do {
            for try await byte in input.bytes {
                guard byte == UInt8(ascii: "\n") else {
                    line.append(byte)
                    continue
                }
                defer { line.removeAll(keepingCapacity: true) }
                guard line.contains(where: { !Character(UnicodeScalar($0)).isWhitespace }) else { continue }
                if let response = await handle(Data(line)) {
                    output.write(response + Data("\n".utf8))
                }
            }
        } catch {
            FileHandle.standardError.write(Data("ohmydiff mcp: \(error)\n".utf8))
        }
    }

    // MARK: - JSON-RPC

    /// The response to one message; `nil` for notifications.
    public func handle(_ message: Data) async -> Data? {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: message) else {
            return Self.encode(Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        guard case .object = request, let method = request["method"]?.stringValue else {
            return Self.encode(Self.error(id: request["id"] ?? .null, code: -32600, message: "Invalid request"))
        }
        // Notifications, e.g. `notifications/initialized`, have no ID and get no answer.
        guard let id = request["id"] else { return nil }
        let params = request["params"]

        let result: JSONValue
        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue
            result = [
                "protocolVersion": .string(requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "ohmydiff", "version": .string(version)],
                "instructions": .string(Self.instructions),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(MCPTool.allCases.map(\.definition))]
        case "tools/call":
            guard let name = params?["name"]?.stringValue, let tool = MCPTool(rawValue: name) else {
                return Self.encode(Self.error(id: id, code: -32602, message: "Unknown tool: \(params?["name"]?.stringValue ?? "")"))
            }
            result = await call(tool, arguments: params?["arguments"] ?? [:])
        default:
            return Self.encode(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static let instructions = """
        ohmydiff is a macOS diff viewer for git and GitButler repositories. Read uncommitted changes, branches \
        and commits with list_changes, get_diff and list_branches. To have the user look at something, call \
        show_file, show_branch or show_commit: they bring the app to the front at that file, line, branch or commit. \
        `repository` defaults to the folder the server was started in.
        """

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    private static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    // MARK: - Tools

    func call(_ tool: MCPTool, arguments: JSONValue) async -> JSONValue {
        do {
            let text = try await run(tool, arguments: arguments)
            return ["content": [["type": "text", "text": .string(text)]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": .string(String(describing: error))]], "isError": true]
        }
    }

    private func run(_ tool: MCPTool, arguments: JSONValue) async throws -> String {
        switch tool {
        case .listProjects:
            let list = try projects.load().map { project -> JSONValue in
                ["name": .string(project.displayName), "path": .string(project.path), "kind": .string(project.kind.rawValue)]
            }
            return Self.pretty(["projects": .array(list)])

        case .listChanges:
            let repository = try await repository(arguments)
            let groups = try await repository.changeGroups()
            return Self.pretty([
                "repository": .string(repository.root.path),
                "kind": .string(repository.kind.rawValue),
                "groups": .array(groups.map(Self.json)),
            ])

        case .getDiff:
            let repository = try await repository(arguments)
            let path = try arguments["path"]?.stringValue.map { try relativePath($0, in: repository) }
            if let commit = arguments["commit"]?.stringValue {
                let sha = try await resolveCommit(commit, in: repository)
                var diffs = try await repository.diff(commit: sha)
                if let path {
                    diffs = diffs.filter { $0.newPath == path || $0.oldPath == path }
                    guard !diffs.isEmpty else { throw MCPToolError("\(path) is not changed in \(sha.prefix(12)).") }
                }
                return Self.limited(diffs.map(\.patch).joined(separator: "\n"))
            }
            return try await uncommittedDiff(repository, path: path)

        case .listBranches:
            let repository = try await repository(arguments)
            let groups = try await repository.history()
            return Self.pretty([
                "repository": .string(repository.root.path),
                "kind": .string(repository.kind.rawValue),
                "groups": .array(groups.map(Self.json)),
            ])

        case .openProject:
            let repository = try await repository(arguments)
            try await openURL(CLIRequest.open(path: repository.root.path).url)
            return "Opened \(repository.root.path) in ohmydiff."

        case .showFile:
            guard let argument = arguments["path"]?.stringValue else { throw MCPToolError("`path` is required.") }
            // An absolute path picks its own repository.
            let isAbsolute = (argument as NSString).expandingTildeInPath.hasPrefix("/")
            let repository = isAbsolute ? try await self.repository(at: resolve(argument).deletingLastPathComponent()) : try await self.repository(arguments)
            let path = try relativePath(argument, in: repository)
            guard try await repository.changeGroups().allFiles.contains(where: { $0.path == path }) else {
                throw MCPToolError("\(path) has no uncommitted changes. Use show_commit or show_branch for committed changes.")
            }
            let line = arguments["line"]?.intValue
            try await openURL(CLIRequest.show(path: repository.root.appending(path: path).path, line: line).url)
            return "Showing \(path)\(line.map { " at line \($0)" } ?? "") in ohmydiff."

        case .showBranch:
            guard let name = arguments["name"]?.stringValue else { throw MCPToolError("`name` is required.") }
            let repository = try await repository(arguments)
            let names = try await repository.history().flatMap { $0.branches.map(\.name) }
            guard names.contains(name) else {
                throw MCPToolError("No branch named \(name). Branches: \(names.joined(separator: ", ")).")
            }
            try await openURL(CLIRequest.branch(path: repository.root.path, name: name).url)
            return "Showing branch \(name) in ohmydiff."

        case .showCommit:
            guard let commit = arguments["sha"]?.stringValue else { throw MCPToolError("`sha` is required.") }
            let repository = try await repository(arguments)
            let sha = try await resolveCommit(commit, in: repository)
            let listed = try await repository.history().contains { $0.branches.contains { $0.commits.contains { $0.sha == sha } } }
            guard listed else {
                throw MCPToolError("\(sha.prefix(12)) is not on a branch ohmydiff lists. Use get_diff with `commit` to read it.")
            }
            try await openURL(CLIRequest.commit(path: repository.root.path, sha: sha).url)
            return "Showing commit \(sha.prefix(12)) in ohmydiff."
        }
    }

    private func uncommittedDiff(_ repository: Repository, path: String?) async throws -> String {
        let groups = try await repository.changeGroups()
        var sections: [String] = []
        for group in groups {
            let files = group.files.filter { path == nil || $0.path == path || $0.previousPath == path }
            var patches: [String] = []
            for file in files {
                guard let diff = try await repository.diff(for: file) else { continue }
                patches.append(diff.patch)
            }
            guard !patches.isEmpty else { continue }
            sections.append("# \(Self.title(of: group))\n\n" + patches.joined(separator: "\n"))
        }
        guard !sections.isEmpty else {
            throw MCPToolError(path.map { "\($0) has no uncommitted changes." } ?? "There are no uncommitted changes.")
        }
        return Self.limited(sections.joined(separator: "\n"))
    }

    // MARK: - Arguments

    private func repository(_ arguments: JSONValue) async throws -> Repository {
        try await repository(at: arguments["repository"]?.stringValue.map(resolve) ?? workingDirectory)
    }

    private func repository(at url: URL) async throws -> Repository {
        guard let toolchain else { throw MCPToolError("git was not found on the login shell PATH.") }
        return try await Repository.open(url, toolchain: toolchain)
    }

    /// An absolute URL for a path that may be relative to the working directory or start with `~`.
    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : workingDirectory.appending(path: expanded)
        return url.standardizedFileURL
    }

    /// `path` relative to the repository root; a relative `path` is taken as relative to the root already.
    private func relativePath(_ path: String, in repository: Repository) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : repository.root.appending(path: expanded)
        // Compare without symlinks, e.g. /var and /private/var; the file itself may be deleted.
        let root = repository.root.resolvingSymlinksInPath().path
        let directory = absolute.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let file = directory + "/" + absolute.lastPathComponent
        guard file.hasPrefix(root + "/") else { throw MCPToolError("\(path) is not inside \(repository.root.path).") }
        return String(file.dropFirst(root.count + 1))
    }

    private func resolveCommit(_ revision: String, in repository: Repository) async throws -> String {
        guard let sha = try await repository.resolveCommit(revision) else { throw MCPToolError("No commit \(revision) in \(repository.root.path).") }
        return sha
    }

    // MARK: - Output

    private static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func limited(_ text: String) -> String {
        guard text.count > diffCharacterLimit else { return text }
        return String(text.prefix(diffCharacterLimit)) + "\n[… cut at \(diffCharacterLimit) characters; pass `path` to read one file]\n"
    }

    private static func title(of group: ChangeGroup) -> String {
        if case .stack(_, let branches) = group.kind { return "Assigned to \(branches.first ?? group.title)" }
        return group.title
    }

    private static func json(_ group: ChangeGroup) -> JSONValue {
        var object: [String: JSONValue] = [
            "title": .string(title(of: group)),
            "files": .array(group.files.map { file in
                var entry: [String: JSONValue] = ["path": .string(file.path), "change": .string(file.kind.rawValue)]
                if let previous = file.previousPath { entry["previousPath"] = .string(previous) }
                if let stats = file.stats {
                    entry["additions"] = .int(stats.additions)
                    entry["deletions"] = .int(stats.deletions)
                }
                return .object(entry)
            }),
        ]
        if case .stack(_, let branches) = group.kind { object["branches"] = .array(branches.map(JSONValue.string)) }
        return .object(object)
    }

    /// Commits listed per branch; the app lists more, but an agent rarely needs them.
    static let commitLimit = 50

    private static func json(_ group: HistoryGroup) -> JSONValue {
        [
            "kind": .string(group.kind == .stack ? "stack" : "localBranches"),
            "branches": .array(group.branches.map { branch in
                var object: [String: JSONValue] = [
                    "name": .string(branch.name),
                    "tip": .string(branch.tip),
                    "commits": .array(branch.commits.prefix(commitLimit).map { commit in
                        var entry: [String: JSONValue] = ["sha": .string(commit.sha), "summary": .string(commit.summary), "author": .string(commit.authorName)]
                        if let date = commit.date { entry["date"] = .string(date.formatted(.iso8601)) }
                        return .object(entry)
                    }),
                ]
                if let base = branch.baseName ?? branch.base { object["base"] = .string(base) }
                if branch.commits.count > commitLimit { object["moreCommits"] = .int(branch.commits.count - commitLimit) }
                if branch.isCurrent { object["isCurrent"] = true }
                return .object(object)
            }),
        ]
    }
}

/// A tool failure the agent sees as the call's result.
struct MCPToolError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// The tools `ohmydiff mcp` offers: read-only ones first, then those that move the app's focus.
enum MCPTool: String, CaseIterable {
    case listProjects = "list_projects"
    case listChanges = "list_changes"
    case getDiff = "get_diff"
    case listBranches = "list_branches"
    case openProject = "open_project"
    case showFile = "show_file"
    case showBranch = "show_branch"
    case showCommit = "show_commit"

    var isReadOnly: Bool {
        switch self {
        case .listProjects, .listChanges, .getDiff, .listBranches: true
        case .openProject, .showFile, .showBranch, .showCommit: false
        }
    }

    var title: String {
        switch self {
        case .listProjects: "List projects"
        case .listChanges: "List uncommitted changes"
        case .getDiff: "Get diff"
        case .listBranches: "List branches"
        case .openProject: "Open project"
        case .showFile: "Show file"
        case .showBranch: "Show branch"
        case .showCommit: "Show commit"
        }
    }

    var description: String {
        switch self {
        case .listProjects:
            "The repositories added to ohmydiff, with their paths."
        case .listChanges:
            "Uncommitted files of a repository with their line counts: staged, unstaged and untracked in plain git; "
                + "unassigned and per branch in a GitButler workspace."
        case .getDiff:
            "The unified diff of uncommitted changes (one file with `path`, else all), or of a commit with `commit`."
        case .listBranches:
            "Branches with their own commits, newest first: the applied stacks of a GitButler workspace, or the local branches."
        case .openProject:
            "Brings ohmydiff to the front with the repository selected, adding it as a project if it is new."
        case .showFile:
            "Brings ohmydiff to the front showing the uncommitted diff of a file, scrolled to `line` of the new file. "
                + "Use it to point the user at a change to review."
        case .showBranch:
            "Brings ohmydiff to the front showing a branch's whole diff in History mode."
        case .showCommit:
            "Brings ohmydiff to the front showing a commit's diff in History mode."
        }
    }

    private static let repositoryProperty: JSONValue = [
        "type": "string",
        "description": "Path of the repository or any folder inside it. Defaults to the folder the server was started in.",
    ]

    var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        if self != .listProjects { properties["repository"] = Self.repositoryProperty }
        switch self {
        case .getDiff:
            properties["path"] = ["type": "string", "description": "A file path, relative to the repository root or absolute."]
            properties["commit"] = ["type": "string", "description": "A commit SHA or revision; omit for uncommitted changes."]
        case .showFile:
            properties["path"] = ["type": "string", "description": "The changed file, relative to the repository or absolute."]
            properties["line"] = ["type": "integer", "minimum": 1, "description": "A line number in the new version of the file."]
            required = ["path"]
        case .showBranch:
            properties["name"] = ["type": "string", "description": "The branch name, as list_branches reports it."]
            required = ["name"]
        case .showCommit:
            properties["sha"] = ["type": "string", "description": "A commit SHA, full or abbreviated, on a branch list_branches reports."]
            required = ["sha"]
        case .listProjects, .listChanges, .listBranches, .openProject:
            break
        }
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    var definition: JSONValue {
        [
            "name": .string(rawValue),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ["readOnlyHint": .bool(isReadOnly), "openWorldHint": false],
        ]
    }
}
