#!/bin/zsh
# Captures the raw App Store screens from a simulator through the DEBUG hooks
# (App/DebugHooks.swift). Then `swift scripts/render-store-shots.swift` frames them.
#
#   scripts/capture-store-shots.sh <simulator udid> <out dir> <pairing url>
#
# Re-captured Nov 1 2026 for the Apple-native redesign (the phone at rest is a little Mac desktop:
# the menu bar, the Dock of the Mac's open apps, the options bar, the Siri-like mic). Shots 01–06
# need a live stand-in Mac: in Packages/MacrophoneKit run `swift build` then
#   .build/debug/mpctl serve --name "Sameer's MacBook Pro" --auto-approve --no-attention --state <fresh dir>
# (it answers with real app icons, a drawn Claude Code window and the demo wallpaper) and pass its
# PAIR URL. A pairing URL works once: a fresh --state for each simulator. If the simulator was
# paired with other Macs before, unpair them first (MACROPHONE_UNPAIR=<name>) or the pill and the
# Macs list show them. The hero's MacBook screen is `mpctl demo-window <out dir>/mac-window.png`
# (done here when mpctl is built). The simulator should be booted with the Debug build installed
# (normal signing — CODE_SIGNING_ALLOWED=NO has no Keychain and never connects). Use a 6.9"
# device (iPhone 17 Pro Max, 1320×2868) for docs/store-screenshots/6.9 and a 6.5" one (iPhone 14
# Plus, 1284×2778) for 6.5. The Duo set is scripts/capture-duo-store-shots.sh.
set -e
U=$1; OUT=$2; PAIR=$3
mkdir -p $OUT
HERE=${0:A:h}
MPCTL=$HERE/../../Packages/MacrophoneKit/.build/debug/mpctl
[ -x $MPCTL ] && $MPCTL demo-window $OUT/mac-window.png >/dev/null && echo "drew mac-window"

# No agent alert banners over the frames, no first-use tip cards.
xcrun simctl spawn $U defaults write com.sameer.macrophone settings.agentAlerts -bool false
xcrun simctl spawn $U defaults write com.sameer.macrophone watch.tips.seen "click,input,keys,scroll,swipe,zoom"
xcrun simctl status_bar $U override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

REPLY="Yes, but also add a test for both the expired and the missing token, then run the whole suite before you commit."

look() { xcrun simctl ui $U appearance $1; }

shot() {  # shot <name> <seconds> KEY=VALUE...
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate $U com.sameer.macrophone 2>/dev/null || true
  local envs=(SIMCTL_CHILD_MACROPHONE_RESET=1 "SIMCTL_CHILD_MACROPHONE_DEVICE_NAME=Sameer's iPhone" SIMCTL_CHILD_MACROPHONE_CLEANUP_AVAILABLE=1)
  for kv in "$@"; do envs+=("SIMCTL_CHILD_$kv"); done
  env "${envs[@]}" xcrun simctl launch $U com.sameer.macrophone >/dev/null
  sleep $wait
  [ "$name" = "-" ] || { xcrun simctl io $U screenshot "$OUT/$name.png" >/dev/null 2>&1; echo "captured $name"; }
}

# Pair with the stand-in Mac (once per simulator; kept across launches).
look light
shot - 8 MACROPHONE_SCREEN=main "MACROPHONE_OPEN_URL=$PAIR"
# The window, live (dark: the terminal and the white status bar read best on the dark desktop);
# the demo reaches its "Do you want to make this edit?" in ~14–20 s. Keep the stand-in fresh for these:
# its drawn pointer stays where the trackpad left it, and over "1. Yes" the question isn't read,
# so the trackpad shot comes last of the three.
look dark
shot 01-watch    24 MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1
look light
# Replying while watching: the window as a strip, the words appearing, the mic open.
shot 02-reply    9  MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1 "MACROPHONE_FAKE_RECORDING=$REPLY"
# The trackpad page, the pointer moved onto the question's first answer (after it was read).
look dark
shot 03-trackpad 22 MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1 \
  "MACROPHONE_WATCH_ACTIONS=page@trackpad,point@-85@45"
look light
# The phone at rest: the menu bar, the Dock of the Mac's open apps, the options bar, the mic.
shot 04-desktop  7  MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1
shot 05-open-app 7  MACROPHONE_SCREEN=openapp
shot 06-settings 5  MACROPHONE_SCREEN=settings MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_DICTIONARY=kubectl,SwiftUI,Postgres,onAppear,TestFlight
# Forget the stand-in Mac first, or onboarding skips past the pairing step.
shot - 5 MACROPHONE_SCREEN=main MACROPHONE_UNPAIR=1
shot 07-pairing  4  MACROPHONE_ONBOARDING_STEP=5 MACROPHONE_FAKE_CAMERA=1
xcrun simctl status_bar $U clear
