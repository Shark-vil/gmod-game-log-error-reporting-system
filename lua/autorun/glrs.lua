-- GLRS: GameLog Error Reporting System.
-- Console: glrs_report   Chat: !glrs
-- Client report: anyone. Server report: admins only (or singleplayer). Files: garrysmod/data/glrs_reports/
local TEST_SECS, ERR_MAX, SAMPLE_EVERY, TOP = 25, 200, 1000, 25

---------------------------------------------------------------- error buffer (RAM only)
-- Deduplicated by message; max ERR_MAX distinct entries, oldest evicted -> bounded memory.
local errs, order, evicted = {}, {}, 0

local function fmtStack(st)
	if type(st) ~= "table" then return tostring(st or "") end
	local t = {}
	for i = 1, math.min(#st, 10) do
		local s = st[i]
		t[#t + 1] = type(s) == "table"
			and ("%s:%s %s"):format(tostring(s.File or s.short_src), tostring(s.Line or s.currentline), tostring(s.Function or s.name or ""))
			or tostring(s)
	end
	return table.concat(t, "\n      ")
end

-- shortcut: relies on the OnLuaError hook; errors thrown before this file loads are not captured.
hook.Add("OnLuaError", "GLRS", function(str, realm, stack, title, id)
	str = tostring(str or "")
	local key = tostring(realm) .. str:sub(1, 300)
	local e = errs[key]
	if e then
		e.count, e.last = e.count + 1, os.date("%H:%M:%S")
		return
	end
	if #order >= ERR_MAX then
		errs[table.remove(order, 1)] = nil
		evicted = evicted + 1
	end
	errs[key] = {
		msg = str:sub(1, 500), stack = fmtStack(stack):sub(1, 1200), realm = tostring(realm),
		addon = title and ("%s (%s)"):format(tostring(title), tostring(id)) or "unknown/base",
		count = 1, first = os.date("%H:%M:%S"), last = os.date("%H:%M:%S"),
	}
	order[#order + 1] = key
end)

---------------------------------------------------------------- helpers
local out, warns, models
local function R(f, ...) out[#out + 1] = select("#", ...) > 0 and f:format(...) or f end
local function W(s) warns[#warns + 1] = s end
local function say(ply, s)
	if SERVER then
		if IsValid(ply) then ply:ChatPrint(s) end
		MsgN(s)
	else
		chat.AddText(Color(120, 200, 255), s)
	end
end
local function top(t, n) -- map key->number  =>  sorted array of {key, number}
	local a = {}
	for k, v in pairs(t) do a[#a + 1] = { k, v } end
	table.sort(a, function(x, y) return x[2] > y[2] end)
	for i = #a, n + 1, -1 do a[i] = nil end
	return a
end
local function ownerName(e)
	local o = e.CPPIGetOwner and e:CPPIGetOwner() or nil
	if IsValid(o) and o:IsPlayer() then return "Player#" .. o:EntIndex() end
end
local function note(m, class)
	if not m or m == "" or m:sub(1, 1) == "*" then return end -- "*N" = map brush models
	local r = models[m]
	if not r then r = { n = 0, c = {} }; models[m] = r end
	r.n = r.n + 1
	r.c[class] = true
end

---------------------------------------------------------------- sections
local function secGame()
	R("== GAME / ENVIRONMENT ==")
	R("Realm: %s", SERVER and "SERVER" or "CLIENT")
	R("GMod: %s (%s) branch=%s", tostring(VERSION), tostring(VERSIONSTR), tostring(BRANCH))
	R("LuaJIT: %s os=%s arch=%s", tostring(jit.version), tostring(jit.os), tostring(jit.arch))
	R("Map: %s | Gamemode: %s (folder %s)", game.GetMap(), tostring(GAMEMODE and GAMEMODE.Name), engine.ActiveGamemode())
	R("SinglePlayer=%s Players=%d/%d Uptime(CurTime)=%.0fs", tostring(game.SinglePlayer()), #player.GetAll(), game.MaxPlayers(), CurTime())
	R("Report time: %s", os.date("%Y-%m-%d %H:%M:%S"))
	local cvars
	if SERVER then
		R("Hostname: %s | DedicatedServer=%s | Tickrate=%.1f", GetHostName(), tostring(game.IsDedicated()), 1 / engine.TickInterval())
		cvars = { "sv_cheats", "host_timescale", "sv_gravity", "sv_allowcslua", "sv_lan", "sv_tags" }
	else
		R("Resolution: %dx%d | DXLevel=%s | WindowFocus=%s", ScrW(), ScrH(), tostring(render.GetDXLevel()), tostring(system.HasFocus()))
		cvars = { "fps_max", "mat_vsync", "gmod_mcore_test", "mat_queue_mode", "cl_interp", "cl_interp_ratio", "cl_updaterate", "cl_cmdrate", "cl_showfps" }
	end
	for _, n in ipairs(cvars) do
		local cv = GetConVar(n)
		if cv then R("ConVar %s = %s", n, cv:GetString()) end
	end
	R("")
end

local function secAddons()
	R("== MOUNTED / SUBSCRIBED WORKSHOP ADDONS ==")
	local list = engine.GetAddons()
	R("Count: %d", #list)
	for _, a in ipairs(list) do
		R("[%s%s] wsid=%s | %s | %.1f MB | updated=%s", a.mounted and "mounted" or "NOT MOUNTED", a.downloaded and "" or ",NOT DOWNLOADED",
			tostring(a.wsid), tostring(a.title), (tonumber(a.size) or 0) / 1048576, a.updated and os.date("%Y-%m-%d", a.updated) or "?")
		if not a.mounted then W(("Workshop addon not mounted: %s (%s)"):format(tostring(a.title), tostring(a.wsid))) end
	end
	R("")
	R("== MOUNTED GAMES (content) ==")
	for _, g in ipairs(engine.GetGames()) do
		R("%s [%s] installed=%s mounted=%s owned=%s", tostring(g.title), tostring(g.folder), tostring(g.installed), tostring(g.mounted), tostring(g.owned))
	end
	R("")
	R("== LOCAL addons/ FOLDERS ==")
	local _, dirs = file.Find("addons/*", "MOD")
	R("%s", #dirs > 0 and table.concat(dirs, ", ") or "(none)")
	R("")
end

local function secPlayers()
	R("== PLAYERS (names/SteamIDs/IPs intentionally omitted) ==")
	if CLIENT then R("Note: client sees weapons of other players only when networked to it.") end
	for _, p in ipairs(player.GetAll()) do
		local aw = p:GetActiveWeapon()
		local ws = {}
		for _, w in ipairs(p:GetWeapons()) do ws[#ws + 1] = ("%s(clip %d)"):format(w:GetClass(), w:Clip1()) end
		R("Player#%d%s team=%s hp=%d armor=%d alive=%s bot=%s ping=%d admin=%s model=%s",
			p:EntIndex(), (CLIENT and p == LocalPlayer()) and "(you)" or "", team.GetName(p:Team()), p:Health(), p:Armor(),
			tostring(p:Alive()), tostring(p:IsBot()), p:Ping(), tostring(p:IsAdmin()), p:GetModel())
		R("   active=%s | weapons: %s", IsValid(aw) and aw:GetClass() or "none", #ws > 0 and table.concat(ws, ", ") or "none")
		note(p:GetModel(), "player")
	end
	R("")
end

local function secEnts()
	R("== ENTITIES ==")
	local all = ents.GetAll()
	R("Total: %d%s", #all, (SERVER and ents.GetEdictCount) and (" | edicts " .. ents.GetEdictCount() .. "/8192") or "")
	if SERVER and ents.GetEdictCount and ents.GetEdictCount() > 7000 then W("Edict count near the 8192 engine limit: " .. ents.GetEdictCount()) end
	local cls, mapN, spawned, byOwner = {}, {}, {}, {}
	for _, e in ipairs(all) do
		local c = e:GetClass()
		cls[c] = (cls[c] or 0) + 1
		note(e:GetModel(), c)
		if e:CreatedByMap() then
			mapN[c] = (mapN[c] or 0) + 1
		elseif not e:IsPlayer() then
			spawned[#spawned + 1] = e
			local o = ownerName(e)
			if o then byOwner[o] = (byOwner[o] or 0) + 1 end
		end
	end
	R("-- by class (top %d): class: total (from map)", TOP * 2)
	for _, kv in ipairs(top(cls, TOP * 2)) do R("%s: %d (%d)", kv[1], kv[2], mapN[kv[1]] or 0) end
	if next(byOwner) then
		R("-- spawned entities per owner (prop protection CPPI):")
		for _, kv in ipairs(top(byOwner, 10)) do R("%s: %d", kv[1], kv[2]) end
	end
	R("-- spawned (non-map) entities, max 1000: #idx class | model | pos | hp | owner")
	for i = 1, math.min(#spawned, 1000) do
		local e = spawned[i]
		local o = e:GetOwner()
		R("#%d %s | %s | %d %d %d | hp %d | %s%s", e:EntIndex(), e:GetClass(), e:GetModel() or "-", e:GetPos().x, e:GetPos().y, e:GetPos().z,
			e:Health(), ownerName(e) or (IsValid(o) and o:GetClass()) or "-", (CLIENT and e:IsDormant()) and " | dormant" or "")
	end
	if #spawned > 1000 then R("... %d more not listed", #spawned - 1000) end
	R("")
end

local function secModels()
	R("== MODELS USED BY ENTITIES (does the model exist on THIS %s?) ==", SERVER and "server" or "client")
	local cnt, bad = {}, {}
	for m, r in pairs(models) do cnt[m] = r.n end
	local lines, shown = {}, 0
	for _, kv in ipairs(top(cnt, 1e9)) do
		local m = kv[1]
		local valid, exists = util.IsValidModel(m), file.Exists(m, "GAME")
		local used = {}
		for c in pairs(models[m].c) do if #used < 5 then used[#used + 1] = c end end
		local line = ("%s | uses=%d | valid=%s file=%s | by: %s"):format(m, kv[2], tostring(valid), tostring(exists), table.concat(used, ","))
		if not valid or not exists or m == "models/error.mdl" then
			bad[#bad + 1] = line
			W(("Missing/invalid model on %s: %s (used by %s)"):format(SERVER and "SERVER" or "CLIENT", m, table.concat(used, ",")))
		elseif shown < 150 then
			shown = shown + 1
			lines[#lines + 1] = line
		end
	end
	R("-- PROBLEM models: %d", #bad)
	for _, l in ipairs(bad) do R("ERROR %s", l) end
	R("-- valid models (top 150 by usage):")
	for _, l in ipairs(lines) do R("%s", l) end
	R("")
end

local function secLua()
	R("== LUA ENVIRONMENT ==")
	R("Lua memory: %.1f MB", collectgarbage("count") / 1024)
	R("Scripted ents: %d | weapons: %d | concommands: %d", table.Count(scripted_ents.GetList()), #weapons.GetList(), table.Count(concommand.GetTable()))
	local n = {}
	for ev, t in pairs(hook.GetTable()) do n[ev] = table.Count(t) end
	R("-- hook events with the most handlers (event: count | identifiers)")
	for _, kv in ipairs(top(n, 15)) do
		local ids = {}
		for id in pairs(hook.GetTable()[kv[1]]) do
			if #ids < 25 then ids[#ids + 1] = tostring(id) end
		end
		R("%s: %d | %s%s", kv[1], kv[2], table.concat(ids, ", "), kv[2] > 25 and ", ..." or "")
	end
	R("")
end

local function secErrors(P)
	R("== LUA ERRORS (RAM buffer: before the command + during the test) ==")
	local total = 0
	for _, e in pairs(errs) do total = total + e.count end
	R("Distinct: %d | Occurrences: %d | Evicted (buffer full, max %d): %d | Errors from before the addon loaded are not captured", #order, total, ERR_MAX, evicted)
	if #order > 0 then W(("%d distinct Lua error(s) recorded on %s"):format(#order, SERVER and "SERVER" or "CLIENT")) end
	for i = #order, 1, -1 do -- newest first
		local e = errs[order[i]]
		local d = e.count - (P.err0[order[i]] or 0)
		R("[x%d%s] realm=%s addon=%s first=%s last=%s", e.count, d > 0 and (", " .. d .. " DURING TEST") or "", e.realm, e.addon, e.first, e.last)
		R("   %s", e.msg:gsub("\n", "\n   "))
		if e.stack ~= "" then R("   stack:\n      %s", e.stack) end
	end
	R("")
end

local function secProfile(P)
	local wall = P.t1 - P.t0
	R("== %d-SECOND TEST (%s) ==", TEST_SECS, SERVER and "server" or "client")
	R("Wall time: %.1fs | Lua memory: %.1f MB -> %.1f MB (%+.1f MB) | Entities: %d -> %d", wall, P.mem0 / 1024, P.mem1 / 1024, (P.mem1 - P.mem0) / 1024, P.ents0, P.ents1)
	local f = P.frames
	if #f > 10 then
		local sum, spikes = 0, 0
		for _, v in ipairs(f) do sum = sum + v; if v > 0.1 then spikes = spikes + 1 end end
		table.sort(f, function(a, b) return a > b end)
		local k = math.max(1, math.floor(#f * 0.01))
		local w = 0
		for i = 1, k do w = w + f[i] end
		local avg, low = #f / sum, k / w
		R("%s: avg %.1f/s | 1%% low %.1f/s | worst frame %.0f ms | spikes >100ms: %d", SERVER and "Think rate" or "FPS", avg, low, f[1] * 1000, spikes)
		if SERVER and avg < 0.8 / engine.TickInterval() then W(("Server runs below its tickrate during test: %.1f/s (expected %.1f)"):format(avg, 1 / engine.TickInterval())) end
		if CLIENT and low < 20 then W(("Client 1%% low FPS is %.1f during the test"):format(low)) end
		if spikes > 0 then W(spikes .. " frame(s) longer than 100 ms during the test") end
	end
	R("")
	R("-- Lua CPU samples: 1 sample per %d VM instructions, JIT disabled during test. Time inside C/engine code (render, physics) is NOT attributed.", SAMPLE_EVERY)
	R("Total samples: %d", P.samples)
	R("-- top files (samples, share)")
	local tops = top(P.files, TOP)
	for _, kv in ipairs(tops) do R("%6d  %5.1f%%  %s", kv[2], 100 * kv[2] / math.max(P.samples, 1), kv[1]) end
	if tops[1] and tops[1][2] > 0.3 * P.samples and P.samples > 200 then W(("Hot Lua file during test: %s (%.0f%% of samples)"):format(tops[1][1], 100 * tops[1][2] / P.samples)) end
	R("-- top functions (file:linedefined)")
	for _, kv in ipairs(top(P.funcs, TOP)) do R("%6d  %5.1f%%  %s", kv[2], 100 * kv[2] / math.max(P.samples, 1), kv[1]) end
	R("-- time spent in hook.Call per event (nested hooks are double counted)")
	for _, kv in ipairs(top(P.hooks, TOP)) do R("%8.1f ms  %5.1f%% of wall  %s", kv[2] * 1000, 100 * kv[2] / wall, kv[1]) end
	R("")
end

---------------------------------------------------------------- profiler
local P, origCall, wrapper -- P = current test state (nil when idle)

local function fin(name, t, ...)
	if P then P.hooks[name] = (P.hooks[name] or 0) + SysTime() - t end
	return ...
end

local function startTest()
	P = { t0 = SysTime(), mem0 = collectgarbage("count"), ents0 = #ents.GetAll(), err0 = {}, frames = {}, files = {}, funcs = {}, hooks = {}, samples = 0 }
	for k, e in pairs(errs) do P.err0[k] = e.count end
	P.jitWas = jit.status()
	if P.jitWas then jit.off() end -- JIT-compiled code does not trigger debug hooks
	local last
	hook.Add("Think", "GLRS_Frame", function()
		local n = SysTime()
		if last and P and #P.frames < 20000 then P.frames[#P.frames + 1] = n - last end
		last = n
	end)
	origCall = hook.Call
	wrapper = function(name, gm, ...) return fin(name, SysTime(), origCall(name, gm, ...)) end
	hook.Call = wrapper
	debug.sethook(function()
		local i = debug.getinfo(2, "S")
		if not i or not P then return end
		P.samples = P.samples + 1
		P.files[i.short_src] = (P.files[i.short_src] or 0) + 1
		local k = i.short_src .. ":" .. i.linedefined
		P.funcs[k] = (P.funcs[k] or 0) + 1
	end, "", SAMPLE_EVERY)
end

local function stopTest() -- always restores everything first
	debug.sethook()
	if P.jitWas then jit.on() end
	hook.Remove("Think", "GLRS_Frame")
	if hook.Call == wrapper then hook.Call = origCall end -- if another addon wrapped us, leave inert wrapper (P=nil => no-op)
	P.t1, P.mem1, P.ents1 = SysTime(), collectgarbage("count"), #ents.GetAll()
	local r = P
	P = nil
	return r
end

---------------------------------------------------------------- report
local running = false

local function build(T)
	out, warns, models = {}, {}, {}
	secGame(); secAddons(); secPlayers(); secEnts(); secModels(); secLua(); secErrors(T); secProfile(T)
	local head = {
		"GLRS REPORT v1 (" .. (SERVER and "SERVER" or "CLIENT") .. ")",
		"Format: sections '== NAME =='. Read '== PROBLEMS DETECTED ==' first; details are below. Intended for addon authors and AI analysis.",
		"",
		"== PROBLEMS DETECTED ==",
	}
	if #warns == 0 then head[#head + 1] = "none detected automatically" end
	for _, w in ipairs(warns) do head[#head + 1] = "- " .. w end
	head[#head + 1] = ""
	return table.concat(head, "\n") .. "\n" .. table.concat(out, "\n")
end

local function runReport(ply)
	if running then return say(ply, "[GLRS] A test is already running.") end
	running = true
	say(ply, ("[GLRS] %s report: %d s test started, play normally."):format(SERVER and "Server" or "Client", TEST_SECS))
	startTest()
	timer.Simple(TEST_SECS, function()
		local T = stopTest()
		local ok, err = pcall(function()
			local name = ("glrs_reports/%s_%s.txt"):format(SERVER and "server" or "client", os.date("%Y%m%d_%H%M%S"))
			file.CreateDir("glrs_reports")
			file.Write(name, build(T))
			say(ply, "[GLRS] Saved: garrysmod/data/" .. name)
		end)
		running = false
		if not ok then say(ply, "[GLRS] Failed: " .. tostring(err)) end
	end)
end

---------------------------------------------------------------- entry points
if SERVER then
	util.AddNetworkString("glrs_req")
	util.AddNetworkString("glrs_run")

	local function request(ply)
		if (ply.glrsNext or 0) > CurTime() then return end
		ply.glrsNext = CurTime() + 5
		net.Start("glrs_run")
		net.Send(ply)
		if ply:IsAdmin() or game.SinglePlayer() then
			runReport(ply)
		else
			say(ply, "[GLRS] Server report is admin-only; only your client report is made.")
		end
	end

	net.Receive("glrs_req", function(_, ply) request(ply) end)
	hook.Add("PlayerSay", "GLRS", function(ply, txt)
		if txt:Trim():lower() == "!glrs" then request(ply) return "" end
	end)
	concommand.Add("glrs_report", function(ply) if not IsValid(ply) then runReport() end end) -- server console / rcon
else
	concommand.Add("glrs_report", function()
		net.Start("glrs_req")
		net.SendToServer()
	end)
	net.Receive("glrs_run", function() runReport() end)
end
