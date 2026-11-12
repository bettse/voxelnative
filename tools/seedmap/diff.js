// Diff the JS generator against the headless reference (worldmap_columns.csv).
const fs = require("fs");
const { makeGen, parseMapMeta } = require("./gen.js");
const ref = process.argv[2];
// Usage: node diff.js WORLDMAP_OUT_DIR [map_meta.txt]  (a tools/worldmap run with --step 1)
const meta = fs.readFileSync(process.argv[3] || process.env.HOME + "/Library/Application Support/minetest/worlds/vrdev/map_meta.txt", "utf8");
const S = parseMapMeta(meta);
const biomes = JSON.parse(fs.readFileSync(ref + "/world/worldmap_biomes.json", "utf8"))
  .map(b => ({ ...b, heat: Number(b.heat), humidity: Number(b.humidity), weight: Number(b.weight) }));
const gen = makeGen(S, biomes);
const rows = fs.readFileSync(ref + "/world/worldmap_columns.csv", "utf8").trim().split("\n").slice(1);
let decoN = 0, n = 0, yBad = 0, yOff1 = 0, waterBad = 0, biomeBad = 0, biomeBadSameY = 0;
const ySamples = [], bSamples = [], yHist = {};
const t0 = Date.now();
for (const line of rows) {
  const [x, z, y, node, biome] = line.split(",");
  const X = +x, Z = +z, Y = +y;
  const c = gen.column(X, Z);
  n++;
  const refWater = node.includes("water");
  // Decorations sit on the terrain: trees, plants, mushrooms, vines, snow
  // layers. The terrain check compares ground nodes only.
  const deco = /flowers|leaves|tree|mushroom|cactus|reeds|bamboo|vine|deadbush|sapling|snow$|top_snow|mcl_farming|cocoa|lily|kelp|seagrass|coral|sweet_berry|mcl_villages|wool|planks|fence|door|torch|glass|stairs|slab|mcl_beds|chest|bell|mcl_lanterns|cobble|brick|sandstone_carved|bookshelf|crafting|furnace|composter|hay|carpet|grass_path|mcl_core:dirt$/i.test(node);
  if (deco) { decoN++; }
  else if (c.y !== Y) { yBad++; if (Math.abs(c.y - Y) === 1) yOff1++; const d = c.y - Y; yHist[d] = (yHist[d] || 0) + 1; if (ySamples.length < 12) ySamples.push(`${X},${Z}: ref ${Y} ${node} got ${c.y}${c.water ? " water" : ""} (surface ${c.surface})`); }
  if (c.water !== refWater) waterBad++;
  const b = gen.biomeAt(X, Y, Z);   // at the reference y, so the biome pick is tested on its own
  const bn = b ? b.name : "";
  if (bn !== biome) { biomeBad++; if (bSamples.length < 12) bSamples.push(`${X},${Z} y=${Y}: ref ${biome} got ${bn} heat ${gen.heat(X, Z).toFixed(2)} hum ${gen.humidity(X, Z).toFixed(2)}`); }
}
console.log(`${n} columns in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
console.log(`decorated columns skipped for height: ${decoN}; height wrong: ${yBad} (${(100 * yBad / (n - decoN)).toFixed(2)}% of ground columns), of which off by one: ${yOff1}; water flag wrong: ${waterBad}`);
console.log("height diff histogram:", Object.entries(yHist).sort((a, b) => b[1] - a[1]).slice(0, 10).map(([k, v]) => `${k}:${v}`).join(" "));
console.log(`biome wrong (at the reference y): ${biomeBad} (${(100 * biomeBad / n).toFixed(2)}%)`);
for (const s of ySamples) console.log("  y ", s);
for (const s of bSamples) console.log("  b ", s);
// Breakdown: which reference nodes the height misses sit on, and which biome pairs.
{
  const byNode = {}, byPair = {};
  for (const line of rows) {
    const [x, z, y, node, biome] = line.split(",");
    const c = gen.column(+x, +z);
    if (c.y !== +y) { const k = `${node} ${c.y - +y > 0 ? "+" : ""}${c.y - +y}`; byNode[k] = (byNode[k] || 0) + 1; }
    const b = gen.biomeAt(+x, +y, +z); const bn = b ? b.name : "";
    if (bn !== biome) { const k = `${biome} -> ${bn}`; byPair[k] = (byPair[k] || 0) + 1; }
  }
  console.log("height misses by node/diff:", Object.entries(byNode).sort((a, b) => b[1] - a[1]).slice(0, 16).map(([k, v]) => `${k}:${v}`).join("  "));
  console.log("biome misses by pair:", Object.entries(byPair).sort((a, b) => b[1] - a[1]).slice(0, 10).map(([k, v]) => `${k}:${v}`).join("  "));
}
