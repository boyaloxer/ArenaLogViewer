-- Demo.lua — rich sample matches so /alv test matches the designed UI mockup.
-- These are fixtures, not live arenas. Real matches come from the CLEU recorder.

local ADDON, NS = ...

local function guid(n)
  return ("Player-0-DEMO%04d"):format(n)
end

local function player(id, name, class, side)
  return { guid = guid(id), name = name, class = class, side = side }
end

local function aura(t0, t1, src, sn, dst, dn, id, name, school)
  return {
    { t = t0, k = "cast", s = src, sn = sn, d = dst, dn = dn, id = id, n = name, sc = school },
    { t = t0, k = "aura_apply", s = src, sn = sn, d = dst, dn = dn, id = id, n = name, sc = school },
    { t = t1, k = "aura_remove", s = src, sn = sn, d = dst, dn = dn, id = id, n = name, sc = school },
  }
end

local function cast(t, src, sn, dst, dn, id, name, school)
  return { t = t, k = "cast", s = src, sn = sn, d = dst, dn = dn, id = id, n = name, sc = school }
end

local function flatten(...)
  local out = {}
  for i = 1, select("#", ...) do
    local chunk = select(i, ...)
    if chunk[1] and chunk[1].k then
      for _, ev in ipairs(chunk) do table.insert(out, ev) end
    else
      table.insert(out, chunk)
    end
  end
  table.sort(out, function(a, b) return a.t < b.t end)
  return out
end

