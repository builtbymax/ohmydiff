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

    /// Throws why `task` cannot run, before any work for it is done.
    func checkReady(_ task: AITask) throws {
        guard AppSettings.isEnabled(task) else { throw SuggestionUnavailable.turnedOff(task) }
        if AppSettings.runsOnDevice(task) {
            if OnDeviceModel.isAvailable { return }
            if AppSettings.suggestionProvider() == nil, let reason = OnDeviceModel.unavailableReason { throw OnDeviceModel.Failure.unavailable(reason) }
        }
        _ = try suggester(for: task)
    }

    /// Runs `task` on Apple's on-device model when Settings → AI says so and it can, else with the CLI provider:
    /// when the model is not available here, or the changes are too large for it and a provider is chosen.
    private func run<Result>(
        _ task: AITask, onDevice: () async throws -> Result, provider: (Suggester) async throws -> Result
    ) async throws -> Result {
        try checkReady(task)
        if AppSettings.runsOnDevice(task), OnDeviceModel.isAvailable {
            do {
                return try await onDevice()
            } catch OnDeviceModel.Failure.tooLarge(_, _) where AppSettings.suggestionProvider() != nil {
                // The provider takes larger changes.
            }
        }
        return try await provider(try suggester(for: task))
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
        let context = Self.filtered(context)
        let style: CommitParts.Style = switch AppSettings.commitStyle() {
        case .conventional: .conventional
        case .gitmoji: .gitmoji
        case .free: .free
        }
        return try await run(.commitMessage) {
            try await OnDeviceModel.commitMessage(
                context: context, style: style, titleLimit: AppSettings.titleLimit(),
                ticketInTitle: AppSettings.isOn(AppSettings.addsTicketToTitleKey))
        } provider: { suggester in
            try await suggester.commitMessage(template: template, context: context)
        }
    }

    /// Both ways of asking throw rather than return no names.
    func branchName(_ context: TemplateContext) async throws -> String {
        try await branchNames(context)[0]
    }

    func branchNames(_ context: TemplateContext) async throws -> [String] {
        let context = Self.filtered(context)
        return try await run(.branchName) {
            try await OnDeviceModel.branchNames(context: context)
        } provider: { suggester in
            try await suggester.branchNames(context: context)
        }
    }

    func pullRequest(_ context: TemplateContext) async throws -> String {
        try await suggester(for: .pullRequest).pullRequest(template: AppSettings.pullRequestTemplate(), context: Self.filtered(context))
    }

    /// `<short sha> <subject>` per commit, newest first, for `{{commits}}`.
    static func commitLog(_ commits: [CommitInfo]) -> String {
        commits.map { "\($0.shortSHA) \($0.summary)" }.joined(separator: "\n")
    }
}
