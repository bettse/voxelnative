#!/bin/zsh
# Item zoo: hold every registered item and use it on air, a block, a mob
# and (for liquids_pointable items) water, from the sim spawn pad. Run with
# the sim up and the audit on:
#   SIM_EXTRA_ARGS="-vrdev.itemZoo 1" SIM_KEEP=1 ./sim.sh && tools/itemzoo.sh [out] [name-regex] [kind]
# kind limits the pass to node, tool or craft items (a node needs a chat
# command to clear what it placed, so the 2,500 nodes take ~2.5 h; the 900
# tools and craftitems take ~35 min).
# The client logs the static audit ([izoo] item/BAD lines: icons, wield
# images, placement prediction, place sounds) at startup; this script reads
# that item list, then drives the hold-and-use pass with the sim control
# channel. Items come from the creative list (vrctl "give"), so the only
# chat commands are the stage setup and clearing a placed node, paced under
# the flood limit (8 per 10 s). Results go to <out>/items.tsv and a summary
# at the end; wield kinds are in the sim log ([izoo] wield).
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/itemzoo}
FILTER=${2:-}
KIND=${3:-}
mkdir -p "$OUT"
SIM=${VRSIM:-AAA51166-3572-43B8-9B71-9090483A2301}
LOG="$(xcrun simctl get_app_container "$SIM" dev.ericbetts.voxelnative data)/Documents/native.log"
for i in {1..90}; do grep -q '^\[izoo\] total' "$LOG" 2>/dev/null && break; sleep 2; done
grep -q '^\[izoo\] total' "$LOG" || { echo "no [izoo] audit in $LOG (launch with SIM_EXTRA_ARGS=\"-vrdev.itemZoo 1\")"; exit 1 }
grep '^\[izoo\] ' "$LOG" | grep -v '^\[izoo\] wield' > "$OUT/audit.txt"
echo "audit: $(grep -c '^\[izoo\] item' "$OUT/audit.txt") items, $(grep -c '^\[izoo\] BAD' "$OUT/audit.txt") flagged (in $OUT/audit.txt)"

OUT="$OUT" FILTER="$FILTER" KIND="$KIND" LOG="$LOG" python3 - <<'EOF'
import json, os, re, subprocess, sys, time
OUT, FILTER, KIND = os.environ["OUT"], os.environ.get("FILTER", ""), os.environ.get("KIND", "")
P = 1.3   # chat pacing

def ctl(*cmds):
    r = subprocess.run(["./vrctl", *cmds], capture_output=True, text=True)
    # vrctl exits 1 on an "err" reply too (an item not in the creative list);
    # only a dead control channel ends the run.
    if r.returncode != 0 and "nothing listening" in r.stderr:
        sys.exit(f"vrctl: {r.stderr.strip()} (the app is gone)")
    return r.stdout
def q(*cmds):
    for l in reversed(ctl(*cmds).splitlines()):
        if l.startswith("{") or l.startswith("["): return json.loads(l)
    return None
def chat(*lines):
    cmds = []
    for l in lines: cmds += [f"chat {l}", f"sleep {P}"]
    ctl(*cmds)
def node(x, y, z):
    d = q(f"node {x} {y} {z}"); return d["name"] if d else "?"
def nodes(cells):
    """Several node lookups in one vrctl call, in order."""
    out = [json.loads(l)["name"] for l in ctl(*[f"node {x} {y} {z}" for x, y, z in cells]).splitlines() if l.startswith("{")]
    return out if len(out) == len(cells) else ["?"] * len(cells)

items = []
for l in open(f"{OUT}/audit.txt"):
    m = re.match(r"\[izoo\] item (\S+) kind=(\S+) pred=(\S*) liquids=(\d) usable=(\d) eat=(\d)", l)
    if m: items.append(dict(name=m[1], kind=m[2], pred=m[3], liquids=m[4] == "1", usable=m[5] == "1", eat=m[6] == "1"))
