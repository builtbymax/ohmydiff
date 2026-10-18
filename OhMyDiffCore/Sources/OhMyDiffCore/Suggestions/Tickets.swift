import Foundation

/// An issue tracker tickets can come from.
public enum TicketSource: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case linear
    case jira
    case github
    case gitlab

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .linear: "Linear"
        case .jira: "Jira"
        case .github: "GitHub Issues"
        case .gitlab: "GitLab Issues"
        }
    }

    /// Whether its tickets are keys like `HAL-128` rather than numbers like `#42`.
    var usesKeys: Bool { self == .linear || self == .jira }
}

/// A ticket whose details a suggestion can use.
public struct Ticket: Sendable, Hashable, Identifiable {
    /// `HAL-128` for Linear and Jira, `#42` for GitHub and GitLab.
    public var id: String
    public var title: String
    public var description: String
    public var url: URL?
    public var source: TicketSource

    public init(id: String, title: String, description: String = "", url: URL? = nil, source: TicketSource) {
        self.id = id
        self.title = title
        self.description = description
        self.url = url
        self.source = source
    }
}

/// How a branch name or search refers to a ticket.
public enum TicketKey: Sendable, Hashable {
    /// `HAL-128`, upper-cased.
    case key(String)
    /// `42`, from `#42`, `42-fix-crash` or `issue-42`.
    case number(Int)

    /// The keys a branch name refers to, most likely first. Only the start of each `/`-separated part
    /// counts, so `feature/hal-128-ai` finds `HAL-128` while words like `add-2-things` mostly do not.
    /// Lookups confirm the guesses.
    public static func keys(inBranch branch: String) -> [TicketKey] {
        var keys: [TicketKey] = []
        for part in branch.split(separator: "/").reversed() {
            let part = String(part)
            // `issue-42` is GitHub's or GitLab's issue 42, not a Jira project called ISSUE.
            if let match = part.firstMatch(of: /^([A-Za-z][A-Za-z0-9]{1,9})-(\d{1,7})(?:\b|_|$)/),
               !["ISSUE", "ISSUES", "GH", "GL"].contains(match.1.uppercased()) {
                keys.append(.key("\(match.1.uppercased())-\(match.2)"))
            } else if let match = part.firstMatch(of: /^(?:#|(?:issue|issues|gh|gl)-)?(\d{1,7})(?:-|_|$)/.ignoresCase()),
                      let number = Int(match.1) {
                keys.append(.number(number))
            }
        }
        var seen = Set<TicketKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// The key a search query names directly, e.g. `hal-128` or `#42`.
    public init?(query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        if let match = query.wholeMatch(of: /([A-Za-z][A-Za-z0-9]{1,9})-(\d{1,7})/) {
            self = .key("\(match.1.uppercased())-\(match.2)")
        } else if let match = query.wholeMatch(of: /#?(\d{1,7})/), let number = Int(match.1) {
            self = .number(number)
        } else {
            return nil
        }
    }
}

public enum TicketError: Error, Sendable, CustomStringConvertible {
    case notConfigured(TicketSource)
    case request(TicketSource, String)
    case toolNotFound(String)

    public var description: String {
        switch self {
        case .notConfigured(let source): "\(source.displayName) is not connected. Connect it in Settings → Tickets."
        case .request(let source, let message): "\(source.displayName): \(message)"
        case .toolNotFound(let tool): "`\(tool)` was not found on your login shell PATH."
        }
    }
}

/// Looks up and searches the tickets of one tracker.
public protocol TicketProvider: Sendable {
    var source: TicketSource { get }
    /// The ticket `key` names; `nil` when the tracker has no such ticket.
    func ticket(_ key: TicketKey) async throws -> Ticket?
    func search(_ query: String) async throws -> [Ticket]
}

/// Sends an HTTP request; swapped out in tests.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public let urlSessionTransport: HTTPTransport = { request in try await URLSession.shared.data(for: request) }

// MARK: - Linear

/// Linear's GraphQL API with a personal API key.
public struct LinearTickets: TicketProvider {
    public let source = TicketSource.linear
    let apiKey: String
    let transport: HTTPTransport

    public init(apiKey: String, transport: @escaping HTTPTransport = urlSessionTransport) {
        self.apiKey = apiKey
        self.transport = transport
    }

    static let endpoint = URL(string: "https://api.linear.app/graphql")!
    private static let fields = "identifier title description url"

    public func ticket(_ key: TicketKey) async throws -> Ticket? {
        guard case .key(let id) = key else { return nil }
        let data = try await query("query($id: String!) { issue(id: $id) { \(Self.fields) } }", variables: ["id": .string(id)])
        guard let issue = data["issue"], case .object = issue else { return nil }
        return Self.ticket(issue)
    }

    public func search(_ query: String) async throws -> [Ticket] {
        let data = try await self.query(
            "query($term: String!) { searchIssues(term: $term, first: 10) { nodes { \(Self.fields) } } }",
            variables: ["term": .string(query)])
        guard case .array(let nodes)? = data["searchIssues"]?["nodes"] else { return [] }
        return nodes.compactMap(Self.ticket)
    }

    private func query(_ query: String, variables: [String: JSONValue]) async throws -> JSONValue {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["query": .string(query), "variables": .object(variables)]))
        let (data, response) = try await transport(request)
        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            throw TicketError.request(source, "the API key was rejected.")
        }
        if case .array(let errors)? = body?["errors"], let first = errors.first {
            // A missing issue is an error in GraphQL, not an empty result.
            if first["extensions"]?["code"] == "INPUT_ERROR" || first["message"]?.stringValue?.contains("not found") == true {
                return [:]
            }
            throw TicketError.request(source, first["message"]?.stringValue ?? "the request failed.")
        }
        guard let result = body?["data"] else { throw TicketError.request(source, "unexpected response.") }
        return result
    }

