// The Nether from the seed. VoxeLibre's nether is a 128-node layer at
// y -29067..-28939 that mapgen v7 fills solid (far below its terrain) and
// then carves with its noise tunnels and caverns; the game adds the bedrock
// floor and ceiling, a lava sea where the caves dip below y -29036, and a
// one-node biome layer (nylium, soul soil, basalt, netherrack) on every
// floor. Biomes are the same heat/humidity noise as the overworld, limited
// to the five nether biomes by their y range. Structures (nether outposts,
// bulwarks, bridges, ruined portals) are all_floors decorations: the engine
// lists every floor of a candidate column and VoxeLibre's callback rolls
// the chunk probability per floor. Needs gen.js and structures.js.
"use strict";
if (typeof module !== "undefined") { var __g = require("./gen.js"), __s = require("./structures.js"); var Pcg = __g.Pcg, noiseMap3D = __g.noiseMap3D, fr = Math.fround, blockSeed2 = __s.blockSeed2, hashNodePos = __s.hashNodePos; }

const NETHER = {
  min: -29067, max: -28939,          // mcl_vars.mg_nether_min / max (bedrock at both)
  lava: -29036,                      // mg_lava_nether_max: air at or below this becomes lava
  bedrockBottom: -29063, bedrockTop: -28943,   // 5 layers each end (the bottom one is partly random)
  decoMax: -28950,                   // mg_nether_deco_max: the biome floor layer stops here
  compression: 8,                    // mcl_portals: overworld x,z = nether x,z * 8
};

