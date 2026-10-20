#!/bin/zsh
# Publishes a release built by scripts/release.sh as the latest GitHub release: scripts/publish.sh 1.1.0
#
# Tags the commit the release was built from as v<version>. Installed copies find the new appcast.xml at
# releases/latest within minutes.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: scripts/publish.sh <version>}"
VERSION="${VERSION#v}"
OUT="build/releases/$VERSION"
ZIP="$OUT/ohmydiff-$VERSION.zip"
[[ -f "$ZIP" && -f "$OUT/appcast.xml" && -f "$OUT/commit" ]] || { echo "No release in $OUT, run make release VERSION=$VERSION first" >&2; exit 1; }

NOTES=(--generate-notes)
[[ -f "$OUT/ohmydiff-$VERSION.md" ]] && NOTES=(--notes-file "$OUT/ohmydiff-$VERSION.md")
gh release create "v$VERSION" "$ZIP" "$OUT/appcast.xml" --title "ohmydiff $VERSION" --target "$(cat "$OUT/commit")" $NOTES
