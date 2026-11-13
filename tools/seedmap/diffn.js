// Nether: compare the port's columns and structures with a headless
// `worldmap.sh --nether` run (worldmap_columns.csv: y, node and biome per
// column; worldmap_pois.json: the structures the game placed).
// Usage: node diffn.js WORLDMAP_OUT_DIR [map_meta.txt]
const fs = require("fs");
const { makeGen, parseMapMeta } = require("./gen.js");
const { makeNether, NETHER } = require("./nether.js");
const ref = process.argv[2];
const pmeta = JSON.parse(fs.readFileSync(ref + "/world/worldmap_pois.json")).meta;
const meta = fs.readFileSync(process.argv[3] || process.env.HOME + "/Library/Application Support/minetest/worlds/vrdev/map_meta.txt", "utf8")
  .replace(/^seed[ \t]*=.*$/m, "") + "\nseed = " + pmeta.seed + "\n";
const S = parseMapMeta(meta);
const biomes = JSON.parse(fs.readFileSync(ref + "/world/worldmap_biomes.json")).map(b => ({ ...b, heat: +b.heat, humidity: +b.humidity, weight: +b.weight }));
const decos = JSON.parse(fs.readFileSync(ref + "/world/worldmap_decorations.json")).map(d => ({ ...d, id: d.name ? d.id : ((d.id ^ 0x00585e6f) & 0x3FFFF) }));
const structs = JSON.parse(fs.readFileSync(ref + "/world/worldmap_structures.json"));
const groups = JSON.parse(fs.readFileSync(ref + "/world/worldmap_groups.json"));
const pois = JSON.parse(fs.readFileSync(ref + "/world/worldmap_pois.json")).pois;
const gen = makeGen(S, biomes);
const N = makeNether(gen, decos, structs, groups);

// columns
const rows = fs.readFileSync(ref + "/world/worldmap_columns.csv", "utf8").trim().split("\n").slice(1);
let n = 0, kindBad = 0, yBad = 0, biomeBad = 0;
const kindPairs = {}, yHist = {}, samples = [];
const t0 = Date.now();
for (const line of rows) {
  const [x, z, y, node, biome] = line.split(",");
  const X = +x, Z = +z, Y = +y;
  const c = N.column(X, Z);
  n++;
  const refKind = node === "lava" ? 2 : node === "solid" ? 0 : 1;
  if (c.kind !== refKind) { kindBad++; const k = `${["solid", "floor", "lava"][refKind]} -> ${["solid", "floor", "lava"][c.kind]}`; kindPairs[k] = (kindPairs[k] || 0) + 1; if (samples.length < 10) samples.push(`${X},${Z}: ref ${node} y ${Y}, got kind ${c.kind} y ${c.y}`); }
  else if (refKind === 1 && c.y !== Y) { yBad++; const d = c.y - Y; yHist[d] = (yHist[d] || 0) + 1; if (samples.length < 10) samples.push(`${X},${Z}: ref ${node} y ${Y}, got y ${c.y}`); }
  const bn = c.biome ? c.biome.name : "";
  if (bn !== biome) biomeBad++;
}
console.log(`${n} columns in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
console.log(`kind wrong: ${kindBad} (${(100 * kindBad / n).toFixed(2)}%)  ${Object.entries(kindPairs).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}:${v}`).join("  ")}`);
console.log(`floor height wrong (same kind): ${yBad} (${(100 * yBad / n).toFixed(2)}%)  ${Object.entries(yHist).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([k, v]) => `${k}:${v}`).join(" ")}`);
console.log(`biome wrong: ${biomeBad} (${(100 * biomeBad / n).toFixed(2)}%)`);
for (const s of samples) console.log("  ", s);

// structures
const CX = pmeta.cx, CZ = pmeta.cz, RAD = pmeta.radius;
const corg = v => Math.floor((v + 32) / 80) * 80 - 32;
let got = [], nchunks = 0;
const t1 = Date.now();
for (let oz = corg(CZ - RAD); oz <= CZ + RAD - 1; oz += 80) for (let ox = corg(CX - RAD); ox <= CX + RAD - 1; ox += 80) { got = got.concat(N.chunkStructures(ox, oz)); nchunks++; }
console.log(`${got.length} placements from ${nchunks} chunks in ${((Date.now() - t1) / 1000).toFixed(1)} s`);
const inArea = p => p.x >= CX - RAD && p.x < CX + RAD && p.z >= CZ - RAD && p.z < CZ + RAD;
got = got.filter(inArea);
const want = pois.filter(p => !/seeded/.test(p.kind) && inArea(p) && p.y < -20000);
const kinds = new Set([...want.map(p => p.kind), ...got.map(p => p.kind)]);
for (const k of [...kinds].sort()) {
  const w = want.filter(p => p.kind === k), g = got.filter(p => p.kind === k);
  const used = new Set();
  let hit = 0;
  for (const p of g) { const j = w.findIndex((q, i) => !used.has(i) && Math.abs(q.x - p.x) <= 2 && Math.abs(q.z - p.z) <= 2); if (j >= 0) { used.add(j); hit++; } }
  console.log(`${k}: reference ${w.length}, port ${g.length}, matched ${hit}`);
  if (hit < w.length) console.log("   missed:", w.filter((q, i) => !used.has(i)).slice(0, 8).map(q => `${q.x},${q.y},${q.z}`).join("  "));
  if (hit < g.length) console.log("   extra:", g.filter(p => !w.some(q => Math.abs(q.x - p.x) <= 2 && Math.abs(q.z - p.z) <= 2)).slice(0, 8).map(p => `${p.x},${p.y},${p.z}${p.note ? " (" + p.note + ")" : ""}`).join("  "));
}
