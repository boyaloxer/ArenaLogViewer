-- UI.lua — WCL-style match list + timeline (ported look from tbc-arena-logs web app).
-- Spell icons via GetSpellTexture. Minimap clock toggles the viewer.

local ADDON, NS = ...
local PX_PER_SEC = 40          -- closer to the web app's ~52 default
local LABEL_W = 200
local ROW_H = 22
local SEG = 16
local RULER_H = 28
local PREFIX = "|cff66bbffArena Log Viewer|r"
local ICON_TEX = "Interface\\Icons\\INV_Misc_PocketWatch_01"

local main, miniBtn, db
local selectedMatch
local segPool, poolIdx = {}, 0
local rowPool = {}             -- { bg, icon, label, track }

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
  return string.format("%d:%04.1f", math.floor(s / 60), s % 60)
end

local function fmtRuler(sec)
  local m = math.floor(sec / 60)
  local r = sec - m * 60
  if m > 0 then return string.format("%d:%04.1f", m, r) end
  return string.format("%.0fs", r)
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
  if row then return row end
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
      row.bg:Hide(); row.icon:Hide(); row.label:Hide(); row.track:Hide()
    end
  end
end

local function clearRuler(content)
  if content.rulerTicks then
    for _, fs in ipairs(content.rulerTicks) do fs:Hide() end
  end
  if content.rulerLines then
    for _, tex in ipairs(content.rulerLines) do tex:Hide() end
  end
end

