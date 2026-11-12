# Seed map (browser)

A VoxeLibre overworld map from a seed, generated in the browser: `gen.js`
ports Luanti's value noise, mapgen v7's terrain and the biome picker in
float32 arithmetic, so terrain heights and biomes match the engine (checked
against a headless render with `diff.js`: biomes exact, ground heights off
only where a structure reshaped the land). `page.html` is the viewer;
`build.py` inlines the generator, the biome table and the default map
settings into `seedmap.html`, which is what gets published as the artifact.

    tools/worldmap/worldmap.sh --seed N --meta map_meta.txt --radius 192 --step 1 --out /tmp/ref
    node tools/seedmap/diff.js /tmp/ref            # how far the port is from the engine
    python3 tools/seedmap/build.py /tmp/ref         # -> tools/seedmap/seedmap.html

Not covered yet: structures (villages, outposts, temples) and caves that
open at the surface.
