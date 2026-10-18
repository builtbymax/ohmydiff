import Foundation
import Synchronization
import Testing
@testable import OhMyDiffCore

@Suite struct MCPServerTests {
    /// A server for a test repository that records the URLs it would open instead of starting the app.
    private final class Recorder: Sendable {
        let urls = Mutex<[URL]>([])
    }

    private final class Harness {
        let repo: TestRepo
        let server: MCPServer
        let opened = Recorder()
        let store: ProjectStore

        init(repo: TestRepo) {
            self.repo = repo
            store = ProjectStore(fileURL: repo.directory.appending(path: "projects.json"))
            let opened = self.opened
            server = MCPServer(toolchain: repo.toolchain, workingDirectory: repo.root, projects: store) { url in
                opened.urls.withLock { $0.append(url) }
            }
        }

        func send(_ message: JSONValue) async throws -> JSONValue? {
            let data = try JSONEncoder().encode(message)
            guard let response = await server.handle(data) else { return nil }
            return try JSONDecoder().decode(JSONValue.self, from: response)
        }

        /// Calls a tool and returns its text and whether it reported an error.
        func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> (text: String, isError: Bool) {
            let response = try #require(try await send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]))
            let result = try #require(response["result"])
            guard case .array(let content)? = result["content"], let text = content.first?["text"]?.stringValue else {
                Issue.record("no text content in \(response)")
                return ("", true)
            }
            return (text, result["isError"] == .bool(true))
        }

        var lastRequest: CLIRequest? {
            opened.urls.withLock { $0.last }.flatMap(CLIRequest.init(url:))?.withoutPrivatePrefix
        }
    }

