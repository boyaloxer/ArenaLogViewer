-- UI.lua — in-game viewer frame: match list sidebar + scrollable timeline.
-- Textures are pooled; spell icons come from GetSpellTexture(spellId).
-- Minimap button toggles the viewer (same idea as ArenaCombatLog).

local ADDON, NS = ...
local PX_PER_SEC_DEFAULT = 9
local ROW_H, SEG = 22, 16
local PREFIX = "|cff66bbffArena Log Viewer|r"
local ICON_TEX = "Interface\\Icons\\INV_Misc_PocketWatch_01"

local main -- lazily created
local miniBtn
local db

local function EnsureDB()
  ArenaLogViewerDB = ArenaLogViewerDB or {}
  db = ArenaLogViewerDB
  db.matches = db.matches or {}
  if db.minimapAngle == nil then db.minimapAngle = 200 end
  if db.minimapHide == nil then db.minimapHide = false end
end

local segPool, poolIdx = {}, 0
local function acquireSeg(parent)
  poolIdx = poolIdx + 1
  local t = segPool[poolIdx]
  if not t then
    t = CreateFrame("Frame", nil, parent)
    t.tex = t:CreateTexture(nil, "ARTWORK")
    t.tex:SetAllPoints()
    t:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
      GameTooltip:SetText(self.tipTitle, 1, 0.82, 0)
      GameTooltip:AddLine(self.tipBody, 0.9, 0.9, 0.9)
      GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    segPool[poolIdx] = t
  end
  t:SetParent(parent); t:Show()
  return t
end
local function releaseAll()
  for _, t in ipairs(segPool) do t:Hide() end
  poolIdx = 0
end

local function fmt(ms)
  local s = (ms or 0) / 1000
  return string.format("%d:%04.1f", math.floor(s / 60), s % 60)
end

