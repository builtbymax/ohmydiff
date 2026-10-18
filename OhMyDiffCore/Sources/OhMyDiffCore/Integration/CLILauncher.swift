import Foundation

/// The `ohmydiff [path]` shell command and the `ohmydiff://open?path=…` URLs it opens.
public enum CLILauncher {
    public static let urlScheme = "ohmydiff"

    /// `~/.local/bin`, where Settings installs the command.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    /// Resolves the folder (default `.`) and hands it to the app, which adds it if it is new and focuses it.
    /// Every byte of the path is percent-encoded, which needs nothing beyond POSIX tools.
    public static let script = """
        #!/bin/sh
        # ohmydiff: open a git repository in ohmydiff. Installed from ohmydiff's Settings.
        set -eu

        case "${1:-}" in
            -h|--help)
                echo "usage: ohmydiff [path]   open the repository containing path (default: .) in ohmydiff"
                exit 0
                ;;
        esac

        target=${1:-.}
        if [ ! -d "$target" ]; then
            echo "ohmydiff: $target is not a directory" >&2
            exit 1
        fi
        path=$(cd "$target" && pwd -P)
        encoded=$(printf '%s' "$path" | od -An -tx1 -v | tr -d ' \\n' | sed 's/../%&/g')
        exec open "ohmydiff://open?path=$encoded"

        """

    /// Writes the command to `directory`/ohmydiff as an executable, replacing an earlier copy.
    @discardableResult
    public static func install(in directory: URL = defaultDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "ohmydiff")
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Whether `directory`/ohmydiff exists and matches the current script.
    public static func isInstalled(in directory: URL = defaultDirectory) -> Bool {
        (try? Data(contentsOf: directory.appending(path: "ohmydiff"))) == Data(script.utf8)
    }

    /// Whether a colon-separated search path contains `directory`.
    public static func searchPath(_ path: String, contains directory: URL) -> Bool {
        let target = directory.standardizedFileURL.path
        return path.split(separator: ":").contains {
            URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL.path == target
        }
    }

    /// The folder an `ohmydiff://open?path=…` URL asks for; `nil` for other URLs.
    public static func openRequestPath(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == urlScheme, url.host() == "open",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty
        else { return nil }
        return path
    }
}
