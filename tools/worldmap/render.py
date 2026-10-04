#!/usr/bin/env python3
"""Render tools/worldmap's dump (worldmap_columns.csv + worldmap_pois.json in a
world dir). OUT.html: a self-contained interactive viewer (viewer.html with
the data embedded: pan/zoom, hover readout, biome/height modes, landmark
filters). OUT.png: a static picture, biomes coloured and hill-shaded,
structures labelled, with a legend. Usage: render.py WORLD_DIR OUT.(html|png)"""
import base64
import os
import struct
import colorsys
import csv
import hashlib
import json
import math
import sys
from collections import Counter

world, out_png = sys.argv[1], sys.argv[2]
show_all = "--all" in sys.argv[3:]
# Placements that aren't landmarks: terrain features and underground filler.
# --all shows them too.
CLUTTER = ("fallen_tree", "geode", "mineshaft", "boulder", "lavapool", "water_lake", "basalt",
           "cocoon", "fossil", "dripstone", "spike", "pile", "rock")
meta_all = json.load(open(f"{world}/worldmap_pois.json"))
meta, pois = meta_all["meta"], meta_all["pois"]
cx, cz, R, step = meta["cx"], meta["cz"], meta["radius"], meta["step"]
water = meta.get("water_level", 0)

# Biome name keywords -> colour, first match wins (VoxeLibre's biome names
# are CamelCase: "ColdTaiga_ocean", "MesaPlateauF", "MushroomIslandShore").
PALETTE = [
    ("deep_ocean", (24, 52, 120)), ("ocean", (40, 80, 160)), ("river", (70, 120, 200)),
    ("beach", (220, 205, 150)), ("shore", (215, 200, 150)), ("mushroom", (150, 110, 160)),
    ("desert", (225, 205, 130)), ("mesa", (200, 110, 60)), ("savanna", (180, 175, 90)),
    ("bamboo", (90, 170, 60)), ("jungle", (40, 130, 40)), ("swamp", (80, 100, 60)),
    ("mangrove", (70, 95, 55)), ("cherry", (235, 170, 200)), ("icespikes", (200, 230, 245)),
    ("ice", (190, 220, 240)), ("snow", (235, 240, 245)), ("cold", (170, 200, 200)),
    ("megataiga", (70, 110, 80)), ("megaspruce", (70, 110, 80)), ("taiga", (90, 130, 100)),
    ("roofed", (40, 80, 35)), ("birch", (120, 165, 90)), ("flower", (130, 180, 80)),
    ("forest", (70, 130, 55)), ("sunflower", (150, 195, 85)), ("plains", (130, 185, 85)),
    ("stonebeach", (140, 140, 140)), ("extremehills", (120, 130, 120)), ("hills", (125, 140, 110)),
]


def biome_colour(name):
    low = name.lower()
    for key, col in PALETTE:
        if key in low:
            return col
    h = int(hashlib.md5(name.encode()).hexdigest()[:6], 16)
    r, g, b = colorsys.hsv_to_rgb((h % 360) / 360, 0.35, 0.75)
    return int(r * 255), int(g * 255), int(b * 255)


cols = {}
biomes = Counter()
with open(f"{world}/worldmap_columns.csv") as f:
    for row in csv.DictReader(f):
        x, z, y = int(row["x"]), int(row["z"]), int(row["y"])
        cols[(x, z)] = (y, row["node"], row["biome"], int(row.get("floor") or y))
        biomes[row["biome"]] += 1

n = (2 * R) // step
# VoxeLibre names the stronghold "end_shrine" (its portal room).
KIND_COL = {"village": (255, 220, 40), "end_shrine": (230, 60, 60), "strongholds": (230, 60, 60)}


def write_html(path):
    """Columns as little-endian arrays indexed i * n + j (i along x, j along z),
    base64'd into viewer.html, so the file works served from anywhere."""
    biome_names = sorted(biomes)
    bidx = {b: k for k, b in enumerate(biome_names)}
    node_names, nidx = [], {}
    hgt, dep, bio, nod = [], bytearray(), bytearray(), []
    for i in range(n):
        for j in range(n):
            c = cols.get((cx - R + i * step, cz - R + j * step))
            y, node, biome, floor = c if c else (0, "air", "", 0)
            if node not in nidx:
                nidx[node] = len(node_names); node_names.append(node)
            hgt.append(max(-32768, min(32767, y))); dep.append(max(0, min(255, y - floor)))
            bio.append(bidx.get(biome, 0)); nod.append(nidx[node])
    enc = lambda b: base64.b64encode(bytes(b)).decode()
    poi_list = [dict(kind=p["kind"].replace(" (seeded)", ""), x=p["x"], y=p["y"], z=p["z"]) for p in pois
                if cx - R <= p["x"] < cx + R and cz - R <= p["z"] < cz + R and p["y"] > -1000]
    data = dict(
        seed=meta["seed"], mgName=meta["mg_name"], gameVersion=meta.get("game_version", ""),
        cx=cx, cz=cz, radius=R, step=step, n=n, water=water,
        height=enc(struct.pack(f"<{len(hgt)}h", *hgt)), depth=enc(dep), biome=enc(bio),
        node=enc(struct.pack(f"<{len(nod)}H", *nod)),
        nodes=node_names, waterNodes=[k for k, nm in enumerate(node_names) if "water" in nm],
        biomes=biome_names, biomeColors=[list(biome_colour(b)) for b in biome_names],
        pois=poi_list, clutter=list(CLUTTER),
        kindColors={k: "rgb(%d,%d,%d)" % v for k, v in KIND_COL.items()},
    )
    tmpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "viewer.html")).read()
    html = tmpl.replace("/*DATA*/null", json.dumps(data, separators=(",", ":")))
    html = html.replace("<title>World Map</title>", f"<title>World Map {meta['seed']}</title>")
    open(path, "w").write(html)
    print(f"wrote {path} ({n}x{n} samples, {len(poi_list)} placements, {len(biome_names)} biomes, {len(html) // 1024} KB)")


