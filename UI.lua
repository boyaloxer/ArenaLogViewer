-- UI.lua — in-game viewer matching the Arena Log Viewer mockup:
-- match cards, stats bar, aura filter dropdown, icon+name timeline rows, export.

local ADDON, NS = ...
local PX_PER_SEC = 40
local LABEL_W = 200
local ROW_H = 22
local SEG = 16
local RULER_H = 28
local SIDE_W = 250
local PREFIX = "|cff66bbffArena Log Viewer|r"
local ICON_TEX = "Interface\\Minimap\\Tracking\\None"
local GOLD = { 0.9, 0.75, 0.2 }

local main, miniBtn, db
local selectedMatch, selectedIndex
local viewMode = "timeline" -- timeline | coordination
local sourceFilter, targetFilter = "all", "any"
local hiddenAuras = {}
local segPool, poolIdx = {}, 0
local rowPool = {}
local auraMenuRows = {}
local cardPool = {}
local auraFilterList = {} -- current match aura rows for the dropdown

local function EnsureDB()
  ArenaLogViewerDB = ArenaLogViewerDB or {}
  db = ArenaLogViewerDB
  db.matches = db.matches or {}
  if db.minimapAngle == nil then db.minimapAngle = 200 end
  if db.minimapHide == nil then db.minimapHide = false end
  if db.pxPerSec == nil then db.pxPerSec = PX_PER_SEC end
end

local function fmt(ms)
  local s = (ms or 0) / 1000
  return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
end

local function fmtPrecise(ms)
  local s = (ms or 0) / 1000
  return string.format("%d:%04.1f", math.floor(s / 60), s % 60)
end

local function fmtRuler(sec)
  local m = math.floor(sec / 60)
  local r = sec - m * 60
  if m > 0 then return string.format("%d:%02d", m, math.floor(r)) end
  return string.format("%d:%02d", 0, math.floor(r))
end

local function classColor(class)
  local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS) and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.8
end

