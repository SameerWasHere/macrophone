#!/bin/zsh
# Captures the raw iPhone Duo App Store screens (Nov 1 2026). Then frame them with
#   swift iOS/scripts/render-store-shots.swift <out dir> iOS/docs/store-screenshots/duo 2007 2853 duo
#
#   scripts/capture-duo-store-shots.sh <duo simulator udid> <out dir> <pairing url>
#
# The simulator is a real Duo (iOS 27.1+), folded and unfolded with the duo-sim skill
# (~/.claude/skills/duo-sim/duo-sim.sh: `create`, `pose`, `shot … inner|cover`) — no
# MACROPHONE_FRAME / MACROPHONE_POSTURE stand-ins. Make your own (`duo-sim.sh create`; other
# sessions share simulators), install the Debug build (normal signing), and pass a fresh
# `mpctl serve … --state <new dir>`'s PAIR URL (see capture-store-shots.sh, with MPCTL_NO_DRAWN_POINTER=1). Inner screen shots are
# 2007×2853 upright / 2853×2007 on its side; the cover 1398×2034.
set -e
U=$1; OUT=$2; PAIR=$3
DUO=~/.claude/skills/duo-sim/duo-sim.sh
mkdir -p $OUT

xcrun simctl spawn $U defaults write com.sameer.macrophone settings.agentAlerts -bool false
xcrun simctl spawn $U defaults write com.sameer.macrophone watch.tips.seen "click,input,keys,scroll,swipe,zoom"
# A fresh simulator's keyboard opens with its "slide to type" introduction over the keys.
xcrun simctl spawn $U defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl ui $U appearance light
xcrun simctl status_bar $U override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

launch() {  # launch <seconds> KEY=VALUE...
  local wait=$1; shift
  xcrun simctl terminate $U com.sameer.macrophone 2>/dev/null || true
  local envs=(SIMCTL_CHILD_MACROPHONE_RESET=1 "SIMCTL_CHILD_MACROPHONE_DEVICE_NAME=Sameer's iPhone" SIMCTL_CHILD_MACROPHONE_CLEANUP_AVAILABLE=1)
  for kv in "$@"; do envs+=("SIMCTL_CHILD_$kv"); done
  env "${envs[@]}" xcrun simctl launch $U com.sameer.macrophone >/dev/null
  sleep $wait
}
grab() { zsh $DUO shot $U $1 "$OUT/$2.png" >/dev/null; echo "captured $2"; }

# Closed: pair, then the cover with the window live (its answers, the one row of keyboard · mic ·
# trackpad, the vertical bar's buttons).
zsh $DUO pose $U closed
launch 8 MACROPHONE_SCREEN=main "MACROPHONE_OPEN_URL=$PAIR"
launch 22 MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1
grab cover 05-cover
# Folded like a laptop: the window takes the top half by itself, the trackpad the deck. The demo
# reaches its question in ~14–20 s.
zsh $DUO pose $U tabletop
sleep 20
grab inner 01-laptop-trackpad
# The same with the deck on the keyboard page (the iOS keyboard with the Mac's keys).
launch 22 MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1 "MACROPHONE_WATCH_ACTIONS=page@keyboard"
grab inner 02-laptop-keyboard
# Opened flat from closed: the glance on the left page, the cover's view on the right.
zsh $DUO pose $U closed
sleep 2
launch 6 MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1
zsh $DUO pose $U open
sleep 22
grab inner 04-open-flat
# Folded like a book with the window in hand: the window on the left page, keys, trackpad and mic on the right.
launch 22 MACROPHONE_SCREEN=main MACROPHONE_SEND_TO=Terminal MACROPHONE_SEND=1 MACROPHONE_WATCH=1
zsh $DUO pose $U folded
sleep 5
grab inner 03-book
zsh $DUO pose $U closed
xcrun simctl status_bar $U clear
