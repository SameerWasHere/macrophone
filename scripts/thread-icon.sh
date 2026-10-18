#!/bin/sh
# The Thread app icon, end to end (scripts/render-thread-icon.swift): every framing's .icon bundles
# and flats, the system's own Liquid Glass render of each (macOS 26+, light — and the dark look
# through a swapped bundle), the comparison sheet and the in-app-vs-port strip into docs/icon/thread/,
# and, with `install`, the chosen framing into both apps (the same wiring as before: the .icon beside
# each target, the classic AppIcon.appiconset PNGs as the fallback).
#
#   sh scripts/thread-icon.sh [work dir]              # renders and writes the sheet, installs nothing
#   sh scripts/thread-icon.sh [work dir] install bold # …and installs that framing (span | bold | sweep)
#
# The in-app strip needs docs/icon/thread/in-app.png — a 1206 × 240 crop of the Thread's band from an
# iPhone simulator screenshot of the main screen (xcrun simctl io <udid> screenshot; crop with sips).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="${1:-${TMPDIR:-/tmp}/macrophone-thread-icon}"
work="$(mkdir -p "$work" && cd "$work" && pwd)"
docs="$root/docs/icon/thread"
mkdir -p "$docs"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 "$here/render-thread-icon.swift" -o "$work/render-thread-icon"
"$work/render-thread-icon" preview "$work"
sh "$here/icon-render-check.sh" "$work" || echo "system render skipped (needs macOS 26+ and Xcode 26+)"
if [ -f "$docs/in-app.png" ]; then
    "$work/render-thread-icon" sheet "$work" "$docs" "$docs/in-app.png"
    "$work/render-thread-icon" compare "$docs/in-app.png" "$docs"
else
    "$work/render-thread-icon" sheet "$work" "$docs"
fi
if [ "${2:-}" = "install" ]; then
    cd "$root"
    "$work/render-thread-icon" install "${3:-bold}"
    # The record of what the system makes of the shipped bundle (light; the dark look via the swapped one).
    f="${3:-bold}"
    cp "$work/$f/system-1024.png" "$docs/final-system-light-1024.png"
    cp "$work/$f-dark/system-1024.png" "$docs/final-system-dark-1024.png"
    cp "$work/$f/system-128.png" "$docs/final-system-light-128.png"
    cp "$work/$f/system-32.png" "$docs/final-system-light-32.png"
fi
