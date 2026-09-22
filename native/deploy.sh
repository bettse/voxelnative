#!/bin/zsh
# Build, install and launch the native visionOS spike on the paired Vision Pro.
# Regenerates the Xcode project from project.yml (xcodegen), works around the
# Xcode 26.6 clang-probe deadlock, and streams the device console.
#   native/deploy.sh [--no-launch]
set -eu
HERE=${0:A:h}
cd "$HERE"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/voxelnative-cli"
BUNDLE=dev.ericbetts.voxelnative
# Pick the PHYSICAL Vision Pro, not a simulator entry: the list can lead with
# shut-down sim devices (installing there fails with "Install Application not
# supported"), and the physical UDID isn't a 36-char UUID anymore (visionOS 27
# gives it a shorter form like 00008142-000C14DE1E47801C), so match the
# "physical" Reality column and take the token right before "(UDID)".
DEV=$(xcrun devicectl list devices 2>/dev/null \
  | awk '/Apple Vision Pro/ && /physical/ { for (i=1;i<=NF;i++) if ($i=="(UDID)") { print $(i-1); exit } }')
[[ -z "$DEV" ]] && { echo "no physical Apple Vision Pro paired"; exit 1; }
echo "device: $DEV"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

# Watchdog: kill the deadlocked clang version probe (swiftlang/swift-build#1315).
( while true; do
    ps -axo pid,etime,command | grep '[c]lang -v -E -dM' | while read -r pid et rest; do
      s=$(echo "$et" | awk -F: '{if(NF==3)print $1*3600+$2*60+$3; else if(NF==2)print $1*60+$2; else print $1}')
      [[ "${s:-0}" -ge 20 ]] && kill -9 "$pid" 2>/dev/null
    done; sleep 5; done ) &
WD=$!; trap 'kill $WD 2>/dev/null' EXIT

echo "building..."
# Stamp the commit into the app (Info.plist GitHash -> logged at connect) so a
# device log says which build it came from; deploy is install-only and a live
# app keeps running old code, which kept fooling us.
GIT_HASH="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# Release by default: the headset ran unoptimized Debug Swift until 2026-09-21,
# and the -vrdev.perfStats numbers showed Release halving the game tick
# (entity emission 4x faster, skinning 7x). DEPLOY_CONFIG=Debug to go back.
# Crash symbolication: the dSYM is next to the app in
# $DERIVED/Build/Products/Release-xros/ (atos -o VoxelNative.app.dSYM/...).
CONFIG="${DEPLOY_CONFIG:-Release}"
xcodebuild -project VoxelNative.xcodeproj -scheme VoxelNative -configuration "$CONFIG" \
  -destination "id=$DEV" -derivedDataPath "$DERIVED" -allowProvisioningUpdates GIT_HASH="$GIT_HASH" build 2>&1 \
  | grep -E 'error:|BUILD' | grep -viE 'UsageDescription' | tee /tmp/voxel_deploy_build.txt || true
# A failed build leaves the PREVIOUS app in Build/Products, and installing
# that silently ships stale code: it did for most of a day when device-only
# state sat under a simulator #if (2026-09-22). Refuse unless xcodebuild
# actually said it succeeded.
grep -q 'BUILD SUCCEEDED' /tmp/voxel_deploy_build.txt || { echo "build FAILED (errors above); not installing the stale app"; exit 1; }

APP="$DERIVED/Build/Products/$CONFIG-xros/VoxelNative.app"
[[ -d "$APP" ]] || { echo "build failed: no app"; exit 1; }

# Don't install over a LIVE app: Eric may be mid-test, and installing terminates
# it. devicectl can't list processes on visionOS, so use native.log as a liveness
# probe: the app writes it unbuffered every few seconds, so a fresh lastModDate
# means the app is running right now. Pass --force to install anyway.
if [[ "${1:-}" != "--force" ]]; then
  FJSON=$(mktemp)
  if xcrun devicectl device info files --device "$DEV" --domain-type appDataContainer \
       --domain-identifier "$BUNDLE" --subdirectory Documents --json-output "$FJSON" >/dev/null 2>&1; then
    if python3 - "$FJSON" <<'PY'
import json,sys,datetime
d=json.load(open(sys.argv[1]))
mod=next((f['metadata']['lastModDate'] for f in d['result']['files'] if f['name']=='native.log'), None)
if not mod: sys.exit(1)                       # no log yet -> not running
t=datetime.datetime.strptime(mod[:19],"%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
age=(datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()
sys.exit(0 if age < 30 else 1)               # 0 = fresh = running
PY
    then
      echo "app appears to be RUNNING (native.log is fresh) -- skipping install so a live test isn't killed. Re-run with --force to override."
      rm -f "$FJSON"; exit 0
    fi
  fi
  rm -f "$FJSON"
fi

echo "installing..."
xcrun devicectl device install app --device "$DEV" "$APP" 2>&1 | grep -E 'App installed|error|Error' || true
# Never auto-launch: the launch handshake hangs on this device connection, and
# Eric launches from the headset himself. Install-only is the whole job now.
echo "installed. Launch it from the headset when ready."
