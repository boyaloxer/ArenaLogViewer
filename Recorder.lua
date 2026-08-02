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

-- Prefer IsInInstance(): IsActiveBattlefieldArena() is FALSE in the waiting
-- room / countdown, so PEW alone would miss the match start.
local function InArena()
  local _, instanceType = IsInInstance()
  if instanceType == "arena" then
    return true
  end
  if type(IsActiveBattlefieldArena) == "function" and IsActiveBattlefieldArena() then
    return true
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

local function isPlayerGUID(guid)
  return guid and guid:find("^Player%-") ~= nil
end

local function snapshotRoster()
  local players = {}
  -- Always include the player
  if UnitExists("player") then
    local _, class = UnitClass("player")
    players[UnitGUID("player")] = { name = UnitName("player"), class = class, side = "friendly" }
  end
  for i = 1, 4 do
    local unit = "party" .. i
    if UnitExists(unit) then
      local _, class = UnitClass(unit)
      players[UnitGUID(unit)] = { name = UnitName(unit), class = class, side = "friendly" }
    end
  end
  for i = 1, 5 do
    local unit = "arena" .. i
    if UnitExists(unit) then
      local _, class = UnitClass(unit)
      players[UnitGUID(unit)] = { name = UnitName(unit), class = class, side = "enemy" }
    end
  end
  return players
end

local function startMatch()
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
  print(PREFIX .. ": |cff88ff88recording|r " .. (current.map or "arena"))
  -- Roster / names often populate a few seconds after zone-in.
  if C_Timer and C_Timer.After then
    C_Timer.After(3, function()
      if current then current.players = snapshotRoster() end
    end)
    C_Timer.After(10, function()
      if current then current.players = snapshotRoster() end
    end)
  end
end

local function endMatch()
  if not current then
    recording = false
    return
  end
  recording = false
  current.durationMs = math.floor((GetTime() - current.startTime) * 1000)
  local ok, timeline = pcall(NS.BuildTimeline, current)
  if ok then
    current.timeline = timeline
  else
    current.timeline = {}
    print(PREFIX .. ": |cffff8888timeline build failed|r — match still saved (" .. tostring(timeline) .. ")")
  end
  current.events = nil -- keep SavedVariables small
  ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }
  ArenaLogViewerDB.matches = ArenaLogViewerDB.matches or {}
  table.insert(ArenaLogViewerDB.matches, current)
  while #ArenaLogViewerDB.matches > MAX_MATCHES do
    table.remove(ArenaLogViewerDB.matches, 1)
  end
  local n = #ArenaLogViewerDB.matches
  local secs = math.floor((current.durationMs or 0) / 1000)
  print(PREFIX .. ": |cff88ff88saved|r " .. (current.map or "?") .. " (" .. secs .. "s) — " .. n .. " match" .. (n == 1 and "" or "es") .. " stored. |cffffffff/alv|r to view.")
  current = nil
end

local function SyncArena()
  local inArena = InArena()
  if inArena and not recording then
    startMatch()
  elseif not inArena and recording then
    endMatch()
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
    -- Defer one frame so IsInInstance() is reliable after zone load.
    if C_Timer and C_Timer.After then
      C_Timer.After(0.5, SyncArena)
    else
      SyncArena()
    end
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" and recording and current then
    local ts, sub, _, srcGUID, srcName, _, _, dstGUID, dstName, _, _,
      spellId, spellName, school, amount = CombatLogGetCurrentEventInfo()
    local kind = TRACKED[sub]
    if not kind then return end
    if not (isPlayerGUID(srcGUID) or isPlayerGUID(dstGUID)) then return end
    local t = math.floor((GetTime() - current.startTime) * 1000)
    table.insert(current.events, {
      t = t, k = kind, s = srcGUID, sn = srcName,
      d = dstGUID, dn = dstName, id = spellId, n = spellName, sc = school, a = amount,
    })
    if kind == "death" and isPlayerGUID(dstGUID) then
      table.insert(current.deaths, { name = dstName, atMs = t })
    end
  end
end)
