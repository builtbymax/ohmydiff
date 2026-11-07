import Foundation
import Observation
import OhMyDiffCore

/// A project's AI review findings, by what was reviewed: from the Review task, or added by an agent through the
/// MCP server. Advisory only; nothing here changes the code.
@Observable
final class ReviewFindings {
    enum State: Equatable {
        case reviewing
        /// `isCut` when files were left out to keep the prompt short.
        case done(isCut: Bool)
        case failed(String)
    }

    private(set) var findings: [ReviewScope: [ReviewFinding]] = [:]
    private(set) var states: [ReviewScope: State] = [:]
    /// Findings handed to the agent with Apply.
    private(set) var applied: Set<ReviewFinding.ID> = []
    @ObservationIgnored private var tasks: [ReviewScope: Task<Void, Never>] = [:]

    /// A scope's findings for one file, most severe first.
    func findings(for scope: ReviewScope, path: String) -> [ReviewFinding] {
        (findings[scope] ?? []).filter { $0.path == path }.sorted { $0.severity < $1.severity }
    }

    func count(for scope: ReviewScope) -> Int { findings[scope]?.count ?? 0 }

    /// Reviews the diffs `load` returns with the provider's Review task; replaces the findings the task made
    /// before and keeps those an agent added.
    func review(
        _ scope: ReviewScope, description: String, suggestions: @escaping () async -> Suggestions?,
        load: @escaping () async throws -> [FileDiff]
    ) {
        tasks[scope]?.cancel()
        states[scope] = .reviewing
        let provider = AppSettings.suggestionProvider()?.displayName ?? "AI"
        tasks[scope] = Task {
            let entry = ActivityLog.shared.begin("Reviewing changes", detail: "\(provider) · \(scope.title)", isAI: true)
            var failure: String?
            defer { ActivityLog.shared.finish(entry, failure: failure) }
            do {
                guard let suggestions = await suggestions() else { throw SuggestionUnavailable.noToolchain }
                let suggester = try suggestions.suggester(for: .review)
                let diffs = try await load()
                let result = try await suggester.review(diffs, description: description)
                guard !Task.isCancelled else { return }
                findings[scope] = (findings[scope] ?? []).filter { $0.origin != .task } + result.findings
                states[scope] = .done(isCut: result.isCut)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failure = String(describing: error)
                states[scope] = .failed(String(describing: error))
            }
        }
    }

    func cancel(_ scope: ReviewScope) {
        tasks[scope]?.cancel()
        tasks[scope] = nil
        if states[scope] == .reviewing { states[scope] = nil }
    }

    /// Adds a finding, e.g. from an agent; it shows with the task's.
    func add(_ finding: ReviewFinding, to scope: ReviewScope) {
        findings[scope, default: []].append(finding)
    }

    func dismiss(_ id: ReviewFinding.ID) {
        for scope in findings.keys {
            findings[scope]?.removeAll { $0.id == id }
        }
        applied.remove(id)
    }

    /// Drops a scope's findings and its state.
    func clear(_ scope: ReviewScope) {
        cancel(scope)
        findings[scope] = nil
        states[scope] = nil
    }

    func markApplied(_ id: ReviewFinding.ID) { applied.insert(id) }
}

extension ReviewScope {
    var title: String {
        switch self {
        case .uncommitted: "uncommitted changes"
        case .commit(let sha): "commit \(sha.prefix(7))"
        case .branch(let name): name
        }
    }
}
