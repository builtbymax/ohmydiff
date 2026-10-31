import Foundation
import Observation
import OhMyDiffCore
import SwiftUI

/// The Pull requests page of one project: pull requests that need the user, theirs, and what merged lately,
/// with the selected one's files and where to look first.
@Observable
final class PullRequestsModel {
    enum Filter: Hashable {
        case mine
        case reviewRequested
        case allOpen
    }

    enum Phase: Equatable {
        case idle
        case ready
        case unavailable(String)
        case failed(String)
    }

    /// A hunk the AI thinks changes behaviour.
    struct FocusHunk: Hashable, Identifiable {
        var path: String
        /// One-based, as shown.
        var hunk: Int
        var reason: String
        var id: String { "\(path)#\(hunk)" }
    }

    enum Focus: Equatable {
        case loading
        case loaded(summary: String, hunks: [FocusHunk])
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var items: [InboxPullRequest] = []
    private(set) var viewer: String?
    var filter = Filter.reviewRequested
    var selectedNumber: Int?
    private(set) var files: [Int: PullRequestFiles] = [:]
    private(set) var diffs: [Int: [FileDiff]] = [:]
    private(set) var focus: [Int: Focus] = [:]
    private(set) var isSubmitting = false
    var actionError: String?

    @ObservationIgnored private var repository: Repository?
    @ObservationIgnored private var loaded: Date?

    var selected: InboxPullRequest? { items.first { $0.number == selectedNumber } }

    // MARK: Sections

    func needsYou(_ item: InboxPullRequest) -> Bool {
        item.state == .open && !isMine(item) && (viewer.map(item.reviewRequests.contains) ?? false)
    }

    func isMine(_ item: InboxPullRequest) -> Bool { viewer != nil && item.author == viewer }

    /// Merged in the last seven days.
    func isRecentlyMerged(_ item: InboxPullRequest) -> Bool {
        guard item.state == .merged, let mergedAt = item.mergedAt else { return false }
        return Date.now.timeIntervalSince(mergedAt) < 7 * 24 * 3600
    }

    /// The sections the filter shows, in order, without empty ones.
    var sections: [(title: String, items: [InboxPullRequest])] {
        let open = items.filter { $0.state == .open }
        let needs = open.filter(needsYou)
        let mine = open.filter(isMine)
        let others = open.filter { !needsYou($0) && !isMine($0) }
        let merged = items.filter(isRecentlyMerged)
        let all: [(String, [InboxPullRequest])] = switch filter {
        case .reviewRequested: [("Needs you", needs)]
        case .mine: [("Yours", mine), ("Merged this week", merged.filter(isMine))]
        case .allOpen: [("Needs you", needs), ("Yours", mine), ("Others", others), ("Merged this week", merged)]
        }
        return all.filter { !$0.1.isEmpty }.map { (title: $0.0, items: $0.1) }
    }

    func count(_ filter: Filter) -> Int {
        let open = items.filter { $0.state == .open }
        return switch filter {
        case .mine: open.filter(isMine).count
        case .reviewRequested: open.filter(needsYou).count
        case .allOpen: open.count
        }
    }

    // MARK: Loading

