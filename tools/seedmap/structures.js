// Structures from the seed: a port of the engine's decoration placer
// (Decoration::placeDeco for heightmap decorations) feeding VoxeLibre's
// gen_callback (chunk_probability gate, place_structure's solid-ground
// check), plus mcl_villages' chunk gate and mcl_strongholds' rings.
// Needs gen.js loaded first (fr, noise, Pcg, makeGen).
"use strict";
if (typeof module !== "undefined") { var __g = require("./gen.js"); var Pcg = __g.Pcg, fractal2d = __g.fractal2d, fr = Math.fround; }

// Mapgen::getBlockSeed2 in u32 arithmetic.
function blockSeed2(x, y, z, seed) {
  let n = (Math.imul(1619, x) + Math.imul(31337, y) + Math.imul(52591, z) + Math.imul(1013, seed)) >>> 0;
  n = ((n >>> 13) ^ n) >>> 0;
  return (Math.imul(n, (Math.imul(Math.imul(n, n), 60493) + 19990303) | 0) + 1376312589) >>> 0;
}
// builtin core.hash_node_position, as a double like Lua computes it.
function hashNodePos(x, y, z) { return (z + 32768) * 65536 * 65536 + (y + 32768) * 65536 + (x + 32768); }

// Luanti's PseudoRandom (LCG), seeded with an s32.
class PseudoRandom {
  constructor(seed) { this.next_ = seed | 0; }
  next() {
    this.next_ = (Math.imul(this.next_ >>> 0, 1103515245) + 12345) | 0;
    const q = Math.trunc(this.next_ / 65536);   // signed division
    return ((q >>> 0) % 32768);
  }
  range(min, max) { return (this.next() % (max - min + 1)) + min; }
}

// mcl_strongholds: 128 positions on rings around the origin. The seed goes
// through tonumber (a double) and then Lua's tointeger: the double's integer
// value to 64 bits, of which PseudoRandom keeps the low 32. Checked on this
// Mac's Luanti for four seeds. A seed at or above 2^63 does not fit, and
// that conversion is CPU-defined: Apple silicon saturates to INT64_MAX (low
// bits -1, checked), x86 is expected to give INT64_MIN (low bits 0).
const STRONGHOLD_RINGS = [[3, 1408, 2688], [6, 4480, 5760], [10, 7552, 8832], [15, 10624, 11904], [21, 13696, 14976], [28, 16768, 18048], [36, 19840, 21120], [9, 22912, 24192]];
function strongholds(seedStr, cpu) {
  const d = Number(seedStr);
  let s;
  if (Math.abs(d) < 2 ** 63) s = Number(BigInt.asIntN(32, BigInt(Math.trunc(d))));
  else s = cpu === "x86" ? 0 : (d > 0 ? -1 : 0);
  const pr = new PseudoRandom(s), out = [];
  for (const [amount, min, max] of STRONGHOLD_RINGS) {
    let angle = (pr.next() / 32767) * (Math.PI * 2);
    for (let a = 0; a < amount; a++) {
      const dist = pr.range(min, max);
      pr.range(-57, -14);   // y: bedrock top + 1 .. overworld min + 48, unused on the map
      out.push({ kind: "stronghold", x: Math.round(Math.cos(angle) * dist), z: Math.round(Math.sin(angle) * dist) });
      angle = (angle + (Math.PI * 2) / amount) % (Math.PI * 2);
    }
  }
  return out;
}

