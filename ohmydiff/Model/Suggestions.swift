import Foundation
import OhMyDiffCore

enum SuggestionUnavailable: Error, CustomStringConvertible {
    /// Suggestions are off in Settings → AI.
    case noProvider
    case noToolchain
    /// The task is turned off in Settings → AI.
    case turnedOff(AITask)

    var description: String {
        switch self {
        case .turnedOff(let task): "\(task.title) are turned off in Settings → AI."
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

    func suggester(for task: AITask = .commitMessage) throws -> Suggester {
        guard AppSettings.suggestionProvider() != nil else { throw SuggestionUnavailable.noProvider }
        guard let suggester = AppSettings.suggester(for: task, toolchain: toolchain) else { throw SuggestionUnavailable.turnedOff(task) }
        return suggester
    }

    /// Leaves out what Settings → AI → What gets sent turned off.
    static func filtered(_ context: TemplateContext) -> TemplateContext {
        var context = context
        if !AppSettings.isOn(AppSettings.aiSendsCommitsKey) {
            context.commits = ""
            context.branch = ""
        }
        if !AppSettings.isOn(AppSettings.aiSendsTicketKey) { context.ticket = nil }
        return context
    }

    func commitMessage(_ context: TemplateContext) async throws -> String {
        var rules: [String] = []
        if let instruction = AppSettings.commitStyle().instruction { rules.append(instruction) }
        rules.append("Keep the title under \(AppSettings.titleLimit()) characters.")
        if AppSettings.isOn(AppSettings.addsTicketToTitleKey), context.ticket != nil {
            rules.append("End the title with the ticket id in parentheses, e.g. (HAL-128).")
        }
        let template = AppSettings.commitTemplate() + "\n\n" + rules.joined(separator: "\n")
        return try await suggester(for: .commitMessage).commitMessage(template: template, context: Self.filtered(context))
    }

    func branchName(_ context: TemplateContext) async throws -> String {
        try await suggester(for: .branchName).branchName(context: Self.filtered(context))
    }

    func pullRequest(_ context: TemplateContext) async throws -> String {
        try await suggester(for: .pullRequest).pullRequest(template: AppSettings.pullRequestTemplate(), context: Self.filtered(context))
    }

    /// `<short sha> <subject>` per commit, newest first, for `{{commits}}`.
    static func commitLog(_ commits: [CommitInfo]) -> String {
        commits.map { "\($0.shortSHA) \($0.summary)" }.joined(separator: "\n")
    }
}
