#!/bin/zsh
# Captures the raw App Store screens from a simulator through the DEBUG hooks
# (App/DebugHooks.swift). Then `swift scripts/render-store-shots.swift` frames them.
#
#   scripts/capture-store-shots.sh <simulator udid> <out dir>
#
# The simulator should be booted with the Debug build installed. Uses a 6.9" device
# (iPhone 17 Pro Max, 1320×2868) for docs/store-screenshots/6.9 and a 6.5" one
# (iPhone 14 Plus, 1284×2778) for 6.5.
set -e
U=$1; OUT=$2
mkdir -p $OUT
# The clock reads the real time so it agrees with the times on the sample dictations.
xcrun simctl status_bar $U override --time "$(date +%-l:%M)" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

MAC="Sameer's MacBook Pro"
PROMPT="Claude, the uploader retries too aggressively when the network drops. Make it back off exponentially, starting at one second and capping at thirty, and log every retry with the attempt number so we can see it in the console."

shot() {  # shot <name> <seconds> KEY=VALUE...
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate $U com.sameer.macrophone 2>/dev/null || true
  local envs=(SIMCTL_CHILD_MACROPHONE_RESET=1 "SIMCTL_CHILD_MACROPHONE_DEVICE_NAME=Sameer's iPhone")
  for kv in "$@"; do envs+=("SIMCTL_CHILD_$kv"); done
  env "${envs[@]}" xcrun simctl launch $U com.sameer.macrophone >/dev/null
  sleep $wait
  xcrun simctl io $U screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "captured $name"
}

shot 01-recording 9  MACROPHONE_SCREEN=main MACROPHONE_CLEANUP_AVAILABLE=1 "MACROPHONE_FAKE_PAIRED=$MAC" MACROPHONE_SEND_TO=Claude MACROPHONE_SEND=1 MACROPHONE_FAKE_HISTORY=1 "MACROPHONE_FAKE_RECORDING=$PROMPT"
shot 02-delivered 2.2 MACROPHONE_SCREEN=main MACROPHONE_CLEANUP_AVAILABLE=1 "MACROPHONE_FAKE_PAIRED=$MAC" MACROPHONE_SEND_TO=Claude MACROPHONE_SEND=1 MACROPHONE_FAKE_HISTORY=1 MACROPHONE_STATUS=delivered-prefix
# The dock of the Mac's open apps, the pick lit, the status line saying what the next one does.
shot 03-send-to   3  MACROPHONE_SCREEN=main "MACROPHONE_FAKE_PAIRED=$MAC" MACROPHONE_SEND_TO=Claude MACROPHONE_SEND=1 MACROPHONE_FAKE_HISTORY=1 MACROPHONE_CLEANUP_AVAILABLE=1 "MACROPHONE_EXPLAIN=Pastes into Claude, then sends"
shot 05-history   3  MACROPHONE_SCREEN=history MACROPHONE_CLEANUP_AVAILABLE=1 "MACROPHONE_FAKE_PAIRED=$MAC" MACROPHONE_FAKE_HISTORY=1
shot 04-cleanup   3  MACROPHONE_SCREEN=settings MACROPHONE_CLEANUP_AVAILABLE=1 "MACROPHONE_FAKE_PAIRED=$MAC" MACROPHONE_FAKE_HISTORY=1 MACROPHONE_DICTIONARY=kubectl,SwiftUI,Postgres,onAppear,TestFlight
shot 06-pairing   3  MACROPHONE_ONBOARDING_STEP=5 MACROPHONE_FAKE_CAMERA=1
