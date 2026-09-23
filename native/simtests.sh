#!/bin/zsh
# Run the headless simulator test scenes (the -vrdev.*Test aids in
# WorldSession) back to back against the local dev server and report each
# one's RESULT line. Builds once via sim.sh, then relaunches the installed app
# per scene with the same base args sim.sh uses.
#
#   ./simtests.sh                 # all scenes, Release build
#   ./simtests.sh sneak igloo     # just these
#   SIM_CONFIG=Debug ./simtests.sh
#
# Each scene must print "[<tag>] RESULT ... pass=true|false" within TIMEOUT
# seconds of launch; anything else counts as a failure. audioTest is left out
# (it needs an unmuted run, see memory/audio-smoke-test-unmuted).
set -u
SIM=${SIM:-AAA51166-3572-43B8-9B71-9090483A2301}
BUNDLE=dev.ericbetts.voxelnative
TIMEOUT=${TIMEOUT:-150}
export SIM_CONFIG="${SIM_CONFIG:-Release}"
cd "${0:A:h}"

# flag:tag pairs. The tag is what the RESULT line is prefixed with.
typeset -A SCENES
SCENES=(
  igloo   "iglooTest:igloo"
  ice     "iceTest:icetest"
  fall    "fallTest:falltest"
  bounce  "bounceTest:bouncetest"
  place   "placeTest:placetest"
  eat     "eatTest:eattest"
  bow     "bowTest:bowtest"
  sneak   "sneakTest:sneaktest"
  dig     "digTest:digtest"
  drop    "dropTest:droptest"
  award   "awardTest:awardtest"
  torch   "torchTest:torchtest"
  fly     "flyTest:flytest"
  invpick "invPickTest:invpick"
  bugnote "bugNoteTest:bugnotetest"
  ladder  "ladderTest:laddertest"
)
# Scenes that walk the player away from the platform origin (ice, sneak) or
# teleport it elsewhere (igloo) go last, so the others start from a known spot.
order=(fall bounce place eat bow dig drop award torch fly invpick bugnote ladder ice igloo sneak)
want=("$@"); [[ ${#want} -eq 0 ]] && want=("${order[@]}")

# Build + install once (sim.sh also boots the simulator and takes a smoke shot).
SIM_KEEP= ./sim.sh >/dev/null 2>&1 || { echo "sim.sh failed"; exit 1; }

fail=0
for name in "${want[@]}"; do
  spec=${SCENES[$name]:-}
  [[ -z "$spec" ]] && { echo "SKIP  $name (unknown scene)"; continue; }
  flag=${spec%%:*}; tag=${spec##*:}
  xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 2   # let the server see the old session go (the client's goodbye + join grace)
  xcrun simctl launch "$SIM" "$BUNDLE" -vrdev.autoConnect 1 -vrdev.day 1 -vrdev.fakeWield 1 \
    -vrdev.fakeXp 1 -vrdev.fakeNametag 1 -vrdev.fakeHud 1 -vrdev.mute 1 "-vrdev.$flag" 1 >/dev/null
  D=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
  LOG="$D/Documents/native.log"
  start=$SECONDS; line=""
  while (( SECONDS - start < TIMEOUT )); do
    line=$(grep -m1 "\[$tag\] RESULT" "$LOG" 2>/dev/null || true)
    [[ -n "$line" ]] && break
    grep -q "disconnected: no answer from server" "$LOG" 2>/dev/null && { line="(no answer from server: is tools/server.sh running?)"; break; }
    sleep 3
  done
  if [[ "$line" == *"pass=true"* ]]; then
    echo "PASS  $name  $((SECONDS - start))s"
  else
    echo "FAIL  $name  ${line:-(no RESULT within ${TIMEOUT}s)}"
    fail=1
  fi
done
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
exit $fail
