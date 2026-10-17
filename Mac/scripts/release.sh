#!/bin/zsh
# Macrophone for Mac — build, sign, notarize, package and publish a release.
#
#   Mac/scripts/release.sh <version> <build>            e.g. release.sh 1.0.0 1
#   Mac/scripts/release.sh <version> <build> --dry-run  dev-signed, no notarization, writes only to Mac/dist/
#
# One-time setup and the full checklist: docs/RELEASING.md.
#
# What it does:
#   1. Preflight — a "Developer ID Application" identity, the `macrophone-notary` notarytool
#      profile, the Sparkle signing key (login keychain, account "macrophone") matching
#      SUPublicEDKey, release notes at Mac/release-notes/<version>.html.
#   2. Archives Release, exports it signed with Developer ID (hardened runtime, timestamp).
#   3. Verifies the signature (app, Sparkle, the embedded `macrophone` CLI).
#   4. Notarizes and staples the app.
#   5. Builds the DMG (app + Applications alias over the rendered background, laid out by
#      scripts/dmg/dsstore.py — no Finder scripting), signs, notarizes and staples it.
#   6. Signs the DMG for Sparkle (EdDSA) and writes the appcast item.
#   7. Copies DMG, Macrophone-latest.dmg, release notes and appcast.xml into the website repo
#      (~/claude-projects/_web/sameer-gpt/public/macrophone/). You commit and push that repo.

set -euo pipefail

VERSION=${1:-}
BUILD=${2:-}
DRY_RUN=0
[[ "${3:-}" == "--dry-run" ]] && DRY_RUN=1
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "usage: $0 <version> <build> [--dry-run]   e.g. $0 1.0.0 1" >&2
  exit 2
fi

MAC_DIR=${0:A:h:h}
TEAM_ID=8523EX5882
NOTARY_PROFILE=macrophone-notary
SPARKLE_ACCOUNT=macrophone
SITE_BASE="https://sameer.us/macrophone"
WEB_DIR=${MACROPHONE_WEB_DIR:-$HOME/claude-projects/_web/sameer-gpt/public/macrophone}
OUT="$MAC_DIR/dist/$VERSION"
DERIVED="$MAC_DIR/build/release"
NOTES="$MAC_DIR/release-notes/$VERSION.html"
DMG_NAME="Macrophone-$VERSION.dmg"

say()  { print -P "%F{cyan}▸%f $*"; }
ok()   { print -P "%F{green}✓%f $*"; }
warn() { print -P "%F{yellow}!%f $*"; }
die()  { print -P "%F{red}✗ $*%f" >&2; exit 1; }

# ── 1. Preflight ────────────────────────────────────────────────────────────────────────────
say "Preflight"
command -v xcodegen >/dev/null || die "xcodegen is missing (brew install xcodegen)."
[[ -f "$NOTES" ]] || die "Release notes missing: $NOTES  (copy release-notes/1.0.0.html and edit it)."

if (( DRY_RUN )); then
  IDENTITY="Apple Development"
  warn "Dry run: signing with Apple Development, skipping notarization; output stays in $OUT."
else
  IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 || true)
  if [[ -z "$IDENTITY_LINE" ]]; then
    die "No \"Developer ID Application\" certificate for team $TEAM_ID in your keychain.
  Create it once: Xcode › Settings › Accounts › (your team) › Manage Certificates… › + › Developer ID Application.
  Then run this again. (Details: docs/RELEASING.md › One-time setup.)"
  fi
  IDENTITY=$(echo "$IDENTITY_LINE" | sed -E 's/.*"(.*)"/\1/')
  ok "Signing identity: $IDENTITY"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "No notarytool profile \"$NOTARY_PROFILE\". Run once:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id $TEAM_ID
  (it asks for an app-specific password from account.apple.com)."
  ok "Notary profile: $NOTARY_PROFILE"
fi

rm -rf "$OUT"; mkdir -p "$OUT"
cd "$MAC_DIR"
say "Generating the project"
xcodegen generate --quiet

# Sparkle's tools come with the package.
xcodebuild -resolvePackageDependencies -project Macrophone.xcodeproj -scheme Macrophone -derivedDataPath "$DERIVED" >/dev/null
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle's sign_update wasn't found under $SPARKLE_BIN."
PLIST_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist)
KEYCHAIN_KEY=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)
[[ -n "$KEYCHAIN_KEY" ]] || die "No Sparkle key for account \"$SPARKLE_ACCOUNT\" in the login keychain. Restore it from your backup (docs/RELEASING.md)."
[[ "$KEYCHAIN_KEY" == "$PLIST_KEY" ]] || die "The Sparkle key in the keychain doesn't match SUPublicEDKey in Info.plist."
ok "Sparkle key matches Info.plist"

