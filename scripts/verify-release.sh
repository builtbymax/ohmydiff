#!/bin/zsh
# Checks a packaged release the way users get it: scripts/verify-release.sh <zip> <version> <build> [appcast.xml]
#
# Unzips into a scratch folder and checks both architectures, the Developer ID signature, notarization,
# entitlements, versions, the embedded Sparkle key against the keychain's, and the zip's Sparkle signature in
# the appcast. Runs at the end of scripts/release.sh; also works on a downloaded zip.
set -euo pipefail
cd "${0:A:h}/.."

ZIP="${1:?usage: scripts/verify-release.sh <zip> <version> <build> [appcast.xml]}"
VERSION="${2:?usage: scripts/verify-release.sh <zip> <version> <build> [appcast.xml]}"
BUILD="${3:?usage: scripts/verify-release.sh <zip> <version> <build> [appcast.xml]}"
APPCAST="${4:-${ZIP:h}/appcast.xml}"
SPARKLE_BIN="${OHMYDIFF_SPARKLE_BIN:-build/release/derived/SourcePackages/artifacts/sparkle/Sparkle/bin}"

failures=0
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $name"; else echo "FAIL  $name" >&2; failures=$((failures + 1)); fi
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
ditto -x -k "$ZIP" "$SCRATCH"
APP="$SCRATCH/ohmydiff.app"
[[ -d "$APP" ]] || { echo "FAIL  ohmydiff.app is not at the top of $ZIP" >&2; exit 1; }
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null }

check "arm64 slice" lipo "$APP/Contents/MacOS/ohmydiff" -verify_arch arm64
check "x86_64 slice" lipo "$APP/Contents/MacOS/ohmydiff" -verify_arch x86_64
check "strict signature" codesign --verify --strict --deep "$APP"
check "Developer ID authority" sh -c "codesign -dvv '$APP' 2>&1 | grep -q '^Authority=Developer ID Application'"
check "hardened runtime" sh -c "codesign -dvv '$APP' 2>&1 | grep -q 'flags=.*runtime'"
check "no get-task-allow entitlement" sh -c "! codesign -d --entitlements - --xml '$APP' 2>/dev/null | grep -q 'get-task-allow'"
check "stapled notarization ticket" xcrun stapler validate "$APP"
check "Gatekeeper accepts it" spctl --assess --type execute "$APP"
check "version $VERSION" test "$(plist CFBundleShortVersionString)" = "$VERSION"
check "build $BUILD" test "$(plist CFBundleVersion)" = "$BUILD"

embedded="$(plist SUPublicEDKey)"
check "embedded Sparkle key" test -n "$embedded"
if [[ -x "$SPARKLE_BIN/generate_keys" ]]; then
  check "embedded Sparkle key matches the keychain's" test "$("$SPARKLE_BIN/generate_keys" --account ohmydiff -p 2>/dev/null)" = "$embedded"
else
  echo "FAIL  no Sparkle tools at $SPARKLE_BIN (set OHMYDIFF_SPARKLE_BIN)" >&2; failures=$((failures + 1))
fi

if [[ ! -f "$APPCAST" ]]; then
  echo "FAIL  no appcast at $APPCAST to check the Sparkle signature against" >&2; failures=$((failures + 1))
elif [[ -x "$SPARKLE_BIN/sign_update" ]]; then
  signature="$(grep -o 'sparkle:edSignature="[^"]*"' "$APPCAST" | head -1 | cut -d'"' -f2)"
  length="$(grep -o 'length="[0-9]*"' "$APPCAST" | head -1 | cut -d'"' -f2)"
  check "appcast length matches the zip" test "$length" = "$(stat -f %z "$ZIP")"
  check "zip's Sparkle signature verifies" "$SPARKLE_BIN/sign_update" --account ohmydiff --verify "$ZIP" "$signature"
fi

if (( failures )); then
  echo "\n$failures check(s) failed for $ZIP" >&2
  exit 1
fi
echo "\n$ZIP passes all checks"
