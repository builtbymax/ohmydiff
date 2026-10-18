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
- **Command line:** install `ohmydiff` from Settings → Command Line (it goes to `~/.local/bin`), then run `ohmydiff` in a repository, or `ohmydiff path/to/repo`. It adds the project if it is new and brings it to the front via the `ohmydiff://open?path=…` URL scheme.

## Development

```sh
make run       # build (Release) and launch the app
make install   # build and copy to /Applications
make test      # run the OhMyDiffCore tests
make large-diff # create a throwaway repo with large changes to open in the app
make compat    # run the GitButler contract tests against the installed `but`
make compat-record # ...and record its version as known-good
make clean     # remove build output
```

Or open `ohmydiff.xcodeproj` in Xcode.

## GitButler compatibility

`but --json` has no versioned schema. The `GitButler compatibility` workflow runs the contract
tests daily against the latest GitButler release and opens an issue when one breaks them. The
last known-good version lives in `OhMyDiffCore/Sources/OhMyDiffCore/GitButler/gitbutler.json`
and ships with the app: with a newer `but`, the app checks `but --json status` against the
contract and shows a workspace that fails it as a plain git repository, with a banner.