if out_png.endswith(".html"):
    write_html(out_png)
    sys.exit(0)

from PIL import Image, ImageDraw, ImageFont

scale = max(1, 1024 // n)
W = n * scale
LEG = 300
img = Image.new("RGB", (W + LEG, max(W, 400)), (30, 30, 34))
px = img.load()


def height(x, z):
    c = cols.get((x, z))
    return c[0] if c else None


for i in range(n):
    for j in range(n):
        x, z = cx - R + i * step, cz - R + j * step
        c = cols.get((x, z))
        if not c:
            continue
        y, node, biome, floor = c
        if "water" in node:
            # Lighter in the shallows, darker with depth.
            d = max(0, y - floor)
            k = max(0.0, min(1.0, d / 30))
            col = (int(90 - 60 * k), int(150 - 90 * k), int(220 - 90 * k))
        elif "snow" in node or "ice" in node:
            col = (235, 240, 248)
        elif "lava" in node:
            col = (230, 90, 20)
        else:
            col = biome_colour(biome)
            # Hill shade: light from the north-west.
            hw, hn = height(x - step, z), height(x, z + step)
            if hw is not None and hn is not None:
                d = ((y - hw) - (y - hn)) / step
                k = max(0.6, min(1.35, 1 + d * 0.25))
                col = tuple(max(0, min(255, int(v * k))) for v in col)
        # Image rows run north (+z) at the top.
        for a in range(scale):
            for b in range(scale):
                px[i * scale + a, (n - 1 - j) * scale + b] = col

draw = ImageDraw.Draw(img)
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 13)
    small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 11)
except OSError:
    font = small = ImageFont.load_default()


def to_img(x, z):
    return ((x - (cx - R)) / step * scale, (n - 1 - (z - (cz - R)) / step) * scale)


# Overworld only (the End and Nether sit thousands of nodes down), inside the map.
inside = [p for p in pois if cx - R <= p["x"] < cx + R and cz - R <= p["z"] < cz + R and p["y"] > -1000
          and (show_all or not any(k in p["kind"] for k in CLUTTER))]
kinds = Counter()
for p in inside:
    kind = p["kind"].replace(" (seeded)", "")
    kinds[kind] += 1
    X, Y = to_img(p["x"], p["z"])
    col = KIND_COL.get(kind, (255, 255, 255))
    draw.ellipse([X - 4, Y - 4, X + 4, Y + 4], fill=col, outline=(0, 0, 0))
    draw.text((X + 6, Y - 7), f"{kind} {p['x']},{p['z']}", fill=(255, 255, 255), font=small,
              stroke_width=2, stroke_fill=(0, 0, 0))

# Origin/centre cross and a scale bar.
ox, oy = to_img(cx, cz)
draw.line([ox - 6, oy, ox + 6, oy], fill=(255, 255, 255)); draw.line([ox, oy - 6, ox, oy + 6], fill=(255, 255, 255))
bar = 100 / step * scale
draw.line([10, W - 14, 10 + bar, W - 14], fill=(255, 255, 255), width=3)
draw.text((10, W - 32), "100 nodes", fill=(255, 255, 255), font=small, stroke_width=2, stroke_fill=(0, 0, 0))
draw.text((10, 8), "N", fill=(255, 255, 255), font=font, stroke_width=2, stroke_fill=(0, 0, 0))

# Legend: world facts, biomes by area, structures by count.
lx, ly = W + 12, 10
for line in [f"seed {meta['seed']}", f"mapgen {meta['mg_name']}  VoxeLibre {meta.get('game_version', '')}",
             f"centre {cx},{cz}  {2 * R}x{2 * R} nodes", ""]:
    draw.text((lx, ly), line, fill=(230, 230, 230), font=font); ly += 17
draw.text((lx, ly), "Biomes", fill=(255, 255, 255), font=font); ly += 18
total = sum(biomes.values())
for name, cnt in biomes.most_common(22):
    draw.rectangle([lx, ly + 2, lx + 12, ly + 14], fill=biome_colour(name))
    draw.text((lx + 18, ly), f"{name}  {100 * cnt / total:.0f}%", fill=(220, 220, 220), font=small); ly += 16
ly += 8
draw.text((lx, ly), "Structures", fill=(255, 255, 255), font=font); ly += 18
for kind, cnt in kinds.most_common():
    draw.ellipse([lx + 2, ly + 3, lx + 10, ly + 11], fill=KIND_COL.get(kind, (255, 255, 255)))
    draw.text((lx + 18, ly), f"{kind} x{cnt}", fill=(220, 220, 220), font=small); ly += 16

for p in sorted(inside, key=lambda p: p["kind"]):
    print(f"  {p['kind']:<32} {p['x']:>7},{p['y']:>5},{p['z']:>7}")
img.save(out_png)
print(f"wrote {out_png} ({W}x{W} map, {len(inside)} structures, {len(biomes)} biomes)")
