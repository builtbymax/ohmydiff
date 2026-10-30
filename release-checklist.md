# Release checklist

Releases are signed with a Developer ID, notarized by Apple and published on GitHub Releases. Installed copies
update themselves with [Sparkle](https://sparkle-project.org) from `appcast.xml` on the latest release.

## One-time setup

- [ ] A "Developer ID Application" certificate in the login keychain (`security find-identity -v -p codesigning`).
- [ ] Notary credentials: `xcrun notarytool store-credentials ohmydiff-notary --apple-id <id> --team-id 36KWU56M5R`,
      or point `OHMYDIFF_NOTARY_PROFILE` at an existing profile.
- [ ] The Sparkle private key in the login keychain under the account `ohmydiff`. Back it up once with
      `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ohmydiff -x ohmydiff-sparkle.key`
      and keep the file somewhere safe. Without it, installed copies can never update again.
- [ ] Off-machine backups of both the Sparkle key file and the Developer ID certificate with its private key
      (exported as `.p12`), in an encrypted store only you can open, e.g. a password manager. Never in the repository.

## Before the release

- [ ] Everything is merged and pushed to `main`. `make release` builds `origin/main`, not the working tree, and
      the build number is its commit count: Sparkle only offers builds with a higher number than the installed one.
- [ ] `make test` passes. `make release` runs the tests again on the exported commit and stops if they fail.
- [ ] Optional release notes in `build/releases/x.y.z/ohmydiff-x.y.z.md` (Markdown), used as the GitHub release notes.
      Open with a short paragraph before the first heading: the update bar's What's New card shows only that part.

## Build

- [ ] `make release VERSION=x.y.z` (universal build, signing, notarization, appcast).
- [ ] Every line of the archive check is `ok` (both architectures, Developer ID, notarization, no `get-task-allow`,
      versions, Sparkle key and signature), and it ends with "ohmydiff x.y.z (…) is ready in build/releases/x.y.z".
      `scripts/verify-release.sh <zip> <version> <build> [appcast.xml]` re-checks a zip, also a downloaded one.

## Publish

- [ ] `make publish VERSION=x.y.z` tags the built commit as `vx.y.z` and creates the GitHub release with the zip
      and `appcast.xml`. It must not be a draft or pre-release, otherwise `releases/latest` still points to the
      old version.

## Check

- [ ] The feed shows the new version:
      `curl -L https://github.com/builtbymax/ohmydiff/releases/latest/download/appcast.xml`
- [ ] Download the zip in a browser, unzip it and open it. No Gatekeeper warning apart from the usual
      "downloaded from the internet" prompt.
- [ ] An installed older version finds the update (ohmydiff → Check for Updates…), installs it and restarts.
- [ ] `ohmydiff` in a terminal still opens the app.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Notarization fails | `xcrun notarytool log <submission-id> --keychain-profile ohmydiff-notary` lists the files with signing problems. |
| "The update is improperly signed" | The Sparkle private key is missing from this Mac's keychain. Restore it with `generate_keys --account ohmydiff -f <file>`. |
| No update offered | The new build number isn't higher than the installed one. Release from a newer commit. |
| `No Developer ID Application identity found` | The certificate isn't in the login keychain, or set `OHMYDIFF_SIGN_IDENTITY` explicitly. |
