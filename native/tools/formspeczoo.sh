#!/bin/zsh
# Formspec zoo: place every station with a form ahead of the sim spawn pad,
# open it, screenshot the panel, close it, remove it. Run with the sim up:
#   SIM_EXTRA_ARGS="-vrdev.formspecZoo 1" SIM_KEEP=1 ./sim.sh && tools/formspeczoo.sh
# The client logs one [fzoo] line per form with its element census. Chat
# commands are paced under the flood limit (8 per 10 s).
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/formspeczoo}
mkdir -p "$OUT"
P=1.3

# Not here: loom, fletching table and lectern have no form in VoxeLibre, and
# the dispenser and dropper only get theirs from after_place_node (a /setblock
# one never opens); place those two by hand to check them.
STATIONS=(mcl_crafting_table:crafting_table mcl_furnaces:furnace mcl_blast_furnace:blast_furnace mcl_smoker:smoker
          mcl_brewing:stand_000 mcl_enchanting:table mcl_anvils:anvil mcl_smithing_table:table mcl_grindstone:grindstone
          mcl_stonecutter:stonecutter mcl_cartography_table:cartography_table mcl_beacons:beacon
          mcl_hoppers:hopper mcl_chests:chest_small
          mcl_chests:trapped_chest_small mcl_chests:ender_chest_small mcl_chests:white_shulker_box_small
          mcl_barrels:barrel_closed)

./vrctl "chat /teleport 0 140 0" "sleep $P" "chat /teleport 0 121 0" "sleep 3" >/dev/null 2>&1
yaw=$(./vrctl state | python3 -c "import sys,json; print(json.loads([l for l in sys.stdin if l.startswith('{')][-1])['yaw'])")
./vrctl "turn $(python3 -c "print(-($yaw))")" "pitch 0" >/dev/null 2>&1
# Three nodes ahead along +z at eye level.
X=0; Y=122; Z=3
# Close whatever panel is open (a station with no form leaves nothing to
# close, and a blind "tap i" would then open the inventory and swallow the
# next station's rightclick).
close_panel() {
  local open
  open=$(./vrctl state | python3 -c "import sys,json; print(json.loads([l for l in sys.stdin if l.startswith('{')][-1])['formspecOpen'])")
  [[ "$open" == "True" ]] && ./vrctl "tap i" "sleep 1" >/dev/null 2>&1
  return 0
}
for st in "${STATIONS[@]}"; do
  short=${st//:/_}
  ./vrctl "chat /setblock $X,$Y,$Z $st" "sleep $P" "pitch 0" "sleep 1.5" "tap rgrip" "sleep 2.5" "shot $OUT/$short.png" "state" 2>&1 \
    | python3 -c "import sys,json; d=json.loads([l for l in sys.stdin if l.startswith('{')][-1]); print('$short open=%s name=%s' % (d['formspecOpen'], d['formspecName']))"
  close_panel
  # A station with no form takes the rightclick as a place: the held block
  # lands between the pad and the station, so clear those cells too.
  ./vrctl "chat /setblock $X,$Y,$Z air" "sleep $P" "chat /setblock $X,$Y,1 air" "sleep $P" "chat /setblock $X,$Y,2 air" "sleep $P" >/dev/null 2>&1
done
# The player's own inventory, survival and creative.
./vrctl "tap i" "sleep 2" "shot $OUT/inventory_survival.png" "tap i" "sleep 1" "chat /gamemode creative" "sleep $P" "tap i" "sleep 2.5" "shot $OUT/inventory_creative.png" "tap i" "sleep 1" "chat /gamemode survival" "sleep $P" >/dev/null 2>&1
# A villager's trade form: it needs a floor (the pad is one node) and a job
# site, or it has no trades and the rightclick does nothing. A lectern beside
# it makes a librarian in about ten seconds.
./vrctl "chat /setblock 0,120,3 mcl_core:stone" "sleep $P" "chat /setblock 0,120,4 mcl_core:stone" "sleep $P" "chat /setblock -1,120,3 mcl_core:stone" "sleep $P" "chat /setblock -1,121,3 mcl_lectern:lectern" "sleep $P" "chat /summon mobs_mc:villager 0,121,3" "sleep 20" >/dev/null 2>&1
./vrctl "pitch -5" "sleep 0.3" "tap rgrip" "sleep 2.5" "shot $OUT/villager_trade.png" "state" 2>&1 \
  | python3 -c "import sys,json; d=json.loads([l for l in sys.stdin if l.startswith('{')][-1]); print('villager open=%s name=%s' % (d['formspecOpen'], d['formspecName']))"
close_panel
./vrctl "chat /clearobjects quick" "sleep $P" "chat /setblock -1,121,3 air" "sleep $P" "chat /setblock 0,120,3 air" "sleep $P" "chat /setblock 0,120,4 air" "sleep $P" "chat /setblock -1,120,3 air" "sleep $P" "pitch 0" >/dev/null 2>&1
echo "done: shots in $OUT"
