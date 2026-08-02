-- Recorder.lua — captures COMBAT_LOG_EVENT_UNFILTERED during arenas.
-- Replaces the web app's file parsing: no file I/O exists in the Lua sandbox,
-- so we record events live and persist them in SavedVariables.

local ADDON, NS = ...
ArenaLogViewerDB = ArenaLogViewerDB or { matches = {} }

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

local function isPlayerGUID(guid) return guid and guid:find("^Player%-") ~= nil end

local function snapshotRoster()
  local players = {}
  for i = 1, GetNumGroupMembers() do
    local unit = (i == 1) and "player" or ("party" .. (i - 1))
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
  current = {
    map = GetZoneText(), startedAt = date("%Y-%m-%d %H:%M"),
    startTime = GetTime(), events = {}, players = snapshotRoster(),
    result = "unknown", deaths = {},
  }
  recording = true
end

local function endMatch()
  if not current then return end
  recording = false
  current.durationMs = math.floor((GetTime() - current.startTime) * 1000)
  current.timeline = NS.BuildTimeline(current) -- Timeline.lua
  current.events = nil -- keep SavedVariables small: persist rows, not raw events
  table.insert(ArenaLogViewerDB.matches, current)
  current = nil
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_HEALTH") -- cheap death confirmation aid
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" then
    local inArena = IsActiveBattlefieldArena and IsActiveBattlefieldArena()
    if inArena and not recording then
      -- roster may not be up yet; re-snapshot when gates open
      C_Timer.After(5, function() if current then current.players = snapshotRoster() end end)
      startMatch()
    elseif not inArena and recording then
      endMatch()
    end
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" and recording then
    local ts, sub, _, srcGUID, srcName, _, _, dstGUID, dstName, _, _,
      spellId, spellName, school, amount = CombatLogGetCurrentEventInfo()
    local kind = TRACKED[sub]
    if not kind then return end
    if not (isPlayerGUID(srcGUID) or isPlayerGUID(dstGUID)) then return end
    local t = math.floor((GetTime() - current.startTime) * 1000)
    table.insert(current.events, { t = t, k = kind, s = srcGUID, sn = srcName,
      d = dstGUID, dn = dstName, id = spellId, n = spellName, sc = school, a = amount })
    if kind == "death" and isPlayerGUID(dstGUID) then
      table.insert(current.deaths, { name = dstName, atMs = t })
    end
  end
end)
