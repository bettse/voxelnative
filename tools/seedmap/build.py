"""Build seedmap.html: page.html with gen.js + structures.js, the biome,
decoration, structure and group tables from a tools/worldmap run (its world/
worldmap_*.json) and the default map settings inlined.
Usage: build.py WORLDMAP_OUT_DIR [map_meta.txt]"""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
R = sys.argv[1]
META = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/Library/Application Support/minetest/worlds/vrdev/map_meta.txt")
# structures.js's Node-only shim redeclares names the inlined gen.js defines
gen = open(os.path.join(HERE, "gen.js")).read()
for extra in ("structures.js", "nether.js"):
    gen += "\n" + "\n".join(l for l in open(os.path.join(HERE, extra)).read().split("\n") if not l.startswith("if (typeof module"))
biomes = json.load(open(R + "/world/worldmap_biomes.json"))
biomes = [{k: b[k] for k in ("id", "name", "heat", "humidity", "y_min", "y_max", "vertical_blend", "weight", "min_pos", "max_pos", "node_top")} for b in biomes]
for b in biomes:
    b["heat"] = float(b["heat"]); b["humidity"] = float(b["humidity"]); b["weight"] = float(b["weight"])
biomes.sort(key=lambda b: b["id"])
meta = open(META).read()
# keep only the lines the generator reads, so the default stays short
keep = []
lines = meta.split("\n"); i = 0
while i < len(lines):
    l = lines[i]
    m = re.match(r"^(mgv7_np_(terrain_base|terrain_alt|terrain_persist|height_select|mount_height|mountain|ridge|ridge_uwater|cave1|cave2|cavern)|mg_biome_np_(heat|heat_blend|humidity|humidity_blend))\s*=\s*\{", l)
    if m:
        while True:
            keep.append(lines[i]); 
            if lines[i].startswith("}"): break
            i += 1
    elif re.match(r"^(water_level|mgv7_spflags|mgv7_mount_zero_level|mg_name|mg_flags|mgv7_cave_width|mgv7_cavern_limit|mgv7_cavern_taper|mgv7_cavern_threshold)\s*=", l):
        keep.append(l)
    i += 1
meta_default = "\n".join(keep) + "\n"
html = open(os.path.join(HERE, "page.html")).read()
html = html.replace("/*__GEN__*/", gen.replace("</script>", "<\\/script>"))
html = html.replace("/*__BIOMES__*/", json.dumps(biomes, separators=(",", ":")))
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
html = html.replace("/*__DECOS__*/", json.dumps(landmarks, separators=(",", ":")))
html = html.replace("/*__STRUCTS__*/", json.dumps(structs, separators=(",", ":")))
html = html.replace("/*__GROUPS__*/", json.dumps(groups, separators=(",", ":")))
html = html.replace("/*__META__*/", json.dumps(meta_default))
open(os.path.join(HERE, "seedmap.html"), "w").write(html)
print(len(html) // 1024, "KB")
