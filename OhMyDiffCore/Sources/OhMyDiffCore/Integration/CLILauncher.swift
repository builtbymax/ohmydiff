import Foundation

/// What an `ohmydiff://…` URL asks the app to show. The `ohmydiff` command and the MCP server build them.
public enum CLIRequest: Sendable, Hashable {
    /// The repository containing `path`, added as a project if it is new.
    case open(path: String)
    /// The uncommitted diff of the file at the absolute `path`, scrolled to `line` of the new file.
    case show(path: String, line: Int?)
    /// A branch of the repository containing `path`, in History mode.
    case branch(path: String, name: String)
    /// A commit of the repository containing `path`, in History mode; `sha` may be abbreviated.
    case commit(path: String, sha: String)

    /// Parses `ohmydiff://open?path=…`, `show?path=…&line=…`, `branch?path=…&name=…` and `commit?path=…&sha=…`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == CLILauncher.urlScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let path = value("path") else { return nil }
        switch url.host() {
        case "open":
            self = .open(path: path)
        case "show":
            self = .show(path: path, line: value("line").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil })
        case "branch":
            guard let name = value("name") else { return nil }
            self = .branch(path: path, name: name)
        case "commit":
            guard let sha = value("sha") else { return nil }
            self = .commit(path: path, sha: sha)
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = CLILauncher.urlScheme
        let items: [URLQueryItem]
        switch self {
        case .open(let path):
            components.host = "open"
            items = [URLQueryItem(name: "path", value: path)]
        case .show(let path, let line):
            components.host = "show"
            items = [URLQueryItem(name: "path", value: path)] + (line.map { [URLQueryItem(name: "line", value: String($0))] } ?? [])
        case .branch(let path, let name):
            components.host = "branch"
            items = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "name", value: name)]
        case .commit(let path, let sha):
            components.host = "commit"
            items = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "sha", value: sha)]
        }
        // Plain `queryItems` leave `&`, `=` and `+` alone, which would split or change the values.
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueCharacters))
        }
        return components.url!
    }

    private static let queryValueCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
}

/// The `ohmydiff` shell command and the `ohmydiff://…` URLs it opens.
public enum CLILauncher {
    public static let urlScheme = "ohmydiff"

    /// `~/.local/bin`, where Settings installs the command.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    /// The command. `app` is the app's executable, which `ohmydiff mcp` runs as the MCP server.
    ///
    /// Paths are resolved here, so the app gets absolute ones. Every byte of a value is percent-encoded,
    /// which needs nothing beyond POSIX tools.
    public static func script(app: String) -> String {
        """
        #!/bin/sh
        # ohmydiff: open repositories, files, branches and commits in ohmydiff. Installed from ohmydiff's Settings.
        set -eu

        \(appLine(app))

        usage() {
            cat <<'EOF'
        usage: ohmydiff [path]               open the repository containing path (default: .)
               ohmydiff open [path]          the same
               ohmydiff show <file>[:line]   show a changed file's diff, at a line of the new file
               ohmydiff branch <name> [path] show a branch of the repository in History
               ohmydiff commit <sha> [path]  show a commit of the repository in History
               ohmydiff mcp                  run the MCP server on stdin and stdout, for coding agents
        EOF
        }

        fail() {
            echo "ohmydiff: $1" >&2
            exit 1
        }

        encode() {
            printf '%s' "$1" | od -An -tx1 -v | tr -d ' \\n' | sed 's/../%&/g'
        }

        # The absolute, symlink-free form of a folder.
        folder() {
            [ -d "$1" ] || fail "$1 is not a directory"
            (cd "$1" && pwd -P)
        }

        case "${1:-}" in
            -h|--help|help)
                usage
                exit 0
                ;;
            open)
                shift
                ;;
            show)
                [ $# -ge 2 ] || { usage >&2; exit 2; }
                target=$2
                line=
                # `file:12` names line 12, unless a file is really called that.
                if [ ! -e "$target" ]; then
                    case "$target" in
                        *:*[0-9])
                            line=${target##*:}
                            case "$line" in *[!0-9]*) line= ;; *) target=${target%:*} ;; esac
                            ;;
                    esac
                fi
                # A deleted file no longer exists, but its folder does.
                dir=$(folder "$(dirname "$target")")
                [ -d "$target" ] && fail "$target is a directory"
                path="$dir/$(basename "$target")"
                exec open "ohmydiff://show?path=$(encode "$path")&line=$line"
                ;;
            branch|commit)
                [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }
                key=name
                [ "$1" = commit ] && key=sha
                path=$(folder "${3:-.}")
                exec open "ohmydiff://$1?path=$(encode "$path")&$key=$(encode "$2")"
                ;;
            mcp)
                [ -x "$app" ] || fail "the app is no longer at $app. Reinstall the command from ohmydiff's Settings."
                exec "$app" --mcp
                ;;
        esac

        path=$(folder "${1:-.}")
        exec open "ohmydiff://open?path=$(encode "$path")"

        """
    }

    public enum InstallState: Sendable {
        case missing
        case current
        /// An earlier version, or one pointing at the app in another place.
        case outdated
    }

    /// Writes the command to `directory`/ohmydiff as an executable, replacing an earlier copy.
    @discardableResult
    public static func install(app: String, in directory: URL = defaultDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "ohmydiff")
        try Data(script(app: app).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    public static func installState(app: String, in directory: URL = defaultDirectory) -> InstallState {
        guard let data = try? Data(contentsOf: directory.appending(path: "ohmydiff")) else { return .missing }
        return data == Data(script(app: app).utf8) ? .current : .outdated
    }

    /// Rewrites an installed command from an earlier version that points at this same `app`, e.g. after an
    /// update replaced the app in place. A command pointing at another copy of the app is left alone.
    @discardableResult
    public static func refresh(app: String, in directory: URL = defaultDirectory) throws -> Bool {
        let url = directory.appending(path: "ohmydiff")
        guard installState(app: app, in: directory) == .outdated,
              let text = try? String(contentsOf: url, encoding: .utf8),
              text.split(separator: "\n").contains(Substring(appLine(app)))
        else { return false }
        try install(app: app, in: directory)
        return true
    }

    private static func appLine(_ app: String) -> String {
        "app=\(EditorCommand.shellQuoted(app))"
    }

    /// Whether a colon-separated search path contains `directory`.
    public static func searchPath(_ path: String, contains directory: URL) -> Bool {
        let target = directory.standardizedFileURL.path
        return path.split(separator: ":").contains {
            URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL.path == target
        }
    }
}