// decorations: the resolved table in engine order (index = placement order);
// structs: mcl_structures' table by name; groups: "group:x" -> node names.
function makeStructures(gen, decorations, structs, groups, biomesByName) {
  const S = gen.settings, seed = gen.seed, CS = 80;
  const seedDouble = Number(S.seed);
  const chunkOrigin = v => Math.floor((v + 32) / CS) * CS - 32;
  const structByName = new Map(structs.map(s => [s.name, s]));
  const nodeSet = (list) => {
    const set = new Set();
    for (const n of (Array.isArray(list) ? list : list ? [list] : [])) {
      const g = /^group:(.+)$/.exec(n);
      if (g) for (const nn of groups[g[1]] || []) set.add(nn); else set.add(n);
    }
    return set;
  };
  // Only surface structures: a decoration with a gen_callback that is not an
  // all-floors/ceilings one (mineshafts, geodes: underground).
  // Landmarks only: structures with a gen_callback, not terrain features
  // (fallen trees, lakes, lava pools), not ones that need air neighbours
  // (spawn_by air, which earlier plant decorations change; spawn_by water is
  // taken as met under the sea), not the underground
  // ones (mineshafts, geodes, fossils). all_floors ones are taken at the
  // ground floor only, so a cave floor under the spot is not considered.
  const UNDERGROUND = /mineshaft|geode|fossil/;
  const decos = decorations.filter(d => d.gen_callback && /^mcl_structures:/.test(d.name) && !/all_ceilings/.test(d.flags || "")
      && !UNDERGROUND.test(d.name) && !(d.spawn_by && d.num_spawn_by > 0 && /air/.test(String(d.spawn_by)))
      && !(structByName.get(d.name.replace(/^mcl_structures:/, "")) || {}).terrain_feature)
    .map(d => ({ ...d, placeOn: nodeSet(d.place_on), biomeSet: d.biomes ? new Set(Array.isArray(d.biomes) ? d.biomes : [d.biomes]) : null,
                 liquid: /liquid_surface/.test(d.flags || ""), useNoise: !!d.noise_params, struct: structByName.get(d.name.replace(/^mcl_structures:/, "")) }));
  const topNode = (biome) => biome ? (biome.node_top || biome.node_filler || "mcl_core:stone") : "mcl_core:stone";

  // One 80x80 chunk column: ground height, water, biome per column.
  const colCache = new Map();
  function columns(ox, oz) {
    const key = ox + "," + oz;
    let c = colCache.get(key);
    if (c) return c;
    const ground = new Int16Array(CS * CS), water = new Uint8Array(CS * CS), biome = new Array(CS * CS);
    for (let j = 0; j < CS; j++) for (let i = 0; i < CS; i++) {
      const col = gen.column(ox + i, oz + j), k = j * CS + i;
      ground[k] = col.floor; water[k] = col.water ? 1 : 0;
      biome[k] = gen.biomeAt(ox + i, ground[k], oz + j);
    }
    c = { ground, water, biome };
    if (colCache.size > 64) colCache.clear();
    colCache.set(key, c);
    return c;
  }
  function groundAt(x, z) {
    const ox = chunkOrigin(x), oz = chunkOrigin(z), c = columns(ox, oz);
    return c.ground[(z - oz) * CS + (x - ox)];
  }

  // Structures of one chunk column (all the y-chunks its surface touches).
  function chunkStructures(ox, oz) {
    const c = columns(ox, oz), out = [];
    const ychunks = new Set();
    for (let k = 0; k < CS * CS; k++) { ychunks.add(chunkOrigin(c.ground[k])); if (c.water[k]) ychunks.add(chunkOrigin(S.water_level)); }
    for (const oy of ychunks) {
      const nminY = oy, nmaxY = oy + CS - 1;
      if (nmaxY < 0 && !ychunks.has(oy)) continue;
      const base = blockSeed2(ox - 16, oy - 16, oz - 16, seed);
      // engine heightmap for this chunk: ground if inside, nmax if the ground
      // is above the chunk (stone at the top), none if below
      const hm = new Int16Array(CS * CS);
      for (let k = 0; k < CS * CS; k++) hm[k] = c.ground[k] > nmaxY ? nmaxY : c.ground[k] < nminY ? -32768 : c.ground[k];
      for (const d of decos) {
        const bs = (base + d.id) >>> 0;
        if (nmaxY < d.y_min || d.y_max < nminY) continue;
        const ps = new Pcg(BigInt((bs + 53) >>> 0));
        let sidelen = d.sidelen; if (CS % sidelen !== 0) sidelen = CS;
        const area = sidelen * sidelen;
        const events = [];
        for (let z0 = 0; z0 < CS; z0 += sidelen) for (let x0 = 0; x0 < CS; x0 += sidelen) {
          const minX = ox + x0, minZ = oz + z0, maxX = minX + sidelen - 1, maxZ = minZ + sidelen - 1;
          const nval = d.useNoise ? fractal2d(npFrom(d.noise_params), minX + (sidelen >> 1), minZ + (sidelen >> 1), seed) : fr(d.fill_ratio);
          let count = 0, cover = false;
          if (nval >= 10) { cover = true; count = area; }
          else {
            const f = fr(area * nval);
            if (f >= 1) count = Math.trunc(f);
            else if (f > 0) { if (ps.next() <= fr(f * 4294967295)) count = 1; }
          }
          let x = minX - 1, z = minZ;
          for (let i = 0; i < count; i++) {
            if (!cover) { x = ps.range(minX, maxX); z = ps.range(minZ, maxZ); }
            else { x++; if (x === maxX + 1) { z++; x = minX; } }
            const k = (z - oz) * CS + (x - ox);
            let y;
            if (d.liquid) { y = c.water[k] && S.water_level >= nminY && S.water_level <= nmaxY && c.ground[k] < S.water_level ? S.water_level : -32768; }
            else y = hm[k];
            if (y < d.y_min || y > d.y_max || y < nminY || y > nmaxY) continue;
            const b = c.biome[k];
            if (d.biomeSet && !(b && d.biomeSet.has(b.name))) continue;
            const node = d.liquid ? "mcl_core:water_source" : (y === c.ground[k] ? topNode(b) : "mcl_core:stone");
            if (!d.placeOn.has(node)) continue;
            events.push([x, y, z]);
          }
        }
        if (!events.length) continue;
        // mcl_structures' gen_callback
        const st = d.struct;
        for (const [x, y, z] of events) {
          const pr = new Pcg(BigInt(Math.trunc(hashNodePos(x, y, z) + seedDouble + 959)));
          if (st && st.chunk_probability != null) {
            if (!(pr.range(0, 1e9) * 1e-9 * st.chunk_probability <= 1)) continue;
          }
          // place_structure(pos + 1)
          const py = y + 1;
          let ok = true, note = "";
          if (st && st.y_offset === "function") note = "y offset random";
          if (st && st.solid_ground && st.sidelen) {
            const h = st.sidelen / 2;
            let solid = 0;
            for (let zz = z - h; zz <= z + h; zz++) for (let xx = x - h; xx <= x + h; xx++) {
              const gx = Math.floor(xx), gz = Math.floor(zz);
              if (groundAt(gx, gz) >= py - 1) solid++;
            }
            if (solid < st.sidelen * st.sidelen) { if (!st.make_foundation) ok = false; else note = "foundation"; }
          }
          if (ok) out.push({ kind: d.name.replace(/^mcl_structures:/, ""), x, y: py, z, note });
          if (st && st.chunk_probability != null) break;
        }
      }
      // mcl_villages: one attempt per chunk whose blockseed % 77 == 17, on
      // flat ground (centre 40x40 of the heightmap within 56), centred.
      if (nmaxY >= 0 && base % 77 === 17) {
        let lo = 32767, hi = -32768, bad = false;
        for (let j = 20; j < 60 && !bad; j++) for (let i = 20; i <= 60; i++) {
          const v = hm[j * CS + i];
          if (v === -32768) { bad = true; break; }
          if (v < lo) lo = v; if (v > hi) hi = v;
        }
        if (!bad && hi - lo <= 56) {
          const cxm = Math.floor((ox + ox + CS - 1) / 2), czm = Math.floor((oz + oz + CS - 1) / 2);
          const k = (czm - oz) * CS + (cxm - ox);
          if (!c.water[k] && c.ground[k] >= nminY && c.ground[k] <= nmaxY) out.push({ kind: "village", x: cxm, y: c.ground[k] + 1, z: czm, note: "centre of the attempt" });
        }
      }
    }
    return out;
  }
  function npFrom(np) {
    const flags = {}; for (const f of String(np.flags || "defaults").split(",")) { const t = f.trim(); if (t) flags[t.replace(/^no/, "")] = !t.startsWith("no"); }
    return { offset: np.offset, scale: np.scale, spread: np.spread, seed: np.seed, octaves: np.octaves, persist: np.persist, lacunarity: np.lacunarity, flags };
  }
  return { chunkStructures, chunkOrigin, strongholds: (cpu) => strongholds(S.seed, cpu) };
}

if (typeof module !== "undefined") module.exports = { makeStructures, strongholds, blockSeed2, PseudoRandom };
