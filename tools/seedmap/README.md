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

Checked on the server's seed over 1280x1280 nodes (289 chunks): 39 of 41
landmarks the headless run placed are found at the same spot (every outpost,
ocean monument, shipwreck and cold ocean ruin; one ruined portal and one
warm ocean ruin missed, one ruined portal extra), all 4 villages' chunks,
and all 128 strongholds.

Known gaps: a village is marked where the game attempts one (the chunk
gate and a flatness check), not where it finishes building; fallen trees
and other terrain features are left out (they depend on the plants placed
before them); caves that open at the surface are not carved. Stronghold
rings depend on the server CPU's float-to-integer cast (a page setting).
