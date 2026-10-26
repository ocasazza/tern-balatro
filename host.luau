--[[
Balatro block: jokers wander a card table, a shop or a blind, and pop a fistful
of mult when clicked. No artwork ships with this plugin -- the sprites are cut
at run time from the player's own Balatro.love by extract.py, into the plugin's
data directory, on first use.

Crop geometry comes from the game's own tables: Jokers.png is a grid of 142x190
tiles at 2x, indexed by each `j_*` entry's `pos` in game.lua's P_CENTERS.
]]

local ui = tern.ui

local TICK_MS = 100
local MAX_JOKERS = 8
local EDITION_ODDS = 8192
local PET_MS = 2600
local IDLE_TICKS = 50
local WALK_TICKS = 60
local SPEED_FRAC = 0.004
local MARGIN = 0.02
local EDGE = 0.96
local MON_FRAC = 0.09
local ASSET_TICKS = 10
local SCENE_TICKS = 100
local EXTRACT_TIMEOUT_MS = 300000
local READ_CAP = 8 * 1024 * 1024

local THEMES = { "table", "shop", "blind", "none" }
local EDITIONS = { "foil", "holo", "poly" }

-- Scene props, in draw order: the ones behind the jokers, then the ones in
-- front of them. Roles carry the CSS that positions each piece.
local SCENE = {
	table = { behind = { "prop-card-a", "prop-card-b" }, front = { "prop-chip" } },
	shop = { behind = { "prop-sign" }, front = { "prop-pack-a", "prop-pack-b" } },
	blind = { behind = { "prop-blind" }, front = {} },
	none = { behind = {}, front = {} },
}

local PROP_ART = {
	["prop-card-a"] = "props/deck_red.png",
	["prop-card-b"] = "props/deck_blue.png",
	["prop-chip"] = "props/edition_gold.png",
	["prop-sign"] = "props/shop_sign_1.png",
	["prop-pack-a"] = "props/booster_a.png",
	["prop-pack-b"] = "props/booster_b.png",
	["prop-blind"] = "props/blind_chips_0.png",
}

-- Balatro.love candidates, the same order balatro-port-tui probes. The env var
-- wins so a non-Steam install can point at its own archive.
local LOVE_PATHS = {
	"/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/Resources/Balatro.love",
	"/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.exe",
	"/.steam/steam/steamapps/common/Balatro/Balatro.exe",
	"/.local/share/Steam/steamapps/common/Balatro/Balatro.exe",
}

local CACHE = tern.plugin.data .. "/cache"
local SCRIPT = tern.plugin.dir .. "/extract.py"

local M = {}

-- ------------------------------------------------------------------ helpers --

