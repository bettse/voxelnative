// VoxeLibre overworld surface from a seed: a port of Luanti's value noise,
// mapgen v7's terrain and the biome picker (BiomeGenOriginal), in float32
// arithmetic so the results match the engine's. Plain script: runs in a Web
// Worker (postMessage API at the bottom) or under Node for the diff harness.
"use strict";
const fr = Math.fround;

// ---- noise.cpp -----------------------------------------------------------
function noise2d(x, y, seed) {
  let n = (Math.imul(1619, x) + Math.imul(31337, y) + Math.imul(1013, seed)) & 0x7fffffff;
  n = (n >>> 13) ^ n;
  n = (Math.imul(n, Math.imul(Math.imul(n, n), 60493) + 19990303) + 1376312589) & 0x7fffffff;
  return fr(1 - n / 0x40000000);
}
function noise3d(x, y, z, seed) {
  let n = (Math.imul(1619, x) + Math.imul(31337, y) + Math.imul(52591, z) + Math.imul(1013, seed)) & 0x7fffffff;
  n = (n >>> 13) ^ n;
  n = (Math.imul(n, Math.imul(Math.imul(n, n), 60493) + 19990303) + 1376312589) & 0x7fffffff;
  return fr(1 - n / 0x40000000);
}
function ease(t) { return fr(fr(fr(t * t) * t) * fr(fr(t * fr(fr(6 * t) - 15)) + 10)); }
function lerp(a, b, t) { return fr(a + fr(fr(b - a) * t)); }
function bilerp(v00, v10, v01, v11, x, y, eased) {
  if (eased) { x = ease(x); y = ease(y); }
  return lerp(lerp(v00, v10, x), lerp(v01, v11, x), y);
}
function trilerp(v000, v100, v010, v110, v001, v101, v011, v111, x, y, z, eased) {
  if (eased) { x = ease(x); y = ease(y); z = ease(z); }
  const u = bilerp(v000, v100, v010, v110, x, y, false);
  const v = bilerp(v001, v101, v011, v111, x, y, false);
  return lerp(u, v, z);
}
function noise2dValue(x, y, seed, eased) {
  const x0 = Math.floor(x), y0 = Math.floor(y);
  const xl = fr(x - x0), yl = fr(y - y0);
  return bilerp(noise2d(x0, y0, seed), noise2d(x0 + 1, y0, seed), noise2d(x0, y0 + 1, seed), noise2d(x0 + 1, y0 + 1, seed), xl, yl, eased);
}
function noise3dValue(x, y, z, seed, eased) {
  const x0 = Math.floor(x), y0 = Math.floor(y), z0 = Math.floor(z);
  const xl = fr(x - x0), yl = fr(y - y0), zl = fr(z - z0);
  return trilerp(noise3d(x0, y0, z0, seed), noise3d(x0 + 1, y0, z0, seed), noise3d(x0, y0 + 1, z0, seed), noise3d(x0 + 1, y0 + 1, z0, seed),
                 noise3d(x0, y0, z0 + 1, seed), noise3d(x0 + 1, y0, z0 + 1, seed), noise3d(x0, y0 + 1, z0 + 1, seed), noise3d(x0 + 1, y0 + 1, z0 + 1, seed),
                 xl, yl, zl, eased);
}
// NoiseParams: {offset, scale, spread:[x,y,z], seed, octaves, persist, lacunarity, flags:{eased, absvalue, defaults}}
function eased2d(np) { return np.flags.defaults || np.flags.eased; }
function eased3d(np) { return !!np.flags.eased; }
// Point evaluation (NoiseFractal2D / 3D).
function fractal2d(np, x, y, seed) {
  let a = fr(0), f = fr(1), g = fr(1);
  x = fr(x / np.spread[0]); y = fr(y / np.spread[1]);
  seed = (seed + np.seed) | 0;
  const e = eased2d(np);
  for (let i = 0; i < np.octaves; i++) {
    let v = noise2dValue(fr(x * f), fr(y * f), (seed + i) | 0, e);
    if (np.flags.absvalue) v = Math.abs(v);
    a = fr(a + fr(g * v));
    f = fr(f * np.lacunarity); g = fr(g * np.persist);
  }
  return fr(np.offset + fr(a * np.scale));
}
function fractal3d(np, x, y, z, seed) {
  let a = fr(0), f = fr(1), g = fr(1);
  x = fr(x / np.spread[0]); y = fr(y / np.spread[1]); z = fr(z / np.spread[2]);
  seed = (seed + np.seed) | 0;
  const e = eased3d(np);
  for (let i = 0; i < np.octaves; i++) {
    let v = noise3dValue(fr(x * f), fr(y * f), fr(z * f), (seed + i) | 0, e);
    if (np.flags.absvalue) v = Math.abs(v);
    a = fr(a + fr(g * v));
    f = fr(f * np.lacunarity); g = fr(g * np.persist);
  }
  return fr(np.offset + fr(a * np.scale));
}

