#!/bin/zsh
# Build the native app for the visionOS Simulator, launch it, and screenshot the
# immersive view. Tight iteration loop with no headset.
set -eu
HERE=${0:A:h}; cd "$HERE"
SIM=${1:-AAA51166-3572-43B8-9B71-9090483A2301}   # Apple Vision Pro, visionOS 26.5
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/voxelnative-sim"
BUNDLE=dev.ericbetts.voxelnative
SHOT=${2:-/tmp/voxel_sim.png}
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
( while true; do
    ps -axo pid,etime,command | grep '[c]lang -v -E -dM' | while read -r pid et rest; do
      s=$(echo "$et" | awk -F: '{if(NF==3)print $1*3600+$2*60+$3; else if(NF==2)print $1*60+$2; else print $1}')
      [[ "${s:-0}" -ge 20 ]] && kill -9 "$pid" 2>/dev/null
    done; sleep 5; done ) & WD=$!; trap 'kill $WD 2>/dev/null' EXIT
echo "building for simulator..."
GIT_HASH="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# SIM_CONFIG=Release builds optimized (what the headset should get; Debug is
# unoptimized Swift and 5-10x slower in the hot loops, see [perf] numbers).
CONFIG="${SIM_CONFIG:-Debug}"
xcodebuild -project VoxelNative.xcodeproj -scheme VoxelNative -configuration "$CONFIG" \
  -destination "id=$SIM" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO GIT_HASH="$GIT_HASH" build 2>&1 | grep -E 'error:|BUILD' | grep -viE 'UsageDescription' | tee /tmp/voxel_sim_build.txt || true
# Same guard as deploy.sh: a failed build leaves the previous app behind,
# and a harness run on stale code is worse than no run.
grep -q 'BUILD SUCCEEDED' /tmp/voxel_sim_build.txt || { echo "build FAILED (errors above); not launching the stale app"; exit 1; }
APP="$DERIVED/Build/Products/$CONFIG-xrsimulator/VoxelNative.app"
[[ -d "$APP" ]] || { echo "build failed: no app"; exit 1; }
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true   # a running old build would otherwise keep going
xcrun simctl install "$SIM" "$APP"
# -vrdev.autoConnect 1 skips the login screen and connects straight to the
# selected server, so this headless loop can screenshot the world. A normal
# launch (device, or the sim by hand) shows the launcher and waits for Connect.
# -vrdev.day forces daylight and -vrdev.fakeWield stubs a wield item + hotbar
# cells so the hand HUD is visible headless (the dev account's inventory is
# empty). SIM_EXTRA_ARGS="-vrdev.openInventory 1" adds args (split on spaces).
extra=(${=SIM_EXTRA_ARGS:-})
xcrun simctl launch "$SIM" "$BUNDLE" -vrdev.autoConnect 1 -vrdev.day 1 -vrdev.fakeWield 1 -vrdev.fakeXp 1 -vrdev.fakeNametag 1 -vrdev.fakeHud 1 -vrdev.mute 1 "${extra[@]}" >/dev/null
echo "launched; waiting to render..."
sleep 14   # long enough for the world to stream in; 8 s often caught the buried pre-spawn frame
xcrun simctl io "$SIM" screenshot "$SHOT" && echo "screenshot: $SHOT"
# Terminate the app so it stops playing game audio through the Mac speakers once
# we have the shot (Eric: the sim was making noise on the desktop). Leaving
# SIM_KEEP=1 in the env keeps it running for interactive poking.
[[ -n "${SIM_KEEP:-}" ]] || xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
