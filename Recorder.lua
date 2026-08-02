-- Recorder.lua — captures COMBAT_LOG_EVENT_UNFILTERED during arenas.
-- Replaces the web app's file parsing: no file I/O exists in the Lua sandbox,
-- so we record events live and persist them in SavedVariables.

local ADDON, NS = ...
ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }

local PREFIX = "|cff66bbffArena Log Viewer|r"
local MAX_MATCHES = 40

local recording = false
local current = nil -- in-progress match

local TRACKED = {
  SPELL_CAST_SUCCESS = "cast", SPELL_CAST_START = "cast_start",
  SPELL_AURA_APPLIED = "aura_apply", SPELL_AURA_REMOVED = "aura_remove",
  SPELL_AURA_REFRESH = "aura_refresh",
  SPELL_DAMAGE = "damage", SPELL_PERIODIC_DAMAGE = "damage", SWING_DAMAGE = "damage",
  RANGE_DAMAGE = "damage",
  SPELL_HEAL = "heal", SPELL_PERIODIC_HEAL = "heal",
  SPELL_INTERRUPT = "interrupt", SPELL_DISPEL = "dispel",
  UNIT_DIED = "death",
}

local function InArena()
  local _, instanceType = IsInInstance()
  if instanceType == "arena" then
    return true
  end
  if type(IsActiveBattlefieldArena) == "function" and IsActiveBattlefieldArena() then
    return true
  end
  if type(GetNumArenaOpponents) == "function" then
    local n = GetNumArenaOpponents()
    if n and n > 0 then
      return true
    end
  end
  if type(GetMaxBattlefieldID) == "function" and type(GetBattlefieldStatus) == "function" then
    for i = 1, GetMaxBattlefieldID() do
      local status, mapName, _, _, _, teamSize = GetBattlefieldStatus(i)
      if status == "active" and teamSize and teamSize > 0 then
        if instanceType == "arena" or instanceType == "pvp" then
          if mapName and (mapName:find("[Aa]rena") or mapName:find("Lordaeron")
              or mapName:find("Nagrand") or mapName:find("Blade")) then
            return true
          end
        end
      end
    end
  end
  return false
end

function NS.IsRecording()
  return recording and true or false
end

function NS.MatchCount()
  ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }
  ArenaLogViewerDB.matches = ArenaLogViewerDB.matches or {}
  return #ArenaLogViewerDB.matches
end

function NS.DebugStatus()
  local _, instanceType = IsInInstance()
  local active = (type(IsActiveBattlefieldArena) == "function") and IsActiveBattlefieldArena() or nil
  local opps = (type(GetNumArenaOpponents) == "function") and GetNumArenaOpponents() or nil
  print(PREFIX .. " status:")
  print("  zone: |cffffffff" .. tostring(GetZoneText()) .. "|r")
  print("  IsInInstance: |cffffffff" .. tostring(instanceType) .. "|r")
  print("  IsActiveBattlefieldArena: |cffffffff" .. tostring(active) .. "|r")
  print("  GetNumArenaOpponents: |cffffffff" .. tostring(opps) .. "|r")
  print("  InArena(): |cffffffff" .. tostring(InArena()) .. "|r")
  print("  recording: |cffffffff" .. tostring(recording) .. "|r")
  print("  saved matches: |cffffffff" .. NS.MatchCount() .. "|r")
  if type(GetMaxBattlefieldID) == "function" then
    for i = 1, GetMaxBattlefieldID() do
      local status, mapName, _, _, _, teamSize = GetBattlefieldStatus(i)
      if status and status ~= "none" then
        print(("  BF[%d]: status=%s map=%s teamSize=%s"):format(
          i, tostring(status), tostring(mapName), tostring(teamSize)))
      end
    end
  end
end

local function isPlayerGUID(guid)
  return type(guid) == "string" and guid:find("^Player%-") ~= nil
end

local function snapshotRoster()
  local byGuid, list = {}, {}
  local function add(unit, side)
    if not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    if not guid or byGuid[guid] then return end
    local _, class = UnitClass(unit)
    local p = { guid = guid, name = UnitName(unit), class = class, side = side }
    byGuid[guid] = p
    table.insert(list, p)
  end
  add("player", "friendly")
  for i = 1, 4 do add("party" .. i, "friendly") end
  for i = 1, 5 do add("arena" .. i, "enemy") end
  return byGuid, list
end

local function classLabel(classToken)
  if not classToken then return "?" end
  local map = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
    PRIEST = "Priest", DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman", MAGE = "Mage",
    WARLOCK = "Warlock", MONK = "Monk", DRUID = "Druid", DEMONHUNTER = "Demon Hunter",
  }
  return map[classToken] or classToken
end

function NS.ClassLabel(classToken)
  return classLabel(classToken)
end

function NS.PlayerList(match)
  if not match then return {} end
  if type(match.playerList) == "table" and #match.playerList > 0 then
    return match.playerList
  end
  local list = {}
  if type(match.players) == "table" then
    for k, p in pairs(match.players) do
      if type(p) == "table" and p.name then
        if not p.guid and type(k) == "string" then p.guid = k end
        table.insert(list, p)
      end
    end
  end
  table.sort(list, function(a, b)
    if a.side == b.side then return (a.name or "") < (b.name or "") end
    return a.side == "friendly"
  end)
  return list
end