local function push(list, item)
	if item ~= nil then
		list[#list + 1] = item
	end
	return list
end

local function seed()
	pcall(function()
		math.randomseed((os.time() * 1000 + (os.clock() * 1000) % 1000) % 2147483647)
	end)
end

local function alive(state)
	local ok, panes = pcall(tern.pane.list)
	if not ok or type(panes) ~= "table" or state.cx == nil then
		return ok
	end
	for _, info in ipairs(panes) do
		if info.pane == state.cx.pane then
			return true
		end
	end
	return false
end

-- ------------------------------------------------------------------- assets --

local function asset(state, key, path, scene)
	local entry = state.assets[key]
	if entry == nil then
		entry = { path = path, scene = scene }
		state.assets[key] = entry
	end
	return entry
end

-- Bytes are read once and kept: a pane only receives a blob's bytes at the
-- moment it is published, so the tick republishes from memory.
local function publish(cx, entry)
	if entry.failed or entry.bytes == nil then
		return false
	end
	entry.id = cx:blob(entry.bytes, "image/png")
	return true
end

local function load(entry)
	if entry.bytes ~= nil or entry.failed then
		return
	end
	local ok, data = pcall(tern.fs.read, entry.path, READ_CAP)
	if ok and type(data) == "string" and #data > 0 then
		entry.bytes = data
	else
		entry.failed = true
		tern.log.warn("balatro: cannot read " .. entry.path)
	end
end

-- ---------------------------------------------------------------- extraction --

local function read_manifest()
	local ok, text = pcall(tern.fs.read, CACHE .. "/jokers.json", 4 * 1024 * 1024)
	if not ok or type(text) ~= "string" then
		return nil
	end
	local decoded, data = pcall(tern.json.decode, text)
	if not decoded or type(data) ~= "table" or type(data.jokers) ~= "table" then
		return nil
	end
	if #data.jokers == 0 then
		return nil
	end
	return data
end

local function find_love()
	local override = tern.getenv("TERN_BALATRO_LOVE")
	if override ~= nil and override ~= "" and tern.fs.exists(override) then
		return override
	end
	local base = tern.getenv("HOME")
	if base == nil or base == "" then
		return nil
	end
	for _, suffix in ipairs(LOVE_PATHS) do
		local candidate = base .. suffix
		if tern.fs.exists(candidate) then
			return candidate
		end
	end
	return nil
end

local function adopt_manifest(state)
	local manifest = read_manifest()
	if manifest == nil then
		return false
	end
	state.roster = manifest.jokers
	state.phase = "ready"
	state.error = nil
	return true
end

-- The Nix build rewrites extract.py's shebang to an absolute interpreter, so
-- the packaged copy runs as-is; a bare checkout needs python3 on PATH.
local function candidates(love)
	local out = {}
	local python = tern.getenv("TERN_BALATRO_PYTHON")
	if python ~= nil and python ~= "" then
		out[#out + 1] = { python, SCRIPT, "--love", love, "--out", CACHE }
	end
	out[#out + 1] = { SCRIPT, "--love", love, "--out", CACHE }
	out[#out + 1] = { "python3", SCRIPT, "--love", love, "--out", CACHE }
	return out
end

local try_extract

local function extraction_done(state, result, argv, index)
	if result.timed_out then
		state.phase = "error"
		state.error = "extract.py timed out after " .. tostring(EXTRACT_TIMEOUT_MS / 1000) .. "s"
	elseif result.status == 126 or result.status == 127 then
		-- The interpreter was not executable; the next form may still work.
		try_extract(state, argv, index + 1, "exit " .. tostring(result.status))
	elseif result.status ~= 0 then
		local why = result.stderr
		if type(why) ~= "string" or why == "" then
			why = "exit " .. tostring(result.status)
		end
		state.phase = "error"
		state.error = "extract.py failed: " .. why
	elseif not adopt_manifest(state) then
		state.phase = "error"
		state.error = "extract.py wrote no joker manifest into " .. CACHE
	elseif #state.mons == 0 then
		M.spawn_default(state)
	end
end

try_extract = function(state, argv, index, last_error)
	if index > #argv then
		state.phase = "error"
		state.error = "Cannot run extract.py" ..
			(last_error and (": " .. last_error) or " (set TERN_BALATRO_PYTHON)")
		return
	end
	local ok, err = pcall(tern.process.run, argv[index], { timeout_ms = EXTRACT_TIMEOUT_MS },
		function(result)
			extraction_done(state, result, argv, index)
		end)
	if not ok then
		try_extract(state, argv, index + 1, tostring(err))
	end
end

local function start_extract(state)
	local love = find_love()
	if love == nil then
		state.phase = "error"
		state.error = "No Balatro install found. Set TERN_BALATRO_LOVE to your Balatro.love."
		return
	end
	state.love = love
	state.phase = "preparing"
	state.detail = "Reading " .. love
	pcall(tern.fs.mkdir, CACHE)
	try_extract(state, candidates(love), 1, nil)
end

-- ------------------------------------------------------------------- roster --

local function by_key(state, key)
	for _, entry in ipairs(state.roster) do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

local function by_id(state, id)
	for _, mon in ipairs(state.mons) do
		if mon.id == id then
			return mon
		end
	end
	return nil
end

local function refilter(state)
	local picker = state.picker
	local found = {}
	local needle = string.lower(picker.q)
	for _, entry in ipairs(state.roster) do
		if needle == ""
			or string.find(string.lower(entry.name or ""), needle, 1, true) ~= nil
			or string.find(string.lower(entry.key or ""), needle, 1, true) ~= nil
		then
			found[#found + 1] = entry
		end
	end
	picker.list = found
	picker.sel = found[1] ~= nil and found[1].key or nil
end

-- ------------------------------------------------------------------- jokers --

local function add(state, key)
	local entry = by_key(state, key)
	if entry == nil or #state.mons >= MAX_JOKERS then
		return
	end
	state.next_id = state.next_id + 1
	local edition = nil
	if state.editions or math.random(EDITION_ODDS) == 1 then
		edition = EDITIONS[math.random(#EDITIONS)]
	end
	state.mons[#state.mons + 1] = {
		id = state.next_id,
		key = key,
		name = entry.name,
		x = MARGIN + math.random() * (EDGE - MON_FRAC - MARGIN),
		dir = math.random(2) == 1 and -1 or 1,
		moving = false,
		hold = math.random(IDLE_TICKS),
		speed = SPEED_FRAC,
		pet_until = 0,
		edition = edition,
	}
	asset(state, "mon:" .. key, CACHE .. "/" .. entry.sprite, false)
end

function M.spawn_default(state)
	add(state, "j_joker")
end

local function spawn_random(state)
	if #state.roster == 0 then
		return
	end
	add(state, state.roster[math.random(#state.roster)].key)
end

local function shuffle(state)
	if #state.roster == 0 then
		return
	end
	for _, mon in ipairs(state.mons) do
		local entry = state.roster[math.random(#state.roster)]
		mon.key = entry.key
		mon.name = entry.name
		asset(state, "mon:" .. mon.key, CACHE .. "/" .. entry.sprite, false)
	end
end

local function toggle_editions(state)
	state.editions = not state.editions
	for _, mon in ipairs(state.mons) do
		if state.editions then
			mon.edition = EDITIONS[math.random(#EDITIONS)]
		else
			mon.edition = nil
		end
	end
end

local function cycle_theme(state)
	for index, theme in ipairs(THEMES) do
		if theme == state.theme then
			state.theme = THEMES[index % #THEMES + 1]
			return
		end
	end
	state.theme = THEMES[1]
end

local function remove_last(state, cx)
	if #state.mons == 0 then
		state.stopped = true
		cx:exit(0)
		return true
	end
	table.remove(state.mons)
	return true
end

-- --------------------------------------------------------------------- walk --

local function settle(mon)
	mon.moving = false
	mon.hold = IDLE_TICKS + math.random(30)
end

local function step(state)
	local limit = EDGE - MON_FRAC
	for _, mon in ipairs(state.mons) do
		mon.hold = mon.hold - 1
		if mon.moving then
			mon.x = mon.x + mon.dir * mon.speed
			if mon.x <= MARGIN then
				mon.x = MARGIN
				settle(mon)
			elseif mon.x >= limit then
				mon.x = limit
				settle(mon)
			elseif mon.hold <= 0 or math.random(100) == 1 then
				settle(mon)
			end
		elseif mon.hold <= 0 then
			mon.dir = mon.x > (MARGIN + limit) / 2 and -1 or 1
			mon.hold = WALK_TICKS
			mon.speed = SPEED_FRAC * (0.7 + math.random() * 0.6)
			mon.moving = true
		end
	end
end

local function start_loop(state, cx)
	state.cx = cx
	tern.timer(TICK_MS, function()
		local live = state.cx
		if state.stopped or live == nil or not alive(state) then
			return
		end
		state.tick = state.tick + 1
		local changed = false

		for _, entry in pairs(state.assets) do
			local due = entry.id == nil
				or (entry.scene and state.tick % SCENE_TICKS == 0)
				or (not entry.scene and state.tick % ASSET_TICKS == 0)
			if due and not entry.failed then
				load(entry)
				if publish(live, entry) then
					changed = true
				end
			end
		end

		if state.phase == "ready" and state.picker == nil then
			step(state)
			changed = true
		end

		if changed then
			live:render()
		end
		start_loop(state, live)
	end)
end

-- --------------------------------------------------------------------- view --

local function prop_node(state, role)
	local entry = state.assets[role]
	if entry == nil or entry.id == nil then
		return nil
	end
	return ui.node("image", { key = role, role = role, blob = entry.id, alt = "" })
end

local function mon_node(state, mon)
	local entry = state.assets["mon:" .. mon.key]
	local body = {}
	if tern.now() < mon.pet_until then
		body[#body + 1] = ui.node("row", { key = "pet", role = "pet" }, {
			ui.text(ui.span("+Mult", "error strong")),
		})
	end
	body[#body + 1] = ui.node("image", {
		key = "sprite",
		role = mon.moving and mon.dir < 0 and "sprite-flip" or "sprite",
		blob = entry ~= nil and entry.id or nil,
		alt = mon.name,
		title = mon.name .. " -- click to pet",
		actions = { click = "pet=" .. tostring(mon.id) },
	})
	return ui.node("row", { key = "mon-" .. tostring(mon.id), role = "mon" }, {
		ui.node("spacer", { key = "l", grow = math.max(0.001, mon.x) }),
		ui.node("col", {
			key = "c",
			role = mon.edition ~= nil and ("edition-" .. mon.edition) or "joker",
		}, body),
		ui.node("spacer", { key = "r", grow = math.max(0.001, 1 - mon.x - MON_FRAC) }),
	})
end

local function stage(state)
	local scene = SCENE[state.theme] or SCENE.none
	local kids = {}
	for _, role in ipairs(scene.behind) do
		push(kids, prop_node(state, role))
	end
	for _, mon in ipairs(state.mons) do
		kids[#kids + 1] = mon_node(state, mon)
	end
	for _, role in ipairs(scene.front) do
		push(kids, prop_node(state, role))
	end
	local light = state.day and "day" or "night"
	return ui.node("col", {
		key = "stage",
		role = "stage-" .. state.theme .. "-" .. light,
		grow = 1,
	}, kids)
end

local function message(state)
	return ui.col({
		ui.text(ui.span(state.error or state.detail or "Working...", "warning")),
		ui.text(ui.span("Press r, or the revert button, to try again.", "muted")),
	})
end

local function button(icon, act, title)
	return ui.node("icon", { key = act, name = icon, role = "btn", title = title, actions = { click = act } })
end

local function dock(state)
	local rows = {}
	if state.phase == "error" then
		rows[#rows + 1] = button("revert", "retry", "Cut the sprites out again (r)")
	else
		rows[#rows + 1] = button("plus", "add", "Add a random joker (n)")
		rows[#rows + 1] = button("sparkle", "pick", "Choose a joker (+)")
		rows[#rows + 1] = button("swap", "shuffle", "Shuffle the jokers (r)")
		rows[#rows + 1] = button("image", "edition", "Golden jokers (s)")
		rows[#rows + 1] = button("palette", "theme", "Card table, shop or blind (t)")
		rows[#rows + 1] = button(state.day and "sun" or "moon", "daylight", "Light or dark (d)")
		rows[#rows + 1] = button("trash", "remove", "Remove the last joker (x)")
	end
	local status = state.phase ~= "ready"
		and "extracting sprites from your Balatro install"
		or string.format("%d/%d jokers -- %s%s", #state.mons, MAX_JOKERS, state.theme,
			state.editions and " -- editions" or "")
	return ui.col({
		ui.node("row", { key = "btns", role = "btns" }, rows),
		ui.text(ui.span(status, "muted")),
	})
end

local function picker_view(state)
	local picker = state.picker
	local items = {}
	local shown = 0
	for _, entry in ipairs(picker.list) do
		shown = shown + 1
		if shown <= 200 then
			items[#items + 1] = {
				id = entry.key,
				label = entry.name,
				detail = string.format("rarity %s -- %s -- $%s",
					tostring(entry.rarity), tostring(entry.set), tostring(entry.cost)),
			}
		end
	end
	return ui.node("picker", {
		key = "picker",
		size = "screen",
		title = "Choose a joker",
		noun = "joker",
		query = picker.q,
		items = items,
		selected = picker.sel,
		total = shown,
		empty = { ui.span("No joker matches that.", "muted") },
		actions = {
			{ id = "spawn", label = "Add", keys = { "enter" }, primary = true },
			{ id = "close", label = "Close", keys = { "escape" } },
		},
	})
end

local function view(state, cx)
	state.cx = cx
	if state.phase ~= "ready" then
		return { main = message(state), dock = dock(state) }
	end
	if state.picker ~= nil then
		return { main = ui.col({ picker_view(state) }), dock = dock(state) }
	end
	return { main = ui.col({ stage(state) }), dock = dock(state) }
end

-- ------------------------------------------------------------------- events --

local function picker_key(state, key)
	local picker = state.picker
	if key.name == "escape" then
		state.picker = nil
	elseif key.name == "enter" then
		if picker.sel ~= nil then
			add(state, picker.sel)
		end
		state.picker = nil
	elseif key.name == "up" then
		for index, entry in ipairs(picker.list) do
			if entry.key == picker.sel and index > 1 then
				picker.sel = picker.list[index - 1].key
				break
			end
		end
	elseif key.name == "down" then
		for index, entry in ipairs(picker.list) do
			if entry.key == picker.sel and picker.list[index + 1] ~= nil then
				picker.sel = picker.list[index + 1].key
				break
			end
		end
	elseif key.name == "backspace" then
		picker.q = string.sub(picker.q, 1, #picker.q - 1)
		refilter(state)
	elseif key.text ~= nil and #key.text > 0 and not key.ctrl and not key.meta then
		picker.q = picker.q .. key.text
		refilter(state)
	else
		return false
	end
	return true
end

local function open_picker(state)
	state.picker = { q = "", sel = nil, list = {} }
	refilter(state)
end

local function on_action(state, ev)
	local act = ev.act
	if act == "pet" then
		local mon = by_id(state, tonumber(ev.value))
		if mon ~= nil then
			mon.pet_until = tern.now() + PET_MS
		end
	elseif act == "add" then
		spawn_random(state)
	elseif act == "pick" then
		open_picker(state)
	elseif act == "shuffle" then
		shuffle(state)
	elseif act == "edition" then
		toggle_editions(state)
	elseif act == "theme" then
		cycle_theme(state)
	elseif act == "daylight" then
		state.day = not state.day
	elseif act == "close" then
		state.picker = nil
	elseif act == "spawn" then
		if state.picker ~= nil and state.picker.sel ~= nil then
			add(state, state.picker.sel)
		end
		state.picker = nil
	elseif act == "retry" then
		start_extract(state)
	end
end

local function restore_mons(state, saved)
	if type(saved) ~= "table" or type(saved.mons) ~= "table" then
		return
	end
	local limit = EDGE - MON_FRAC
	for _, row in ipairs(saved.mons) do
		local entry = type(row) == "table" and type(row.key) == "string" and by_key(state, row.key) or nil
		if entry ~= nil then
			state.next_id = state.next_id + 1
			state.mons[#state.mons + 1] = {
				id = state.next_id,
				key = row.key,
				name = entry.name,
				x = math.max(MARGIN, math.min(limit, tonumber(row.x) or 0.4)),
				dir = row.d == -1 and -1 or 1,
				moving = row.mv == true,
				hold = IDLE_TICKS,
				speed = SPEED_FRAC,
				pet_until = 0,
				edition = row.e,
			}
			asset(state, "mon:" .. row.key, CACHE .. "/" .. entry.sprite, false)
		end
	end
end

local function initial_state(cx, saved)
	local state = {
		cx = cx,
		phase = "preparing",
		detail = "Looking for your Balatro install...",
		error = nil,
		love = nil,
		roster = {},
		mons = {},
		assets = {},
		picker = nil,
		theme = "table",
		day = true,
		editions = false,
		tick = 0,
		next_id = 0,
		stopped = false,
	}
	if type(saved) == "table" then
		for _, theme in ipairs(THEMES) do
			if theme == saved.theme then
				state.theme = theme
			end
		end
		if type(saved.day) == "boolean" then
			state.day = saved.day
		end
		state.editions = saved.editions == true
	end
	for _, theme in ipairs(THEMES) do
		local scene = SCENE[theme] or SCENE.none
		for _, role in ipairs(scene.behind) do
			asset(state, role, CACHE .. "/" .. PROP_ART[role], true)
		end
		for _, role in ipairs(scene.front) do
			asset(state, role, CACHE .. "/" .. PROP_ART[role], true)
		end
	end
	return state
end

local definition = {
	init = function(cx, _args, saved)
		seed()
		local state = initial_state(cx, saved)
		if adopt_manifest(state) then
			restore_mons(state, saved)
			if #state.mons == 0 then
				M.spawn_default(state)
			end
		else
			start_extract(state)
		end
		start_loop(state, cx)
		return state
	end,

	view = view,

	title = function(state)
		if state.phase ~= "ready" then
			return "Balatro"
		end
		return string.format("Balatro -- %d jokers", #state.mons)
	end,

	key = function(state, key, cx)
		if state.phase ~= "ready" then
			if key.name == "r" then
				start_extract(state)
				return true
			end
			return false
		end
		if state.picker ~= nil then
			return picker_key(state, key)
		end
		if key.name == "n" or key.text == "+" then
			spawn_random(state)
		elseif key.name == "r" then
			shuffle(state)
		elseif key.name == "s" then
			toggle_editions(state)
		elseif key.name == "t" then
			cycle_theme(state)
		elseif key.name == "d" then
			state.day = not state.day
		elseif key.name == "x" or key.name == "delete" then
			return remove_last(state, cx)
		else
			return false
		end
		return true
	end,

	event = function(state, ev)
		if ev.ev == "action" then
			on_action(state, ev)
		elseif ev.ev == "select" then
			if state.picker ~= nil and type(ev.item) == "string" then
				state.picker.sel = ev.item
			end
		elseif ev.ev == "activate" then
			if state.picker ~= nil and type(ev.item) == "string" then
				add(state, ev.item)
				state.picker = nil
			end
		end
	end,

	save = function(state)
		local mons = tern.json.array({})
		for _, mon in ipairs(state.mons) do
			mons[#mons + 1] = {
				key = mon.key,
				x = mon.x,
				d = mon.dir,
				mv = mon.moving,
				e = mon.edition,
			}
		end
		return {
			v = 1,
			theme = state.theme,
			day = state.day,
			editions = state.editions,
			mons = mons,
		}
	end,
}

tern.block.define("balatro", definition)
