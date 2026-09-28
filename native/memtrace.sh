#!/bin/zsh
# Record a Game Memory trace of the game on the headset. Instruments can't
# attach to the game once it's running, so this LAUNCHES it: start this, then
# put the headset on (the launch waits until it's worn), connect and play.
# Usage: ./memtrace.sh [seconds]   (default 300)
DEV=00008142-000C14DE1E47801C
SECS=${1:-300}
OUT=${TMPDIR:-/tmp}/memtrace-$(date +%m%d-%H%M).trace
echo "recording ${SECS}s to $OUT (waits for the headset to be worn)"
xcrun xctrace record --device "$DEV" --template "Game Memory" --time-limit "${SECS}s" \
  --output "$OUT" --launch -- dev.ericbetts.voxelnative
echo "saved $OUT"