# ── 2. Archive and export ──────────────────────────────────────────────────────────────────
say "Archiving $VERSION ($BUILD)"
ARCHIVE="$OUT/Macrophone.xcarchive"
# Alerts that reach a closed iPhone app go through iCloud: the app target signs with the
# Developer ID profile that carries the container (made with the App Store Connect API; see
# docs/RELEASING.md). A dry run signs for development, without iCloud.
CLOUD_PROFILE="Macrophone Mac iCloud Developer ID"
if (( DRY_RUN )); then
  CLOUD_ARGS=()
else
  CLOUD_ARGS=(MACROPHONE_SIGN_STYLE=Manual MACROPHONE_APP_PROFILE="$CLOUD_PROFILE"
              MACROPHONE_ENTITLEMENTS_FILE=Resources/Macrophone-iCloud.entitlements
              MACROPHONE_CLOUD_ALERTS=YES MACROPHONE_SIGN_IDENTITY="Developer ID Application")
fi
xcodebuild archive -project Macrophone.xcodeproj -scheme Macrophone -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" DEVELOPMENT_TEAM="$TEAM_ID" \
  "${CLOUD_ARGS[@]}" -allowProvisioningUpdates -quiet \
  || die "Archive failed."

APP="$OUT/Macrophone.app"
if (( DRY_RUN )); then
  ditto "$ARCHIVE/Products/Applications/Macrophone.app" "$APP"
else
  say "Exporting with Developer ID"
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict><key>com.sameer.macrophone.mac</key><string>$CLOUD_PROFILE</string></dict>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet || die "Export failed."
  ditto "$OUT/export/Macrophone.app" "$APP"
fi

# ── 3. Verify ──────────────────────────────────────────────────────────────────────────────
say "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
CLI="$APP/Contents/Helpers/macrophone"
[[ -x "$CLI" ]] || die "The command-line tool isn't at Contents/Helpers/macrophone."
for f in "$APP" "$CLI" "$APP/Contents/Frameworks/Sparkle.framework"; do
  FLAGS=$(codesign -dv --verbose=4 "$f" 2>&1 | grep -E "^CodeDirectory" || true)
  [[ "$FLAGS" == *"runtime"* ]] || warn "No hardened runtime flag on ${f:t}"
done
ACTUAL=$(codesign -dv --verbose=2 "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2)
(( DRY_RUN )) || [[ "$ACTUAL" == Developer\ ID\ Application* ]] || die "The app is signed by \"$ACTUAL\", not Developer ID."
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
[[ "$APP_VERSION" == "$VERSION" && "$APP_BUILD" == "$BUILD" ]] || die "Built $APP_VERSION ($APP_BUILD), expected $VERSION ($BUILD)."
"$CLI" --version | grep -q "$VERSION" || die "The CLI reports the wrong version."
ok "Signed by: $ACTUAL"

notarize() {  # notarize <file>
  local file=$1 log="$OUT/notary-${1:t}.json"
  say "Notarizing ${file:t} (this takes a few minutes)"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$log" \
    || die "notarytool failed — see $log"
  local result=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('status',''))" "$log")
  if [[ "$result" != "Accepted" ]]; then
    local id=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('id',''))" "$log")
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-log-${1:t}.json" || true
    die "Notarization status: $result — see $OUT/notary-log-${1:t}.json"
  fi
  ok "Notarized ${file:t}"
}

# ── 4. Notarize + staple the app ────────────────────────────────────────────────────────────
if (( ! DRY_RUN )); then
  ditto -c -k --keepParent "$APP" "$OUT/Macrophone-notarize.zip"
  notarize "$OUT/Macrophone-notarize.zip"
  xcrun stapler staple "$APP" >/dev/null && ok "Stapled the app"
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -1
fi

# ── 5. DMG ─────────────────────────────────────────────────────────────────────────────────
say "Building the DMG"
STAGE="$OUT/dmg"; mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Macrophone.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
swift "$MAC_DIR/scripts/render-dmg-background.swift" "$OUT/bg" >/dev/null
tiffutil -cathidpicheck "$OUT/bg/background.png" "$OUT/bg/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
RW="$OUT/rw.dmg"; DMG="$OUT/$DMG_NAME"
hdiutil create -quiet -volname "Macrophone" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" 2>/dev/null | grep -o '/Volumes/.*$' | head -1)
[[ -n "$MOUNT" ]] || die "Couldn't mount the DMG."
VOL=${MOUNT:t}
if [[ "$VOL" != "Macrophone" ]]; then
  hdiutil detach -quiet "$MOUNT" || true
  die "Another volume called Macrophone is mounted (this one came up as \"$VOL\"). Eject it and run again."
