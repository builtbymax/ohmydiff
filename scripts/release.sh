#!/bin/zsh
# Builds a notarized, universal release of ohmydiff plus the Sparkle appcast: scripts/release.sh 1.1.0 [ref]
#
# Builds `ref` (default origin/main, fetched first) from a clean export, not the working tree, so a release is
# exactly a pushed commit and never the GitButler workspace.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. Notary credentials: xcrun notarytool store-credentials ohmydiff-notary --apple-id <id> --team-id <team>
#   3. The Sparkle private key in the login keychain (account "ohmydiff"), matching SUPublicEDKey in
#      Config/Info.plist. Back it up with generate_keys --account ohmydiff -x <file>.
#
# Environment:
#   OHMYDIFF_SIGN_IDENTITY   Defaults to the first Developer ID Application identity in the keychain.
#   OHMYDIFF_NOTARY_PROFILE  notarytool keychain profile, defaults to ohmydiff-notary.
#
# Output in build/releases/<version>/: ohmydiff-<version>.zip and appcast.xml. Release notes go into an optional
# ohmydiff-<version>.md next to the zip before running; Sparkle shows them in the update bar.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
VERSION="${VERSION#v}"
PROFILE="${OHMYDIFF_NOTARY_PROFILE:-ohmydiff-notary}"
IDENTITY="${OHMYDIFF_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)}"
[[ "$IDENTITY" == "Developer ID Application"* ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }

REF="${2:-origin/main}"
[[ "$REF" == origin/* ]] && git fetch --quiet origin "${REF#origin/}"
COMMIT="$(git rev-parse --verify "$REF^{commit}")"
# Sparkle compares CFBundleVersion to find newer builds, so it must only ever go up: use the commit count.
BUILD="$(git rev-list --count "$COMMIT")"

WORK="$PWD/build/release"
SRC="$WORK/src"
DERIVED="$WORK/derived"
APP="$DERIVED/Build/Products/Release/ohmydiff.app"
rm -rf "$WORK"
mkdir -p "$SRC"
git archive "$COMMIT" | tar -x -C "$SRC"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$SRC/Config/Info.plist" 2>/dev/null)" ]] \
  || { echo "SUPublicEDKey in Config/Info.plist of ${COMMIT:0:7} is empty, run Sparkle's generate_keys --account ohmydiff first" >&2; exit 1; }
xcodebuild -project "$SRC/ohmydiff.xcodeproj" -scheme ohmydiff -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build
scripts/sign.sh "$APP" "$IDENTITY"

OUT="build/releases/$VERSION"
ZIP="$OUT/ohmydiff-$VERSION.zip"
mkdir -p "$OUT"
rm -f "$ZIP" "$OUT/appcast.xml"
echo "$COMMIT" > "$OUT/commit"

# Notarize, staple the ticket to the app so it also opens offline, then zip the stapled app again.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

# The appcast only lists this release; Sparkle just needs the newest one.
"$DERIVED"/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --account ohmydiff --embed-release-notes \
  --download-url-prefix "https://github.com/builtbymax/ohmydiff/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/builtbymax/ohmydiff/releases/tag/v$VERSION" "$OUT"

echo "\nohmydiff $VERSION ($BUILD, ${COMMIT:0:7}) is ready in $OUT. Publish it with: make publish VERSION=$VERSION"
