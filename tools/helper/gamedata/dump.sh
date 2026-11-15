#!/bin/zsh
# Dump VoxeLibre's item, recipe, mob, spawn, brewing and enchantment tables
# from the installed game on a throwaway headless server (see mod/init.lua).
# Usage: dump.sh [OUT_DIR]   -> OUT_DIR/gamedata.json (default $TMPDIR/gamedata)
set -e
HERE=${0:A:h}
LUANTI=/Applications/luanti.app/Contents/MacOS/luanti
OUT=${1:-${TMPDIR:-/tmp}/gamedata}
WORLD=$OUT/world
rm -rf "$WORLD"; mkdir -p "$WORLD/worldmods"
cp -R "$HERE/mod" "$WORLD/worldmods/gamedata"
printf 'gameid = mineclone2\nbackend = sqlite3\n' > "$WORLD/world.mt"
printf 'seed = 1\nmg_name = v7\n[end_of_params]\n' > "$WORLD/map_meta.txt"
# The spawn and brewing tables are mod locals, read via debug.getupvalue,
# which the secure environment strips. The server lives for a few seconds.
printf 'server_announce = false\nsecure.enable_security = false\n' > "$OUT/gamedata.conf"
"$LUANTI" --server --gameid mineclone2 --world "$WORLD" --port 30124 \
  --config "$OUT/gamedata.conf" --logfile "$OUT/server.log" >/dev/null 2>&1 || true
[[ -f $WORLD/gamedata_done ]] || { echo "no dump; see $OUT/server.log"; grep -i "gamedata\|error" "$OUT/server.log" | tail -5; exit 1; }
cp "$WORLD/gamedata.json" "$OUT/gamedata.json"
grep -o '\[gamedata\].*' "$OUT/server.log" | tail -1
echo "$OUT/gamedata.json"
