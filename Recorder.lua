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
  SPELL_HEAL = "heal", SPELL_PERIODIC_HEAL = "heal",
  SPELL_INTERRUPT = "interrupt", SPELL_DISPEL = "dispel",
  UNIT_DIED = "death",
}

-- Same idea as Gladdy: instance type + active battlefield + arena opponents.
-- IsActiveBattlefieldArena() alone is FALSE in the waiting room / countdown.
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
  -- Battlefield status (skirmish / rated) while the match is active
  if type(GetMaxBattlefieldID) == "function" and type(GetBattlefieldStatus) == "function" then
    for i = 1, GetMaxBattlefieldID() do
      local status, mapName, _, _, _, teamSize = GetBattlefieldStatus(i)
      if status == "active" and teamSize and teamSize > 0 then
        -- teamSize > 0 distinguishes arena from many BGs
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
  local players = {}
  if UnitExists("player") then
    local _, class = UnitClass("player")
    local guid = UnitGUID("player")
    if guid then
      players[guid] = { name = UnitName("player"), class = class, side = "friendly" }
    end
  end
  for i = 1, 4 do
    local unit = "party" .. i
    if UnitExists(unit) then
      local _, class = UnitClass(unit)
      local guid = UnitGUID(unit)
      if guid then
        players[guid] = { name = UnitName(unit), class = class, side = "friendly" }
      end
    end
  end
  for i = 1, 5 do
    local unit = "arena" .. i
    if UnitExists(unit) then
      local _, class = UnitClass(unit)
      local guid = UnitGUID(unit)
      if guid then
        players[guid] = { name = UnitName(unit), class = class, side = "enemy" }
      end
    end
  end
  return players
end

local function startMatch(reason)
  if recording then return end
  ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }
  ArenaLogViewerDB.matches = ArenaLogViewerDB.matches or {}
  current = {
    map = GetZoneText() or "Arena",
    startedAt = date("%Y-%m-%d %H:%M"),
    startTime = GetTime(),
    events = {},
    players = snapshotRoster(),
    result = "unknown",
    deaths = {},
  }
  recording = true
  print(PREFIX .. ": |cff88ff88recording|r " .. (current.map or "arena")
    .. (reason and (" |cffaaaaaa(" .. reason .. ")|r") or ""))
  local function resnap()
    if current then current.players = snapshotRoster() end
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
  -- Always leave at least an empty timeline so the UI can list the match
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
    .. " (" .. secs .. "s, " .. eventCount .. " events) — " .. n
    .. " match" .. (n == 1 and "" or "es") .. ". |cffffffff/alv|r to view"
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

-- Fake match so you can verify the UI without queueing
function NS.InsertTestMatch()
  ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }
  ArenaLogViewerDB.matches = ArenaLogViewerDB.matches or {}
  local now = GetTime()
  local match = {
    map = "Test Arena",
    startedAt = date("%Y-%m-%d %H:%M"),
    startTime = now,
    durationMs = 45000,
    players = snapshotRoster(),
    result = "unknown",
    deaths = {},
    events = {
      { t = 1000, k = "cast", s = UnitGUID("player"), sn = UnitName("player"),
        d = UnitGUID("player"), dn = UnitName("player"), id = 5782, n = "Fear", sc = 32 },
      { t = 1000, k = "aura_apply", s = UnitGUID("player"), sn = UnitName("player"),
        d = UnitGUID("player"), dn = UnitName("player"), id = 5782, n = "Fear", sc = 32 },
      { t = 9000, k = "aura_remove", s = UnitGUID("player"), sn = UnitName("player"),
        d = UnitGUID("player"), dn = UnitName("player"), id = 5782, n = "Fear", sc = 32 },
      { t = 12000, k = "cast", s = UnitGUID("player"), sn = UnitName("player"),
        d = UnitGUID("player"), dn = UnitName("player"), id = 172, n = "Corruption", sc = 32 },
      { t = 12000, k = "aura_apply", s = UnitGUID("player"), sn = UnitName("player"),
        d = UnitGUID("player"), dn = UnitName("player"), id = 172, n = "Corruption", sc = 32 },
      { t = 30000, k = "aura_remove", s = UnitGUID("player"), sn = UnitName("player"),
        d = UnitGUID("player"), dn = UnitName("player"), id = 172, n = "Corruption", sc = 32 },
    },
  }
  match.timeline = NS.BuildTimeline(match)
  match.events = nil
  table.insert(ArenaLogViewerDB.matches, match)
  print(PREFIX .. ": inserted |cfffffffftest match|r — open |cffffffff/alv|r")
  return match
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
      -- Second pass: waiting-room → gates sometimes flips instance flags late
      C_Timer.After(2.0, function() SyncArena(event .. "+2s") end)
    else
      SyncArena(event)
    end
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" and recording and current then
    local _, sub, _, srcGUID, srcName, _, _, dstGUID, dstName, _, _,
      spellId, spellName, school = CombatLogGetCurrentEventInfo()
    local kind = TRACKED[sub]
    if not kind then return end
    if not (isPlayerGUID(srcGUID) or isPlayerGUID(dstGUID)) then return end
    local t = math.floor((GetTime() - current.startTime) * 1000)
    table.insert(current.events, {
      t = t, k = kind, s = srcGUID, sn = srcName,
      d = dstGUID, dn = dstName, id = spellId, n = spellName, sc = school,
    })
    if kind == "death" and isPlayerGUID(dstGUID) then
      table.insert(current.deaths, { name = dstName, atMs = t })
    end
  end
end)
