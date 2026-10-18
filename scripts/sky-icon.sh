#!/bin/sh
# The sky app icon, end to end (scripts/render-sky-icon.swift — SameerOS's icon recipe in Macrophone's
# colours): the flats, the .icon bundles and their layers, the system's own Liquid Glass render of the
# bundle (macOS 26+, light — and the dark look through a swapped bundle), the side-by-side sheet
# against SameerOS's icon into docs/icon/sky/, and, with `install`, the icon into both apps (the .icon
# beside each target, the classic AppIcon.appiconset PNGs as the fallback).
#
#   sh scripts/sky-icon.sh [work dir]            # renders and writes the sheet, installs nothing
#   sh scripts/sky-icon.sh [work dir] install    # …and installs it
#
# The sheet reads SameerOS's icon from $SAMEEROS_APPICON (default
# ~/claude-projects/SameerOS/SameerOS/Assets.xcassets/AppIcon.appiconset), read only.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="${1:-${TMPDIR:-/tmp}/macrophone-sky-icon}"
work="$(mkdir -p "$work" && cd "$work" && pwd)"
docs="$root/docs/icon/sky"
mkdir -p "$docs"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 "$here/render-sky-icon.swift" -o "$work/render-sky-icon"
"$work/render-sky-icon" render "$work"
sh "$here/icon-render-check.sh" "$work" || echo "system render skipped (needs macOS 26+ and Xcode 26+)"
"$work/render-sky-icon" sheet "$work" "$docs" "${SAMEEROS_APPICON:-$HOME/claude-projects/SameerOS/SameerOS/Assets.xcassets/AppIcon.appiconset}"
if [ "${2:-}" = "install" ]; then
    cd "$root"
    "$work/render-sky-icon" install
    # The record of what the system makes of the shipped bundle (light; the dark look via the swapped one).
    cp "$work/sky/system-1024.png" "$docs/final-system-light-1024.png" 2>/dev/null || true
    cp "$work/sky-dark/system-1024.png" "$docs/final-system-dark-1024.png" 2>/dev/null || true
    cp "$work/sky/system-128.png" "$docs/final-system-light-128.png" 2>/dev/null || true
    cp "$work/sky/system-32.png" "$docs/final-system-light-32.png" 2>/dev/null || true
fi