if FILTER: items = [i for i in items if re.search(FILTER, i["name"])]
if KIND: items = [i for i in items if i["kind"] == KIND]
# Lava would flood the stage; a thrown pearl teleports the player off it; the
# 600 banner previews are crafting-guide pictures, not in the creative list.
SKIP = {"mcl_buckets:bucket_lava", "mcl_throwing:ender_pearl"}
items = [i for i in items if i["name"] not in SKIP and "banner_preview" not in i["name"]]
print(f"{len(items)} items to hold")

# Some items open a form (a writable book, a sign) and the spatial keyboard
# with it; anything left open swallows the next item's rightclick.
def ensure_clear():
    for _ in range(3):
        d = q("state") or {}
        if not (d.get("formspecOpen") or d.get("keyboardOpen") or d.get("inventoryOpen") or d.get("menuOpen")): return
        ctl("tap esc", "sleep 0.5")
        d = q("state") or {}
        if d.get("formspecOpen") or d.get("inventoryOpen"): ctl("tap i", "sleep 0.5")
# Stage, from the pad at (0.5,121,0.5) facing +z: a stone ahead whose top is
# the placement cell (0,121,3); a cow in a fenced 1x1 pen down-left at
# (-2,120,2); a water source in a stone-lined hole down-right at (2,120,2).
chat("/gamemode creative", "/clearinv", "/teleport 0 140 0", "/teleport 0 121 0")
time.sleep(2)
st = q("state"); ctl(f"turn {-st['yaw']}", "pitch 0", "tap 1")
def yaw_now():
    time.sleep(0.25); y = q("state")["yaw"]; return (y + 180) % 360 - 180
# turn sign calibration (a turn lands on the next input poll, so wait before reading)
y0 = yaw_now(); ctl("turn 10"); y1 = yaw_now(); ctl("turn -10")
sgn = 1 if ((y1 - y0 + 180) % 360 - 180) > 0 else -1
def face(deg):
    """Absolute yaw (0 = +z, 90 = +x), verified against the state and corrected."""
    for _ in range(4):
        d = (deg - yaw_now() + 180) % 360 - 180
        if abs(d) < 1.5: return
        ctl(f"turn {sgn * d}")
    print(f"warning: could not face {deg}", flush=True)
chat("/setblock 0,120,3 mcl_core:stone", "/setblock 0,121,3 air", "/setblock 0,120,2 air", "/setblock 0,121,2 air",
     "/setblock -2,119,2 mcl_core:stone", "/setblock -2,120,2 air", "/setblock -3,120,2 mcl_fences:fence", "/setblock -1,120,2 mcl_fences:fence",
     "/setblock -2,120,1 mcl_fences:fence", "/setblock -2,120,3 mcl_fences:fence",
     "/setblock 2,119,2 mcl_core:stone", "/setblock 3,120,2 mcl_core:stone", "/setblock 1,120,2 mcl_core:stone",
     "/setblock 2,120,1 mcl_core:stone", "/setblock 2,120,3 mcl_core:stone", "/setblock 2,120,2 mcl_core:water_source",
     "/summon mobs_mc:cow -2,120.5,2")
time.sleep(1)
def cow_ok():
    ents = q("entities") or []
    return any(e["name"] == "mobs_mc:cow" and abs(e["pos"][0] + 1.5) < 1 and abs(e["pos"][2] - 2.5) < 1 for e in ents)
if not cow_ok(): print("warning: the cow is not in its pen")
# The creative list reaches the client once the creative inventory has been
# opened (the server sends the detached inventory with its form).
if "err" in ctl("give mcl_core:dirt"):
    ctl("tap i", "sleep 2", "tap i", "sleep 1")
    r = ctl("give mcl_core:dirt")
    if "err" in r: sys.exit(f"give does not work: {r.strip()}")

# A boat or minecart placed on the stone gets boarded by the next click, and
# a mob can shove the player: make sure every item starts from the pad.
def on_pad():
    d = q("state") or {}
    p = d.get("pos") or [0, 0, 0]
    return abs(p[0] - 0.5) < 0.3 and abs(p[1] - 121) < 0.3 and abs(p[2] - 0.5) < 0.3
