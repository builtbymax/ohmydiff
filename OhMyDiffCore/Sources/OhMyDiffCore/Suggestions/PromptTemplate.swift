import Foundation

/// The values a suggestion template can use as `{{name}}` placeholders.
public struct TemplateContext: Sendable, Hashable {
    /// The changes to describe, as a unified diff.
    public var diff: String
    /// Commits on the branch, one `<sha> <subject>` per line.
    public var commits: String
    /// The branch the changes go to.
    public var branch: String
    /// The linked ticket; its placeholders are empty without one.
    public var ticket: Ticket?

    public init(diff: String = "", commits: String = "", branch: String = "", ticket: Ticket? = nil) {
        self.diff = diff
        self.commits = commits
        self.branch = branch
        self.ticket = ticket
    }

    /// Every placeholder this context fills, by name.
    public var values: [String: String] {
        [
            "diff": diff,
            "commits": commits,
            "branch": branch,
            "ticket.id": ticket?.id ?? "",
            "ticket.title": ticket?.title ?? "",
            "ticket.description": ticket?.description ?? "",
            "ticket.url": ticket?.url?.absoluteString ?? "",
        ]
    }

    /// The placeholders a template can use, for the template editor's help.
    public static let placeholders: [(name: String, description: String)] = [
        ("diff", "The changes to describe"),
        ("commits", "Commits on the branch"),
        ("branch", "The branch name"),
        ("ticket.id", "The linked ticket's ID, e.g. HAL-128"),
        ("ticket.title", "The linked ticket's title"),
        ("ticket.description", "The linked ticket's description"),
        ("ticket.url", "The linked ticket's web address"),
    ]
}

/// Prompts that ask an AI provider for a commit message, a pull request or a branch name.
public enum PromptTemplate {
    /// Replaces `{{name}}` (spaces inside the braces allowed) with the context's values. Unknown names are
    /// left as written, so a typo shows up in the prompt instead of silently vanishing.
    public static func render(_ template: String, context: TemplateContext) -> String {
        let values = context.values
        var result = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result += values[name] ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// Diffs beyond this many characters are cut, so a prompt stays within what a CLI accepts as an argument.
    public static let diffCharacterLimit = 60_000

    public static func limitedDiff(_ diff: String) -> String {
        guard diff.count > diffCharacterLimit else { return diff }
        return String(diff.prefix(diffCharacterLimit)) + "\n[… the rest of the diff is left out]\n"
    }

    public static let defaultCommit = """
        Write a git commit message for the following changes.

        Rules:
        - Only respond with the commit message.
        - Use this exact format:

        <type>(<scope>): <short title>

        - <bullet point>
        - <bullet point>

        Formatting rules:
        - Use semantic commit types: feat, fix, chore, refactor, docs, style, test, ci, build
        - Use the component or feature name as scope when possible.
        - Keep the title concise and under 72 characters.
        - Use present tense and lowercase bullet points.
        - Every bullet starts with "- ", max 30 words each.
        - Prefer 2-4 bullet points, focused on the most important changes.
        - Hard wrap lines at 72 characters.
        - No markdown code blocks, no lines starting with "#", no summaries or notes.
        - If a ticket is linked, use it as context and add a final line "Refs: {{ticket.id}}".

        Example:

        feat(patient): add tag translation system

        - create generic tag translation helper with regex rules
        - add service tag mappings for patient details
        - update billing service tag appearance in patient details

        Refs: HAL-42

        Ticket (may be empty):

        {{ticket.id}} {{ticket.title}}
        {{ticket.description}}

        Diff:

        {{diff}}
        """

    public static let defaultPullRequest = """
        Write a pull request title and description for the following changes.

        Rules:
        - Only respond with the title and description.
        - Title: "<type>(<scope>): <short title>", under 72 characters, semantic type.
        - Keep it succinct: explain what changed, why, and any important decision.

        Use this structure:

        ## Summary
        <1-3 sentences on what this PR does and why>

        ## Changes
        - <key change>
        - <key change>

        ## Ticket
        [{{ticket.id}}]({{ticket.url}}): {{ticket.title}}
        (omit this section if no ticket is linked)

        ## Notes
        <important decisions, trade-offs, follow-ups or testing hints; omit if none>

        Ticket context (may be empty):

        {{ticket.description}}

        Commits:

        {{commits}}

        Diff:

        {{diff}}
        """

    /// Built in rather than editable: the answer must be a valid branch name.
    public static let branchName = """
        Suggest a git branch name for the following changes.

        Rules:
        - Only respond with the branch name, nothing else.
        - Use the format <type>/<short-name>, e.g. feat/ai-suggestions.
        - Types: feat, fix, chore, refactor, docs, style, test, ci, build.
        - The short name is 2-5 lowercase words joined by hyphens.
        - If a ticket is linked, start the short name with its lowercase ID, e.g. feat/hal-128-ai-suggestions.

        Ticket (may be empty):

        {{ticket.id}} {{ticket.title}}

        Diff:

        {{diff}}
        """
}
