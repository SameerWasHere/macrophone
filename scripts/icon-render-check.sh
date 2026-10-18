#!/bin/sh
# Renders each candidate .icon the way macOS 26+ does: actool compiles the bundle into a stub .app,
# then the system draws that app's icon (scripts/icon-system-render.swift) at 1024 and at the Dock's
# sizes. Run after `render-icons preview <dir>`; it writes <dir>/<design>/system-1024.png etc., and
# `render-icons sheet <dir>` puts them on the comparison sheet.
#
#   sh scripts/icon-render-check.sh <preview dir>
set -eu
dir="$1"
here="$(cd "$(dirname "$0")" && pwd)"
tool="$dir/icon-system-render"
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 "$here/icon-system-render.swift" -o "$tool"
for icon in "$dir"/*/AppIcon.icon; do
    d="$(dirname "$icon")"
    app="$d/Stub.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS"
    xcrun actool "$icon" --compile "$app/Contents/Resources" --output-format human-readable-text --notices --warnings \
        --output-partial-info-plist "$d/partial.plist" --app-icon AppIcon --platform macosx --target-device mac \
        --minimum-deployment-target 14.0 >/dev/null
    name="Macrophone$(basename "$d")"
    # Launch Services draws a "can't run" slash over a bundle with no executable: give it one.
    cp "$tool" "$app/Contents/MacOS/$name"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sameer.macrophone.iconstub.$(basename "$d")</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
</dict></plist>
EOF
    for px in 1024 256 128 64 32; do "$tool" "$app" "$d/system-$px.png" "$px"; done
    "$tool" "$app" "$d/system-dark-1024.png" 1024 dark
done