function makeNether(gen, decorations, structs, groups) {
  const S = gen.settings, seed = gen.seed, CS = 80;
  const seedDouble = Number(S.seed);
  const chunkOrigin = v => Math.floor((v + 32) / CS) * CS - 32;
  const YCHUNKS = [chunkOrigin(NETHER.min), chunkOrigin(NETHER.min) + CS];   // -29067 and -28987
  const Y0 = YCHUNKS[0] - 1, YTOP = YCHUNKS[1] + CS - 1, H = YTOP - Y0 + 1;  // -29068 .. -28908
  const structByName = new Map(structs.map(s => [s.name, s]));
  const nodeSet = (list) => {
    const set = new Set();
    for (const n of (Array.isArray(list) ? list : list ? [list] : [])) {
      const g = /^group:(.+)$/.exec(n);
      if (g) for (const nn of groups[g[1]] || []) set.add(nn); else set.add(n);
    }
    return set;
  };
  // Structures whose y range touches the nether and that place on floors.
  const decos = decorations.filter(d => d.gen_callback && /^mcl_structures:/.test(d.name)
      && /all_floors/.test(d.flags || "") && d.y_min <= YTOP && d.y_max >= Y0
      && !(structByName.get(d.name.replace(/^mcl_structures:/, "")) || {}).terrain_feature)
    .map(d => ({ ...d, placeOn: nodeSet(d.place_on), biomeSet: d.biomes ? new Set(Array.isArray(d.biomes) ? d.biomes : [d.biomes]) : null,
                 struct: structByName.get(d.name.replace(/^mcl_structures:/, "")) }));

  const contour = v => { v = Math.abs(v); return v >= 1 ? 0 : fr(1 - v); };

  // One 80x80 chunk column: a carved bit per node for y in Y0..YTOP (both
  // y-chunks, the way v7 leaves them before the game's own passes), the
  // biome per column, and whether each y-chunk had caverns (without them
  // v7 adds random-walk caves, which this port does not carve).
  const cache = new Map();
  function chunk(ox, oz) {
    const key = ox + "," + oz;
    let c = cache.get(key);
    if (c) return c;
    const carved = new Uint8Array(CS * CS * H), nearCavern = [];
    if (S.caves) for (const oy of YCHUNKS) {
      // Noise over (80, 81, 80) from one node below the chunk, like the engine.
      const n1 = noiseMap3D(S.np_cave1, ox, oy - 1, oz, seed, CS, CS + 1, CS);
      const n2 = noiseMap3D(S.np_cave2, ox, oy - 1, oz, seed, CS, CS + 1, CS);
      const nc = S.caverns ? noiseMap3D(S.np_cavern, ox, oy - 1, oz, seed, CS, CS + 1, CS) : null;
      let near = false;
      for (let j = 0; j <= CS; j++) {
        const y = oy - 1 + j;
        // cavern amplitude: full this deep (the taper is near y -256)
        const amp = Math.min(fr(fr(S.cavern_limit - y) / S.cavern_taper), 1);
        for (let z = 0; z < CS; z++) for (let x = 0; x < CS; x++) {
          const i3 = (z * (CS + 1) + j) * CS + x, col = z * CS + x;
          let cut = fr(contour(n1[i3]) * contour(n2[i3])) > S.cave_width;
          if (nc) {
            const a = fr(Math.abs(nc[i3]) * amp);
            if (a > fr(S.cavern_threshold - 0.1)) { near = true; if (a > S.cavern_threshold) cut = true; }
          }
          if (cut) carved[col * H + (y - Y0)] = 1;
        }
      }
      nearCavern.push(near);
    }
    const biome = new Array(CS * CS);
    for (let z = 0; z < CS; z++) for (let x = 0; x < CS; x++) biome[z * CS + x] = gen.biomeAt(ox + x, NETHER.lava, oz + z);
    c = { ox, oz, carved, biome, nearCavern };
    if (cache.size > 12) cache.clear();
    cache.set(key, c);
    return c;
  }
  const carvedAt = (c, col, y) => y >= Y0 && y <= YTOP && c.carved[col * H + (y - Y0)] === 1;
  // The node as the game leaves it: bedrock at both ends, air above the
  // ceiling, lava in the carved space at or below the lava level.
  // 0 solid, 1 air, 2 lava.
  function finalNode(c, col, y) {
    if (y > NETHER.max) return 1;
    if (y >= NETHER.bedrockTop || y <= NETHER.bedrockBottom) return 0;
    if (!carvedAt(c, col, y)) return 0;
    return y <= NETHER.lava ? 2 : 1;
  }

  // What you would see from above: the lava sea where it is open to the
  // air, else the lowest floor above the lava level (plus the biome's
  // one-node layer, placed on floors up to decoMax), else solid rock.
  // {kind: 0 solid / 1 floor / 2 lava, y, biome}
  function column(x, z) {
    const ox = chunkOrigin(x), oz = chunkOrigin(z), c = chunk(ox, oz);
    const col = (z - oz) * CS + (x - ox), b = c.biome[col];
    if (finalNode(c, col, NETHER.lava) === 2 && finalNode(c, col, NETHER.lava + 1) === 1) return { kind: 2, y: NETHER.lava, biome: b };
    for (let y = NETHER.lava; y < NETHER.bedrockTop - 1; y++) {
      if (finalNode(c, col, y) === 0 && finalNode(c, col, y + 1) === 1) {
        // The soul sand valley is the exception: its blob ore turns most of
        // the floor to soul sand before the layer pass, which skips it (the
        // headless check had 69k soul sand floors to 19k soul soil ones).
        const covered = y >= NETHER.lava && y <= NETHER.decoMax && !(b && b.name === "SoulsandValley");
        return { kind: 1, y: covered ? y + 1 : y, biome: b };
      }
    }
    return { kind: 0, y: NETHER.bedrockTop, biome: b };
  }

  // Structures of one chunk column, both y-chunks.
  function chunkStructures(ox, oz) {
    const c = chunk(ox, oz), out = [];
    for (const oy of YCHUNKS) {
      const nminY = oy, nmaxY = oy + CS - 1;
      const base = blockSeed2(ox - 16, oy - 16, oz - 16, seed);
      for (const d of decos) {
        if (nmaxY < d.y_min || d.y_max < nminY) continue;
        const bs = (base + d.id) >>> 0;
        const ps = new Pcg(BigInt((bs + 53) >>> 0));
        let sidelen = d.sidelen; if (CS % sidelen !== 0) sidelen = CS;
        const area = sidelen * sidelen;
        const events = [];
        for (let z0 = 0; z0 < CS; z0 += sidelen) for (let x0 = 0; x0 < CS; x0 += sidelen) {
          const minX = ox + x0, minZ = oz + z0, maxX = minX + sidelen - 1, maxZ = minZ + sidelen - 1;
          const nval = fr(d.fill_ratio);
          let count = 0;
          if (nval >= 10) count = area;
          else {
            const f = fr(area * nval);
            if (f >= 1) count = Math.trunc(f);
            else if (f > 0) { if (ps.next() <= fr(f * 4294967295)) count = 1; }
          }
          for (let i = 0; i < count; i++) {
            const x = ps.range(minX, maxX), z = ps.range(minZ, maxZ);
            const col = (z - oz) * CS + (x - ox), b = c.biome[col];
            if (d.biomeSet && !(b && d.biomeSet.has(b.name))) continue;
            // Mapgen::getSurfaces over the chunk's y range, before the
            // game's passes: solid is whatever v7 did not carve.
            let above = !carvedAt(c, col, nmaxY);
            for (let y = nmaxY - 1; y >= nminY; y--) {
              const solid = !carvedAt(c, col, y);
              if (solid && !above && y >= d.y_min && y <= d.y_max && d.placeOn.has("mcl_nether:netherrack")) events.push([x, y, z]);
              above = solid;
            }
          }
        }
        if (!events.length) continue;
        const st = d.struct;
        for (const [x, y, z] of events) {
          const pr = new Pcg(BigInt(Math.trunc(hashNodePos(x, y, z) + seedDouble + 959)));
          if (st && st.chunk_probability != null) {
            if (!(pr.range(0, 1e9) * 1e-9 * st.chunk_probability <= 1)) continue;
          }
          let note = "";
          if (st && st.y_offset === "function") note = "y offset random";
          else if (st && st.solid_ground && st.sidelen) {
            // place_structure's solid-ground count at the floor level
            const h = st.sidelen / 2;
            let solid = 0;
            for (let zz = z - h; zz <= z + h; zz++) for (let xx = x - h; xx <= x + h; xx++) {
              const gx = Math.floor(xx), gz = Math.floor(zz);
              const cc = chunkOrigin(gx) === ox && chunkOrigin(gz) === oz ? c : chunk(chunkOrigin(gx), chunkOrigin(gz));
              if (finalNode(cc, (gz - cc.oz) * CS + (gx - cc.ox), y) === 0) solid++;
            }
            if (solid < st.sidelen * st.sidelen) note = st.make_foundation ? "foundation" : "";
          }
          out.push({ kind: d.name.replace(/^mcl_structures:/, ""), x, y: y + 1, z, note });
          if (st && st.chunk_probability != null) break;
        }
      }
    }
    if (c.nearCavern.some(n => !n)) for (const p of out) p.note = (p.note ? p.note + ", " : "") + "chunk has random caves";
    return out;
  }
  return { column, chunkStructures, chunkOrigin, chunk };
}

if (typeof module !== "undefined") module.exports = { makeNether, NETHER };
