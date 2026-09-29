#!/bin/zsh
# Record a Game Memory trace of the game on the headset. Instruments can't
# attach to the game once it's running, so this LAUNCHES it. It can only reach
# the headset while it's awake (worn): xctrace gives up with "Timed out waiting
# for device to boot" otherwise, so retry for up to 10 minutes.
# Usage: ./memtrace.sh [seconds]   (default 300)
DEV=00008142-000C14DE1E47801C
SECS=${1:-300}
OUT=${TMPDIR:-/tmp}/memtrace-$(date +%m%d-%H%M).trace
LOG=$(mktemp)
deadline=$(( $(date +%s) + 600 ))
while (( $(date +%s) < deadline )); do
  # Waking the devicectl tunnel first is what gets xctrace through: without it
  # it reported "waiting for device to boot" even with the headset on.
  xcrun devicectl device info details --device "$DEV" >/dev/null 2>&1
  echo "$(date +%H:%M:%S) trying: recording ${SECS}s to $OUT"
  xcrun xctrace record --device "$DEV" --template "Game Memory" --time-limit "${SECS}s" \
    --output "$OUT" --launch -- dev.ericbetts.voxelnative > "$LOG" 2>&1
  tail -3 "$LOG"
  if grep -q "Timed out waiting for device to boot" "$LOG"; then continue; fi
  [[ -d "$OUT" ]] && { echo "saved $OUT"; exit 0; }
  echo "no trace written"; exit 1
done
echo "headset never woke in 10 minutes"; exit 1