def back_on_pad():
    if on_pad(): return False
    ctl("tap shift", "sleep 0.5")   # leave a vehicle
    # Two hops: the client leaves a server move under 6 nodes alone.
    chat("/clearobjects quick", "/teleport 0 140 0", "/teleport 0 121 0")
    time.sleep(1)
    if not cow_ok(): chat("/summon mobs_mc:cow -2,120.5,2"); time.sleep(1)
    face(0)
    if not on_pad(): print("warning: could not get back on the pad", flush=True)
    return True
# The pad's surroundings, in case an earlier run left blocks there.
chat(*[f"/setblock {x},{y},{z} air" for x in (-2, -1, 0, 1, 2) for y in (121, 122, 123) for z in (-1, 0, 1)])
ensure_clear()

# Aims from the real gaze ray origin (the sim's head sits behind and below
# the nominal eye), verified with a dirt probe on the stone and the log's
# "rightclick object" count on the cow. yaw: 0 = +z, +90 = +x; pitch < 0 = down.
import math
LOG = os.environ["LOG"]
ray = (q("state") or {}).get("ray") or [0.5, st["pos"][1] + 1.5, 0.5]
def aim_at(x, y, z):
    dx, dy, dz = x - ray[0], y - ray[1], z - ray[2]
    return math.degrees(math.atan2(dx, dz)), math.degrees(math.atan2(dy, math.hypot(dx, dz)))
def rightclicks(): return sum(1 for l in open(LOG, errors="replace") if "[place] rightclick object" in l)
# What the stage should hold; anything else (a two-high door, a block that
# landed on the pen or in front of the face) gets reset before the next item.
STAGE = {(0, 120, 3): "mcl_core:stone", (2, 120, 2): "mcl_core:water_source"}
for c in [(-2, 120, 2), (0, 121, 3), (0, 122, 3), (0, 123, 3), (0, 120, 2), (0, 121, 2), (0, 122, 2), (0, 121, 1), (0, 122, 1), (0, 122, 0), (0, 123, 0),
          (-1, 121, 1), (-1, 122, 1), (1, 121, 1), (1, 122, 1), (-2, 121, 2), (-2, 122, 2), (-1, 121, 2), (-1, 122, 2), (1, 121, 2), (1, 122, 2), (2, 121, 2), (2, 122, 2)]:
    STAGE[c] = "air"
STAGE_CELLS = list(STAGE)
def fix_stage():
    """One vrctl call to read every stage cell; a chat per cell that is wrong."""
    wrong = [(c, n) for c, n in zip(STAGE_CELLS, nodes(STAGE_CELLS)) if n != STAGE[c] and n != "?"]
    if wrong: chat(*[f"/setblock {c[0]},{c[1]},{c[2]} {STAGE[c]}" for c, _ in wrong])
    return wrong
Y_BLOCK, P_BLOCK = aim_at(0.5, 120.5, 3.5)
def probe_block(p):
    ctl("give mcl_core:dirt 1", "sleep 0.3"); face(Y_BLOCK)
    ctl(f"pitch {p:.1f}", "sleep 0.15", "tap rgrip", "sleep 0.6")
    hit = node(0, 121, 3) == "mcl_core:dirt"; fix_stage(); return hit
P_BLOCK = next((p for p in [P_BLOCK + d for d in (0, -3, 3, -6, 6, -9, 9)] if probe_block(p)), None)
if P_BLOCK is None: sys.exit("could not land a block on the stone")
def cow_pos():
    for e in q("entities") or []:
        if e["name"] == "mobs_mc:cow" and abs(e["pos"][0] + 1.5) < 1 and abs(e["pos"][2] - 2.5) < 1: return e["pos"]
    return None
def cow_aim():
    p = cow_pos() or [-1.5, 120.0, 2.5]
    return aim_at(p[0], p[1] + 0.7, p[2])
def probe_cow():
    y, p = cow_aim(); n = rightclicks(); face(y); ctl(f"pitch {p:.1f}", "sleep 0.15", "tap rgrip", "sleep 0.5"); return rightclicks() > n
