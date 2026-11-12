// Structures: compare the port's placements with the headless run's pois.
const fs = require("fs");
const { makeGen, parseMapMeta } = require("./gen.js");
const { makeStructures, strongholds } = require("./structures.js");
const ref = process.argv[2];
const pmeta = JSON.parse(fs.readFileSync(ref + "/world/worldmap_pois.json")).meta;
// the run's own seed and area (the map_meta gives the noise settings)
const meta = fs.readFileSync(process.argv[3] || process.env.HOME + "/Library/Application Support/minetest/worlds/vrdev/map_meta.txt", "utf8")
  .replace(/^\s*seed\s*=.*$/m, "") + "\nseed = " + pmeta.seed + "\n";
const S = parseMapMeta(meta);
const CX = pmeta.cx, CZ = pmeta.cz, RAD = pmeta.radius;
const corg = v => Math.floor((v + 32) / 80) * 80 - 32;
const biomes = JSON.parse(fs.readFileSync(ref + "/world/worldmap_biomes.json")).map(b => ({ ...b, heat: +b.heat, humidity: +b.humidity, weight: +b.weight }));
const decos = JSON.parse(fs.readFileSync(ref + "/world/worldmap_decorations.json")).map(d => ({ ...d, id: d.name ? d.id : ((d.id ^ 0x00585e6f) & 0x3FFFF) }));
const structs = JSON.parse(fs.readFileSync(ref + "/world/worldmap_structures.json"));
const groups = JSON.parse(fs.readFileSync(ref + "/world/worldmap_groups.json"));
const pois = JSON.parse(fs.readFileSync(ref + "/world/worldmap_pois.json")).pois;
const gen = makeGen(S, biomes);
const st = makeStructures(gen, decos, structs, groups);
const t0 = Date.now(); let got = [];
let nchunks = 0;
for (let oz = corg(CZ - RAD); oz <= CZ + RAD - 1; oz += 80) for (let ox = corg(CX - RAD); ox <= CX + RAD - 1; ox += 80) { got = got.concat(st.chunkStructures(ox, oz)); nchunks++; }
console.log(`${got.length} placements from ${nchunks} chunks in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
// only the area the headless run emerged counts, on both sides
const inArea = p => p.x >= CX - RAD && p.x < CX + RAD && p.z >= CZ - RAD && p.z < CZ + RAD;
got = got.filter(inArea);
const want = pois.filter(p => !/seeded/.test(p.kind) && !/mineshaft|geode|fallen_tree|water_lake|lavapool/.test(p.kind) && inArea(p));
const kinds = new Set([...want.map(p => p.kind), ...got.map(p => p.kind)]);
for (const k of [...kinds].sort()) {
  const w = want.filter(p => p.kind === k), g = got.filter(p => p.kind === k);
  const used = new Set();
  let hit = 0;
  const tol = k === "village" ? 45 : 2;
  for (const p of g) { const j = w.findIndex((q, i) => !used.has(i) && Math.abs(q.x - p.x) <= tol && Math.abs(q.z - p.z) <= tol); if (j >= 0) { used.add(j); hit++; } }
  console.log(`${k}: reference ${w.length}, port ${g.length}, matched ${hit}`);
  if (hit < w.length) console.log("   missed:", w.filter((q, i) => !used.has(i)).slice(0, 6).map(q => `${q.x},${q.y},${q.z}`).join("  "));
  if (hit < g.length) console.log("   extra:", g.filter(p => !w.some(q => Math.abs(q.x - p.x) <= tol && Math.abs(q.z - p.z) <= tol)).slice(0, 6).map(p => `${p.x},${p.y},${p.z}${p.note ? " (" + p.note + ")" : ""}`).join("  "));
}
// strongholds vs the seeded end_shrine positions
const shrines = pois.filter(p => p.kind === "end_shrine (seeded)");
for (const cpu of ["arm64", "x86"]) {
  const sh = strongholds(S.seed, cpu);
  const m = sh.filter(s => shrines.some(q => q.x === s.x && q.z === s.z)).length;
  console.log(`strongholds (${cpu} seed cast): ${m} of ${sh.length} match the reference's ${shrines.length}`);
}
