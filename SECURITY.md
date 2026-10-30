# Security

## Reporting a vulnerability

Report it privately through [GitHub's vulnerability reporting](https://github.com/builtbymax/ohmydiff/security/advisories/new),
not in a public issue. Only the latest release gets fixes.

## What ohmydiff trusts

ohmydiff is a local tool that runs `git`, `but`, `gh`, `glab` and your editor on your behalf. It treats these as
yours, with the same trust as your own terminal:

- **Your Git configuration**, global and per repository (`.git/config`), including the helpers it can start:
  textconv and external diff drivers, clean and smudge filters, fsmonitor, hooks and credential helpers. A clone
  never copies another person's `.git/config` or hooks, so a repository you cloned cannot set these up for you.
  A repository someone else prepared on your disk, such as a copied or extracted folder, can. Open those only
  if you trust where they came from.
- **Installed tools** found on your login shell's `PATH`: `git`, `but`, `gh`, `glab` and the AI provider CLIs.
- **Your editor and shell commands**: ⌘O and custom editor commands run what you configured in Settings, and
  "Ask About Diffs" starts the chosen AI provider in a terminal in the repository with its normal permissions.
- **The MCP host**: `ohmydiff mcp` talks over stdio to the program that started it. It opens no network port,
  and its tools only read and bring the app to the front.

## What ohmydiff does not trust

- **Repository contents.** File names are passed to Git as literal paths, never as patterns, so selecting
  `a[1].txt` cannot touch `a1.txt`. Diffs, file names and commit messages are only displayed.
- **AI suggestions.** Commit messages, branch names and pull request drafts come from the provider's CLI run once
  in an empty temporary folder, with its tools turned off where the CLI allows. The repository's own agent
  settings, hooks, plugins and MCP servers are never loaded. The prompt is sent to that provider: the selected
  diff, recent commits, the branch name and the linked ticket. Turn suggestions off in Settings → AI if that
  code must not leave your Mac.
- **Unknown repositories from links.** `ohmydiff://` links to a repository that is not in your project list ask
  before opening it.
- **Runaway processes.** Every command has a timeout. Stopping it ends the whole process group, and output is
  capped, so a misbehaving tool cannot hang the app or fill its memory.

## Releases

Releases are signed with a Developer ID, notarized by Apple and checked with `scripts/verify-release.sh` before
publishing. Sparkle verifies each update's EdDSA signature against the key built into the app. v1.0.0 predates
this: it is ad-hoc signed, has no updater and is not supported. Install the current release instead.
