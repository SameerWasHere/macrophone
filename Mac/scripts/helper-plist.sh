#!/bin/zsh
# Writes Keep Awake's launchd plist into the app being built (an Xcode build phase, before
# signing): Contents/Library/LaunchDaemons/<label>.plist, the label per configuration so a debug
# build never collides with an installed release (Mac/Helper/HelperProtocol.swift has the names).
set -euo pipefail
LABEL=${MACROPHONE_HELPER_LABEL:?}
DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchDaemons"
mkdir -p "$DIR"
find "$DIR" -name "*.plist" -delete
cat > "$DIR/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/MacrophoneHelper</string>
	<key>MachServices</key>
	<dict>
		<key>$LABEL</key>
		<true/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$PRODUCT_BUNDLE_IDENTIFIER</string>
	</array>
</dict>
</plist>
PLIST