    @Test func answersTheHandshake() async throws {
        let harness = Harness(repo: try await TestRepo())
        let initialize = try #require(try await harness.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]],
        ]))
        #expect(initialize["id"] == .int(1))
        #expect(initialize["result"]?["protocolVersion"] == "2025-03-26")
        #expect(initialize["result"]?["serverInfo"]?["name"] == "ohmydiff")
        #expect(initialize["result"]?["capabilities"]?["tools"] != nil)

        let unknownVersion = try await harness.send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect(unknownVersion?["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))

        #expect(try await harness.send(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        #expect(try await harness.send(["jsonrpc": "2.0", "id": "p", "method": "ping"])?["result"] == [:])

        let list = try #require(try await harness.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))
        guard case .array(let tools)? = list["result"]?["tools"] else {
            Issue.record("no tools")
            return
        }
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names == MCPTool.allCases.map(\.rawValue))
        let showFile = try #require(tools.first { $0["name"] == "show_file" })
        #expect(showFile["inputSchema"]?["required"] == ["path"])
        #expect(showFile["annotations"]?["readOnlyHint"] == false)
    }

    @Test func reportsProtocolErrors() async throws {
        let harness = Harness(repo: try await TestRepo())
        let garbage = try JSONDecoder().decode(JSONValue.self, from: try #require(await harness.server.handle(Data("{nope".utf8))))
        #expect(garbage["error"]?["code"] == -32700)
        #expect(try await harness.send(["jsonrpc": "2.0", "id": 1, "method": "resources/list"])?["error"]?["code"] == -32601)
        #expect(try await harness.send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "rm_rf"]])?["error"]?["code"] == -32602)
    }

    @Test func readsChangesAndDiffs() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("init")
        try repo.write("a.txt", "one\nTWO\n")
        try repo.write("new.txt", "fresh\n")
        let harness = Harness(repo: repo)

        let changes = try await harness.call("list_changes")
        #expect(!changes.isError)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(changes.text.utf8))
        #expect(parsed["kind"] == "git")
        guard case .array(let groups)? = parsed["groups"] else {
            Issue.record("no groups")
            return
        }
        #expect(groups.compactMap { $0["title"]?.stringValue } == ["Unstaged", "Untracked"])
        #expect(groups.first?["files"] == [["path": "a.txt", "change": "modified", "additions": 1, "deletions": 1]])

        let diff = try await harness.call("get_diff", ["path": "a.txt"])
        #expect(diff.text.contains("# Unstaged"))
        #expect(diff.text.contains("diff --git a/a.txt b/a.txt"))
        #expect(diff.text.contains("-two\n+TWO\n"))
        #expect(!diff.text.contains("new.txt"))

        let all = try await harness.call("get_diff")
        #expect(all.text.contains("+fresh"))

        let absolute = try await harness.call("get_diff", ["path": .string(repo.root.appending(path: "new.txt").path)])
        #expect(absolute.text.contains("new file mode"))

        let unchanged = try await harness.call("get_diff", ["path": "nothing.txt"])
        #expect(unchanged.isError)
    }

    @Test func readsCommitsAndBranches() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("init")
        try await repo.git("checkout", "-q", "-b", "feat/x")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("add two")
        let sha = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let harness = Harness(repo: repo)

        let commit = try await harness.call("get_diff", ["commit": .string(String(sha.prefix(8)))])
        #expect(commit.text.contains("+two"))

        let branches = try await harness.call("list_branches")
        #expect(branches.text.contains("\"name\" : \"feat/x\""))
        #expect(branches.text.contains("\"summary\" : \"add two\""))

        #expect(try await harness.call("show_commit", ["sha": .string(String(sha.prefix(8)))]).isError == false)
        #expect(harness.lastRequest == .commit(path: repo.root.path, sha: sha))

        #expect(try await harness.call("show_branch", ["name": "feat/x"]).isError == false)
        #expect(harness.lastRequest == .branch(path: repo.root.path, name: "feat/x"))

        let missing = try await harness.call("show_branch", ["name": "nope"])
        #expect(missing.isError)
        #expect(missing.text.contains("feat/x"))
        #expect(try await harness.call("show_commit", ["sha": "deadbeef"]).isError)
    }

    @Test func pointsTheAppAtChangedFiles() async throws {
        let repo = try await TestRepo()
        try repo.write("src/a.txt", "one\n")
        try await repo.commitAll("init")
        try repo.write("src/a.txt", "one\ntwo\n")
        let harness = Harness(repo: repo)

        let shown = try await harness.call("show_file", ["path": "src/a.txt", "line": 2])
        #expect(!shown.isError)
        #expect(harness.lastRequest == .show(path: repo.root.appending(path: "src/a.txt").path, line: 2))

        let clean = try await harness.call("show_file", ["path": "README.md"])
        #expect(clean.isError)
        #expect(try await harness.call("show_file", ["path": "/elsewhere/x.txt"]).isError)

        #expect(try await harness.call("open_project", ["repository": "src"]).isError == false)
        #expect(harness.lastRequest == .open(path: repo.root.path))
    }

    @Test func listsProjects() async throws {
        let harness = Harness(repo: try await TestRepo())
        try harness.store.save([Project(path: "/code/app", kind: .gitButler)])
        let text = try await harness.call("list_projects").text
        #expect(text.contains("\"path\" : \"/code/app\""))
        #expect(text.contains("\"kind\" : \"gitButler\""))
    }

    @Test func cutsLongDiffs() {
        let long = String(repeating: "x", count: MCPServer.diffCharacterLimit + 10)
        #expect(MCPServer.limited(long).count < long.count + 100)
        #expect(MCPServer.limited(long).hasSuffix("to read one file]\n"))
        #expect(MCPServer.limited("short") == "short")
    }
}

@Suite struct DiffTextTests {
    @Test func printsPatchesGitCanApply() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\ntwo\nthree")
        try await repo.commitAll("init")
        try repo.write("a.txt", "one\n2\nthree\nfour")
        let repository = try await repo.open()
        let file = try #require(try await repository.changeGroups().allFiles.first)
        let diff = try #require(try await repository.diff(for: file))
        // Reverse-applying the printed patch must restore the committed file.
        _ = try await repo.toolchain.git(["apply", "--reverse", "-"], in: repo.root, input: Data(diff.patch.utf8))
        #expect(try await repo.git("status", "--porcelain").isEmpty)
    }
}
