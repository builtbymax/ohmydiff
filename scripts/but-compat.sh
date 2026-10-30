#!/bin/sh
# GitButler compatibility helpers.
#
#   scripts/but-compat.sh record              store the installed `but` version as known-good
#   scripts/but-compat.sh check               print whether the installed `but` is newer than known-good
#   scripts/but-compat.sh issue REPORT LOG    open (or update) a GitHub issue for a failed contract run
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
record="$root/OhMyDiffCore/Sources/OhMyDiffCore/GitButler/gitbutler.json"

installed() {
    but --version | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

known_good() {
    sed -n 's/.*"knownGood": *"\([^"]*\)".*/\1/p' "$record"
}

case "${1:-}" in
record)
    version=$(installed)
    printf '{\n  "knownGood": "%s",\n  "recordedAt": "%s"\n}\n' "$version" "$(date -u +%F)" > "$record"
    echo "known-good GitButler version is now $version"
    ;;
check)
    version=$(installed)
    good=$(known_good)
    newest=$(printf '%s\n%s\n' "$version" "$good" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    if [ "$version" = "$good" ] || [ "$newest" = "$good" ]; then
        echo "but $version is covered by the known-good version $good"
    else
        echo "::notice::but $version passes the contract tests and is newer than the known-good $good. Run 'make compat-record' to record it."
    fi
    ;;
issue)
    report=$2
    log=$3
    # The report job has no `but`; the contract job passes its version on.
    version=$(echo "${OHMYDIFF_BUT_VERSION:-}" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1 || true)
    [ -n "$version" ] || version=$(installed 2>/dev/null || echo unknown)
    title="GitButler $version breaks ohmydiff's but --json contract"
    body=$(mktemp)
    {
        echo "The daily compatibility check failed against \`but $version\` (known-good: $(known_good))."
        echo
        if [ -s "$report" ]; then
            echo "Fields that no longer match:"
            echo
            jq -r '.violations[] | "- `" + . + "`"' "$report"
            echo
        fi
        echo "Failing expectations:"
        echo
        echo '```'
        grep -E 'recorded an issue|Expectation failed|error:' "$log" | head -n 40 || true
        echo '```'
        echo
        echo "Run: ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
        echo
        echo "Until this is fixed the app shows such workspaces as plain git repositories."
    } > "$body"

    existing=$(gh issue list --state open --search "in:title \"$title\"" --json number --jq '.[0].number // empty')
    if [ -n "$existing" ]; then
        gh issue comment "$existing" --body-file "$body"
    else
        gh issue create --title "$title" --body-file "$body"
    fi
    rm -f "$body"
    ;;
*)
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
    ;;
esac
