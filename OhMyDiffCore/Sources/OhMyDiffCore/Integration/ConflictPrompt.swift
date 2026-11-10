import Foundation

extension ClaudePrompt {
    /// Commits listed per side; the agent can read the rest with git.
    static let conflictCommitLimit = 20
    /// Characters of conflict text a prompt carries; files past it are only named.
    static let conflictTextLimit = 40_000

    /// Asks an agent to resolve a branch's conflicts, with the branches, commits and conflicts the report holds
    /// and the commands that finish the job in the repository's kind.
    public static func resolveConflicts(_ report: ConflictReport) -> String {
        let branch = report.branch.map { "`\($0)`" } ?? "the checked-out branch"
        var sections = ["Resolve the merge conflicts on \(branch)."]

        var facts = ["Repository: `\(report.repositoryPath)`" + (report.isGitButler ? " (GitButler workspace)" : "")]
        if let name = report.branch { facts.append("Branch: `\(name)`") }
        if let target = report.target { facts.append("Target: `\(target)`") }
        facts.append("What happened: " + situation(report))
        sections.append(facts.map { "- \($0)" }.joined(separator: "\n"))

        if !report.commits.isEmpty {
            sections.append("Commits on the branch, newest first:\n\n" + commitList(report.commits))
        }
        if !report.incoming.isEmpty, let target = report.target {
            sections.append("Commits on `\(target)` the branch does not have, newest first:\n\n" + commitList(report.incoming))
        }

        if let details = report.details, !details.isEmpty {
            sections.append("The conflicts, as `but resolve conflicts` shows them:\n\n" + fenced(details, language: "text"))
        } else if !report.files.isEmpty {
            sections.append(conflicts(report.files))
        }

        sections.append(steps(report))
        sections.append(
            "Keep the intent of both sides. Where they contradict, keep the target's behavior, adapt the branch's change to it "
                + "and say so. Build and run the tests if the repository has them. Do not push. When you are done, list each "
                + "conflict and how you resolved it.")
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func situation(_ report: ConflictReport) -> String {
        let target = report.target.map { "`\($0)`" } ?? "the target branch"
        switch report.situation {
        case .conflictedCommits:
            return "updating from \(target) rebased the branch, and GitButler marked the commits that no longer apply "
                + "as conflicted. Nothing is checked out for resolving yet."
        case .resolving:
            return "GitButler's resolution mode (`but resolve <commit>`) checked out a conflicted commit; its conflicts "
                + "are in the worktree."
        case .operation(let operation):
            return "a git \(operation) stopped on conflicts; they are in the worktree."
        case .pullRequest(let number, let base):
            return "pull request #\(number) can’t be merged: it conflicts with `\(base)`. Nothing is conflicted locally "
                + "yet; the conflicts below are those of merging the branch into \(target)."
        }
    }

    private static func steps(_ report: ConflictReport) -> String {
        let target = report.target.map { "`\($0)`" } ?? "the target branch"
        switch report.situation {
        case .conflictedCommits:
            return "Use GitButler's `but` CLI rather than git commands that rewrite history. Run `but resolve conflicts "
                + "\(report.branch ?? "<branch>")` to see each conflict of the oldest conflicted commit, resolve it with "
                + "`but resolve apply <path>:<N>` (pipe the merged content in, or pass `--ours` or `--theirs`), and repeat "
                + "until `but status` shows no conflicted commits on the branch."
        case .resolving:
            return "Edit the conflicted files until no conflict markers are left. Check with `but resolve status`, then "
                + "run `but resolve finish` to write the resolved commit. `but resolve cancel` leaves it conflicted."
        case .operation(let operation):
            let next = switch operation {
            case "rebase": "`git rebase --continue`, and resolve each further commit that stops the same way"
            case "cherry-pick": "`git cherry-pick --continue`"
            case "revert": "`git revert --continue`"
            default: "`git commit --no-edit`"
            }
            return "Edit the conflicted files until no conflict markers are left, `git add` them, then run \(next)."
        case .pullRequest:
            return report.isGitButler
                ? "Update the workspace from \(target) with `but pull`; GitButler marks the commits that conflict. Then "
                    + "resolve them with `but resolve conflicts` and `but resolve apply <path>:<N>` until `but status` "
                    + "shows no conflicted commits."
                : "Bring \(target) into the branch the way this repository does it (rebase or merge; check its history), "
                    + "resolve the conflicts and complete the rebase or merge."
        }
    }

    private static func commitList(_ commits: [CommitInfo]) -> String {
        var lines = commits.prefix(conflictCommitLimit).map { commit in
            "- `\(commit.shortSHA)` \(commit.summary)" + (commit.isConflicted ? " (conflicted)" : "")
        }
        if commits.count > conflictCommitLimit { lines.append("- … and \(commits.count - conflictCommitLimit) more") }
        return lines.joined(separator: "\n")
    }

    private static func conflicts(_ files: [ConflictedFile]) -> String {
        var parts = ["Conflicted files:"]
        var budget = conflictTextLimit
        var omitted: [String] = []
        for file in files {
            let regions = file.regions.map { "Line \($0.line):\n\n" + fenced($0.text, language: "") }
            let text = regions.joined(separator: "\n\n")
            guard text.count <= budget else {
                omitted.append(file.path)
                continue
            }
            budget -= text.count
            parts.append("`\(file.path)`" + (regions.isEmpty ? " (no conflict markers left, or a binary file)" : "\n\n" + text))
        }
        if !omitted.isEmpty {
            parts.append("Also conflicted, read them in the repository: " + omitted.map { "`\($0)`" }.joined(separator: ", "))
        }
        return parts.joined(separator: "\n\n")
    }
}
