import Foundation
import OhMyDiffCore

/// The installed ohmydiff, or ohmydiff Dev from `make run`. Dev has its own bundle identifier, so its own
/// settings, projects and Keychain items, and neither handles `ohmydiff://` links nor updates itself, so it runs
/// beside the installed app without touching it.
nonisolated enum AppVariant {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.koby.ohmydiff"
    static let isDev = bundleIdentifier.hasSuffix(".dev")

    /// `~/Library/Application Support/ohmydiff/projects.json`, or `ohmydiff Dev/` for Dev.
    static var projectStore: ProjectStore {
        ProjectStore(fileURL: isDev ? ProjectStore.fileURL(folder: "ohmydiff Dev") : ProjectStore.defaultFileURL)
    }
}
