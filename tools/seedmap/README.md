# Seed map (browser)

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
decorations, placed per floor with `getSurfaces`. `page.html` is the
viewer; `build.py` inlines the generator and the tables the headless mod
dumps (biomes, decorations, structures, node groups) into `seedmap.html`,
which is what gets published as the artifact.

    tools/worldmap/worldmap.sh --seed N --meta map_meta.txt --radius 192 --step 1 --out /tmp/ref
    node tools/seedmap/diff.js /tmp/ref            # terrain and biomes vs the engine
    node tools/seedmap/diff2.js /tmp/ref           # landmarks and strongholds vs the engine
    python3 tools/seedmap/build.py /tmp/ref         # -> tools/seedmap/seedmap.html
    tools/worldmap/worldmap.sh --seed N --meta map_meta.txt --radius 320 --step 1 --nether --out /tmp/refn
    node tools/seedmap/diffn.js /tmp/refn          # nether columns and structures vs the engine

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