local function drawRuler(content, durationMs, pps, trackX)
  clearRuler(content)
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

  local majorEvery = (pps >= 48) and 1 or (pps >= 24) and 2 or 5
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
      line:SetColorTexture(0.22, 0.22, 0.25, 0.9)
      line:SetWidth(1)
      content.rulerLines[lineI] = line
    end
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", x, -RULER_H)
    line:SetHeight(math.max(#(selectedMatch and selectedMatch.timeline or {}) * ROW_H, 40))
    line:Show()
  end
  for i = tickI + 1, #(content.rulerTicks or {}) do content.rulerTicks[i]:Hide() end
  for i = lineI + 1, #(content.rulerLines or {}) do content.rulerLines[i]:Hide() end
end

local function renderMatch(match, content, pps)
  releaseAllSegs()
  selectedMatch = match
  if not match or type(match.timeline) ~= "table" then
    hideExtraRows(1)
    clearRuler(content)
    if content.emptyTrack then
      content.emptyTrack:SetText("No timeline for this match.")
      content.emptyTrack:Show()
    end
    return
  end
  if content.emptyTrack then content.emptyTrack:Hide() end

  local trackX = LABEL_W + 8
  local dur = math.max((match.durationMs or 0) / 1000, 1)
  local trackW = dur * pps
  drawRuler(content, match.durationMs, pps, trackX)

  if main and main.header then
    main.header:SetText(string.format("%s  ·  %s  ·  %d spells",
      match.map or "Arena", fmt(match.durationMs), #match.timeline))
  end

  for i, rowData in ipairs(match.timeline) do
    local y = -RULER_H - (i - 1) * ROW_H
    local row = ensureRow(content, i)
    local r, g, b = NS.SchoolColor(rowData.school)
    local tex = GetSpellTexture(rowData.spellId) or 134400

    row.bg:ClearAllPoints()
    row.bg:SetPoint("TOPLEFT", 0, y)
    row.bg:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
    if i % 2 == 0 then
      row.bg:SetColorTexture(1, 1, 1, 0.03)
    else
      row.bg:SetColorTexture(0, 0, 0, 0.15)
    end
    row.bg:Show()

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
      f.tipBody = fmt(seg.startMs) .. " · " .. seg.kind
        .. (seg.targetName and ("\n" .. (rowData.sourceName or "?") .. " → " .. seg.targetName) or "")

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
  hideExtraRows(#match.timeline + 1)
  content:SetSize(trackX + trackW + 40, RULER_H + #match.timeline * ROW_H + 20)
end

local function refreshSidebar(sideContent, content)
  if sideContent.buttons then
    for _, b in ipairs(sideContent.buttons) do b:Hide() end
  end
  sideContent.buttons = sideContent.buttons or {}
  local matches = ArenaLogViewerDB.matches or {}

  if sideContent.note then sideContent.note:Hide() end

  for i, m in ipairs(matches) do
    local b = sideContent.buttons[i]
    if not b then
      b = CreateFrame("Button", nil, sideContent, "UIPanelButtonTemplate")
      b:SetSize(200, 36)
      sideContent.buttons[i] = b
    end
    b:SetPoint("TOPLEFT", 4, -(i - 1) * 40 - 4)
    b:SetText(("%s\n|cffaaaaaa%s|r"):format(m.map or "Arena", fmt(m.durationMs or 0)))
    -- UIPanelButtonTemplate may not wrap; use short single line
    b:SetText(("%d. %s (%s)"):format(i, m.map or "?", fmt(m.durationMs or 0)))
    b:SetScript("OnClick", function()
      renderMatch(m, content, db.pxPerSec or PX_PER_SEC)
    end)
    b:Show()
  end
  sideContent:SetHeight(math.max(#matches, 1) * 40 + 60)

  if #matches == 0 then
    if not sideContent.emptyHint then
      sideContent.emptyHint = sideContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      sideContent.emptyHint:SetPoint("TOPLEFT", 8, -8)
      sideContent.emptyHint:SetWidth(190)
      sideContent.emptyHint:SetJustifyH("LEFT")
    end
    if NS.IsRecording and NS.IsRecording() then
      sideContent.emptyHint:SetText("Recording this arena…\nLeave the match to save it.")
    else
      sideContent.emptyHint:SetText(
        "No live matches yet.\n\n" ..
        "|cffffffffDisk WoWCombatLog files|r are for the\n" ..
        "web app (TBC Arena Logs), not this\n" ..
        "window — Lua can't read those files.\n\n" ..
        "Queue arenas to record here, or\n" ..
        "|cffffffff/alv test|r for a sample.")
    end
    sideContent.emptyHint:Show()
  else
    if sideContent.emptyHint then sideContent.emptyHint:Hide() end
    -- Auto-open newest match
    renderMatch(matches[#matches], content, db.pxPerSec or PX_PER_SEC)
  end
end

local function buildMain()
  EnsureDB()
  main = CreateFrame("Frame", "ArenaLogViewerFrame", UIParent, "BackdropTemplate")
  main:SetSize(1100, 640)
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
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  main:SetBackdropColor(0.02, 0.02, 0.02, 0.97)
  main:SetBackdropBorderColor(0.15, 0.15, 0.18, 1)
  main:Hide()

  local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("Arena Log Viewer")
  title:SetTextColor(0.9, 0.9, 0.95)

  local header = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header:SetPoint("LEFT", title, "RIGHT", 16, 0)
  header:SetTextColor(0.65, 0.7, 0.75)
  main.header = header

  local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  -- Sidebar
  local sideBg = CreateFrame("Frame", nil, main, "BackdropTemplate")
  sideBg:SetPoint("TOPLEFT", 10, -36)
  sideBg:SetSize(220, 590)
  sideBg:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  sideBg:SetBackdropColor(0.04, 0.04, 0.045, 1)
  sideBg:SetBackdropBorderColor(0.12, 0.12, 0.14, 1)

  local side = CreateFrame("ScrollFrame", nil, sideBg, "UIPanelScrollFrameTemplate")
  side:SetPoint("TOPLEFT", 4, -4)
  side:SetPoint("BOTTOMRIGHT", -26, 4)
  local sideContent = CreateFrame("Frame", nil, side)
  sideContent:SetSize(190, 10)
  side:SetScrollChild(sideContent)
  main.sideContent = sideContent

  -- Timeline pane
  local paneBg = CreateFrame("Frame", nil, main, "BackdropTemplate")
  paneBg:SetPoint("TOPLEFT", 238, -36)
  paneBg:SetPoint("BOTTOMRIGHT", -10, 14)
  paneBg:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  paneBg:SetBackdropColor(0, 0, 0, 1)
  paneBg:SetBackdropBorderColor(0.12, 0.12, 0.14, 1)

  local pane = CreateFrame("ScrollFrame", nil, paneBg, "UIPanelScrollFrameTemplate")
  pane:SetPoint("TOPLEFT", 6, -6)
  pane:SetPoint("BOTTOMRIGHT", -28, 6)
  local content = CreateFrame("Frame", nil, pane)
  content:SetSize(100, 100)
  pane:SetScrollChild(content)
  main.content = content

  content.emptyTrack = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  content.emptyTrack:SetPoint("TOPLEFT", 20, -40)
  content.emptyTrack:Hide()

  -- Zoom buttons
  local zoomOut = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
  zoomOut:SetSize(28, 22)
  zoomOut:SetPoint("TOPRIGHT", -40, -8)
  zoomOut:SetText("-")
  zoomOut:SetScript("OnClick", function()
    db.pxPerSec = math.max(12, (db.pxPerSec or PX_PER_SEC) - 8)
    if selectedMatch then renderMatch(selectedMatch, content, db.pxPerSec) end
  end)
  local zoomIn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
  zoomIn:SetSize(28, 22)
  zoomIn:SetPoint("RIGHT", zoomOut, "LEFT", -4, 0)
  zoomIn:SetText("+")
  zoomIn:SetScript("OnClick", function()
    db.pxPerSec = math.min(80, (db.pxPerSec or PX_PER_SEC) + 8)
    if selectedMatch then renderMatch(selectedMatch, content, db.pxPerSec) end
  end)

  main:SetScript("OnShow", function()
    EnsureDB()
    refreshSidebar(sideContent, content)
  end)
end

local function ToggleViewer()
  EnsureDB()
  if not main then buildMain() end
  main:SetShown(not main:IsShown())
end

-- =====================================================================
-- Minimap button
-- =====================================================================
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
  icon:SetTexture(ICON_TEX)
  icon:SetPoint("TOPLEFT", 7, -7)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  btn.icon = icon

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
    GameTooltip:AddLine("Arena Log Viewer", 0.4, 0.75, 1)
    GameTooltip:AddLine(("Saved matches: |cffffffff%d|r"):format(NS.MatchCount and NS.MatchCount() or 0), 1, 1, 1)
    if NS.IsRecording and NS.IsRecording() then
      GameTooltip:AddLine("Status: |cff88ff88RECORDING|r", 1, 1, 1)
    else
      GameTooltip:AddLine("Live recorder (not disk combat logs)", 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine("Left-click: open  ·  /alv test for sample", 0.75, 0.75, 0.75)
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
  elseif msg == "test" then
    if NS.InsertTestMatch then NS.InsertTestMatch() end
    if not main then buildMain() end
    main:Show()
  else
    ToggleViewer()
  end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  EnsureDB()
  EnsureMinimapButton()
  print(PREFIX .. " ready — |cffffffff/alv|r ("
    .. (NS.MatchCount and NS.MatchCount() or 0)
    .. " live). Disk logs → web app. |cffffffff/alv test|r = sample.")
end)
