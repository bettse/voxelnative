"""Build seedmap.html: page.html with gen.js, the biome table from a
tools/worldmap run (its world/worldmap_biomes.json) and the default map
settings inlined. Usage: build.py WORLDMAP_OUT_DIR [map_meta.txt]"""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
R = sys.argv[1]
META = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/Library/Application Support/minetest/worlds/vrdev/map_meta.txt")
gen = open(os.path.join(HERE, "gen.js")).read()
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
    m = re.match(r"^(mgv7_np_(terrain_base|terrain_alt|terrain_persist|height_select|mount_height|mountain|ridge|ridge_uwater)|mg_biome_np_(heat|heat_blend|humidity|humidity_blend))\s*=\s*\{", l)
    if m:
        while True:
            keep.append(lines[i]); 
            if lines[i].startswith("}"): break
            i += 1
    elif re.match(r"^(water_level|mgv7_spflags|mgv7_mount_zero_level|mg_name)\s*=", l):
        keep.append(l)
    i += 1
meta_default = "\n".join(keep) + "\n"
html = open(os.path.join(HERE, "page.html")).read()
html = html.replace("/*__GEN__*/", gen.replace("</script>", "<\\/script>"))
html = html.replace("/*__BIOMES__*/", json.dumps(biomes, separators=(",", ":")))
html = html.replace("/*__META__*/", json.dumps(meta_default))
open(os.path.join(HERE, "seedmap.html"), "w").write(html)
print(len(html) // 1024, "KB")
