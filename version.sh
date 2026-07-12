#!/bin/zsh
# version.sh — the ONE place the app version is parsed from source. install.sh, package.sh, and CI all
# call this, so if `let macrecVersion` moves (as the #88 file split moved it from macrec.swift into
# Sources/Tray.swift, silently breaking both scripts — CI never ran them), CI fails here instead of a
# user's install. Searches macrec.swift AND Sources RECURSIVELY (find, matching the build's own
# `find Sources -name '*.swift'`), so the constant can live in ANY module file — including a subdir like
# Sources/Tray/. A non-recursive Sources/*.swift glob would miss it the moment a top-level file is split.
set -e
HERE="${0:A:h}"
V=$(grep -hE '^let macrecVersion = ' "$HERE/macrec.swift" $(find "$HERE/Sources" -name '*.swift') 2>/dev/null \
    | head -1 | sed -E 's/.*"([0-9][0-9.]*)".*/\1/')
[[ -n "$V" ]] || { echo "❌ version.sh: no 'let macrecVersion' in macrec.swift or Sources (searched recursively)" >&2; exit 1; }
print -r -- "$V"
