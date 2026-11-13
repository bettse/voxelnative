-- tools/worldmap's server half. Runs in a throwaway world on a headless
-- server: generates the requested square, then writes per-column surface
-- samples and every structure the game placed, and shuts the server down.
--
-- Settings (from the config worldmap.sh writes):
--   worldmap_cx, worldmap_cz   centre of the square (nodes)
--   worldmap_radius            half the side (nodes)
--   worldmap_step              sample every Nth column
--   worldmap_ymin, worldmap_ymax  height range to generate and search

local S = minetest.settings
local cx = math.floor(tonumber(S:get("worldmap_cx")) or 0)
local cz = math.floor(tonumber(S:get("worldmap_cz")) or 0)
local R = math.floor(tonumber(S:get("worldmap_radius")) or 384)
local step = math.max(1, math.floor(tonumber(S:get("worldmap_step")) or 2))
local nether = S:get_bool("worldmap_nether", false)
local ymin = math.floor(tonumber(S:get("worldmap_ymin")) or (nether and -29067 or -64))
local ymax = math.floor(tonumber(S:get("worldmap_ymax")) or (nether and -28944 or 255))
-- The nether's lava sea fills carved space at or below this height.
local NETHER_LAVA = -29036
local out = minetest.get_worldpath()

local pois = {}
local function poi(kind, pos)
	pois[#pois + 1] = string.format('{"kind":%q,"x":%d,"y":%d,"z":%d}',
		kind, math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5))
end

-- Every schematic structure (temples, wells, igloos, huts, ...) goes through
-- place_structure, either from its decoration's gen_callback or as a static
-- position. Record only the ones it actually placed.
if minetest.global_exists("mcl_structures") and mcl_structures.place_structure then
	local orig = mcl_structures.place_structure
	mcl_structures.place_structure = function(pos, def, ...)
		local ok = orig(pos, def, ...)
		if ok ~= false and def and def.name then poi(def.name, pos) end
		return ok
	end
end

-- Villages are built by mcl_villages from a site plan; the first entry is
-- the bell, the village centre.
if minetest.global_exists("settlements") and settlements.place_schematics then
	local orig = settlements.place_schematics
	settlements.place_schematics = function(info, ...)
		if info and info[1] and info[1].pos then poi("village", info[1].pos) end
		return orig(info, ...)
	end
end

local function write(name, text)
	local f = assert(io.open(out .. "/" .. name, "w"))
	f:write(text); f:close()
end

-- The game's version= from its game.conf (get_game_info has no version).
local function game_version()
	local info = minetest.get_game_info and minetest.get_game_info()
	local f = info and info.path and io.open(info.path .. "/game.conf")
	if not f then return "" end
	local text = f:read("*a"); f:close()
	return text:match("\nversion%s*=%s*([^\n]+)") or ""
end