local function buildStats(match)
  local dmg, heal = {}, {}
  for _, ev in ipairs(match.events or {}) do
    if ev.k == "damage" and ev.s and ev.amount then
      dmg[ev.s] = (dmg[ev.s] or 0) + ev.amount
    elseif ev.k == "heal" and ev.s and ev.amount then
      heal[ev.s] = (heal[ev.s] or 0) + ev.amount
    end
  end
  local stats = {}
  for _, p in ipairs(NS.PlayerList(match)) do
    table.insert(stats, {
      guid = p.guid, name = p.name,
      damage = dmg[p.guid] or 0,
      healing = heal[p.guid] or 0,
    })
  end
  return stats
end

local function inferResult(match)
  local enemyDead, friendDead = 0, 0
  local byGuid = match.players or {}
  for _, d in ipairs(match.deaths or {}) do
    local p = (d.guid and byGuid[d.guid]) or nil
    if not p then
      for _, q in pairs(byGuid) do
        if type(q) == "table" and q.name == d.name then p = q; break end
      end
    end
    if p then
      if p.side == "enemy" then enemyDead = enemyDead + 1
      elseif p.side == "friendly" then friendDead = friendDead + 1 end
    end
  end
  if enemyDead > friendDead then return "WIN" end
  if friendDead > enemyDead then return "LOSS" end
  return "unknown"
end

local function startMatch(reason)
  if recording then return end
  ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }
  ArenaLogViewerDB.matches = ArenaLogViewerDB.matches or {}
  local byGuid, list = snapshotRoster()
  current = {
    map = GetZoneText() or "Arena",
    startedAt = date("%H:%M"),
    startTime = GetTime(),
    events = {},
    players = byGuid,
    playerList = list,
    result = "unknown",
    deaths = {},
  }
  recording = true
  print(PREFIX .. ": |cff88ff88recording|r " .. (current.map or "arena")
    .. (reason and (" |cffaaaaaa(" .. reason .. ")|r") or ""))
  local function resnap()
    if not current then return end
    local g, l = snapshotRoster()
    current.players = g
    current.playerList = l
  end
  if C_Timer and C_Timer.After then
    C_Timer.After(2, resnap)
    C_Timer.After(8, resnap)
  end
end

local function endMatch(reason)
  if not current then
    recording = false
    return
  end
  recording = false
  current.durationMs = math.floor((GetTime() - current.startTime) * 1000)
  current.stats = buildStats(current)
  current.result = inferResult(current)
  if type(NS.BuildTimeline) == "function" and current.events then
    local ok, timeline = pcall(NS.BuildTimeline, current)
    current.timeline = (ok and timeline) or {}
    if not ok then
      print(PREFIX .. ": |cffff8888timeline build failed|r — " .. tostring(timeline))
    end
  else
    current.timeline = {}
  end
  local eventCount = current.events and #current.events or 0
  current.events = nil
  ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }
  ArenaLogViewerDB.matches = ArenaLogViewerDB.matches or {}
  table.insert(ArenaLogViewerDB.matches, current)
  while #ArenaLogViewerDB.matches > MAX_MATCHES do
    table.remove(ArenaLogViewerDB.matches, 1)
  end
  local n = #ArenaLogViewerDB.matches
  local secs = math.floor((current.durationMs or 0) / 1000)
  print(PREFIX .. ": |cff88ff88saved|r " .. (current.map or "?")
    .. " (" .. secs .. "s, " .. eventCount .. " events, " .. (current.result or "?")
    .. ") — " .. n .. " match" .. (n == 1 and "" or "es")
    .. ". |cffffffff/alv|r to view"
    .. (reason and (" |cffaaaaaa(" .. reason .. ")|r") or ""))
  current = nil
end

local function SyncArena(reason)
  local inArena = InArena()
  if inArena and not recording then
    startMatch(reason)
  elseif not inArena and recording then
    endMatch(reason)
  end
end

function NS.InsertTestMatch()
  if NS.LoadDemoMatches then
    return NS.LoadDemoMatches()
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA"
      or event == "UPDATE_BATTLEFIELD_STATUS" then
    if C_Timer and C_Timer.After then
      C_Timer.After(0.25, function() SyncArena(event) end)
      C_Timer.After(2.0, function() SyncArena(event .. "+2s") end)
    else
      SyncArena(event)
    end
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" and recording and current then
    local timestamp, sub, hideCaster, srcGUID, srcName, srcFlags, srcRaidFlags,
      dstGUID, dstName, dstFlags, dstRaidFlags, arg12, arg13, arg14, arg15 =
      CombatLogGetCurrentEventInfo()
    local kind = TRACKED[sub]
    if not kind then return end
    if not (isPlayerGUID(srcGUID) or isPlayerGUID(dstGUID)) then return end
    local t = math.floor((GetTime() - current.startTime) * 1000)
    local spellId, spellName, school, amount
    if sub == "SWING_DAMAGE" then
      spellId, spellName, school = 0, "Melee", 1
      amount = tonumber(arg12) or 0
    elseif sub == "UNIT_DIED" then
      spellId, spellName, school = nil, nil, nil
    else
      spellId, spellName, school = arg12, arg13, arg14
      if kind == "damage" or kind == "heal" then
        amount = tonumber(arg15) or 0
      end
    end
    table.insert(current.events, {
      t = t, k = kind, s = srcGUID, sn = srcName,
      d = dstGUID, dn = dstName, id = spellId, n = spellName, sc = school,
      amount = amount,
    })
    if kind == "death" and isPlayerGUID(dstGUID) then
      table.insert(current.deaths, { name = dstName, guid = dstGUID, atMs = t })
    end
  end
end)