// Map evaluation (Noise::noiseMap2D + valueMap2D): the engine computes a
// chunk's noise on a lattice and walks the interpolation weights
// incrementally, which rounds differently from point evaluation. sx * sy
// results indexed [j * sx + i] for the chunk at (x, y) (x along i).
function valueMap2D(np, x, y, stepX, stepY, seed, sx, sy, out) {
  const eased = eased2d(np);
  const x0 = Math.floor(x), y0 = Math.floor(y);
  let u = fr(x - x0), v = fr(y - y0);
  const origU = u;
  const nlx = ((u + sx * stepX) >>> 0) + 2, nly = ((v + sy * stepY) >>> 0) + 2;
  const buf = new Float32Array(nlx * nly);
  let k = 0;
  for (let j = 0; j !== nly; j++) for (let i = 0; i !== nlx; i++) buf[k++] = noise2d(x0 + i, y0 + j, seed);
  let index = 0, noisey = 0;
  for (let j = 0; j !== sy; j++) {
    let v00 = buf[noisey * nlx], v10 = buf[noisey * nlx + 1], v01 = buf[(noisey + 1) * nlx], v11 = buf[(noisey + 1) * nlx + 1];
    u = origU; let noisex = 0;
    for (let i = 0; i !== sx; i++) {
      out[index++] = bilerp(v00, v10, v01, v11, u, v, eased);
      u = fr(u + stepX);
      if (u >= 1.0) {
        u = fr(u - 1.0); noisex++;
        v00 = v10; v01 = v11;
        v10 = buf[noisey * nlx + noisex + 1]; v11 = buf[(noisey + 1) * nlx + noisex + 1];
      }
    }
    v = fr(v + stepY);
    if (v >= 1.0) { v = fr(v - 1.0); noisey++; }
  }
}
function noiseMap2D(np, x, y, seed, sx, sy, persistMap) {
  const n = sx * sy, result = new Float32Array(n), vbuf = new Float32Array(n);
  let f = fr(1), g = fr(1);
  x = fr(x / np.spread[0]); y = fr(y / np.spread[1]);
  const gmap = persistMap ? new Float32Array(n).fill(1) : null;
  for (let oct = 0; oct < np.octaves; oct++) {
    valueMap2D(np, fr(x * f), fr(y * f), fr(f / np.spread[0]), fr(f / np.spread[1]), (seed + np.seed + oct) | 0, sx, sy, vbuf);
    if (np.flags.absvalue) {
      if (gmap) for (let i = 0; i < n; i++) { result[i] = fr(result[i] + fr(gmap[i] * Math.abs(vbuf[i]))); gmap[i] = fr(gmap[i] * persistMap[i]); }
      else for (let i = 0; i < n; i++) result[i] = fr(result[i] + fr(g * Math.abs(vbuf[i])));
    } else {
      if (gmap) for (let i = 0; i < n; i++) { result[i] = fr(result[i] + fr(gmap[i] * vbuf[i])); gmap[i] = fr(gmap[i] * persistMap[i]); }
      else for (let i = 0; i < n; i++) result[i] = fr(result[i] + fr(g * vbuf[i]));
    }
    f = fr(f * np.lacunarity); g = fr(g * np.persist);
  }
  if (Math.abs(np.offset) > 0.00001 || Math.abs(np.scale - 1) > 0.00001)
    for (let i = 0; i < n; i++) result[i] = fr(fr(result[i] * np.scale) + np.offset);
  return result;
}

// ---- PcgRandom (biome vertical blend) ------------------------------------
const M64 = (1n << 64n) - 1n;
class Pcg {
  constructor(state, seq = PCG_DEFAULT_SEQ) {
    this.state = 0n; this.inc = ((BigInt(seq) << 1n) | 1n) & M64;
    this.next(); this.state = (this.state + (BigInt.asUintN(64, state))) & M64; this.next();
  }
  next() {
    const old = this.state;
    this.state = (old * 6364136223846793005n + this.inc) & M64;
    const xorshifted = Number((((old >> 18n) ^ old) >> 27n) & 0xffffffffn) >>> 0;
    const rot = Number(old >> 59n);
    return ((xorshifted >>> rot) | (xorshifted << ((-rot) & 31))) >>> 0;
  }
  rangeBound(bound) {
    if (bound === 0) return this.next();
    if (bound === 1) return 0;
    const threshold = ((0x100000000 - bound) % bound) >>> 0;
    let r;
    do { r = this.next(); } while (r < threshold);
    return r % bound;
  }
  range(min, max) { return this.rangeBound((max - min + 1) >>> 0) + min; }
}
const PCG_DEFAULT_SEQ = 0xda3e39cb94b95bdbn;