local function rosterList(...)
  local list, byGuid = {}, {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    table.insert(list, p)
    byGuid[p.guid] = p
  end
  return list, byGuid
end

local function buildMatch(opts)
  local list, byGuid = rosterList(unpack(opts.players))
  local match = {
    id = opts.id,
    isDemo = true,
    map = opts.map,
    startedAt = opts.startedAt,
    durationMs = opts.durationMs,
    result = opts.result,
    players = byGuid,
    playerList = list,
    deaths = opts.deaths or {},
    stats = opts.stats or {},
    events = opts.events,
  }
  match.timeline = NS.BuildTimeline(match)
  match.events = nil
  return match
end

-- Spell IDs (TBC-ish) used for icons
local SID = {
  MS = 30330, SWP = 25368, KS = 8643, PWS = 25218, PS = 10890,
  IS = 5246, RG = 26980, Blind = 2094, CY = 33786, EV = 26669,
  CS = 26861, Gouge = 38764, Haunt = 27216, Fear = 6215, Hex = 51514,
  Scatter = 19503, HoJ = 10308, Sap = 11297,
}

function NS.BuildDemoMatches()
  -- Mockup roster: Vexara = Rogue (dmg), Solenne = Priest (heals)
  local V, S, G, T = guid(1), guid(2), guid(3), guid(4)
  local m3 = buildMatch({
    id = "demo-3",
    map = "Nagrand Arena",
    startedAt = "19:42",
    durationMs = 95000,
    result = "WIN",
    players = {
      player(1, "Vexara", "ROGUE", "friendly"),
      player(2, "Solenne", "PRIEST", "friendly"),
      player(3, "Gorehowl", "WARRIOR", "enemy"),
      player(4, "Thornweave", "DRUID", "enemy"),
    },
    deaths = { { name = "Gorehowl", guid = G, atMs = 89200 } },
    stats = {
      { guid = V, name = "Vexara", damage = 18240, healing = 1105 },
      { guid = S, name = "Solenne", damage = 2410, healing = 24890 },
      { guid = G, name = "Gorehowl", damage = 21733, healing = 0 },
      { guid = T, name = "Thornweave", damage = 4102, healing = 19340 },
    },
    events = flatten(
      aura(2000, 8000, G, "Gorehowl", V, "Vexara", SID.MS, "Mortal Strike", 1),
      cast(2500, G, "Gorehowl", V, "Vexara", SID.MS, "Mortal Strike", 1),
      aura(4000, 22000, S, "Solenne", G, "Gorehowl", SID.SWP, "Shadow Word: Pain", 32),
      aura(9000, 15000, V, "Vexara", G, "Gorehowl", SID.KS, "Kidney Shot", 1),
      aura(12000, 28000, S, "Solenne", V, "Vexara", SID.PWS, "Power Word: Shield", 2),
      aura(18000, 26000, S, "Solenne", G, "Gorehowl", SID.PS, "Psychic Scream", 32),
      aura(20000, 28000, G, "Gorehowl", V, "Vexara", SID.IS, "Intimidating Shout", 1),
      aura(24000, 36000, T, "Thornweave", G, "Gorehowl", SID.RG, "Regrowth", 8),
      aura(32000, 42000, V, "Vexara", T, "Thornweave", SID.Blind, "Blind", 1),
      aura(40000, 46000, T, "Thornweave", V, "Vexara", SID.CY, "Cyclone", 8),
      aura(50000, 65000, V, "Vexara", V, "Vexara", SID.EV, "Evasion", 1),
      aura(55000, 70000, S, "Solenne", G, "Gorehowl", SID.SWP, "Shadow Word: Pain", 32),
      aura(62000, 70000, V, "Vexara", G, "Gorehowl", SID.KS, "Kidney Shot", 1),
      aura(72000, 88000, S, "Solenne", V, "Vexara", SID.PWS, "Power Word: Shield", 2),
      cast(78000, G, "Gorehowl", V, "Vexara", SID.MS, "Mortal Strike", 1),
      aura(80000, 92000, T, "Thornweave", T, "Thornweave", SID.RG, "Regrowth", 8)
    ),
  })

  local W, H = guid(5), guid(6)
  local m2 = buildMatch({
    id = "demo-2",
    map = "Blade's Edge Arena",
    startedAt = "19:31",
    durationMs = 168000,
    result = "LOSS",
    players = {
      player(1, "Vexara", "ROGUE", "friendly"),
      player(2, "Solenne", "PRIEST", "friendly"),
      player(5, "Voidmark", "WARLOCK", "enemy"),
      player(6, "Tidecaller", "SHAMAN", "enemy"),
    },
    deaths = { { name = "Vexara", guid = V, atMs = 161000 } },
    stats = {
      { guid = V, name = "Vexara", damage = 14210, healing = 0 },
      { guid = S, name = "Solenne", damage = 3200, healing = 31200 },
      { guid = W, name = "Voidmark", damage = 19880, healing = 400 },
      { guid = H, name = "Tidecaller", damage = 8900, healing = 24500 },
    },
    events = flatten(
      aura(3000, 18000, W, "Voidmark", V, "Vexara", SID.Haunt, "Corruption", 32),
      aura(8000, 16000, W, "Voidmark", S, "Solenne", SID.Fear, "Fear", 32),
      aura(14000, 20000, V, "Vexara", W, "Voidmark", SID.KS, "Kidney Shot", 1),
      aura(22000, 40000, S, "Solenne", V, "Vexara", SID.PWS, "Power Word: Shield", 2),
      aura(30000, 38000, H, "Tidecaller", V, "Vexara", 10414, "Earth Shock", 8),
      aura(45000, 55000, V, "Vexara", H, "Tidecaller", SID.Blind, "Blind", 1),
      aura(60000, 78000, S, "Solenne", W, "Voidmark", SID.SWP, "Shadow Word: Pain", 32),
      aura(90000, 105000, V, "Vexara", V, "Vexara", SID.EV, "Evasion", 1),
      aura(120000, 140000, W, "Voidmark", V, "Vexara", SID.Fear, "Fear", 32)
    ),
  })

  local Hu, Pa = guid(7), guid(8)
  local m1 = buildMatch({
    id = "demo-1",
    map = "Nagrand Arena",
    startedAt = "19:24",
    durationMs = 58000,
    result = "WIN",
    players = {
      player(1, "Vexara", "ROGUE", "friendly"),
      player(2, "Solenne", "PRIEST", "friendly"),
      player(7, "Bowstring", "HUNTER", "enemy"),
      player(8, "Lightbrand", "PALADIN", "enemy"),
    },
    deaths = { { name = "Bowstring", guid = Hu, atMs = 54000 } },
    stats = {
      { guid = V, name = "Vexara", damage = 9800, healing = 0 },
      { guid = S, name = "Solenne", damage = 1100, healing = 14200 },
      { guid = Hu, name = "Bowstring", damage = 7200, healing = 0 },
      { guid = Pa, name = "Lightbrand", damage = 2100, healing = 9800 },
    },
    events = flatten(
      aura(2000, 8000, V, "Vexara", Hu, "Bowstring", SID.Sap, "Sap", 1),
      aura(9000, 15000, V, "Vexara", Hu, "Bowstring", SID.KS, "Kidney Shot", 1),
      aura(10000, 25000, S, "Solenne", Hu, "Bowstring", SID.SWP, "Shadow Word: Pain", 32),
      aura(16000, 30000, S, "Solenne", V, "Vexara", SID.PWS, "Power Word: Shield", 2),
      aura(28000, 34000, Pa, "Lightbrand", V, "Vexara", SID.HoJ, "Hammer of Justice", 2),
      cast(40000, V, "Vexara", Hu, "Bowstring", 1833, "Cheap Shot", 1),
      aura(40000, 44000, V, "Vexara", Hu, "Bowstring", 1833, "Cheap Shot", 1),
      aura(48000, 56000, V, "Vexara", V, "Vexara", SID.EV, "Evasion", 1)
    ),
  })

  return { m1, m2, m3 }
end

function NS.LoadDemoMatches()
  ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }
  ArenaLogViewerDB.matches = ArenaLogViewerDB.matches or {}
  -- Drop previous demos; keep any live-recorded matches
  local kept = {}
  for _, m in ipairs(ArenaLogViewerDB.matches) do
    if not m.isDemo then table.insert(kept, m) end
  end
  for _, m in ipairs(NS.BuildDemoMatches()) do
    table.insert(kept, m)
  end
  ArenaLogViewerDB.matches = kept
  print("|cff66bbffArena Log Viewer|r: loaded |cffffffff3 demo matches|r (mockup sample). Live arenas still record separately.")
  return kept
end