fi
# Window layout: written straight into the volume's .DS_Store (icon view, window size, icon
# positions, the background picture) — no Finder scripting, so no Automation prompt.
python3 "$MAC_DIR/scripts/dmg/dsstore.py" "$MOUNT" >/dev/null || die "Couldn't lay out the DMG window."
rm -rf "$MOUNT/.fseventsd"
# The volume shows the app's icon in Finder's sidebar and title bar.
SetFile -a C "$MOUNT" 2>/dev/null || true
sync; sleep 1
hdiutil detach -quiet "$MOUNT" || hdiutil detach -force -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
if (( ! DRY_RUN )); then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null && ok "Stapled the DMG"
fi
ok "DMG: $DMG ($(du -h "$DMG" | cut -f1))"

# ── 6. Sparkle signature + appcast ─────────────────────────────────────────────────────────
say "Signing the update for Sparkle"
# Export the key just long enough to sign (sign_update reading the keychain itself would ask
# for permission in a dialog every time); the copy lives in a private temp folder and is wiped.
KEYDIR=$(mktemp -d); chmod 700 "$KEYDIR"
trap 'rm -rf "$KEYDIR"' EXIT
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$KEYDIR/key" >/dev/null || die "Couldn't read the Sparkle key from the keychain."
SIG_ATTRS=$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEYDIR/key" "$DMG") || die "sign_update failed."
ED_SIG=$(echo "$SIG_ATTRS" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
LENGTH=$(echo "$SIG_ATTRS" | sed -E 's/.*length="([0-9]+)".*/\1/')
[[ -n "$ED_SIG" && -n "$LENGTH" ]] || die "Couldn't read sign_update's output: $SIG_ATTRS"
"$SPARKLE_BIN/sign_update" --ed-key-file "$KEYDIR/key" --verify "$DMG" "$ED_SIG" >/dev/null 2>&1 || die "The Sparkle signature didn't verify."
rm -P "$KEYDIR/key" 2>/dev/null || rm -f "$KEYDIR/key"
ok "EdDSA signature made (${LENGTH} bytes)"

DEST="$WEB_DIR"
(( DRY_RUN )) && DEST="$OUT/site"
mkdir -p "$DEST/releases"
APPCAST="$DEST/releases/appcast.xml"
# Start from the published appcast so earlier versions stay listed.
[[ -f "$APPCAST" ]] || { [[ -f "$WEB_DIR/releases/appcast.xml" ]] && cp "$WEB_DIR/releases/appcast.xml" "$APPCAST" || true; }

python3 - "$APPCAST" "$VERSION" "$BUILD" "$SITE_BASE" "$DMG_NAME" "$ED_SIG" "$LENGTH" <<'PY'
import sys, os, re
from email.utils import formatdate
path, version, build, base, dmg, sig, length = sys.argv[1:]
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{base}/releases/notes-{version}.html</sparkle:releaseNotesLink>
      <enclosure url="{base}/releases/{dmg}" length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
    </item>
"""
head = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Macrophone</title>
    <link>""" + base + """/appcast.xml</link>
    <description>Updates for Macrophone for Mac.</description>
    <language>en</language>
"""
tail = "  </channel>\n</rss>\n"
items = []
if os.path.exists(path):
    old = open(path, encoding="utf-8").read()
    items = re.findall(r"    <item>.*?</item>\n", old, flags=re.S)
    # Replace an earlier item for the same build.
    items = [i for i in items if f"<sparkle:version>{build}</sparkle:version>" not in i]
open(path, "w", encoding="utf-8").write(head + item + "".join(items) + tail)
print(f"appcast: {len(items) + 1} item(s)")
PY

# ── 7. Publish into the website repo ───────────────────────────────────────────────────────
cp "$DMG" "$DEST/releases/$DMG_NAME"
cp "$DMG" "$DEST/releases/Macrophone-latest.dmg"
cp "$NOTES" "$DEST/releases/notes-$VERSION.html"
# The feed URL in Info.plist is $SITE_BASE/appcast.xml; keep that copy identical.
cp "$APPCAST" "$DEST/appcast.xml"
ok "Wrote releases/$DMG_NAME, Macrophone-latest.dmg, notes-$VERSION.html, releases/appcast.xml and appcast.xml into $DEST"

echo
if (( DRY_RUN )); then
  ok "Dry run finished. Nothing was notarized or published."
else
  ok "Macrophone $VERSION ($BUILD) is signed, notarized and staged."
  echo "  Next: in ${WEB_DIR:h:h:h}, commit public/macrophone and push to deploy."
  echo "  Then: open an older copy and choose Check for Updates… to see the update arrive."
fi
