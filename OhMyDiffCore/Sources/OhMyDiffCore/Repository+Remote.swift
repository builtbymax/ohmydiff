import Foundation

extension Repository {
    /// The web page of the `origin` remote, or of the only remote, e.g. `https://github.com/owner/repo`.
    public func remoteWebURL() async -> URL? {
        guard let output = try? await toolchain.git(["remote"], in: root) else { return nil }
        let remotes = output.stdoutString.split(separator: "\n").map(String.init)
        guard let name = remotes.contains("origin") ? "origin" : remotes.first,
              let url = try? await toolchain.git(["remote", "get-url", name], in: root)
        else { return nil }
        return Self.webURL(forRemote: url.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `git@github.com:owner/repo.git`, `ssh://…` and `https://…` remotes as their https page;
    /// `nil` for local paths.
    static func webURL(forRemote remote: String) -> URL? {
        var host: String
        var path: String
        if remote.contains("://") {
            guard let components = URLComponents(string: remote), let scheme = components.scheme,
                  ["https", "http", "ssh", "git"].contains(scheme), let componentsHost = components.host
            else { return nil }
            (host, path) = (componentsHost, components.path)
        } else if let colon = remote.firstIndex(of: ":") {
            // scp-like syntax: `user@host:path`.
            let login = remote[..<colon]
            host = String(login.split(separator: "@").last ?? login)
            path = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(path)")
    }
}