local function scan()
	local t0 = os.clock()
	local lines = { "x,z,y,node,biome,floor" }
	local c_air = minetest.get_content_id("air")
	local c_ignore = minetest.get_content_id("ignore")
	local liquid = {}   -- content id -> true for water (sea floor depth)
	for name, def in pairs(minetest.registered_nodes) do
		if def.liquidtype and def.liquidtype ~= "none" and name:find("water") then liquid[minetest.get_content_id(name)] = true end
	end
	local names = {}
	local function name_of(c)
		local n = names[c]
		if not n then n = minetest.get_name_from_content_id(c); names[c] = n end
		return n
	end
	local walkable = {}
	for name, def in pairs(minetest.registered_nodes) do
		if def.walkable ~= false then walkable[minetest.get_content_id(name)] = true end
	end
	walkable[c_air] = nil; walkable[c_ignore] = nil
	local c_nlava = minetest.get_content_id("mcl_nether:nether_lava_source")
	-- Nether: what you would see from above. The lava sea where it is open
	-- to the air, else the lowest walkable floor above the lava level, else
	-- solid rock.
	local function nether_column(data, area, x, z)
		local lava = data[area:index(x, NETHER_LAVA, z)]
		if lava == c_nlava and data[area:index(x, NETHER_LAVA + 1, z)] == c_air then return NETHER_LAVA, "lava" end
		for y = NETHER_LAVA, ymax - 1 do
			local c = data[area:index(x, y, z)]
			if walkable[c] and not walkable[data[area:index(x, y + 1, z)]] then return y, name_of(c) end
		end
		return ymax, "solid"
	end
	-- One VoxelManip per 80x80 tile keeps memory flat.
	local tile = 80
	for tx = cx - R, cx + R - 1, tile do
		for tz = cz - R, cz + R - 1, tile do
			local vm = VoxelManip()
			local e1, e2 = vm:read_from_map({x = tx, y = ymin, z = tz}, {x = tx + tile - 1, y = ymax, z = tz + tile - 1})
			local area = VoxelArea:new({MinEdge = e1, MaxEdge = e2})
			local data = vm:get_data()
			for x = tx, math.min(tx + tile - 1, cx + R - 1) do
				if (x - (cx - R)) % step == 0 then
					for z = tz, math.min(tz + tile - 1, cz + R - 1) do
						if (z - (cz - R)) % step == 0 then
							local y, c, cname
							if nether then
								y, cname = nether_column(data, area, x, z)
							else
								y = ymax
								c = data[area:index(x, y, z)]
								while y > ymin and (c == c_air or c == c_ignore) do
									y = y - 1
									c = data[area:index(x, y, z)]
								end
								cname = name_of(c)
							end
							local b = minetest.get_biome_data({x = x, y = y, z = z})
							local bn = b and minetest.get_biome_name(b.biome) or ""
							-- Under water: where the floor is, for depth shading.
							local fy = y
							if c and liquid[c] then
								while fy > ymin and liquid[data[area:index(x, fy, z)]] do fy = fy - 1 end
							end
							lines[#lines + 1] = x .. "," .. z .. "," .. y .. "," .. cname .. "," .. bn .. "," .. fy
						end
					end
				end
			end
		end
	end
	write("worldmap_columns.csv", table.concat(lines, "\n") .. "\n")
	-- The biome table as the engine resolved it (registration order is the
	-- engine's id order, which breaks ties in biome selection), for a port of
	-- the biome picker to check against.
	local bl = {}
	for name, def in pairs(minetest.registered_biomes) do
		local id = minetest.get_biome_id(name)
		bl[#bl + 1] = string.format('{"id":%d,"name":%q,"heat":%s,"humidity":%s,"y_min":%d,"y_max":%d,"node_top":%q,"node_filler":%q,"node_water_top":%q,"node_water":%q,"node_riverbed":%q,"vertical_blend":%d,"weight":%s,"min_pos":%s,"max_pos":%s}',
			id, name, tostring(def.heat_point or 50), tostring(def.humidity_point or 50), def.y_min or -31000, def.y_max or 31000,
			def.node_top or "", def.node_filler or "", def.node_water_top or "", def.node_water or "", def.node_riverbed or "",
			def.vertical_blend or 0, tostring(def.weight or 1),
			def.min_pos and string.format("[%d,%d,%d]", def.min_pos.x, def.min_pos.y, def.min_pos.z) or "null",
			def.max_pos and string.format("[%d,%d,%d]", def.max_pos.x, def.max_pos.y, def.max_pos.z) or "null")
	end
	write("worldmap_biomes.json", "[" .. table.concat(bl, ",") .. "]\n")
	-- Every registered decoration as the engine resolved it, for a port of the
	-- decoration placer: VoxeLibre's structures are decorations with a
	-- gen_callback. Registration order is the engine's placement order.
	-- Keyed by the engine's handle (placement order and the per-decoration
	-- blockseed offset); a named decoration appears under its name too.
	local dl, seen = {}, {}
	for id, def in pairs(minetest.registered_decorations) do
		local handle = tonumber(id) or (def.name and minetest.get_decoration_id(def.name))
		if handle and not seen[handle] then
			seen[handle] = true
			local np = def.noise_params
			dl[#dl + 1] = {
				id = handle, name = def.name or "", deco_type = def.deco_type,
				place_on = def.place_on, spawn_by = def.spawn_by, num_spawn_by = def.num_spawn_by or -1,
				sidelen = def.sidelen or 8, fill_ratio = def.fill_ratio or 0.02,
				noise_params = np and { offset = np.offset or 0, scale = np.scale or 1,
					spread = np.spread and { np.spread.x, np.spread.y, np.spread.z } or { 1, 1, 1 },
					seed = np.seed or 0, octaves = np.octaves or 1, persist = np.persist or np.persistence or 0.5,
					lacunarity = np.lacunarity or 2, flags = np.flags or "defaults" } or nil,
				biomes = def.biomes, y_min = def.y_min or -31000, y_max = def.y_max or 31000, flags = def.flags or "",
				schematic = type(def.schematic) == "string" and def.schematic or (type(def.schematic) == "table" and "table" or ""),
				place_offset_y = def.place_offset_y or 0, height = def.height or 1, height_max = def.height_max or 0,
				decoration = def.decoration, gen_callback = def.gen_callback and true or false,
				struct = def.mcl_structure_name,
			}
		end
	end
	write("worldmap_decorations.json", minetest.write_json(dl) .. "\n")
	-- Node names behind each "group:x" a decoration places on, and the
	-- structure table (what place_structure checks before it builds).
	local groups = {}
	for _, d in ipairs(dl) do
		for _, list in ipairs({ d.place_on or {}, d.spawn_by or {} }) do
			for _, n in ipairs(type(list) == "table" and list or { list }) do
				local g = n:match("^group:(.+)$")
				if g and not groups[g] then
					local names = {}
					for nn, nd in pairs(minetest.registered_nodes) do
						if nd.groups and (nd.groups[g] or 0) > 0 then names[#names + 1] = nn end
					end
					table.sort(names)
					groups[g] = names
				end
			end
		end
	end
	write("worldmap_groups.json", minetest.write_json(groups) .. "\n")
	local sl = {}
	if minetest.global_exists("mcl_structures") then
		for name, def in pairs(mcl_structures.registered_structures) do
			sl[#sl + 1] = {
				name = name, sidelen = def.sidelen, solid_ground = def.solid_ground and true or false,
				make_foundation = def.make_foundation and true or false, chunk_probability = def.chunk_probability,
				y_offset = type(def.y_offset) == "function" and "function" or (def.y_offset or 0),
				on_place = def.on_place and true or false, place_func = def.place_func and true or false,
				filenames = def.filenames and #def.filenames or 0, terrain_feature = def.terrain_feature and true or false,
				static_pos = def.static_pos and #def.static_pos or 0, y_min = def.y_min, y_max = def.y_max,
				biomes = def.biomes, place_on = def.place_on, fill_ratio = def.fill_ratio, flags = def.flags,
			}
		end
	end
	write("worldmap_structures.json", minetest.write_json(sl) .. "\n")

	-- Strongholds come straight from the seed (rings around the origin), so
	-- list all of them, generated here or not.
	if minetest.global_exists("mcl_structures") then
		for name, def in pairs(mcl_structures.registered_structures or {}) do
			if def.static_pos then
				for _, p in ipairs(def.static_pos) do poi(name .. " (seeded)", p) end
			end
		end
	end
	local meta = string.format('{"seed":%q,"mg_name":%q,"cx":%d,"cz":%d,"radius":%d,"step":%d,"water_level":%d,"game_version":%q}',
		minetest.get_mapgen_setting("seed"), minetest.get_mapgen_setting("mg_name"), cx, cz, R, step,
		tonumber(minetest.get_mapgen_setting("water_level")) or 0,
		game_version())
	write("worldmap_pois.json", '{"meta":' .. meta .. ',"pois":[' .. table.concat(pois, ",") .. "]}\n")
	minetest.log("action", string.format("[worldmap] scanned %d columns in %.1fs, %d pois", #lines - 1, os.clock() - t0, #pois))
	-- --probe: the nodes below, at and above each listed point (x,y,z per
	-- line), to check a player's logged path against the generated world.
	local pf = io.open(out .. "/probe.txt")
	if pf then
		local rows = { "x,y,z,below,feet,head" }
		for line in pf:lines() do
			local x, y, z = line:match("^([-%d.]+),([-%d.]+),([-%d.]+)")
			if x then
				local p = {x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5)}
				local vm = VoxelManip()
				vm:read_from_map(vector.offset(p, 0, -1, 0), vector.offset(p, 0, 1, 0))
				rows[#rows + 1] = string.format("%d,%d,%d,%s,%s,%s", p.x, p.y, p.z,
					vm:get_node_at(vector.offset(p, 0, -1, 0)).name, vm:get_node_at(p).name, vm:get_node_at(vector.offset(p, 0, 1, 0)).name)
			end
		end
		pf:close()
		write("probe_out.csv", table.concat(rows, "\n") .. "\n")
	end
	write("worldmap_done", "ok\n")
	minetest.request_shutdown("worldmap done", false, 0)
end

-- Villages aren't built during generation: mcl_villages drops a structblock
-- at a candidate chunk's minp and builds when an LBM sees that block load,
-- which takes a player nearby. Find the structblocks and forceload each one
-- briefly so the normal build runs (and place_schematics records it).
local function chunk_minps()
	local cs = 80   -- chunksize 5 x 16, offset by -32 like the engine's mapchunks
	local out = {}
	local function first(v) return math.floor((v + 32) / cs) * cs - 32 end
	for x = first(cx - R), cx + R - 1, cs do
		for z = first(cz - R), cz + R - 1, cs do
			for y = first(ymin), ymax, cs do
				if y + cs - 1 >= 0 then out[#out + 1] = {x = x, y = y, z = z} end
			end
		end
	end
	return out
end

local function build_villages(done)
	if not minetest.registered_nodes["mcl_villages:structblock"] then return done() end
	local sites = {}
	for _, p in ipairs(chunk_minps()) do
		local vm = VoxelManip()
		vm:read_from_map(p, p)
		if vm:get_node_at(p).name == "mcl_villages:structblock" then sites[#sites + 1] = p end
	end
	minetest.log("action", "[worldmap] " .. #sites .. " village sites to try")
	local i = 0
	local function next_site()
		i = i + 1
		if i > #sites then return done() end
		local p = sites[i]
		minetest.forceload_block(p, true)
		-- The LBM emerges the chunk again and builds; give it time, then move on.
		minetest.after(4, function()
			minetest.forceload_free_block(p, true)
			next_site()
		end)
	end
	next_site()
end

minetest.register_on_mods_loaded(function()
	minetest.after(1, function()
		local p1 = {x = cx - R, y = ymin, z = cz - R}
		local p2 = {x = cx + R - 1, y = ymax, z = cz + R - 1}
		local t0 = os.time()
		local last = 0
		minetest.log("action", "[worldmap] emerging " .. minetest.pos_to_string(p1) .. " .. " .. minetest.pos_to_string(p2))
		minetest.emerge_area(p1, p2, function(_, _, remaining)
			if os.time() - last >= 10 then
				last = os.time()
				minetest.log("action", "[worldmap] " .. remaining .. " blocks left (" .. (os.time() - t0) .. "s)")
			end
			if remaining == 0 then minetest.after(0, function() build_villages(scan) end) end
		end)
	end)
end)
