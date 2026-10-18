#!/bin/sh
# Creates a throwaway git repository with large uncommitted changes, for checking that big diffs
# scroll smoothly with syntax highlighting in both layouts.
#
#   Sources/Items.swift  ~13k lines, a modification touching every block (a 10k+ line diff)
#   web/items.ts         ~3k lines, a modification with insertions and deletions
#   data/fixtures.json   ~30k lines, untracked, so it starts collapsed behind "Show Diff"
#
# Usage: scripts/large-diff.sh [directory]   (default: $TMPDIR/ohmydiff-large-diff)
set -eu

dir=${1:-${TMPDIR:-/tmp}/ohmydiff-large-diff}
marker=.ohmydiff-fixture

if [ -e "$dir" ]; then
    if [ ! -e "$dir/$marker" ]; then
        echo "error: $dir exists and was not created by this script" >&2
        exit 1
    fi
    rm -rf "$dir"
fi
mkdir -p "$dir/Sources" "$dir/web" "$dir/data"
cd "$dir"
touch "$marker"

git init -q
git config user.name "ohmydiff fixture"
git config user.email "fixture@example.invalid"
printf '%s\n' "$marker" > .gitignore

# $1 = 0 for the committed version, 1 for the modified one.
swift_file() {
    awk -v modified="$1" 'BEGIN {
        print "import Foundation"
        print ""
        for (i = 1; i <= 1200; i++) {
            count = (modified && i % 2 == 0) ? i " * 2" : i
            name = (modified && i % 3 == 0) ? "item-" i "-renamed" : "item-" i
            if (modified && i % 40 == 0) continue
            print "/// Block " i " computes a value."
            print "struct Item" i " {"
            print "    var name = \"" name "\""
            print "    var count = " count
            print "    func total(_ factor: Int) -> Int {"
            if (modified && i % 11 == 0) print "        guard factor > 0 else { return 0 }"
            if (!(modified && i % 7 == 0)) print "        // multiply by the factor"
            print "        return count * factor + " ((modified && i % 2) ? i " + 1" : i)
            print "    }"
            print "}"
            print ""
        }
    }'
}

ts_file() {
    awk -v modified="$1" 'BEGIN {
        print "// Generated items."
        print ""
        for (i = 1; i <= 400; i++) {
            if (modified && i % 25 == 0) continue
            print "export function item" i "(factor: number): string {"
            print "  const label = `item ${" i "}`;"
            print (modified && i % 4 == 0) ? "  return label.repeat(factor).toUpperCase();" : "  return label.repeat(factor);"
            print "}"
            if (modified && i % 9 == 0) print "export const ITEM_" i " = item" i "(2);"
            print ""
        }
    }'
}

swift_file 0 > Sources/Items.swift
ts_file 0 > web/items.ts
git add -A
git commit -qm "initial fixture"

swift_file 1 > Sources/Items.swift
ts_file 1 > web/items.ts
awk 'BEGIN {
    print "["
    for (i = 1; i <= 6000; i++) {
        print "  {"
        print "    \"id\": " i ","
        print "    \"name\": \"fixture-" i "\","
        print "    \"enabled\": " (i % 2 ? "true" : "false")
        print (i < 6000) ? "  }," : "  }"
    }
    print "]"
}' > data/fixtures.json

echo "Created $dir"
git --no-pager diff --stat
