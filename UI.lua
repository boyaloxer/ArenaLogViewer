-- UI.lua — in-game viewer frame: match list sidebar + scrollable timeline.
-- Textures are pooled; spell icons come from GetSpellTexture(spellId).

local ADDON, NS = ...
local PX_PER_SEC_DEFAULT = 9
local ROW_H, SEG = 22, 16

local main -- lazily created

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
  local s = ms / 1000
  return string.format("%d:%04.1f", math.floor(s / 60), s % 60)
end

local function renderMatch(match, content, pps)
  releaseAll()
  local trackX = 190
  for i, row in ipairs(match.timeline) do
    local y = -(i - 1) * ROW_H - 24
    -- label
    local label = content.labels and content.labels[i]
    if not label then
      content.labels = content.labels or {}
      label = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      content.labels[i] = label
    end
    label:SetPoint("TOPLEFT", 22, y - 4)
    local r, g, b = NS.SchoolColor(row.school)
    label:SetText(row.spellName); label:SetTextColor(r, g, b); label:Show()
    -- segments
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
  content:SetSize(trackX + (match.durationMs / 1000) * pps + 40,
    #match.timeline * ROW_H + 40)
end

local function buildMain()
  main = CreateFrame("Frame", "ArenaLogViewerFrame", UIParent, "BasicFrameTemplateWithInset")
  main:SetSize(980, 620); main:SetPoint("CENTER")
  main:SetMovable(true); main:EnableMouse(true)
  main:RegisterForDrag("LeftButton")
  main:SetScript("OnDragStart", main.StartMoving)
  main:SetScript("OnDragStop", main.StopMovingOrSizing)
  main.TitleText:SetText("Arena Log Viewer")

  -- sidebar: one button per stored match
  local side = CreateFrame("ScrollFrame", nil, main, "UIPanelScrollFrameTemplate")
  side:SetPoint("TOPLEFT", 8, -28); side:SetSize(210, 580)
  local sideContent = CreateFrame("Frame", nil, side)
  sideContent:SetSize(210, 10); side:SetScrollChild(sideContent)

  -- timeline scroll pane
  local pane = CreateFrame("ScrollFrame", nil, main, "UIPanelScrollFrameTemplate")
  pane:SetPoint("TOPLEFT", 240, -28); pane:SetPoint("BOTTOMRIGHT", -28, 8)
  local content = CreateFrame("Frame", nil, pane)
  content:SetSize(100, 100); pane:SetScrollChild(content)
  main.content = content

  for i, m in ipairs(ArenaLogViewerDB.matches) do
    local b = CreateFrame("Button", nil, sideContent, "UIPanelButtonTemplate")
    b:SetSize(195, 34); b:SetPoint("TOPLEFT", 0, -(i - 1) * 38)
    b:SetText(("Match %d — %s (%s)"):format(i, m.map or "?", fmt(m.durationMs or 0)))
    b:SetScript("OnClick", function() renderMatch(m, content, PX_PER_SEC_DEFAULT) end)
  end
  sideContent:SetHeight(#ArenaLogViewerDB.matches * 38 + 10)
end

SLASH_ARENALOGVIEWER1 = "/alv"
SlashCmdList.ARENALOGVIEWER = function()
  if not main then buildMain() end
  main:SetShown(not main:IsShown())
end
