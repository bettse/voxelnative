#!/bin/zsh
# Map a VoxeLibre world from its seed: biomes, terrain and structures.
#
# Runs a headless Luanti server on a throwaway world with the same seed (and
# the same mapgen settings, given the server's map_meta.txt), lets the game
# generate the area, and renders it to a PNG. The seed comes from the [seed]
# line the client logs on join; without a map_meta.txt this assumes
# VoxeLibre's defaults (mapgen v7), which only matches servers that kept them.
#
# --from-world DIR starts from a copy of a real world (one of our servers):
# explored land comes out exactly as it is, the rest is generated.
#
# Usage: tools/worldmap/worldmap.sh --seed N [--meta map_meta.txt]
#          [--from-world DIR] [--center X,Z] [--radius R] [--step S]
#          [--out DIR] [--port P] [--all]   (--all: label terrain features too)
set -e
HERE=${0:A:h}
LUANTI=/Applications/luanti.app/Contents/MacOS/luanti
SEED="" META="" FROM="" RENDER_ARGS="" CX=0 CZ=0 RADIUS=384 STEP=2 PORT=30123 OUT=""
while (( $# )); do
  case $1 in
    --seed) SEED=$2; shift 2 ;;
    --meta) META=$2; shift 2 ;;
    --from-world) FROM=$2; META=${META:-$2/map_meta.txt}; shift 2 ;;
    --all) RENDER_ARGS=--all; shift ;;
    --center) CX=${2%,*}; CZ=${2#*,}; shift 2 ;;
    --radius) RADIUS=$2; shift 2 ;;
    --step) STEP=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
if [[ -z $SEED && -n $META ]]; then SEED=$(awk -F' = ' '$1=="seed"{print $2}' "$META"); fi
[[ -n $SEED ]] || { echo "need --seed or --meta"; exit 2; }
OUT=${OUT:-${TMPDIR:-/tmp}/worldmap-$SEED-$CX,$CZ-r$RADIUS${FROM:+-copy}}
WORLD=$OUT/world
rm -rf "$WORLD"; mkdir -p "$WORLD/worldmods"
cp -R "$HERE/mod" "$WORLD/worldmods/worldmap"
[[ -n $FROM ]] && cp "$FROM/map.sqlite" "$WORLD/map.sqlite"
cat > "$WORLD/world.mt" <<EOF
gameid = mineclone2
backend = sqlite3
EOF
if [[ -n $META ]]; then
  cp "$META" "$WORLD/map_meta.txt"
else
  # VoxeLibre's defaults for a fresh world (it disallows v6).
  printf 'seed = %s\nmg_name = v7\n[end_of_params]\n' "$SEED" > "$WORLD/map_meta.txt"
fi
cat > "$OUT/worldmap.conf" <<EOF
server_announce = false
enable_damage = false
worldmap_cx = $CX
worldmap_cz = $CZ
worldmap_radius = $RADIUS
worldmap_step = $STEP
EOF
echo "generating $((2*RADIUS))x$((2*RADIUS)) around $CX,$CZ for seed $SEED (log: $OUT/server.log)"
"$LUANTI" --server --gameid mineclone2 --world "$WORLD" --port "$PORT" \
  --config "$OUT/worldmap.conf" --logfile "$OUT/server.log" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' INT TERM
LAST=""
while kill -0 $PID 2>/dev/null; do
  L=$(grep -o '\[worldmap\].*' "$OUT/server.log" 2>/dev/null | tail -1)
  [[ $L != $LAST ]] && { echo "  $L"; LAST=$L; }
  sleep 2
done
[[ -f $WORLD/worldmap_done ]] || { echo "server exited without a map; see $OUT/server.log"; tail -5 "$OUT/server.log"; exit 1; }
python3 "$HERE/render.py" "$WORLD" "$OUT/worldmap-$SEED.png" $RENDER_ARGS
