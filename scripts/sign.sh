#!/bin/zsh
# Signs ohmydiff.app inside-out (never --deep): Sparkle's helpers first, then the framework, then the app.
#
#   scripts/sign.sh <app> <identity>
#
# A "Developer ID Application" identity also adds a secure timestamp, which notarization requires.
set -euo pipefail

APP="${1:?usage: scripts/sign.sh <app> <identity>}"
IDENTITY="${2:?usage: scripts/sign.sh <app> <identity>}"

SIGN=(codesign --force --sign "$IDENTITY" --options runtime)
[[ "$IDENTITY" == "Developer ID Application"* ]] && SIGN+=(--timestamp)

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
$SIGN "$SPARKLE/XPCServices/Installer.xpc"
$SIGN --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
$SIGN "$SPARKLE/Autoupdate"
$SIGN "$SPARKLE/Updater.app"
$SIGN "$APP/Contents/Frameworks/Sparkle.framework"
$SIGN "$APP"
codesign --verify --strict --deep "$APP"
