"""Build helper.html: page.html with the seed map generator (gen.js,
structures.js, nether.js), the biome, decoration, structure and group tables
from a tools/worldmap run (its world/worldmap_*.json), the default map
settings, and the guides (guides.json) with the items, recipes, mobs and
brewing tables they mention taken from a gamedata/dump.sh run, icons inlined
from the installed game's textures.
Usage: build.py WORLDMAP_OUT_DIR [map_meta.txt] [--gamedata gamedata.json] [--textures DIR]"""
import base64, io, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
args = [a for a in sys.argv[1:]]
def opt(name, default):
    if name in args:
        i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
    return default
GAMEDATA = opt("--gamedata", os.path.join(HERE, "gamedata", "gamedata.json"))
TEXTURES = opt("--textures", os.path.expanduser("~/Library/Application Support/minetest/games/mineclone2/textures"))
R = args[0]
META = args[1] if len(args) > 1 else os.path.expanduser("~/Library/Application Support/minetest/worlds/vrdev/map_meta.txt")

# ---- seed map half (unchanged from the seed map tool) ----
gen = open(os.path.join(HERE, "gen.js")).read()
for extra in ("structures.js", "nether.js"):
    gen += "\n" + "\n".join(l for l in open(os.path.join(HERE, extra)).read().split("\n") if not l.startswith("if (typeof module"))
biomes = json.load(open(R + "/world/worldmap_biomes.json"))
biomes = [{k: b[k] for k in ("id", "name", "heat", "humidity", "y_min", "y_max", "vertical_blend", "weight", "min_pos", "max_pos", "node_top")} for b in biomes]
for b in biomes:
    b["heat"] = float(b["heat"]); b["humidity"] = float(b["humidity"]); b["weight"] = float(b["weight"])
biomes.sort(key=lambda b: b["id"])
meta = open(META).read()
keep = []
lines = meta.split("\n"); i = 0
while i < len(lines):
    l = lines[i]
    m = re.match(r"^(mgv7_np_(terrain_base|terrain_alt|terrain_persist|height_select|mount_height|mountain|ridge|ridge_uwater|cave1|cave2|cavern)|mg_biome_np_(heat|heat_blend|humidity|humidity_blend))\s*=\s*\{", l)
    if m:
        while True:
            keep.append(lines[i])
            if lines[i].startswith("}"): break
            i += 1
    elif re.match(r"^(water_level|mgv7_spflags|mgv7_mount_zero_level|mg_name|mg_flags|mgv7_cave_width|mgv7_cavern_limit|mgv7_cavern_taper|mgv7_cavern_threshold)\s*=", l):
        keep.append(l)
    i += 1
meta_default = "\n".join(keep) + "\n"
SALT = 0x00585e6f
decos = json.load(open(R + "/world/worldmap_decorations.json"))
for d in decos:
    if not d.get("name"):
        d["id"] = (d["id"] ^ SALT) & 0x3FFFF
structs = json.load(open(R + "/world/worldmap_structures.json"))
groups = json.load(open(R + "/world/worldmap_groups.json"))
landmarks = [d for d in decos if d.get("gen_callback") and str(d.get("name", "")).startswith("mcl_structures:")]
keep_d = ("id", "name", "place_on", "spawn_by", "num_spawn_by", "sidelen", "fill_ratio", "noise_params", "biomes", "y_min", "y_max", "flags", "gen_callback")
landmarks = [{k: d.get(k) for k in keep_d} for d in landmarks]
keep_s = ("name", "sidelen", "solid_ground", "make_foundation", "chunk_probability", "y_offset", "terrain_feature")
structs = [{k: x.get(k) for k in keep_s} for x in structs]
used = set()
for d in landmarks:
    lists = [d.get("place_on") or [], d.get("spawn_by") or []]
    for n in [x for l in lists for x in (l if isinstance(l, list) else [l])]:
        if isinstance(n, str) and n.startswith("group:"): used.add(n[6:])
groups = {k: v for k, v in groups.items() if k in used}

