#!/bin/zsh
# Pull Godot's log from the app on the paired Vision Pro (file logging is on
# in project.godot; user:// maps to the app's Documents folder).
set -eu
DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep 'Apple Vision Pro' | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
OUT=${1:-${0:A:h}/device-logs}
mkdir -p "$OUT"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier dev.ericbetts.voxelibrevr --source Documents/logs --destination "$OUT" >/dev/null
ls -t "$OUT"/logs/*.log | head -3
echo "--- newest log tail:"
tail -40 "$(ls -t "$OUT"/logs/*.log | head -1)"
