-- Timeline.lua — Lua port of buildTimeline.ts: merge raw events into
-- per-spell rows of cast ticks + aura duration bars.

local ADDON, NS = ...

-- WoW spell school bitmask -> bar color (mirrors schoolColor.ts)
NS.SchoolColor = function(school)
  if not school then return 0.6, 0.6, 0.65 end
  if school == 1 then return 1.0, 1.0, 0.30 end   -- Physical
  if school == 2 then return 1.0, 0.90, 0.50 end  -- Holy
  if school == 4 then return 1.0, 0.50, 0.10 end  -- Fire
  if school == 8 then return 0.30, 1.0, 0.30 end  -- Nature
  if school == 16 then return 0.50, 1.0, 1.0 end  -- Frost
  if school == 32 then return 0.50, 0.50, 1.0 end -- Shadow
  if school == 64 then return 1.0, 0.50, 1.0 end  -- Arcane
  return 0.7, 0.7, 0.75
end

function NS.BuildTimeline(match)
  local rows, order = {}, {}
  local function rowFor(ev)
    local key = (ev.s or "?") .. ":" .. (ev.id or ev.n or "?")
    local r = rows[key]
    if not r then
      r = { key = key, spellId = ev.id, spellName = ev.n or "Melee",
            school = ev.sc, sourceName = ev.sn or "?", segments = {} }
      rows[key] = r; table.insert(order, r)
    end
    return r
  end

  local openAuras = {} -- key .. dstGUID -> segment awaiting removal
  for _, ev in ipairs(match.events) do
    if ev.k == "cast" then
      local r = rowFor(ev)
      table.insert(r.segments, { startMs = ev.t, endMs = nil, kind = "cast",
        targetName = ev.dn })
    elseif ev.k == "aura_apply" or ev.k == "aura_refresh" then
      local r = rowFor(ev)
      local ak = r.key .. "@" .. (ev.d or "")
      if ev.k == "aura_refresh" and openAuras[ak] then
        openAuras[ak].endMs = ev.t -- close and reopen on refresh
      end
      local seg = { startMs = ev.t, endMs = nil, kind = "aura", targetName = ev.dn }
      table.insert(r.segments, seg)
      openAuras[ak] = seg
    elseif ev.k == "aura_remove" then
      local key = (ev.s or "?") .. ":" .. (ev.id or ev.n or "?")
      local ak = key .. "@" .. (ev.d or "")
      if openAuras[ak] then openAuras[ak].endMs = ev.t; openAuras[ak] = nil end
    end
  end
  -- close dangling auras at match end
  for _, seg in pairs(openAuras) do seg.endMs = match.durationMs end

  table.sort(order, function(a, b)
    local as = a.segments[1] and a.segments[1].startMs or 0
    local bs = b.segments[1] and b.segments[1].startMs or 0
    return as < bs
  end)
  return order
end