if not probe_cow(): print("warning: the cow aim missed on the probe", flush=True)
Y_WATER, P_WATER = aim_at(2.5, 120.3, 2.5)
print(f"ray {ray}: block yaw {Y_BLOCK:.1f} pitch {P_BLOCK:.1f}, cow {cow_aim()}, water yaw {Y_WATER:.1f} pitch {P_WATER:.1f}", flush=True)

tsv = open(f"{OUT}/items.tsv", "w")
tsv.write("item\tkind\tpred\theld\tplaced\twater\tstray\n")
placed_count = 0; miss_held = []; placed_other = []; t0 = time.time(); COW = cow_aim()
for n, it in enumerate(items):
    name = it["name"]
    ensure_clear()
    if back_on_pad(): COW = cow_aim()
    ctl(f"give {name} 3", "sleep 0.35")
    held = (q("state") or {}).get("wieldItem", "")
    if not held.startswith(name): miss_held.append(f"{name} (hand: {held or 'empty'})")
    if n % 40 == 0:
        face(0); ctl("pitch 0", "sleep 0.3", f"shot {OUT}/hold_{n:04d}_{name.replace(':', '_')}.png")
    # use on air: the use button with nothing in reach (throwables, bows, rods)
    if it["usable"]:
        face(0); ctl("pitch 45", "sleep 0.2", "tap rt", "sleep 0.4")
    # use on a block: the stone's top face, so a node lands in (0,121,3)
    face(Y_BLOCK); ctl(f"pitch {P_BLOCK:.1f}", "sleep 0.15", "tap rgrip", "sleep 0.5")
    placed = node(0, 121, 3)
    if placed != "air":
        placed_count += 1
        if it["pred"] and placed != it["pred"]: placed_other.append(f"{name}: predicted {it['pred']}, got {placed}")
    # use on a mob (not for plain blocks: that is just a block held at a cow)
    if it["kind"] != "node":
        yc, pc = COW; face(yc); ctl(f"pitch {pc:.1f}", "sleep 0.15", "tap rgrip", "sleep 0.4")
    water = ""
    if it["liquids"]:
        face(Y_WATER); ctl(f"pitch {P_WATER:.1f}", "sleep 0.2", "tap rgrip", "sleep 0.7")
        water = node(2, 120, 2)
    wrong = fix_stage()
    stray = " ".join(f"{n}@{c[0]},{c[1]},{c[2]}" for c, n in wrong if c != (0, 121, 3))
    tsv.write(f"{name}\t{it['kind']}\t{it['pred']}\t{held}\t{placed}\t{water}\t{stray}\n"); tsv.flush()
    if n % 25 == 24:
        chat("/clearobjects quick")
        if not cow_ok(): chat("/summon mobs_mc:cow -2,120.5,2"); time.sleep(1)
        COW = cow_aim()
        el = time.time() - t0
        print(f"{n + 1}/{len(items)} ({el / 60:.0f} min, {el / (n + 1) * (len(items) - n - 1) / 60:.0f} to go)", flush=True)
face(0); ctl("pitch 0")
# Take the stage down so the other sim scenes start from a clean pad.
chat("/clearobjects quick", "/setblock 0,121,3 air", "/setblock 0,120,3 air",
     "/setblock -2,119,2 air", "/setblock -3,120,2 air", "/setblock -1,120,2 air", "/setblock -2,120,1 air", "/setblock -2,120,3 air",
     "/setblock 2,120,2 air", "/setblock 2,119,2 air", "/setblock 3,120,2 air", "/setblock 1,120,2 air", "/setblock 2,120,1 air", "/setblock 2,120,3 air",
     "/clearinv", "/gamemode survival")
print(f"done: {len(items)} items held, {placed_count} placed a node")
print(f"hand did not show the item: {len(miss_held)}"); [print("  " + m) for m in miss_held[:50]]
print(f"placed something other than predicted: {len(placed_other)}"); [print("  " + m) for m in placed_other[:100]]
EOF
echo "shots and items.tsv in $OUT"
