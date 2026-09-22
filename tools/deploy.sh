#!/bin/zsh
# Build, install and launch the client on the paired Apple Vision Pro without
# opening Xcode. Works around the Xcode 26.6 build-system deadlock on the
# `clang -v` probe (swiftlang/swift-build#1315) by killing probes stuck >20 s.
#
#   tools/deploy.sh [--export] [--no-launch]
#     --export     re-export the Xcode project from Godot first
#     --no-launch  build and install only
set -eu
HERE=${0:A:h}
CLIENT="$HERE/../client"
PROJ="$CLIENT/export/visionos/VoxeLibreVR.xcodeproj"
GODOT=/Applications/Godot-4.8-dev4.app/Contents/MacOS/Godot
BUNDLE=dev.ericbetts.voxelibrevr
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/voxelibre-vr-cli"

DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep 'Apple Vision Pro' | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
[[ -z "$DEVICE" ]] && { echo "no Apple Vision Pro paired/visible (xcrun devicectl list devices)"; exit 1; }
echo "device: $DEVICE"

if [[ "${1:-}" == "--export" ]]; then
  shift
  echo "exporting from Godot..."
  "$GODOT" --headless --path "$CLIENT" --export-debug visionOS "$PROJ" 2>&1 | grep -iE 'error|fail' | grep -v 'f.is_null' || true
fi

# Watchdog for the deadlocked clang version probe.
(
  while true; do
    ps -axo pid,etime,command | grep '[c]lang -v -E -dM' | while read -r pid et rest; do
      secs=$(echo "$et" | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print $1 }')
      if [[ "${secs:-0}" -ge 20 ]]; then kill -9 "$pid" 2>/dev/null && echo "  (killed stuck clang probe $pid)"; fi
    done
    sleep 5
  done
) &
WATCHDOG=$!
trap 'kill $WATCHDOG 2>/dev/null' EXIT

echo "building..."
xcodebuild -project "$PROJ" -scheme VoxeLibreVR -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 \
  | grep -E 'error:|BUILD|Signing Identity|CodeSign ' | grep -vE 'UIRequiresFullScreen|UsageDescription' || true

APP="$DERIVED/Build/Products/Debug-xros/VoxeLibreVR.app"
[[ -d "$APP" ]] || { echo "build failed: no $APP"; exit 1; }

echo "installing..."
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | grep -E 'App installed|error|Error' || true

if [[ "${1:-}" != "--no-launch" ]]; then
  echo "launching (console follows, ctrl-c to stop)..."
  xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing "$BUNDLE"
fi
