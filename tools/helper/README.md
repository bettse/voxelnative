# VoxeLibre Helper (browser)

One page, two tabs, published as the "VoxeLibre Helper" artifact: a seed
map and a set of progression guides. `page.html` is the page; `build.py`
inlines everything it needs into `helper.html` (git-ignored; that file is
what gets published).

## Guides

`guides.json` holds the trees: each guide is a list of nodes (an item, a
mob, a place or a step, with a short note) and edges between them (with a
label like "drops, 2.5%"). The page lays each tree out left to right by
dependency depth and draws it as SVG; clicking a node shows the note, the
game's own description, the crafting or smelting recipes, a mob's drops and
spawn rule, the brewing tables, and the neighbouring steps. Those facts
come from `gamedata/dump.sh`, which runs the installed VoxeLibre once on a
headless Luanti server with the `gamedata` mod and writes
`gamedata/gamedata.json` (git-ignored, 2 MB): every item with description,
icon texture and recipes, every mob with drops, the spawn rules, the brewing
and enchantment tables. `build.py` keeps only what the guides mention and
inlines the icons from the game's textures (a small subset of Luanti's
texture modifiers is rendered: layers, colorize, multiply, transform,
resize). The notes themselves are written against VoxeLibre 0.92.3's Lua;
after a game upgrade, rerun the dump and reread the notes whose numbers
come from code (drop chances, spawn odds, structure probabilities).

    tools/helper/gamedata/dump.sh                    # -> $TMPDIR/gamedata/gamedata.json; copy to tools/helper/gamedata/
    python3 tools/helper/build.py /tmp/refn           # -> tools/helper/helper.html (seed map tables from a worldmap run, below)

Node fields: `id`; one of `item` (itemstring), `mob` (entity name), or
`kind` = `place` / `step` / `goto` (with `guide`); optional `label`, `note`,
`icon` (a texture name, for items whose own texture is a model UV sheet),
`brew` (`mcl_potions:water` or `mcl_potions:awkward` shows that brewing
table) and `brewmods`. Edges are `[from, to, label]`. The page takes
`?tab=guides&g=<guide>&n=<node>`.

## Seed map

A VoxeLibre overworld map from a seed, generated in the browser: `gen.js`
ports Luanti's value noise, mapgen v7's terrain and the biome picker in
float32 arithmetic, so terrain heights and biomes match the engine (checked
against a headless render with `diff.js`: biomes exact, ground heights off
only where a structure reshaped the land). `structures.js` ports the
engine's decoration placer and VoxeLibre's structure callback (chunk
probability, solid-ground check), the village chunk gate and the stronghold
rings; `diff2.js` checks those against the headless run's placements.
`nether.js` adds the Nether: v7 fills that layer solid and carves it with
its noise tunnels and caverns (`noiseMap3D` in gen.js is the engine's
incremental 3D lattice walk), the game adds bedrock, the lava sea and a
one-node biome layer on floors; structures there are all_floors
decorations, placed per floor with `getSurfaces`. `build.py` inlines the generator and the tables the headless mod
dumps (biomes, decorations, structures, node groups) into the page.

    tools/worldmap/worldmap.sh --seed N --meta map_meta.txt --radius 192 --step 1 --out /tmp/ref
    node tools/helper/diff.js /tmp/ref            # terrain and biomes vs the engine
    node tools/helper/diff2.js /tmp/ref           # landmarks and strongholds vs the engine
    python3 tools/helper/build.py /tmp/ref         # -> tools/helper/helper.html
    tools/worldmap/worldmap.sh --seed N --meta map_meta.txt --radius 320 --step 1 --nether --out /tmp/refn
    node tools/helper/diffn.js /tmp/refn          # nether columns and structures vs the engine

Checked on the server's seed (7869100364537964025) over 1280x1280 nodes,
289 chunks: 38 of 40 landmarks the headless run placed are found at the
same spot (every ruined portal, ocean ruin and ocean monument; 6 of 7
outposts and 17 of 19 igloos, each miss paired with a nearby extra where
the game took a chunk's second candidate), both villages' chunks, and all
128 strongholds. On the dev world's seed over the same area: 36 of 37
landmarks, 4 of 4 villages, 128 strongholds.

Nether, dev seed over 640x640: biomes exact; the lava / floor / solid
reading matches 98.7% of columns and the floor height 94% (the misses are
huge fungi, fossils and structure blocks the reference scan hits, and the
one-node floor layer, which the port assumes everywhere but the soul sand
valley); 7 of 7 structures at the same spot. Ores are not modelled, so a
floor the game turned to quartz or gravel is still a candidate here, and
chunks without caverns (where v7 adds random-walk caves) are flagged.

Known gaps: a village is marked where the game attempts one (the chunk
gate and a flatness check), not where it finishes building; fallen trees
and other terrain features are left out (they depend on the plants placed
before them); caves that open at the surface are not carved. Stronghold
rings use the seed's low 32 bits (checked on this Mac's Luanti for four
seeds); a seed at or above 2^63 converts in a CPU-defined way and the page
then shows a CPU setting (Apple silicon checked, x86 assumed).
