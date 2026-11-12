# Seed map (browser)

A VoxeLibre overworld map from a seed, generated in the browser: `gen.js`
ports Luanti's value noise, mapgen v7's terrain and the biome picker in
float32 arithmetic, so terrain heights and biomes match the engine (checked
against a headless render with `diff.js`: biomes exact, ground heights off
only where a structure reshaped the land). `structures.js` ports the
engine's decoration placer and VoxeLibre's structure callback (chunk
probability, solid-ground check), the village chunk gate and the stronghold
rings; `diff2.js` checks those against the headless run's placements.
`page.html` is the viewer; `build.py` inlines the generator and the tables
the headless mod dumps (biomes, decorations, structures, node groups) into
`seedmap.html`, which is what gets published as the artifact.

    tools/worldmap/worldmap.sh --seed N --meta map_meta.txt --radius 192 --step 1 --out /tmp/ref
    node tools/seedmap/diff.js /tmp/ref            # terrain and biomes vs the engine
    node tools/seedmap/diff2.js /tmp/ref           # landmarks and strongholds vs the engine
    python3 tools/seedmap/build.py /tmp/ref         # -> tools/seedmap/seedmap.html

Checked on the server's seed (7869100364537964025) over 1280x1280 nodes,
289 chunks: 38 of 40 landmarks the headless run placed are found at the
same spot (every ruined portal, ocean ruin and ocean monument; 6 of 7
outposts and 17 of 19 igloos, each miss paired with a nearby extra where
the game took a chunk's second candidate), both villages' chunks, and all
128 strongholds. On the dev world's seed over the same area: 36 of 37
landmarks, 4 of 4 villages, 128 strongholds.

Known gaps: a village is marked where the game attempts one (the chunk
gate and a flatness check), not where it finishes building; fallen trees
and other terrain features are left out (they depend on the plants placed
before them); caves that open at the surface are not carved. Stronghold
rings use the seed's low 32 bits (checked on this Mac's Luanti for four
seeds); a seed at or above 2^63 converts in a CPU-defined way and the page
then shows a CPU setting (Apple silicon checked, x86 assumed).
