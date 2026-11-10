#!/bin/zsh
# Entity zoo: spawn every VoxeLibre mob on a stone platform ahead of the sim
# spawn pad, in batches, and screenshot each batch. Run with the sim up:
#   SIM_EXTRA_ARGS="-vrdev.entityZoo 1" SIM_KEEP=1 ./sim.sh && tools/entityzoo.sh
# The client logs one [ezoo] line per mob kind (visual, model, textures). The
# server commands are paced under the chat flood limit (8 per 10 s). The
# wither and ender dragon are left out: both wreck the area around them.
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/entityzoo}
mkdir -p "$OUT"
P=1.3   # seconds between chat commands

MOBS=(axolotl baby_hoglin baby_husk baby_pigman baby_strider baby_zombie baby_zombified_piglin bat cat cave_spider
      chicken cod cow dog dolphin donkey elemental_fire endermite evoker ghast glow_squid guardian guardian_elder hoglin
      horse husk illusioner iron_golem killer_bunny llama magma_cube_big magma_cube_small magma_cube_tiny mooshroom mule
      ocelot parrot pig piglin piglin_brute pigman pillager polar_bear rabbit rover salmon sheep shulker silverfish
      skeleton skeleton_horse slime_big slime_small slime_tiny snowman spider squid stalker stalker_overloaded stray
      strider sword_piglin tropical_fish vex villager villager_zombie vindicator witch witherskeleton wolf zoglin zombie
      zombie_horse zombified_piglin)

cmds=()
chat() { cmds+=("chat $1" "sleep $P") }

# Creative so nothing attacks the sim player; back on the pad, facing +z.
chat "/gamemode creative"
chat "/teleport 0 140 0"
chat "/teleport 0 121 0"
# A 13x9 stone platform at pad level ahead (y=120 is the pad surface).
for x in {-6..6}; do for z in {3..11}; do chat "/setblock $x,120,$z mcl_core:stone"; done; done
./vrctl "${cmds[@]}" >/dev/null 2>&1
cmds=()

# Face +z: our yaw 0 looks along +z.
yaw=$(./vrctl state | python3 -c "import sys,json; print(json.loads([l for l in sys.stdin if l.startswith('{')][-1])['yaw'])")
./vrctl "turn $(python3 -c "print(-($yaw))")" "pitch -8" >/dev/null 2>&1

batch=0; i=0
spawn_batch() {
  local names=("$@")
  cmds=()
  local k=0
  for m in "${names[@]}"; do
    local x=$(( -5 + (k % 6) * 2 )); local z=$(( 4 + (k / 6) * 2 ))
    chat "/summon mobs_mc:$m $x,122,$z"
    k=$((k+1))
  done
  ./vrctl "${cmds[@]}" "sleep 2" "shot $OUT/zoo_$batch.png" "turn 25" "sleep 1" "shot $OUT/zoo_${batch}_r.png" "turn -50" "sleep 1" "shot $OUT/zoo_${batch}_l.png" "turn 25" >/dev/null 2>&1
  ./vrctl "chat /clearobjects quick" "sleep 3" >/dev/null 2>&1
  batch=$((batch+1))
}
chunk=()
for m in "${MOBS[@]}"; do
  chunk+=("$m")
  if (( ${#chunk[@]} == 24 )); then spawn_batch "${chunk[@]}"; chunk=(); fi
done
(( ${#chunk[@]} > 0 )) && spawn_batch "${chunk[@]}"

# Put the pad area back and leave creative.
cmds=()
for x in {-6..6}; do for z in {3..11}; do chat "/setblock $x,120,$z air"; done; done
chat "/gamemode survival"
./vrctl "${cmds[@]}" >/dev/null 2>&1
echo "done: $batch batches, shots in $OUT"
