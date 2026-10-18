#!/bin/sh
# Renders every icon option: the .icon bundles and flats, the system's own Liquid Glass render of
# each (macOS 26+), the comparison sheet, and the 1024 light PNGs into docs/icon/options/.
#
#   sh scripts/icon-options/run.sh [work dir]
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="${1:-${TMPDIR:-/tmp}/macrophone-icon-options}"
mkdir -p "$work"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 "$here/render-options.swift" -o "$work/render-options"
"$work/render-options" preview "$work"
sh "$root/scripts/icon-render-check.sh" "$work" || echo "system render skipped (needs macOS 26+ and Xcode 26+)"
"$work/render-options" sheet "$work" "$root/docs/icon/options"
