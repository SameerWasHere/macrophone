#!/bin/zsh
# Captures the raw App Store screens from a simulator through the DEBUG hooks
# (App/DebugHooks.swift). Then `swift scripts/render-store-shots.swift` frames them.
#
#   scripts/capture-store-shots.sh <simulator udid> <out dir> <pairing url>
#
# The pitch (Oct 14 2026): your Mac does the coding, your iPhone runs the session. Shots 1–4 need
# a live Mac: run `swift run mpctl serve --name "Sameer's MacBook Pro" --auto-approve` in
# Packages/MacrophoneKit (it answers with real app icons and a drawn Claude Code window) and pass
# its PAIR URL. A pairing URL works once: start a fresh `mpctl serve --state <new dir>` for each
# simulator (the 6.5" set uploaded on Oct 14 2026 showed "Mac not connected" because the 6.9" run
# had used it). `mpctl demo-window <dir>/mac-window.png` draws the hero's Mac screen. The simulator should be booted with the Debug build installed. Use a 6.9" device
# (iPhone 17 Pro Max, 1320×2868) for docs/store-screenshots/6.9 and a 6.5" one (iPhone 14 Plus,
# 1284×2778) for 6.5.
set -e
U=$1; OUT=$2; PAIR=$3
mkdir -p $OUT
xcrun simctl status_bar $U override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

MAC="Sameer's MacBook Pro"
REPLY="Yes, but also add a test for both the expired and the missing token, then run the whole suite before you commit."

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
shot - 6 MACROPHONE_SCREEN=main "MACROPHONE_OPEN_URL=$PAIR"
# The window, live; the demo reaches its "Do you want to make this edit?" in ~14 s.
shot 01-watch    18 MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1
shot 02-reply    7  MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1 "MACROPHONE_FAKE_RECORDING=$REPLY"
shot 03-send-to  5  MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Claude MACROPHONE_SEND=1 "MACROPHONE_EXPLAIN=Pastes into Claude, then sends"
shot 04-open-app 6  MACROPHONE_SCREEN=openapp
shot 05-cleanup  3  MACROPHONE_SCREEN=settings "MACROPHONE_FAKE_PAIRED=$MAC" MACROPHONE_DICTIONARY=kubectl,SwiftUI,Postgres,onAppear,TestFlight
# Forget the stand-in Mac first, or onboarding skips past the pairing step.
shot - 5 MACROPHONE_SCREEN=main MACROPHONE_UNPAIR=1
shot 06-pairing  4  MACROPHONE_ONBOARDING_STEP=5 MACROPHONE_FAKE_CAMERA=1
xcrun simctl status_bar $U clear
