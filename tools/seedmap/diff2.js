// Structures: compare the port's placements with the headless run's pois.
const fs = require("fs");
const { makeGen, parseMapMeta } = require("./gen.js");
const { makeStructures, strongholds } = require("./structures.js");
const ref = process.argv[2];
const meta = fs.readFileSync(process.argv[3] || process.env.HOME + "/Library/Application Support/minetest/worlds/vrdev/map_meta.txt", "utf8");
const S = parseMapMeta(meta);
const biomes = JSON.parse(fs.readFileSync(ref + "/world/worldmap_biomes.json")).map(b => ({ ...b, heat: +b.heat, humidity: +b.humidity, weight: +b.weight }));
const decos = JSON.parse(fs.readFileSync(ref + "/world/worldmap_decorations.json")).map(d => ({ ...d, id: d.name ? d.id : ((d.id ^ 0x00585e6f) & 0x3FFFF) }));
const structs = JSON.parse(fs.readFileSync(ref + "/world/worldmap_structures.json"));
const groups = JSON.parse(fs.readFileSync(ref + "/world/worldmap_groups.json"));
const pois = JSON.parse(fs.readFileSync(ref + "/world/worldmap_pois.json")).pois;
const gen = makeGen(S, biomes);
const st = makeStructures(gen, decos, structs, groups);
const t0 = Date.now(); let got = [];
for (let oz = -192; oz <= 128; oz += 80) for (let ox = -192; ox <= 128; ox += 80) got = got.concat(st.chunkStructures(ox, oz));
console.log(`${got.length} placements from 25 chunks in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
const inArea = p => p.x >= -192 && p.x <= 207 && p.z >= -192 && p.z <= 207;
const want = pois.filter(p => !/seeded/.test(p.kind) && !/mineshaft|geode/.test(p.kind) && inArea(p));
const kinds = new Set([...want.map(p => p.kind), ...got.map(p => p.kind)]);
for (const k of [...kinds].sort()) {
  const w = want.filter(p => p.kind === k), g = got.filter(p => p.kind === k);
  const used = new Set();
  let hit = 0;
  for (const p of g) { const j = w.findIndex((q, i) => !used.has(i) && Math.abs(q.x - p.x) <= 2 && Math.abs(q.z - p.z) <= 2); if (j >= 0) { used.add(j); hit++; } }
  console.log(`${k}: reference ${w.length}, port ${g.length}, matched ${hit}`);
  if (hit < w.length) console.log("   missed:", w.filter((q, i) => !used.has(i)).slice(0, 6).map(q => `${q.x},${q.y},${q.z}`).join("  "));
  if (hit < g.length) console.log("   extra:", g.filter(p => !w.some(q => Math.abs(q.x - p.x) <= 2 && Math.abs(q.z - p.z) <= 2)).slice(0, 6).map(p => `${p.x},${p.y},${p.z}${p.note ? " (" + p.note + ")" : ""}`).join("  "));
}
// strongholds vs the seeded end_shrine positions
const shrines = pois.filter(p => p.kind === "end_shrine (seeded)");
for (const cpu of ["arm64", "x86"]) {
  const sh = strongholds(S.seed, cpu);
  const m = sh.filter(s => shrines.some(q => q.x === s.x && q.z === s.z)).length;
  console.log(`strongholds (${cpu} seed cast): ${m} of ${sh.length} match the reference's ${shrines.length}`);
}