    static func ticket(_ issue: JSONValue) -> Ticket? {
        guard let id = issue["identifier"]?.stringValue, let title = issue["title"]?.stringValue else { return nil }
        return Ticket(
            id: id, title: title, description: issue["description"]?.stringValue ?? "",
            url: issue["url"]?.stringValue.flatMap(URL.init(string:)), source: .linear)
    }
}

// MARK: - Jira

/// Jira Cloud's REST API with an account email and API token.
public struct JiraTickets: TicketProvider {
    public let source = TicketSource.jira
    /// e.g. `https://example.atlassian.net`.
    let site: URL
    let email: String
    let token: String
    let transport: HTTPTransport

    public init(site: URL, email: String, token: String, transport: @escaping HTTPTransport = urlSessionTransport) {
        self.site = site
        self.email = email
        self.token = token
        self.transport = transport
    }

    /// `example.atlassian.net` or a full address, as typed in Settings.
    public static func siteURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    public func ticket(_ key: TicketKey) async throws -> Ticket? {
        guard case .key(let id) = key else { return nil }
        let (status, body) = try await get("rest/api/2/issue/\(id)", query: [URLQueryItem(name: "fields", value: "summary,description")])
        if status == 404 { return nil }
        return body.flatMap(ticket)
    }

    public func search(_ query: String) async throws -> [Ticket] {
        let jql = if case .key(let id)? = TicketKey(query: query) {
            "key = \"\(id)\""
        } else {
            "text ~ \"\(query.replacing("\\", with: "\\\\").replacing("\"", with: "\\\""))\" ORDER BY updated DESC"
        }
        let (_, body) = try await get("rest/api/2/search/jql", query: [
            URLQueryItem(name: "jql", value: jql), URLQueryItem(name: "fields", value: "summary,description"),
            URLQueryItem(name: "maxResults", value: "10"),
        ])
        guard case .array(let issues)? = body?["issues"] else { return [] }
        return issues.compactMap(ticket)
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> (Int, JSONValue?) {
        var components = URLComponents(url: site.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw TicketError.request(source, "the email or API token was rejected.") }
        // Jira answers 400 for a JQL key that does not exist; treat it like no match.
        if status == 400, path.hasSuffix("search/jql") { return (status, nil) }
        guard status == 404 || (200..<300).contains(status) else {
            throw TicketError.request(source, "the request failed with status \(status).")
        }
        return (status, try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    func ticket(_ issue: JSONValue) -> Ticket? {
        guard let key = issue["key"]?.stringValue, let title = issue["fields"]?["summary"]?.stringValue else { return nil }
        return Ticket(
            id: key, title: title, description: issue["fields"]?["description"]?.stringValue ?? "",
            url: site.appending(path: "browse/\(key)"), source: .jira)
    }
}

// MARK: - GitHub and GitLab

/// GitHub or GitLab issues of the repository, through the signed-in `gh` or `glab` CLI.
public struct ForgeTickets: TicketProvider {
    public let source: TicketSource
    let root: URL
    let toolchain: Toolchain

    /// `source` must be `.github` or `.gitlab`.
    public init(source: TicketSource, root: URL, toolchain: Toolchain) {
        precondition(source == .github || source == .gitlab)
        self.source = source
        self.root = root
        self.toolchain = toolchain
    }

    var tool: String { source == .github ? "gh" : "glab" }

    public func ticket(_ key: TicketKey) async throws -> Ticket? {
        guard case .number(let number) = key else { return nil }
        let arguments = source == .github
            ? ["issue", "view", String(number), "--json", "number,title,body,url"]
            : ["issue", "view", String(number), "--output", "json"]
        // Both exit non-zero for a missing issue.
        guard let output = try await run(arguments, allowFailure: true) else { return nil }
        return Self.ticket(try JSONDecoder().decode(JSONValue.self, from: output), source: source)
    }

    public func search(_ query: String) async throws -> [Ticket] {
        if let key = TicketKey(query: query), case .number = key {
            return try await ticket(key).map { [$0] } ?? []
        }
        let arguments = source == .github
            ? ["issue", "list", "--search", query, "--state", "all", "--limit", "10", "--json", "number,title,body,url"]
            : ["issue", "list", "--search", query, "--all", "--per-page", "10", "--output", "json"]
        guard let output = try await run(arguments, allowFailure: false),
              case .array(let issues) = try JSONDecoder().decode(JSONValue.self, from: output)
        else { return [] }
        return issues.compactMap { Self.ticket($0, source: source) }
    }

    private func run(_ arguments: [String], allowFailure: Bool) async throws -> Data? {
        guard let executable = Toolchain.locate(tool, in: toolchain.environment["PATH"] ?? "") else { throw TicketError.toolNotFound(tool) }
        let output = try await toolchain.runner.run(
            executable, arguments: arguments, currentDirectory: root, environment: toolchain.environment, timeout: .seconds(20))
        guard output.exitCode == 0 else {
            if allowFailure { return nil }
            throw TicketError.request(source, output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.stdout
    }

    /// An issue from `gh … --json number,title,body,url` or `glab … --output json`.
    static func ticket(_ issue: JSONValue, source: TicketSource) -> Ticket? {
        guard let number = (issue["number"] ?? issue["iid"])?.intValue, let title = issue["title"]?.stringValue else { return nil }
        return Ticket(
            id: "#\(number)", title: title,
            description: (issue["body"] ?? issue["description"])?.stringValue ?? "",
            url: (issue["url"] ?? issue["web_url"])?.stringValue.flatMap(URL.init(string:)), source: source)
    }
}

// MARK: - Resolving

/// Finds tickets across the connected trackers.
public struct TicketResolver: Sendable {
    public let providers: [any TicketProvider]

    public init(providers: [any TicketProvider]) {
        self.providers = providers
    }

    public var isEmpty: Bool { providers.isEmpty }

    /// The ticket a branch name refers to, e.g. `feature/hal-128` → HAL-128; `nil` when none is found.
    /// Lookup failures count as not found, so a tracker being down never blocks a commit.
    public func ticket(forBranch branch: String) async -> Ticket? {
        for key in TicketKey.keys(inBranch: branch) {
            for provider in providers where Self.accepts(provider.source, key) {
                if let ticket = try? await provider.ticket(key) { return ticket }
            }
        }
        return nil
    }

    /// Matches from every tracker, in provider order. Throws only when every tracker failed.
    public func search(_ query: String) async throws -> [Ticket] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let results = await withTaskGroup(of: (Int, Result<[Ticket], Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do { return (index, .success(try await provider.search(query))) } catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<[Ticket], Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var tickets: [Ticket] = []
        var failures: [Error] = []
        for result in results {
            switch result {
            case .success(let found): tickets += found
            case .failure(let error): failures.append(error)
            }
        }
        if failures.count == results.count, let failure = failures.first { throw failure }
        return tickets
    }

    static func accepts(_ source: TicketSource, _ key: TicketKey) -> Bool {
        switch key {
        case .key: source.usesKeys
        case .number: !source.usesKeys
        }
    }
}