local function renderMatch(match, content, pps)
  releaseAll()
  if content.labels then
    for _, label in ipairs(content.labels) do label:Hide() end
  end
  if not match or not match.timeline then return end
  local trackX = 190
  for i, row in ipairs(match.timeline) do
    local y = -(i - 1) * ROW_H - 24
    local label = content.labels and content.labels[i]
    if not label then
      content.labels = content.labels or {}
      label = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      content.labels[i] = label
    end
    label:SetPoint("TOPLEFT", 22, y - 4)
    local r, g, b = NS.SchoolColor(row.school)
    label:SetText(row.spellName); label:SetTextColor(r, g, b); label:Show()
    for _, seg in ipairs(row.segments) do
      local f = acquireSeg(content)
      local x = trackX + (seg.startMs / 1000) * pps
      f:SetPoint("TOPLEFT", x, y - 3)
      f.tipTitle = row.spellName
      f.tipBody = fmt(seg.startMs) .. " · " .. seg.kind ..
        (seg.targetName and ("\n" .. row.sourceName .. " -> " .. seg.targetName) or "")
      if seg.kind == "cast" then
        f:SetSize(SEG, SEG)
        f.tex:SetTexture(GetSpellTexture(row.spellId) or 134400)
        f.tex:SetVertexColor(1, 1, 1)
      else
        local w = math.max(((seg.endMs or seg.startMs) - seg.startMs) / 1000 * pps, SEG)
        f:SetSize(w, SEG)
        f.tex:SetColorTexture(r, g, b, 0.85)
      end
    end
  end
  content:SetSize(trackX + ((match.durationMs or 0) / 1000) * pps + 40,
    #match.timeline * ROW_H + 40)
end

local function refreshSidebar(sideContent, content)
  if sideContent.buttons then
    for _, b in ipairs(sideContent.buttons) do b:Hide() end
  end
  sideContent.buttons = sideContent.buttons or {}
  local matches = ArenaLogViewerDB.matches or {}
  for i, m in ipairs(matches) do
    local b = sideContent.buttons[i]
    if not b then
      b = CreateFrame("Button", nil, sideContent, "UIPanelButtonTemplate")
      b:SetSize(195, 34)
      sideContent.buttons[i] = b
    end
    b:SetPoint("TOPLEFT", 0, -(i - 1) * 38)
    b:SetText(("Match %d — %s (%s)"):format(i, m.map or "?", fmt(m.durationMs or 0)))
    b:SetScript("OnClick", function()
      renderMatch(m, content, PX_PER_SEC_DEFAULT)
    end)
    b:Show()
  end
  sideContent:SetHeight(math.max(#matches, 1) * 38 + 10)

  if #matches == 0 then
    if not sideContent.emptyHint then
      sideContent.emptyHint = sideContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
      sideContent.emptyHint:SetPoint("TOPLEFT", 8, -8)
      sideContent.emptyHint:SetWidth(180)
      sideContent.emptyHint:SetJustifyH("LEFT")
    end
    if NS.IsRecording and NS.IsRecording() then
      sideContent.emptyHint:SetText("Recording this arena now.\nLeave the match to save it here.")
    else
      sideContent.emptyHint:SetText("No matches yet.\nQueue an arena — you'll see\n\"recording\" in chat when it starts.")
    end
    sideContent.emptyHint:Show()
  elseif sideContent.emptyHint then
    sideContent.emptyHint:Hide()
  end
end

local function buildMain()
  EnsureDB()
  main = CreateFrame("Frame", "ArenaLogViewerFrame", UIParent, "BasicFrameTemplateWithInset")
  main:SetSize(980, 620); main:SetPoint("CENTER")
  main:SetMovable(true); main:EnableMouse(true)
  main:RegisterForDrag("LeftButton")
  main:SetScript("OnDragStart", main.StartMoving)
  main:SetScript("OnDragStop", main.StopMovingOrSizing)
  main.TitleText:SetText("Arena Log Viewer")
  main:Hide()

  local side = CreateFrame("ScrollFrame", nil, main, "UIPanelScrollFrameTemplate")
  side:SetPoint("TOPLEFT", 8, -28); side:SetSize(210, 580)
  local sideContent = CreateFrame("Frame", nil, side)
  sideContent:SetSize(210, 10); side:SetScrollChild(sideContent)
  main.sideContent = sideContent

  local pane = CreateFrame("ScrollFrame", nil, main, "UIPanelScrollFrameTemplate")
  pane:SetPoint("TOPLEFT", 240, -28); pane:SetPoint("BOTTOMRIGHT", -28, 8)
  local content = CreateFrame("Frame", nil, pane)
  content:SetSize(100, 100); pane:SetScrollChild(content)
  main.content = content

  main:SetScript("OnShow", function()
    EnsureDB()
    refreshSidebar(sideContent, content)
  end)
end

local function ToggleViewer()
  EnsureDB()
  if not main then buildMain() end
  if main:IsShown() then
    main:Hide()
  else
    main:Show()
  end
end

-- =====================================================================
-- Minimap button
-- =====================================================================
local function UpdateMinimapPosition()
  if not miniBtn or not db then return end
  local angle = math.rad(db.minimapAngle or 200)
  local x = math.cos(angle) * 80
  local y = math.sin(angle) * 80
  miniBtn:ClearAllPoints()
  miniBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
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
      print(PREFIX .. ": minimap button hidden — /alv minimap to show again")
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

  btn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Arena Log Viewer", 0.4, 0.75, 1)
    local n = NS.MatchCount and NS.MatchCount() or #(ArenaLogViewerDB.matches or {})
    GameTooltip:AddLine(("Saved matches: |cffffffff%d|r"):format(n), 1, 1, 1)
    if NS.IsRecording and NS.IsRecording() then
      GameTooltip:AddLine("Status: |cff88ff88RECORDING|r", 1, 1, 1)
      btn.icon:SetVertexColor(0.45, 1, 0.55)
    else
      GameTooltip:AddLine("Status: idle (queue an arena)", 0.75, 0.75, 0.75)
      btn.icon:SetVertexColor(1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffaaaaaaLeft-click:|r open / close viewer", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffaaaaaaRight-click:|r hide this button", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffaaaaaaDrag:|r move button", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffaaaaaa/alv|r also toggles the window", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)

  btn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  miniBtn = btn
  UpdateMinimapPosition()
  if db.minimapHide then
    btn:Hide()
  else
    btn:Show()
  end
  return btn
end

SLASH_ARENALOGVIEWER1 = "/alv"
SLASH_ARENALOGVIEWER2 = "/arenalogviewer"
SlashCmdList.ARENALOGVIEWER = function(msg)
  msg = strtrim(string.lower(msg or ""))
  EnsureDB()
  if msg == "minimap" then
    db.minimapHide = not db.minimapHide
    if miniBtn then
      miniBtn:SetShown(not db.minimapHide)
    end
    print(PREFIX .. ": minimap button " .. (db.minimapHide and "hidden" or "shown"))
    return
  end
  ToggleViewer()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  EnsureDB()
  EnsureMinimapButton()
  print(PREFIX .. " ready — click the |cffffffffminimap clock icon|r or type |cffffffff/alv|r.")
end)