# ---- guides half ----
gd = json.load(open(GAMEDATA))
ITEMS, MOBS = gd["items"], gd["mobs"]
guides = json.load(open(os.path.join(HERE, "guides.json")))["guides"]

try:
    from PIL import Image, ImageOps
except ImportError:
    Image = None
icon_cache = {}
def load_png(name):
    p = os.path.join(TEXTURES, name)
    if not os.path.isfile(p) or Image is None: return None
    return Image.open(p).convert("RGBA")
def parse_color(s):
    s = s.strip()
    if s.startswith("#"):
        h = s[1:]
        if len(h) in (3, 4): h = "".join(c * 2 for c in h)
        if len(h) == 6: return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,)
        if len(h) == 8: return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4, 6))
    named = {"red": (255, 0, 0, 255), "white": (255, 255, 255, 255), "black": (0, 0, 0, 255), "yellow": (255, 255, 0, 255), "green": (0, 128, 0, 255), "blue": (0, 0, 255, 255), "orange": (255, 165, 0, 255), "purple": (128, 0, 128, 255)}
    return named.get(s, None)
def split_top(s, sep="^"):
    # split a texture modifier string on top-level ^ (not inside [combine parens)
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(": depth += 1
        elif ch == ")": depth -= 1
        if ch == sep and depth == 0: out.append(cur); cur = ""
        else: cur += ch
    out.append(cur)
    return out
def render(spec):
    """A small subset of Luanti's texture modifiers: layers, [colorize,
    [multiply, [transform (rotations), [resize. Enough for item icons."""
    base = None
    for part in split_top(spec):
        part = part.strip()
        if not part: continue
        if part.startswith("(") and part.endswith(")"):
            layer = render(part[1:-1])
            if layer is None: continue
            if base is None: base = layer
            else:
                layer = layer.resize(base.size, Image.NEAREST) if layer.size != base.size else layer
                base = Image.alpha_composite(base, layer)
            continue
        if part.startswith("["):
            if base is None: continue
            cmd = part[1:].split(":")
            if cmd[0] == "colorize" and len(cmd) >= 2:
                col = parse_color(cmd[1])
                if col is None: continue
                ratio = col[3]
                if len(cmd) >= 3 and cmd[2] != "alpha":
                    try: ratio = int(cmd[2])
                    except ValueError: pass
                solid = Image.new("RGBA", base.size, col[:3] + (255,))
                tinted = Image.blend(base, solid, max(0, min(255, ratio)) / 255)
                tinted.putalpha(base.getchannel("A"))
                base = tinted
            elif cmd[0] == "multiply" and len(cmd) >= 2:
                col = parse_color(cmd[1])
                if col is None: continue
                px = base.load(); w, h = base.size
                for y in range(h):
                    for x in range(w):
                        r, g, b, a = px[x, y]
                        px[x, y] = (r * col[0] // 255, g * col[1] // 255, b * col[2] // 255, a)
            elif cmd[0] == "transform" and len(cmd) >= 2:
                t = cmd[1]
                if t in ("R90", "1"): base = base.rotate(-90, expand=True)
                elif t in ("R180", "2"): base = base.rotate(180)
                elif t in ("R270", "3"): base = base.rotate(90, expand=True)
                elif t in ("FX", "4"): base = ImageOps.mirror(base)
                elif t in ("FY", "5"): base = ImageOps.flip(base)
            elif cmd[0] == "resize" and len(cmd) >= 2 and "x" in cmd[1]:
                w, h = cmd[1].split("x"); base = base.resize((int(w), int(h)), Image.NEAREST)
            continue
        layer = load_png(part)
        if layer is None: continue
        if base is None: base = layer
        else:
            if layer.size != base.size:
                if layer.size[0] > base.size[0]: base = base.resize(layer.size, Image.NEAREST)
                else: layer = layer.resize(base.size, Image.NEAREST)
            base = Image.alpha_composite(base, layer)
    return base
def icon(spec):
    if not spec or Image is None: return ""
    if spec in icon_cache: return icon_cache[spec]
    img = render(spec)
    if img is None:
        icon_cache[spec] = ""; return ""
    img = img.resize((32, 32), Image.NEAREST)
    buf = io.BytesIO(); img.save(buf, "PNG", optimize=True)
    icon_cache[spec] = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()
    return icon_cache[spec]

# A representative item for "group:x" ingredients: prefer the plainest mcl_core one.
group_cache = {}
def group_rep(g):
    if g in group_cache: return group_cache[g]
    best = None
    for name, it in ITEMS.items():
        gr = it.get("groups")
        if isinstance(gr, dict) and gr.get(g):
            if best is None or (name.startswith("mcl_core:") and not best.startswith("mcl_core:")) or (name.startswith("mcl_core:") == best.startswith("mcl_core:") and len(name) < len(best)):
                best = name
    group_cache[g] = best
    return best
GROUP_LABEL = {"wood": "any planks", "cobble": "any cobblestone", "wood_slab": "any wood slab", "shulker_box": "any shulker box", "sand": "any sand", "stick": "any stick", "coal": "coal or charcoal", "tree": "any log", "wool": "any wool", "stone": "any stone", "wood_stairs": "any wood stairs"}

pick_items, pick_mobs = set(), set()
for g in guides:
    for n in g["nodes"]:
        if n.get("item"): pick_items.add(n["item"])
        if n.get("mob"): pick_mobs.add(n["mob"])
        if n.get("brew"): pick_items.add(n["brew"])
        if n.get("ingredient"): pick_items.add(n["ingredient"])
# recipe ingredients and mob drops, one level deep, so detail cards have icons and names
def add_recipe_items(name):
    it = ITEMS.get(name)
    if not it: return
    for r in it.get("recipes") or []:
        for ing in r["items"]:
            if ing.startswith("group:"):
                rep = group_rep(ing[6:])
                if rep: pick_items.add(rep)
            elif ing: pick_items.add(ing)
for name in list(pick_items): add_recipe_items(name)
for m in list(pick_mobs):
    for d in (MOBS.get(m, {}).get("drops") or []): pick_items.add(d["name"])
brew = gd.get("brewing", {})
for key in ("mcl_potions:water", "mcl_potions:awkward"):
    for ing, out in (brew.get("outputs", {}).get(key) or {}).items():
        pick_items.add(ing); pick_items.add(out)
for ing, table in (brew.get("modifiers") or {}).items():
    pick_items.add(ing)
    if isinstance(table, dict):
        for a, b in table.items():
            if a in pick_items: pick_items.add(b)

missing = []
items_out = {}
for name in sorted(pick_items):
    it = ITEMS.get(name)
    if not it:
        missing.append(name); continue
    recipes = []
    for r in it.get("recipes") or []:
        recipes.append({"t": r["type"], "w": r["width"], "i": r["items"], "o": r["output"]})
    items_out[name] = {"d": it["desc"], "i": icon(it["image"]), "r": recipes, "l": it.get("long", ""), "u": it.get("usage", "")}
# group placeholders: label + icon of the representative
groups_out = {}
for name, it in items_out.items():
    for r in it["r"]:
        for ing in r["i"]:
            if ing.startswith("group:") and ing not in groups_out:
                g = ing[6:]; rep = group_rep(g)
                groups_out[ing] = {"d": GROUP_LABEL.get(g, "any " + g.replace("_", " ")), "i": items_out.get(rep, {}).get("i", "") or icon(ITEMS.get(rep, {}).get("image", "")) if rep else ""}
SPAWN_ICON = {"mobs_mc:rover": "enderman", "mobs_mc:elemental_fire": "blaze", "mobs_mc:villager_zombie": "zombie_villager", "mobs_mc:zombified_piglin": "zombie_pigman",
              "mobs_mc:polar_bear": "polarbear", "mobs_mc:magma_cube_big": "magmacube", "mobs_mc:enderdragon": "dragon", "mobs_mc:guardian_elder": "guardian_elder"}
MOB_ICON = {"mobs_mc:witherskeleton": "mcl_heads_wither_skeleton.png"}
# Mobs without a spawn icon: the face square of their skin (x0, y0, x1, y1).
MOB_FACE = {"mobs_mc:strider": ("extra_mobs_strider.png", (16, 16, 32, 32)), "mobs_mc:piglin": ("extra_mobs_piglin.png", (8, 8, 16, 16)),
            "mobs_mc:piglin_brute": ("extra_mobs_piglin_brute.png", (8, 8, 16, 16)), "mobs_mc:hoglin": ("extra_mobs_hoglin.png", (0, 0, 16, 16)),
            "mobs_mc:zombified_piglin": ("extra_mobs_zombified_piglin.png", (8, 8, 16, 16))}
def face_icon(tex, box):
    key = "%s|%s" % (tex, box)
    if key in icon_cache: return icon_cache[key]
    img = load_png(tex)
    if img is None: icon_cache[key] = ""; return ""
    img = img.crop(box).resize((32, 32), Image.NEAREST)
    buf = io.BytesIO(); img.save(buf, "PNG", optimize=True)
    icon_cache[key] = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()
    return icon_cache[key]
def spawn_text(name):
    rules = [s for s in gd.get("spawns", []) if s["name"] == name]
    if not rules: return ""
    dims = sorted(set(s["dimension"] for s in rules))
    light = min(s["min_light"] for s in rules), max(s["max_light"] for s in rules)
    nb = max(len(s["biomes"]) for s in rules)
    txt = "Spawns naturally in the " + ", ".join(dims).replace("overworld", "overworld").replace("nether", "Nether").replace("end", "End")
    txt += " at light %d to %d" % light
    txt += ", %d biome%s." % (nb, "" if nb == 1 else "s")
    return txt
mobs_out = {}
for name in sorted(pick_mobs):
    m = MOBS.get(name)
    if not m:
        missing.append(name); continue
    short = name.split(":")[1]
    ic = MOB_ICON.get(name) or ("mobs_mc_spawn_icon_%s.png" % SPAWN_ICON.get(name, short))
    face = MOB_FACE.get(name)
    drops = [{"n": d["name"], "c": d.get("chance"), "a": d.get("min"), "b": d.get("max")} for d in (m.get("drops") or []) if d.get("name") in items_out]
    mobs_out[name] = {"d": m["desc"], "i": face_icon(*face) if face else icon(ic), "t": m.get("type"), "drops": drops, "s": spawn_text(name)}
brew_out = {"water": brew.get("outputs", {}).get("mcl_potions:water") or {}, "awkward": brew.get("outputs", {}).get("mcl_potions:awkward") or {},
            "mods": {k: {a: b for a, b in v.items() if a in items_out} for k, v in (brew.get("modifiers") or {}).items() if isinstance(v, dict)}}
for g in guides:
    for n in g["nodes"]:
        if n.get("icon"): n["iconData"] = icon(n["icon"]); del n["icon"]
if missing: print("WARNING: not in the game data:", ", ".join(missing))

html = open(os.path.join(HERE, "page.html")).read()
html = html.replace("/*__GEN__*/", gen.replace("</script>", "<\\/script>"))
J = lambda v: json.dumps(v, separators=(",", ":")).replace("</", "<\\/")
html = html.replace("/*__BIOMES__*/", J(biomes))
html = html.replace("/*__DECOS__*/", J(landmarks))
html = html.replace("/*__STRUCTS__*/", J(structs))
html = html.replace("/*__GROUPS__*/", J(groups))
html = html.replace("/*__META__*/", json.dumps(meta_default))
html = html.replace("/*__GUIDES__*/", J(guides))
html = html.replace("/*__ITEMS__*/", J(items_out))
html = html.replace("/*__GROUPITEMS__*/", J(groups_out))
html = html.replace("/*__MOBS__*/", J(mobs_out))
html = html.replace("/*__BREW__*/", J(brew_out))
html = html.replace("/*__GAMEVERSION__*/", json.dumps(gd.get("game", "")))
open(os.path.join(HERE, "helper.html"), "w").write(html)
print(len(html) // 1024, "KB;", len(items_out), "items,", len(mobs_out), "mobs,", len(guides), "guides")
