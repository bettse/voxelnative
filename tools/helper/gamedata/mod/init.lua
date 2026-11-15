-- tools/helper's game data half. Runs once on a throwaway headless server
-- and writes gamedata.json: every registered item with its description,
-- icon texture and crafting recipes; every mob with its drops; the mob spawn
-- rules; the brewing tables; the enchantments. The helper page's guides are
-- written against this, so the recipes and numbers it shows are the game's
-- own. Needs secure.enable_security = false: the spawn and brewing tables
-- are locals of their mods, read through debug.getupvalue.
local out = minetest.get_worldpath()

local function upvalue(fn, wanted)
	if not fn or not debug or not debug.getupvalue then return nil end
	for i = 1, 60 do
		local name, value = debug.getupvalue(fn, i)
		if not name then break end
		if name == wanted then return value end
	end
end

local function clean(s)
	if type(s) ~= "string" then return "" end
	s = minetest.strip_colors and minetest.strip_colors(s) or s
	s = s:gsub("\27%b()", ""):gsub("\27E", ""):gsub("\27F", "")
	return s
end

local function tile_name(t)
	if type(t) == "string" then return t end
	if type(t) == "table" then return t.name or t.image or "" end
	return ""
end

-- Recipes from get_all_craft_recipes: items is a table with holes, laid out
-- row by row at `width` columns (0 = shapeless). Normalise to a flat array
-- with "" for empty slots.
local function recipes_for(name)
	local list = minetest.get_all_craft_recipes(name)
	if not list then return nil end
	local outl = {}
	for _, r in ipairs(list) do
		local items, n = {}, 0
		for k in pairs(r.items or {}) do if type(k) == "number" and k > n then n = k end end
		for i = 1, n do items[i] = r.items[i] or "" end
		outl[#outl + 1] = { type = r.type, width = r.width or 0, items = items, output = r.output }
	end
	return outl
end

local function dump()
	local data = { game = "", items = {}, mobs = {}, spawns = {}, brewing = {}, enchantments = {} }
	local info = minetest.get_game_info and minetest.get_game_info()
	local f = info and info.path and io.open(info.path .. "/game.conf")
	if f then local text = f:read("*a"); f:close(); data.game = text:match("\nversion%s*=%s*([^\n]+)") or "" end

	for name, def in pairs(minetest.registered_items) do
		if name ~= "" and name ~= "unknown" and name ~= "air" and name ~= "ignore" then
			local img = def.inventory_image
			if (not img or img == "") and def.tiles and def.tiles[1] then img = tile_name(def.tiles[1]) end
			if (not img or img == "") and def.wield_image and def.wield_image ~= "" then img = def.wield_image end
			local groups = {}
			for g, v in pairs(def.groups or {}) do if v and v ~= 0 then groups[g] = v end end
			data.items[name] = {
				desc = clean(def.description):match("^[^\n]*") or "",
				long = clean(def._doc_items_longdesc or ""),
				usage = clean(def._doc_items_usagehelp or ""),
				type = def.type, image = img or "", groups = groups,
				light = def.light_source, repair = def._repair_material,
				recipes = recipes_for(name),
			}
		end
	end

	for name, def in pairs(minetest.registered_entities) do
		if def.is_mob then
			local drops = {}
			for _, d in ipairs(def.drops or {}) do
				drops[#drops + 1] = { name = d.name, chance = d.chance, min = d.min, max = d.max, looting = d.looting }
			end
			data.mobs[name] = {
				desc = clean(def.description or name), type = def.type, hp_min = def.hp_min, hp_max = def.hp_max,
				damage = def.damage, armor = def.armor, xp_min = def.xp_min, xp_max = def.xp_max,
				spawn_class = def.spawn_class, passive = def.passive, attack_type = def.attack_type,
				fire_resistant = def.fire_resistant, drops = drops,
			}
		end
	end

	local sd = upvalue(mcl_mobs.spawn_setup, "spawn_dictionary")
	if type(sd) == "table" then
		local function add(d)
			if type(d) ~= "table" or not d.name then return end
			local biomes = {}
			if type(d.biomes) == "table" then for _, b in ipairs(d.biomes) do biomes[#biomes + 1] = b end end
			data.spawns[#data.spawns + 1] = {
				name = d.name, dimension = d.dimension, type_of_spawning = d.type_of_spawning, biomes = biomes,
				min_light = d.min_light, max_light = d.max_light, chance = d.chance, aoc = d.aoc,
				min_height = d.min_height, max_height = d.max_height, day_toggle = d.day_toggle,
			}
		end
		for _, d in pairs(sd) do
			if type(d) == "table" and d.name then add(d)
			elseif type(d) == "table" then for _, dd in pairs(d) do add(dd) end end
		end
	end

	data.brewing.outputs = upvalue(mcl_potions.register_ingredient_potion, "output_table") or {}
	data.brewing.modifiers = upvalue(mcl_potions.register_table_modifier, "mod_table") or {}
	data.brewing.inversions = upvalue(mcl_potions.register_inversion_recipe, "inversion_table") or {}

	for id, e in pairs(mcl_enchanting.enchantments or {}) do
		local prim, sec, inc = {}, {}, {}
		for k in pairs(e.primary or {}) do prim[#prim + 1] = k end
		for k in pairs(e.secondary or {}) do sec[#sec + 1] = k end
		for k in pairs(e.incompatible or {}) do inc[#inc + 1] = k end
		table.sort(prim); table.sort(sec); table.sort(inc)
		data.enchantments[id] = { name = clean(e.name), max_level = e.max_level, primary = prim, secondary = sec,
			incompatible = inc, treasure = e.treasure, curse = e.curse, weight = e.weight, description = clean(e.description) }
	end

	local json, err = minetest.write_json(data)
	assert(json, err)
	local fh = assert(io.open(out .. "/gamedata.json", "w"))
	fh:write(json); fh:close()
	local n = 0; for _ in pairs(data.items) do n = n + 1 end
	local m = 0; for _ in pairs(data.mobs) do m = m + 1 end
	minetest.log("action", string.format("[gamedata] wrote %d items, %d mobs, %d spawn rules", n, m, #data.spawns))
	local done = io.open(out .. "/gamedata_done", "w"); done:write("ok"); done:close()
	minetest.request_shutdown()
end

minetest.register_on_mods_loaded(function()
	minetest.after(1, function()
		local ok, err = pcall(dump)
		if not ok then minetest.log("error", "[gamedata] " .. tostring(err)); minetest.request_shutdown() end
	end)
end)