local function estimateSVKB()
  local n = #(ArenaLogViewerDB.matches or {})
  local bytes = 8 * 1024
  for _, m in ipairs(ArenaLogViewerDB.matches or {}) do
    bytes = bytes + 1200 + (#(m.timeline or {}) * 180)
    for _, row in ipairs(m.timeline or {}) do
      bytes = bytes + (#(row.segments or {}) * 40)
    end
  end
  return math.max(1, math.floor(bytes / 1024)), n
end

local function shortMap(map)
  if not map then return "Arena" end
  map = map:gsub(" Arena$", "")
  if #map > 14 then return string.sub(map, 1, 12) .. "…" end
  return map
end

local function compLine(match, side)
  local parts = {}
  for _, p in ipairs(NS.PlayerList(match)) do
    if p.side == side then
      table.insert(parts, NS.ClassLabel(p.class) or p.name or "?")
    end
  end
  return (#parts > 0) and table.concat(parts, " / ") or "—"
end

local function acquireSeg(parent)
  poolIdx = poolIdx + 1
  local t = segPool[poolIdx]
  if not t then
    t = CreateFrame("Frame", nil, parent)
    t:EnableMouse(true)
    t.bar = t:CreateTexture(nil, "ARTWORK")
    t.bar:SetAllPoints()
    t.iconBg = t:CreateTexture(nil, "OVERLAY", nil, 1)
    t.iconBg:SetColorTexture(0, 0, 0, 0.85)
    t.icon = t:CreateTexture(nil, "OVERLAY", nil, 2)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
      GameTooltip:SetText(self.tipTitle or "?", 1, 0.82, 0)
      if self.tipBody then GameTooltip:AddLine(self.tipBody, 0.9, 0.9, 0.9, true) end
      GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    segPool[poolIdx] = t
  end
  t:SetParent(parent)
  t:SetFrameLevel(parent:GetFrameLevel() + 3)
  t:Show()
  return t
end

local function releaseAllSegs()
  for _, t in ipairs(segPool) do t:Hide() end
  poolIdx = 0
end

local function ensureRow(content, i)
  local row = rowPool[i]
  if row then
    if not row.icon then
      row.icon = content:CreateTexture(nil, "ARTWORK")
      row.icon:SetSize(SEG, SEG)
      row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    return row
  end
  row = {}
  row.bg = content:CreateTexture(nil, "BACKGROUND")
  row.bg:SetHeight(ROW_H)
  row.icon = content:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(SEG, SEG)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.label = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.label:SetJustifyH("LEFT")
  row.track = CreateFrame("Frame", nil, content)
  row.track:SetHeight(ROW_H)
  rowPool[i] = row
  return row
end

local function hideExtraRows(fromIndex)
  for i = fromIndex, #rowPool do
    local row = rowPool[i]
    if row then
      row.bg:Hide()
      if row.icon then row.icon:Hide() end
      if row.abbr then row.abbr:Hide() end
      row.label:Hide()
      row.track:Hide()
    end
  end
end

local function filteredRows(match)
  if not match or type(match.timeline) ~= "table" then return {} end
  local out = {}
  for _, row in ipairs(match.timeline) do
    if not hiddenAuras[row.key] then
      if sourceFilter ~= "all" and row.sourceGuid ~= sourceFilter then
        -- skip
      else
        local segs = row.segments
        if targetFilter ~= "any" then
          local filtered = {}
          for _, s in ipairs(row.segments) do
            if s.targetGuid == targetFilter then table.insert(filtered, s) end
          end
          if #filtered == 0 then segs = nil
          else segs = filtered end
        end
        if segs then
          if segs == row.segments then
            table.insert(out, row)
          else
            table.insert(out, {
              key = row.key, spellId = row.spellId, spellName = row.spellName,
              school = row.school, sourceName = row.sourceName, sourceGuid = row.sourceGuid,
              segments = segs,
            })
          end
        end
      end
    end
  end
  return out
end

local function drawRuler(content, durationMs, pps, trackX, rowCount)
  content.rulerTicks = content.rulerTicks or {}
  content.rulerLines = content.rulerLines or {}
  if not content.rulerAxis then
    content.rulerAxis = content:CreateTexture(nil, "ARTWORK")
    content.rulerAxis:SetColorTexture(0.35, 0.35, 0.38, 1)
    content.rulerAxis:SetHeight(1)
  end
  local dur = math.max((durationMs or 0) / 1000, 1)
  local trackW = dur * pps
  content.rulerAxis:ClearAllPoints()
  content.rulerAxis:SetPoint("TOPLEFT", trackX, -(RULER_H - 10))
  content.rulerAxis:SetSize(trackW, 1)
  content.rulerAxis:Show()

  local majorEvery = (pps >= 48) and 5 or (pps >= 24) and 10 or 15
  local tickI, lineI = 0, 0
  for t = 0, dur + 0.001, majorEvery do
    tickI = tickI + 1
    lineI = lineI + 1
    local fs = content.rulerTicks[tickI]
    if not fs then
      fs = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      content.rulerTicks[tickI] = fs
    end
    local x = trackX + t * pps
    fs:ClearAllPoints()
    fs:SetPoint("BOTTOMLEFT", content, "TOPLEFT", x + 2, -RULER_H + 2)
    fs:SetText(fmtRuler(t))
    fs:Show()

    local line = content.rulerLines[lineI]
    if not line then
      line = content:CreateTexture(nil, "BACKGROUND")
      line:SetColorTexture(0.22, 0.22, 0.25, 0.7)
      line:SetWidth(1)
      content.rulerLines[lineI] = line
    end
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", x, -RULER_H)
    line:SetHeight(math.max(rowCount * ROW_H, 40))
    line:Show()
  end
  for i = tickI + 1, #content.rulerTicks do content.rulerTicks[i]:Hide() end
  for i = lineI + 1, #content.rulerLines do content.rulerLines[i]:Hide() end
  return trackW
end

local function renderTimeline(match, content, pps)
  releaseAllSegs()
  local rows = filteredRows(match)
  if content.emptyTrack then content.emptyTrack:Hide() end
  if #rows == 0 then
    hideExtraRows(1)
    if content.emptyTrack then
      content.emptyTrack:SetText(viewMode == "coordination" and "" or "No rows for this filter.")
      content.emptyTrack:Show()
    end
    content:SetSize(400, 80)
    if main and main.syncTimelineScrollBars then main.syncTimelineScrollBars() end
    return
  end

  local trackX = LABEL_W + 8
  local trackW = drawRuler(content, match.durationMs, pps, trackX, #rows)

  for i, rowData in ipairs(rows) do
    local y = -RULER_H - (i - 1) * ROW_H
    local row = ensureRow(content, i)
    local r, g, b = NS.SchoolColor(rowData.school)
    local tex = GetSpellTexture(rowData.spellId) or 134400

    row.bg:ClearAllPoints()
    row.bg:SetPoint("TOPLEFT", 0, y)
    row.bg:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
    row.bg:SetColorTexture(i % 2 == 0 and 1 or 0, i % 2 == 0 and 1 or 0, i % 2 == 0 and 1 or 0, i % 2 == 0 and 0.03 or 0.12)
    row.bg:Show()

    if row.abbr then row.abbr:Hide() end
    row.icon:ClearAllPoints()
    row.icon:SetPoint("TOPLEFT", 6, y - 3)
    row.icon:SetTexture(tex)
    row.icon:Show()

    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.label:SetWidth(LABEL_W - 36)
    row.label:SetText(rowData.spellName or "?")
    row.label:SetTextColor(r, g, b)
    row.label:Show()

    row.track:ClearAllPoints()
    row.track:SetPoint("TOPLEFT", trackX, y)
    row.track:SetSize(trackW + 20, ROW_H)
    row.track:Show()

    for _, seg in ipairs(rowData.segments) do
      local f = acquireSeg(row.track)
      local left = (seg.startMs / 1000) * pps
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", left, -3)
      f.tipTitle = rowData.spellName
      f.tipBody = fmtPrecise(seg.startMs) .. " · " .. seg.kind
        .. "\n" .. (seg.sourceName or rowData.sourceName or "?")
        .. " → " .. (seg.targetName or "?")

      if seg.kind == "cast" then
        f:SetSize(SEG, SEG)
        f.bar:SetColorTexture(0, 0, 0, 0)
        f.iconBg:Hide()
        f.icon:SetAllPoints()
        f.icon:SetTexture(tex)
        f.icon:Show()
      else
        local w = math.max(((seg.endMs or seg.startMs) - seg.startMs) / 1000 * pps, SEG)
        f:SetSize(w, SEG)
        f.bar:SetColorTexture(r, g, b, 0.85)
        f.iconBg:ClearAllPoints()
        f.iconBg:SetPoint("TOPLEFT")
        f.iconBg:SetSize(SEG, SEG)
        f.iconBg:Show()
        f.icon:ClearAllPoints()
        f.icon:SetPoint("TOPLEFT", 0, 0)
        f.icon:SetSize(SEG, SEG)
        f.icon:SetTexture(tex)
        f.icon:Show()
      end
    end
  end
  hideExtraRows(#rows + 1)
  content:SetSize(trackX + trackW + 40, RULER_H + #rows * ROW_H + 20)
  if main and main.syncTimelineScrollBars then main.syncTimelineScrollBars() end
end

local function renderCoordination(match, content)
  releaseAllSegs()
  hideExtraRows(1)
  if content.rulerAxis then content.rulerAxis:Hide() end
  if content.rulerTicks then for _, fs in ipairs(content.rulerTicks) do fs:Hide() end end
  if content.rulerLines then for _, tex in ipairs(content.rulerLines) do tex:Hide() end end

  local tgtGuid = targetFilter
  if tgtGuid == "any" then
    -- busiest enemy by damage taken (approx: most aura/cast targets that are enemy)
    local counts = {}
    for _, row in ipairs(match.timeline or {}) do
      for _, seg in ipairs(row.segments or {}) do
        if seg.targetGuid then
          counts[seg.targetGuid] = (counts[seg.targetGuid] or 0) + 1
        end
      end
    end
    local best, bestN = nil, 0
    for _, p in ipairs(NS.PlayerList(match)) do
      if p.side == "enemy" and (counts[p.guid] or 0) > bestN then
        best, bestN = p.guid, counts[p.guid] or 0
      end
    end
    tgtGuid = best
  end

  local lines = {}
  local tgtName = "?"
  for _, p in ipairs(NS.PlayerList(match)) do
    if p.guid == tgtGuid then tgtName = p.name end
  end
  table.insert(lines, "Coordination — focus on " .. tgtName)
  table.insert(lines, "")

  local bySrc = {}
  for _, st in ipairs(match.stats or {}) do
    bySrc[st.guid] = st
  end
  for _, p in ipairs(NS.PlayerList(match)) do
    if sourceFilter == "all" or sourceFilter == p.guid then
      if p.side == "friendly" or p.guid == tgtGuid then
        local st = bySrc[p.guid]
        local dmg = st and st.damage or 0
        table.insert(lines, string.format("%s  %s dmg", p.name, BreakUpLargeNumbers and BreakUpLargeNumbers(dmg) or dmg))
      end
    end
  end
  table.insert(lines, "")
  table.insert(lines, "(Full focus-fire graph is on the web viewer.)")

  if not content.coordText then
    content.coordText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    content.coordText:SetJustifyH("LEFT")
    content.coordText:SetPoint("TOPLEFT", 16, -16)
    content.coordText:SetWidth(600)
  end
  content.coordText:SetText(table.concat(lines, "\n"))
  content.coordText:Show()
  if content.emptyTrack then content.emptyTrack:Hide() end
  content:SetSize(640, 200)
  if main and main.syncTimelineScrollBars then main.syncTimelineScrollBars() end
end

local function updateStatsBar(match)
  if not main or not main.statsBar then return end
  local bar = main.statsBar
  bar:SetText("")
  if not match then return end
  local bits = {}
  local byGuid = {}
  for _, p in ipairs(NS.PlayerList(match)) do byGuid[p.guid] = p end
  for _, st in ipairs(match.stats or {}) do
    local p = byGuid[st.guid]
    local r, g, b = classColor(p and p.class)
    local name = string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, st.name or "?")
    local dmg = BreakUpLargeNumbers and BreakUpLargeNumbers(st.damage or 0) or (st.damage or 0)
    local heal = BreakUpLargeNumbers and BreakUpLargeNumbers(st.healing or 0) or (st.healing or 0)
    table.insert(bits, name .. "  " .. dmg .. " dmg / " .. heal .. " heal")
  end
  if match.deaths and #match.deaths > 0 then
    local dbits = {}
    for _, d in ipairs(match.deaths) do
      table.insert(dbits, string.format("%s @ %.1fs", d.name or "?", (d.atMs or 0) / 1000))
    end
    table.insert(bits, "|cffff6666Deaths: " .. table.concat(dbits, ", ") .. "|r")
  end
  bar:SetText(table.concat(bits, "   "))
end

local function collectAuraRows(match)
  local seen, list = {}, {}
  if not match then return list end
  for _, row in ipairs(match.timeline or {}) do
    local hasAura = false
    for _, s in ipairs(row.segments or {}) do
      if s.kind == "aura" then hasAura = true; break end
    end
    if hasAura and not seen[row.key] then
      seen[row.key] = true
      table.insert(list, row)
    end
  end
  return list
end

local function ensureAuraMenuRow(i)
  local b = auraMenuRows[i]
  if b then return b end
  local menu = main.auraMenu
  b = CreateFrame("Button", nil, menu.content, "BackdropTemplate")
  b:SetSize(220, 22)
  b:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(16, 16)
  b.icon:SetPoint("LEFT", 4, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.check = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.check:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
  b.check:SetWidth(14)
  b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.fs:SetPoint("LEFT", b.check, "RIGHT", 2, 0)
  b.fs:SetPoint("RIGHT", -4, 0)
  b.fs:SetJustifyH("LEFT")
  auraMenuRows[i] = b
  return b
end

local function refreshAuraMenuContents()
  if not main or not main.auraMenu then return end
  local list = auraFilterList
  local hiddenN = 0
  for i, row in ipairs(list) do
    local b = ensureAuraMenuRow(i)
    local r, g, bl = NS.SchoolColor(row.school)
    local off = hiddenAuras[row.key]
    if off then hiddenN = hiddenN + 1 end
    b:SetBackdropColor(0.08, 0.08, 0.09, 1)
    b:SetBackdropBorderColor(r * 0.5, g * 0.5, bl * 0.5, off and 0.35 or 0.9)
    b.icon:SetTexture(GetSpellTexture(row.spellId) or 134400)
    b.icon:SetDesaturated(off and true or false)
    b.check:SetText(off and "" or "✓")
    b.check:SetTextColor(r, g, bl)
    b.fs:SetText(row.spellName or "?")
    b.fs:SetTextColor(r, g, bl, off and 0.45 or 1)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 4, -(i - 1) * 24 - 4)
    b:SetScript("OnClick", function()
      if hiddenAuras[row.key] then hiddenAuras[row.key] = nil
      else hiddenAuras[row.key] = true end
      if selectedMatch then NS.RefreshViewer() end
    end)
    b:Show()
  end
  for i = #list + 1, #auraMenuRows do auraMenuRows[i]:Hide() end
  main.auraMenu.content:SetHeight(math.max(40, #list * 24 + 8))
  if main.auraBtn then
    if #list == 0 then
      main.auraBtn:SetText("Aura filters")
      main.auraBtn:Disable()
    else
      main.auraBtn:Enable()
      if hiddenN > 0 then
        main.auraBtn:SetText(("Aura filters (%d hidden)"):format(hiddenN))
      else
        main.auraBtn:SetText(("Aura filters (%d)"):format(#list))
      end
    end
  end
end

local function updateAuraFilters(match)
  if not main or not main.auraBtn then return end
  if main.auraMenu and viewMode ~= "timeline" then
    main.auraMenu:Hide()
  end
  if not match or viewMode ~= "timeline" then
    auraFilterList = {}
    if main.auraBtn then
      main.auraBtn:SetText("Aura filters")
      main.auraBtn:Disable()
    end
    for _, b in ipairs(auraMenuRows) do b:Hide() end
    return
  end
  auraFilterList = collectAuraRows(match)
  refreshAuraMenuContents()
end

local function cycleFilter(which)
  if not selectedMatch then return end
  local players = NS.PlayerList(selectedMatch)
  local opts = { "all" }
  if which == "target" then opts = { "any" } end
  for _, p in ipairs(players) do table.insert(opts, p.guid) end
  local cur = (which == "source") and sourceFilter or targetFilter
  local idx = 1
  for i, v in ipairs(opts) do if v == cur then idx = i; break end end
  idx = idx + 1
  if idx > #opts then idx = 1 end
  if which == "source" then sourceFilter = opts[idx] else targetFilter = opts[idx] end
  NS.RefreshViewer()
end

local function filterLabel(which)
  if not selectedMatch then
    return which == "source" and "Source: All players" or "Target: Any target"
  end
  local val = which == "source" and sourceFilter or targetFilter
  if val == "all" then return "Source: All players" end
  if val == "any" then return "Target: Any target" end
  for _, p in ipairs(NS.PlayerList(selectedMatch)) do
    if p.guid == val then
      return (which == "source" and "Source: " or "Target: ") .. p.name
    end
  end
  return which == "source" and "Source: All players" or "Target: Any target"
end

local function selectMatch(match, index)
  selectedMatch = match
  selectedIndex = index
  sourceFilter, targetFilter = "all", "any"
  wipe(hiddenAuras)
  NS.RefreshViewer()
end

function NS.RefreshViewer()
  if not main or not main:IsShown() then return end
  EnsureDB()
  local matches = ArenaLogViewerDB.matches or {}
  local kb, n = estimateSVKB()
  if main.statusText then
    main.statusText:SetText(string.format("%d matches saved  •  SavedVariables %d KB", n, kb))
  end

  -- Sidebar cards (newest first)
  for _, c in ipairs(cardPool) do c:Hide() end
  local y = -4
  local displayI = 0
  for rev = #matches, 1, -1 do
    local i = rev
    local m = matches[i]
    displayI = displayI + 1
    local card = cardPool[displayI]
    if not card then
      card = CreateFrame("Button", nil, main.sideContent, "BackdropTemplate")
      card:SetSize(SIDE_W - 28, 72)
      card:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
      })
      card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      card.title:SetPoint("TOPLEFT", 8, -8)
      card.title:SetJustifyH("LEFT")
      card.meta = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      card.meta:SetPoint("TOPLEFT", 8, -26)
      card.meta:SetWidth(SIDE_W - 44)
      card.meta:SetJustifyH("LEFT")
      cardPool[displayI] = card
    end
    local res = m.result or "unknown"
    local resColor = (res == "WIN" and "|cff66ff66" or res == "LOSS" and "|cffff6666" or "|cffaaaaaa")
    card.title:SetText(string.format("Match %d — %s (%s%s|r)", i, shortMap(m.map), resColor, res))
    card.meta:SetText(string.format("%s  ·  %s\nUs: %s\nThem: %s",
      m.startedAt or "?", fmt(m.durationMs),
      compLine(m, "friendly"), compLine(m, "enemy")))
    local active = (selectedMatch == m) or (not selectedMatch and i == #matches)
    card:SetBackdropColor(0.08, 0.08, 0.09, 1)
    if active then
      card:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1)
    else
      card:SetBackdropBorderColor(0.25, 0.25, 0.28, 1)
    end
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", 4, y)
    card:SetScript("OnClick", function() selectMatch(m, i) end)
    card:Show()
    y = y - 78
  end
  main.sideContent:SetHeight(math.max(120, displayI * 78 + 80))

  if main.sideEmpty then
    if #matches == 0 then
      main.sideEmpty:SetText("No matches yet.\n\nQueue arenas to record live,\nor |cffffffff/alv test|r for the mockup sample.\n\nDisk WoWCombatLog files → web app.")
      main.sideEmpty:Show()
    else
      main.sideEmpty:Hide()
    end
  end

  if not selectedMatch and #matches > 0 then
    selectedMatch = matches[#matches]
    selectedIndex = #matches
  end

  local m = selectedMatch
  if main.header then
    if m then
      local rows = filteredRows(m)
      main.header:SetText(string.format("%s  ·  %s  ·  %d rows",
        m.map or "Arena", fmtPrecise(m.durationMs), #rows))
    else
      main.header:SetText("")
    end
  end

  if main.tabTimeline and main.tabCoord then
    if viewMode == "timeline" then
      main.tabTimeline:SetText("|cffffd100Timeline|r")
      main.tabCoord:SetText("|cffaaaaaaCoordination|r")
    else
      main.tabTimeline:SetText("|cffaaaaaaTimeline|r")
      main.tabCoord:SetText("|cffffd100Coordination|r")
    end
  end
  if main.sourceBtn then main.sourceBtn:SetText(filterLabel("source")) end
  if main.targetBtn then main.targetBtn:SetText(filterLabel("target")) end
  if main.zoomLabel then
    main.zoomLabel:SetText(string.format("Zoom %d", db.pxPerSec or PX_PER_SEC))
  end

  updateStatsBar(m)
  updateAuraFilters(m)

  if main.content and main.content.coordText then main.content.coordText:Hide() end
  if m then
    if viewMode == "coordination" then
      renderCoordination(m, main.content)
    else
      renderTimeline(m, main.content, db.pxPerSec or PX_PER_SEC)
    end
  else
    releaseAllSegs()
    hideExtraRows(1)
  end
end

local function showExport()
  if not selectedMatch then
    print(PREFIX .. ": select a match first")
    return
  end
  if not main.exportBox then return end
  local m = selectedMatch
  local lines = {
    "ALV1",
    "map=" .. tostring(m.map),
    "at=" .. tostring(m.startedAt),
    "dur=" .. tostring(m.durationMs),
    "result=" .. tostring(m.result),
  }
  for _, p in ipairs(NS.PlayerList(m)) do
    table.insert(lines, string.format("P|%s|%s|%s|%s", p.guid or "", p.name or "", p.class or "", p.side or ""))
  end
  for _, st in ipairs(m.stats or {}) do
    table.insert(lines, string.format("S|%s|%d|%d", st.guid or "", st.damage or 0, st.healing or 0))
  end
  for _, row in ipairs(m.timeline or {}) do
    for _, seg in ipairs(row.segments or {}) do
      table.insert(lines, string.format("E|%s|%d|%s|%d|%s|%s|%s",
        row.spellName or "?", row.spellId or 0, seg.kind,
        seg.startMs or 0, tostring(seg.endMs or ""),
        seg.sourceName or "", seg.targetName or ""))
    end
  end
  local text = table.concat(lines, "\n")
  main.exportBox:SetText(text)
  main.exportFrame:Show()
  main.exportBox:HighlightText()
  main.exportBox:SetFocus()
  print(PREFIX .. ": export string ready — Ctrl+C in the box, paste into the web viewer later")
end

local function buildMain()
  EnsureDB()
  main = CreateFrame("Frame", "ArenaLogViewerFrame", UIParent, "BackdropTemplate")
  main:SetSize(1180, 700)
  main:SetPoint("CENTER")
  main:SetMovable(true)
  main:EnableMouse(true)
  main:RegisterForDrag("LeftButton")
  main:SetScript("OnDragStart", main.StartMoving)
  main:SetScript("OnDragStop", main.StopMovingOrSizing)
  main:SetFrameStrata("DIALOG")
  main:SetClampedToScreen(true)
  main:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
  })
  main:SetBackdropColor(0.04, 0.04, 0.045, 0.98)
  main:Hide()

  local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 18, -14)
  title:SetText("Arena Log Viewer")
  title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

  local status = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("TOPRIGHT", -40, -16)
  main.statusText = status

  local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  -- Sidebar
  local sideBg = CreateFrame("Frame", nil, main, "BackdropTemplate")
  sideBg:SetPoint("TOPLEFT", 14, -40)
  sideBg:SetPoint("BOTTOMLEFT", 14, 48)
  sideBg:SetWidth(SIDE_W)
  sideBg:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  sideBg:SetBackdropColor(0.05, 0.05, 0.055, 1)
  sideBg:SetBackdropBorderColor(0.2, 0.18, 0.1, 1)

  local sideTitle = sideBg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sideTitle:SetPoint("TOPLEFT", 10, -8)
  sideTitle:SetText("MATCHES")
  sideTitle:SetTextColor(0.7, 0.7, 0.7)

  local side = CreateFrame("ScrollFrame", nil, sideBg, "UIPanelScrollFrameTemplate")
  side:SetPoint("TOPLEFT", 4, -24)
  side:SetPoint("BOTTOMRIGHT", -26, 44)
  local sideContent = CreateFrame("Frame", nil, side)
  sideContent:SetSize(SIDE_W - 30, 10)
  side:SetScrollChild(sideContent)
  main.sideContent = sideContent

  main.sideEmpty = sideContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  main.sideEmpty:SetPoint("TOPLEFT", 8, -8)
  main.sideEmpty:SetWidth(SIDE_W - 48)
  main.sideEmpty:SetJustifyH("LEFT")
  main.sideEmpty:Hide()

  local exportBtn = CreateFrame("Button", nil, sideBg, "UIPanelButtonTemplate")
  exportBtn:SetSize(SIDE_W - 24, 32)
  exportBtn:SetPoint("BOTTOM", 0, 8)
  exportBtn:SetText("Export match string")
  exportBtn:SetScript("OnClick", showExport)
  local exportHint = sideBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  exportHint:SetPoint("BOTTOM", exportBtn, "TOP", 0, 2)
  exportHint:SetText("copy into the web viewer")

  -- Main pane
  local paneBg = CreateFrame("Frame", nil, main, "BackdropTemplate")
  paneBg:SetPoint("TOPLEFT", 14 + SIDE_W + 8, -40)
  paneBg:SetPoint("BOTTOMRIGHT", -14, 48)
  paneBg:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  paneBg:SetBackdropColor(0, 0, 0, 1)
  paneBg:SetBackdropBorderColor(0.2, 0.18, 0.1, 1)

  local header = paneBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header:SetPoint("TOPLEFT", 10, -8)
  header:SetTextColor(0.75, 0.75, 0.8)
  main.header = header

  local tabTimeline = CreateFrame("Button", nil, paneBg)
  tabTimeline:SetSize(80, 18)
  tabTimeline:SetPoint("TOPLEFT", 10, -28)
  tabTimeline:SetNormalFontObject(GameFontNormal)
  tabTimeline:SetText("Timeline")
  tabTimeline:SetScript("OnClick", function()
    viewMode = "timeline"; NS.RefreshViewer()
  end)
  main.tabTimeline = tabTimeline

  local tabCoord = CreateFrame("Button", nil, paneBg)
  tabCoord:SetSize(100, 18)
  tabCoord:SetPoint("LEFT", tabTimeline, "RIGHT", 8, 0)
  tabCoord:SetNormalFontObject(GameFontNormal)
  tabCoord:SetText("Coordination")
  tabCoord:SetScript("OnClick", function()
    viewMode = "coordination"; NS.RefreshViewer()
  end)
  main.tabCoord = tabCoord

  local sourceBtn = CreateFrame("Button", nil, paneBg, "UIPanelButtonTemplate")
  sourceBtn:SetSize(140, 20)
  sourceBtn:SetPoint("LEFT", tabCoord, "RIGHT", 16, 0)
  sourceBtn:SetText("Source: All players")
  sourceBtn:SetScript("OnClick", function() cycleFilter("source") end)
  main.sourceBtn = sourceBtn

  local targetBtn = CreateFrame("Button", nil, paneBg, "UIPanelButtonTemplate")
  targetBtn:SetSize(140, 20)
  targetBtn:SetPoint("LEFT", sourceBtn, "RIGHT", 6, 0)
  targetBtn:SetText("Target: Any target")
  targetBtn:SetScript("OnClick", function() cycleFilter("target") end)
  main.targetBtn = targetBtn

  local zoomOut = CreateFrame("Button", nil, paneBg, "UIPanelButtonTemplate")
  zoomOut:SetSize(24, 20)
  zoomOut:SetPoint("LEFT", targetBtn, "RIGHT", 10, 0)
  zoomOut:SetText("-")
  zoomOut:SetScript("OnClick", function()
    db.pxPerSec = math.max(12, (db.pxPerSec or PX_PER_SEC) - 8)
    NS.RefreshViewer()
  end)
  local zoomIn = CreateFrame("Button", nil, paneBg, "UIPanelButtonTemplate")
  zoomIn:SetSize(24, 20)
  zoomIn:SetPoint("LEFT", zoomOut, "RIGHT", 2, 0)
  zoomIn:SetText("+")
  zoomIn:SetScript("OnClick", function()
    db.pxPerSec = math.min(80, (db.pxPerSec or PX_PER_SEC) + 8)
    NS.RefreshViewer()
  end)
  local zoomLabel = paneBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  zoomLabel:SetPoint("LEFT", zoomIn, "RIGHT", 6, 0)
  main.zoomLabel = zoomLabel

  local auraBtn = CreateFrame("Button", nil, paneBg, "UIPanelButtonTemplate")
  auraBtn:SetSize(150, 20)
  auraBtn:SetPoint("LEFT", zoomLabel, "RIGHT", 12, 0)
  auraBtn:SetText("Aura filters")
  auraBtn:Disable()
  main.auraBtn = auraBtn

  local auraMenu = CreateFrame("Frame", "ArenaLogViewerAuraMenu", paneBg, "BackdropTemplate")
  auraMenu:SetSize(240, 200)
  auraMenu:SetPoint("TOPLEFT", auraBtn, "BOTTOMLEFT", 0, -2)
  auraMenu:SetFrameStrata("FULLSCREEN_DIALOG")
  auraMenu:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  auraMenu:SetBackdropColor(0.05, 0.05, 0.06, 0.98)
  auraMenu:Hide()
  auraMenu:EnableMouse(true)
  main.auraMenu = auraMenu

  local auraScroll = CreateFrame("ScrollFrame", nil, auraMenu, "UIPanelScrollFrameTemplate")
  auraScroll:SetPoint("TOPLEFT", 8, -8)
  auraScroll:SetPoint("BOTTOMRIGHT", -28, 8)
  local auraContent = CreateFrame("Frame", nil, auraScroll)
  auraContent:SetSize(200, 40)
  auraScroll:SetScrollChild(auraContent)
  auraMenu.content = auraContent

  auraBtn:SetScript("OnClick", function()
    if auraMenu:IsShown() then
      auraMenu:Hide()
    else
      refreshAuraMenuContents()
      local h = math.min(220, math.max(60, #auraFilterList * 24 + 24))
      auraMenu:SetHeight(h)
      auraMenu:Show()
    end
  end)

  local statsBar = paneBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statsBar:SetPoint("TOPLEFT", 10, -52)
  statsBar:SetPoint("TOPRIGHT", -10, -52)
  statsBar:SetJustifyH("LEFT")
  statsBar:SetWordWrap(true)
  main.statsBar = statsBar

  -- Dual-axis scroll: vertical bar on the right, horizontal along the bottom.
  local pane = CreateFrame("ScrollFrame", "ArenaLogViewerTimelineScroll", paneBg)
  pane:SetPoint("TOPLEFT", 6, -78)
  pane:SetPoint("BOTTOMRIGHT", -28, 28)
  pane:EnableMouse(true)
  pane:EnableMouseWheel(true)
  local content = CreateFrame("Frame", nil, pane)
  content:SetSize(100, 100)
  pane:SetScrollChild(content)
  main.content = content
  main.pane = pane
  content.emptyTrack = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  content.emptyTrack:SetPoint("TOPLEFT", 20, -40)
  content.emptyTrack:Hide()

  local vScroll = CreateFrame("Slider", "ArenaLogViewerVScroll", pane, "UIPanelScrollBarTemplate")
  vScroll:SetPoint("TOPLEFT", pane, "TOPRIGHT", 4, -16)
  vScroll:SetPoint("BOTTOMLEFT", pane, "BOTTOMRIGHT", 4, 16)
  vScroll:SetMinMaxValues(0, 1)
  vScroll:SetValue(0)
  main.vScroll = vScroll

  local hScroll = CreateFrame("Slider", "ArenaLogViewerHScroll", paneBg)
  hScroll:SetHeight(16)
  hScroll:SetPoint("BOTTOMLEFT", 6, 8)
  hScroll:SetPoint("BOTTOMRIGHT", -28, 8)
  hScroll:SetOrientation("HORIZONTAL")
  hScroll:SetMinMaxValues(0, 1)
  hScroll:SetValue(0)
  hScroll:SetValueStep(1)
  local hTrack = hScroll:CreateTexture(nil, "BACKGROUND")
  hTrack:SetColorTexture(0.12, 0.12, 0.14, 1)
  hTrack:SetAllPoints()
  local hThumb = hScroll:CreateTexture(nil, "OVERLAY")
  hThumb:SetColorTexture(0.55, 0.55, 0.6, 1)
  hThumb:SetSize(48, 14)
  hScroll:SetThumbTexture(hThumb)
  main.hScroll = hScroll

  local syncingScroll = false
  local function syncTimelineScrollBars()
    if not pane or syncingScroll then return end
    syncingScroll = true
    local xrange = pane:GetHorizontalScrollRange() or 0
    local yrange = pane:GetVerticalScrollRange() or 0
    vScroll:SetMinMaxValues(0, math.max(yrange, 0.001))
    hScroll:SetMinMaxValues(0, math.max(xrange, 0.001))
    local vx = math.min(pane:GetVerticalScroll() or 0, yrange)
    local hx = math.min(pane:GetHorizontalScroll() or 0, xrange)
    vScroll:SetValue(vx)
    hScroll:SetValue(hx)
    if yrange > 1 then vScroll:Show() else vScroll:Hide() end
    if xrange > 1 then hScroll:Show() else hScroll:Hide() end
    syncingScroll = false
  end
  main.syncTimelineScrollBars = syncTimelineScrollBars

  vScroll:SetScript("OnValueChanged", function(_, value)
    if syncingScroll then return end
    pane:SetVerticalScroll(value)
  end)
  hScroll:SetScript("OnValueChanged", function(_, value)
    if syncingScroll then return end
    pane:SetHorizontalScroll(value)
  end)
  pane:SetScript("OnScrollRangeChanged", function()
    syncTimelineScrollBars()
  end)
  pane:SetScript("OnVerticalScroll", function()
    syncTimelineScrollBars()
  end)
  pane:SetScript("OnHorizontalScroll", function()
    syncTimelineScrollBars()
  end)
  pane:SetScript("OnMouseWheel", function(self, delta)
    if IsShiftKeyDown() then
      local max = self:GetHorizontalScrollRange() or 0
      local next = math.max(0, math.min(max, (self:GetHorizontalScroll() or 0) - delta * 80))
      self:SetHorizontalScroll(next)
    else
      local max = self:GetVerticalScrollRange() or 0
      local next = math.max(0, math.min(max, (self:GetVerticalScroll() or 0) - delta * 36))
      self:SetVerticalScroll(next)
    end
    syncTimelineScrollBars()
  end)

  local footerL = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footerL:SetPoint("BOTTOMLEFT", 18, 18)
  footerL:SetText("Scroll · Shift+scroll horizontal · hover bar for details")

  local footerR = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footerR:SetPoint("BOTTOMRIGHT", -18, 18)
  footerR:SetText("/alv to toggle  •  drag title bar to move")

  -- Export overlay
  local exportFrame = CreateFrame("Frame", nil, main, "BackdropTemplate")
  exportFrame:SetPoint("CENTER")
  exportFrame:SetSize(520, 280)
  exportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
  exportFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
  })
  exportFrame:SetBackdropColor(0.05, 0.05, 0.05, 1)
  exportFrame:Hide()
  main.exportFrame = exportFrame
  local exTitle = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  exTitle:SetPoint("TOP", 0, -16)
  exTitle:SetText("Export match string — Ctrl+C to copy")
  local exClose = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
  exClose:SetPoint("TOPRIGHT", -4, -4)
  local eb = CreateFrame("EditBox", nil, exportFrame)
  eb:SetMultiLine(true)
  eb:SetFontObject(GameFontHighlightSmall)
  eb:SetPoint("TOPLEFT", 20, -40)
  eb:SetPoint("BOTTOMRIGHT", -20, 20)
  eb:SetAutoFocus(false)
  eb:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
  main.exportBox = eb

  main:SetScript("OnShow", function()
    EnsureDB()
    selectedMatch = nil
    NS.RefreshViewer()
  end)
  main:SetScript("OnHide", function()
    if main.auraMenu then main.auraMenu:Hide() end
  end)
end

local function ToggleViewer()
  EnsureDB()
  if not main then buildMain() end
  main:SetShown(not main:IsShown())
end

local function UpdateMinimapPosition()
  if not miniBtn or not db then return end
  local angle = math.rad(db.minimapAngle or 200)
  miniBtn:ClearAllPoints()
  miniBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function EnsureMinimapButton()
  if miniBtn then return miniBtn end
  EnsureDB()
  local btn = CreateFrame("Button", "ArenaLogViewerMinimapButton", Minimap)
  btn:SetSize(32, 32)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")

  local overlay = btn:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")
  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 6, -6)
  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetSize(18, 18)
  icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
  icon:SetPoint("TOPLEFT", 7, -7)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  btn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      db.minimapHide = true
      btn:Hide()
      print(PREFIX .. ": minimap hidden — /alv minimap to show")
    else
      ToggleViewer()
    end
  end)
  btn:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = GetCursorPosition()
      local cx, cy = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      db.minimapAngle = math.deg(math.atan2(my / scale - cy, mx / scale - cx))
      UpdateMinimapPosition()
    end)
  end)
  btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Arena Log Viewer", GOLD[1], GOLD[2], GOLD[3])
    GameTooltip:AddLine(("Saved matches: |cffffffff%d|r"):format(NS.MatchCount and NS.MatchCount() or 0), 1, 1, 1)
    GameTooltip:AddLine("Left-click: open  ·  /alv test = mockup sample", 0.75, 0.75, 0.75)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", GameTooltip_Hide)

  miniBtn = btn
  UpdateMinimapPosition()
  btn:SetShown(not db.minimapHide)
  return btn
end

SLASH_ARENALOGVIEWER1 = "/alv"
SLASH_ARENALOGVIEWER2 = "/arenalogviewer"
SlashCmdList.ARENALOGVIEWER = function(msg)
  msg = strtrim(string.lower(msg or ""))
  EnsureDB()
  if msg == "minimap" then
    db.minimapHide = not db.minimapHide
    if miniBtn then miniBtn:SetShown(not db.minimapHide) end
    print(PREFIX .. ": minimap " .. (db.minimapHide and "hidden" or "shown"))
  elseif msg == "status" or msg == "debug" then
    if NS.DebugStatus then NS.DebugStatus() end
  elseif msg == "test" or msg == "demo" then
    if NS.LoadDemoMatches then NS.LoadDemoMatches() end
    if not main then buildMain() end
    selectedMatch = nil
    main:Show()
    NS.RefreshViewer()
  else
    ToggleViewer()
  end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  EnsureDB()
  EnsureMinimapButton()
  print(PREFIX .. " ready — |cffffffff/alv|r  ·  |cffffffff/alv test|r = mockup sample  ·  disk logs → web app")
end)
