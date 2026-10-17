# ohmydiff

A native macOS diff viewer for git and [GitButler](https://gitbutler.com) workspaces.

## Requirements

- macOS 26+
- Xcode 26+

## Layout

- `ohmydiff.xcodeproj` / `ohmydiff/` — the SwiftUI app
- `OhMyDiffCore/` — local Swift package with the git/but integration, diff parsing and models

## Development

```sh
make run       # build (Release) and launch the app
make install   # build and copy to /Applications
make test      # run the OhMyDiffCore tests
make clean     # remove build output
```

Or open `ohmydiff.xcodeproj` in Xcode.