// ---- mapgen v7 -----------------------------------------------------------
function rangelim(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
function toS16(v) { return v < 0 ? Math.ceil(v) : Math.floor(v); }   // (s16) cast truncates toward zero

// Map settings: the noise params from map_meta.txt (VoxeLibre's v7 world)
// plus water_level, mount_zero_level, spflags and the seed (s32 of the u64).
function makeGen(settings, biomes) {
  const S = settings;
  const seed = Number(BigInt.asIntN(32, BigInt(S.seed)));
  const CS = 80;   // chunksize 5 x 16, chunks offset by -32 (MAP_BLOCKSIZE * 2)
  const chunkOrigin = v => Math.floor((v + 32) / CS) * CS - 32;
  const gen = { seed, settings: S, biomes };
  const bySorted = biomes.slice().sort((a, b) => a.id - b.id).map(b => ({
    ...b,
    y_min: b.min_pos ? b.min_pos[1] : b.y_min,
    y_max: b.max_pos ? b.max_pos[1] : b.y_max,
  }));

  // One 80x80 chunk column's 2D maps, cached.
  const chunkCache = new Map();
  function chunk2D(ox, oz) {
    const key = ox + "," + oz;
    let c = chunkCache.get(key);
    if (c) return c;
    const persist = noiseMap2D(S.np_terrain_persist, ox, oz, seed, CS, CS, null);
    c = {
      base: noiseMap2D(S.np_terrain_base, ox, oz, seed, CS, CS, persist),
      alt: noiseMap2D(S.np_terrain_alt, ox, oz, seed, CS, CS, persist),
      hsel: noiseMap2D(S.np_height_select, ox, oz, seed, CS, CS, null),
      mounth: S.mountains ? noiseMap2D(S.np_mount_height, ox, oz, seed, CS, CS, null) : null,
      uwater: S.ridges ? noiseMap2D(S.np_ridge_uwater, ox, oz, seed, CS, CS, null) : null,
    };
    if (chunkCache.size > 64) chunkCache.clear();
    chunkCache.set(key, c);
    return c;
  }
  function baseLevel(c, i) {
    const hselect = rangelim(c.hsel[i], 0, 1);
    const hb = c.base[i], ha = c.alt[i];
    if (ha > hb) return ha;
    return fr(fr(hb * hselect) + fr(ha * fr(1 - hselect)));
  }
  function mountain(x, y, z, mounthn) {
    const mh = Math.max(mounthn, 1);
    const grad = fr(-fr((y - S.mount_zero_level) / mh));
    const mn = fractal3d(S.np_mountain, x, y, z, seed);
    return fr(mn + grad) >= 0;
  }
  function river(x, y, z, uwatern) {
    const width = 0.2;
    const abs2 = fr(Math.abs(uwatern) * 2);
    if (abs2 > width) return false;
    const altitude = fr(y - S.water_level);
    const heightMod = fr(fr(altitude + 17) / 2.5);
    const widthMod = fr(width - abs2);
    const nridge = fr(fr(fractal3d(S.np_ridge, x, y, z, seed) * Math.max(altitude, 0)) / 7);
    return fr(nridge + fr(widthMod * heightMod)) >= 0.6;
  }
  // The column's top node: {y, water} where water means the top node is sea
  // water (y == water_level with no stone above the sea floor).
  gen.column = function (x, z) {
    const ox = chunkOrigin(x), oz = chunkOrigin(z);
    const c = chunk2D(ox, oz);
    const i = (z - oz) * CS + (x - ox);
    const surface = toS16(baseLevel(c, i));
    const mounthn = c.mounth ? c.mounth[i] : 0;
    const uw = c.uwater ? c.uwater[i] : 1;
    const riversHere = S.ridges && fr(Math.abs(uw) * 2) <= 0.2;
    // Mountains: stone where mountn >= y / mounthn. mountn rarely passes 0.8,
    // so nothing above 0.8 * mounthn; scan down from there in steps of 4
    // (the noise is 350 nodes tall in y, no thin layers), then refine.
    let top = -1e9, water = false;
    if (S.mountains) {
      const ymax = Math.min(S.ymax, Math.floor(0.8 * Math.max(mounthn, 1)));
      for (let y = ymax; y > surface; y -= 4) {
        if (mountain(x, y, z, mounthn) && !(riversHere && river(x, y, z, uw))) {
          let yy = y;
          while (yy + 1 <= ymax && mountain(x, yy + 1, z, mounthn) && !(riversHere && river(x, yy + 1, z, uw))) yy++;
          top = yy; break;
        }
      }
    }
    if (top < surface + 1) {
      // Base terrain, minus a river channel carved through it.
      let y = surface;
      if (riversHere) while (y > S.ymin && river(x, y, z, uw)) y--;
      top = y;
    }
    if (top < S.water_level) { top = S.water_level; water = true; }
    return { y: top, water, surface };
  };
  // calcBiomeAtPoint: point heat/humidity, nearest biome valid at y.
  gen.heat = (x, z) => fr(fractal2d(S.np_heat, x, z, seed) + fractal2d(S.np_heat_blend, x, z, seed));
  gen.humidity = (x, z) => fr(fractal2d(S.np_humidity, x, z, seed) + fractal2d(S.np_humidity_blend, x, z, seed));
  gen.biomeAt = function (x, y, z) {
    const heat = gen.heat(x, z), hum = gen.humidity(x, z);
    let best = null, bestBlend = null, dmin = Infinity, dminBlend = Infinity;
    for (const b of bySorted) {
      if (y < b.y_min || y > b.y_max + b.vertical_blend) continue;
      if (b.min_pos && (x < b.min_pos[0] || z < b.min_pos[2])) continue;
      if (b.max_pos && (x > b.max_pos[0] || z > b.max_pos[2])) continue;
      const dh = fr(heat - b.heat), du = fr(hum - b.humidity);
      let dist = fr(fr(dh * dh) + fr(du * du));
      if (b.weight > 0) dist = fr(dist / b.weight);
      if (y <= b.y_max) { if (dist < dmin) { dmin = dist; best = b; } }
      else if (dist < dminBlend) { dminBlend = dist; bestBlend = b; }
    }
    if (bestBlend && dminBlend <= dmin) {
      const s = BigInt(Math.trunc(y + fr(fr(heat + hum) * 0.9)));
      const rng = new Pcg(s);
      if (rng.range(0, bestBlend.vertical_blend) >= y - bestBlend.y_max) return bestBlend;
    }
    return best;
  };
  return gen;
}

// map_meta.txt -> settings object (noise params, water level, flags, seed).
function parseMapMeta(text) {
  const S = { np: {} };
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^\s*([a-z0-9_]+)\s*=\s*(.*)$/);
    if (!m) continue;
    const key = m[1], val = m[2].trim();
    if (val === "{") {
      const np = { offset: 0, scale: 1, spread: [1, 1, 1], seed: 0, octaves: 1, persist: 0.5, lacunarity: 2, flags: { defaults: true } };
      for (i++; i < lines.length && !/^\s*}/.test(lines[i]); i++) {
        const f = lines[i].match(/^\s*([a-z]+)\s*=\s*(.*)$/);
        if (!f) continue;
        const k = f[1], v = f[2].trim();
        if (k === "spread") np.spread = v.replace(/[()]/g, "").split(",").map(Number);
        else if (k === "flags") { np.flags = {}; for (const fl of v.split(",")) np.flags[fl.trim().replace(/^no/, "")] = !fl.trim().startsWith("no"); }
        else if (k === "persistence") np.persist = Number(v);
        else np[k] = Number(v);
      }
      S.np[key] = np;
    } else S[key] = val;
  }
  const get = (k) => S.np[k];
  return {
    seed: S.seed, water_level: Number(S.water_level ?? 1), mount_zero_level: Number(S.mgv7_mount_zero_level ?? 0),
    mountains: /\bmountains\b/.test(S.mgv7_spflags || "mountains,ridges") && !/\bnomountains\b/.test(S.mgv7_spflags || ""),
    ridges: /\bridges\b/.test(S.mgv7_spflags || "mountains,ridges") && !/\bnoridges\b/.test(S.mgv7_spflags || ""),
    ymin: -64, ymax: 255,
    np_terrain_base: get("mgv7_np_terrain_base"), np_terrain_alt: get("mgv7_np_terrain_alt"), np_terrain_persist: get("mgv7_np_terrain_persist"),
    np_height_select: get("mgv7_np_height_select"), np_mount_height: get("mgv7_np_mount_height"), np_mountain: get("mgv7_np_mountain"),
    np_ridge: get("mgv7_np_ridge"), np_ridge_uwater: get("mgv7_np_ridge_uwater"),
    np_heat: get("mg_biome_np_heat"), np_heat_blend: get("mg_biome_np_heat_blend"),
    np_humidity: get("mg_biome_np_humidity"), np_humidity_blend: get("mg_biome_np_humidity_blend"),
  };
}

if (typeof module !== "undefined") module.exports = { makeGen, parseMapMeta, noise2d, fractal2d, noiseMap2D, Pcg };
