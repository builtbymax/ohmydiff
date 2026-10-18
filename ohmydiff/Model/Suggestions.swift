import Foundation
import OhMyDiffCore

enum SuggestionUnavailable: Error, CustomStringConvertible {
    /// Suggestions are off in Settings → AI.
    case noProvider
    case noToolchain

    var description: String {
        switch self {
        case .noProvider: "No AI Provider is selected. Choose one in Settings → AI."
        case .noToolchain: "git was not found on your login shell PATH."
        }
    }
}

/// What suggestions need from a project, read from Settings each time so changes apply at once.
struct Suggestions {
    let root: URL
    let toolchain: Toolchain

    var tickets: TicketResolver { AppSettings.ticketResolver(root: root, toolchain: toolchain) }

    func suggester() throws -> Suggester {
        guard let suggester = AppSettings.suggester(toolchain: toolchain) else { throw SuggestionUnavailable.noProvider }
        return suggester
    }

    func commitMessage(_ context: TemplateContext) async throws -> String {
        try await suggester().commitMessage(template: AppSettings.commitTemplate(), context: context, in: root)
    }

    func branchName(_ context: TemplateContext) async throws -> String {
        try await suggester().branchName(context: context, in: root)
    }

    func pullRequest(_ context: TemplateContext) async throws -> String {
        try await suggester().pullRequest(template: AppSettings.pullRequestTemplate(), context: context, in: root)
    }

    /// `<short sha> <subject>` per commit, newest first, for `{{commits}}`.
    static func commitLog(_ commits: [CommitInfo]) -> String {
        commits.map { "\($0.shortSHA) \($0.summary)" }.joined(separator: "\n")
    }
}