    func refresh(_ repository: Repository, force: Bool = false) async {
        self.repository = repository
        guard repository.canManagePullRequests else {
            phase = .unavailable("Install the GitHub CLI (gh) and sign in with gh auth login to see pull requests.")
            return
        }
        guard force || loaded.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
        loaded = .now
        if viewer == nil { viewer = await repository.gitHubViewer() }
        do {
            let items = try await repository.inbox()
            // A pull request that changed since (a push, a review) loads its diff and files again.
            let before = Dictionary(self.items.map { ($0.number, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
            for item in items where before[item.number] != nil && before[item.number] != item.updatedAt {
                diffs[item.number] = nil
                files[item.number] = nil
                focus[item.number] = nil
            }
            if items != self.items { self.items = items }
            phase = .ready
            // Start with what needs the user; with nothing there, show everything open.
            if filter == .reviewRequested, count(.reviewRequested) == 0 { filter = count(.mine) > 0 ? .mine : .allOpen }
            if selected == nil || !sections.contains(where: { $0.items.contains { $0.number == selectedNumber } }) {
                selectedNumber = sections.first?.items.first?.number
            }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func loadFiles(of number: Int) async {
        guard let repository, let found = try? await repository.files(of: number) else { return }
        files[number] = found
    }

    func loadDiff(of number: Int) async -> [FileDiff]? {
        if let diff = diffs[number] { return diff }
        guard let repository else { return nil }
        do {
            let diff = try await repository.diff(ofPullRequest: number)
            diffs[number] = diff
            return diff
        } catch {
            actionError = String(describing: error)
            return nil
        }
    }

    func toggleViewed(_ file: PullRequestFile, in number: Int) async {
        guard let repository, var current = files[number], let index = current.files.firstIndex(of: file) else { return }
        current.files[index].isViewed.toggle()
        files[number] = current
        do {
            try await repository.setViewed(current.files[index].isViewed, path: file.path, pullRequestNodeID: current.nodeID)
        } catch {
            current.files[index].isViewed.toggle()
            files[number] = current
            actionError = String(describing: error)
        }
    }

    func submit(_ verdict: ReviewVerdict, body: String, on item: InboxPullRequest) async -> Bool {
        guard let repository, !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await repository.review(item.number, verdict: verdict, body: body)
            Toasts.shared.show(
                verdict == .comment ? "Commented on #\(item.number)" : verdict == .approve ? "Approved #\(item.number)" : "Requested changes on #\(item.number)",
                systemImage: verdict == .comment ? "bubble.left" : "checkmark.circle", tint: Theme.okFg,
                action: .init(title: "Open #\(item.number)") { NSWorkspace.shared.open(item.url) })
            await refresh(repository, force: true)
            return true
        } catch {
            actionError = String(describing: error)
            return false
        }
    }

    // MARK: Where to look first

    /// Asks the AI which hunks change behaviour; sends only the pull request's diff and description.
    func findFocus(for item: InboxPullRequest, description: String, suggestions: Suggestions?) async {
        focus[item.number] = .loading
        do {
            guard let suggestions else { throw SuggestionUnavailable.noToolchain }
            guard let diffs = await loadDiff(of: item.number) else { throw SuggestionUnavailable.noToolchain }
            let suggester = try suggestions.suggester(for: .pullRequest)
            let answer = try await suggester.complete(Self.focusPrompt(item: item, description: description, diffs: diffs))
            let parsed = Self.parseFocus(answer)
            focus[item.number] = .loaded(summary: parsed.summary, hunks: parsed.hunks)
        } catch {
            focus[item.number] = .failed(String(describing: error))
        }
    }

    static func focusPrompt(item: InboxPullRequest, description: String, diffs: [FileDiff]) -> String {
        // Number the hunks so the answer can point at them.
        var numbered = ""
        for diff in diffs {
            numbered += "=== \(diff.path)\n"
            for (index, hunk) in diff.hunks.enumerated() {
                numbered += "--- hunk \(index + 1) \(hunk.header)\n"
                numbered += hunk.lines.map { line in
                    (line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " ") + line.text
                }.joined(separator: "\n") + "\n"
            }
        }
        return """
        You review a pull request. Find the at most 3 hunks that change behaviour, as opposed to moving or renaming code, \
        formatting, tests or docs.

        Answer with one line of summary, e.g. "Most of this PR moves code. These 3 hunks change behaviour:", then one line \
        per hunk exactly as: path | hunk number | why it matters in under 8 words

        Title: \(item.title)
        Description:
        \(description.isEmpty ? "(none)" : description)

        Diff, hunks numbered per file:
        \(PromptTemplate.limitedDiff(numbered))
        """
    }

    static func parseFocus(_ answer: String) -> (summary: String, hunks: [FocusHunk]) {
        var summary = ""
        var hunks: [FocusHunk] = []
        for line in answer.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, let number = Int(parts[1].filter(\.isNumber)) {
                hunks.append(FocusHunk(path: parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "`")), hunk: number, reason: parts[2...].joined(separator: " ")))
            } else if summary.isEmpty {
                summary = line
            }
        }
        return (summary, Array(hunks.prefix(3)))
    }
}
