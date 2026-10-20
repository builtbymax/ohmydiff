# ohmydiff

A native macOS diff viewer for git and [GitButler](https://gitbutler.com) workspaces.

## Requirements

- macOS 26+
- Xcode 26+

## Layout

- `ohmydiff.xcodeproj` / `ohmydiff/` — the SwiftUI app
- `OhMyDiffCore/` — local Swift package with the git/but integration, diff parsing and models

## Usage

- **⌘O** opens the selected file at the selected line in your editor (Cursor, VS Code, Zed, Xcode, Sublime Text or a custom command, chosen in Settings).
- **⇧⌘C** copies the file's path, **⌘R** refreshes, **⇧⌘O** adds a project.
- **⌘K** or the project name in the toolbar switches projects. **⌘0** hides the file list so the diff gets the whole window, and **⌥⌘O** opens the diff in its own window (live for uncommitted files).
- **Actions:** right-click a file, a section header or a hunk in the diff, or use the bar floating over the diff for the hunk at the top (**n** / **p** move between hunks). Plain git repositories can stage, unstage and discard (untracked files go to the Trash). GitButler workspaces can commit to a branch you pick and discard, always through `but` with explicit change IDs, so `but undo` reverts them.
- **Command line:** install `ohmydiff` from Settings → Command Line (it goes to `~/.local/bin`), then run `ohmydiff` in a repository, or `ohmydiff path/to/repo`. It brings the app to the front via the `ohmydiff://open?path=…` URL scheme and asks before adding a repository that is not a project yet, since any link can open these URLs. `ohmydiff show <file>[:line]` shows a changed file at a line, `ohmydiff branch <name>` and `ohmydiff commit <sha>` show a branch or commit in History.
- **AI suggestions:** choose a provider and model under Settings → AI → Commit Messages & Branch Names. The commit sheet then generates a message (✦ Generate) and a new branch name (✦ Suggest) from the selected changes, and History drafts a pull request for a branch. Nothing is committed or pushed on its own. Settings → Templates holds the commit and pull request prompts with `{{diff}}`, `{{commits}}`, `{{branch}}` and `{{ticket.id}}`, `{{ticket.title}}`, `{{ticket.description}}`, `{{ticket.url}}`. Settings → Tickets connects Linear and Jira (keys in the Keychain) and GitHub or GitLab issues through `gh` / `glab`; a branch like `feature/hal-128` links its ticket, or you search for one in the sheet.
- **Coding agents:** `ohmydiff mcp` is a local MCP server on stdio (`claude mcp add ohmydiff -- ohmydiff mcp`). Its read-only tools (`list_projects`, `list_changes`, `get_diff`, `list_branches`) answer from git and `but` without the app; `open_project`, `show_file`, `show_branch` and `show_commit` bring the app to the front at that file, line, branch or commit.

## Development

```sh
make run       # build (Release) and launch the app
make install   # build and copy to /Applications
make test      # run the OhMyDiffCore tests
make large-diff # create a throwaway repo with large changes to open in the app
make compat    # run the GitButler contract tests against the installed `but`
make compat-record # ...and record its version as known-good
make release VERSION=1.1.0 # notarized universal build of origin/main plus the Sparkle appcast
make publish VERSION=1.1.0 # the GitHub release installed copies update from
make clean     # remove build output
```

Or open `ohmydiff.xcodeproj` in Xcode.

## Updates

ohmydiff updates itself with [Sparkle](https://sparkle-project.org): it checks `appcast.xml` on the latest
GitHub release on launch and daily (Settings → General → Updates), shows a bar at the bottom of the window when
a newer version is out, and installs it and restarts on request. Debug builds never update themselves. See
[release-checklist.md](release-checklist.md) for the steps of a release.

## GitButler compatibility

`but --json` has no versioned schema. The `GitButler compatibility` workflow runs the contract
tests daily against the latest GitButler release and opens an issue when one breaks them. The
last known-good version lives in `OhMyDiffCore/Sources/OhMyDiffCore/GitButler/gitbutler.json`
and ships with the app: with a newer `but`, the app checks `but --json status` against the
contract and shows a workspace that fails it as a plain git repository, with a banner.
