-- ZugLoot/SRView.lua
-- Fancy read-only sheet window: sorted by item, player xN (+SR+), WON marks.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.SRView = M

local frame = nil
local content = nil

local function classColor(name)
  if Z.ClassColors and Z.ClassColors.ColoredName then
    local c = Z.ClassColors.ClassOf(name)
    if c then return "|c" .. (Z.ClassColors.COLORS[c] or "FFFFFFFF") end
  end
  return "|cFFFFFFFF"
end

function M.FormatRollerRow(r, won)
  local plus = (r.sr_plus and r.sr_plus > 0) and (" |c" .. Z.Colors.GOLD .. "(+" .. r.sr_plus .. ")|r") or ""
  local n = " x" .. tostring(r.rolls or 1)
  if won then
    return classColor(r.name) .. r.name .. "|r" .. n .. plus .. "  |c" .. Z.Colors.RED .. "[WON]|r"
  end
  return classColor(r.name) .. r.name .. "|r" .. n .. plus
end

-- Pure text render used by tests (no frames).
function M.RenderText(sheet)
  local out = {}
  if not sheet then return { "(no sheet imported)" } end
  table.insert(out, "raidID=" .. tostring(sheet.meta and sheet.meta.raidID) .. " by=" .. tostring(sheet.meta and sheet.meta.importedBy))
  for _, id in ipairs(Z.SRData.SortedCardIDs(sheet)) do
    local rollers = Z.SRData.GetRollers(sheet, id)
    local unsr = Z.SRData.IsUnreserved and Z.SRData.IsUnreserved(sheet, id)
    table.insert(out, "item " .. id .. ":" .. (unsr and " [not SR'd]" or ""))
    for i = 1, Z.Util.ArrayCount(rollers) do
      local r = rollers[i]
      local won = Z.SRData.HasWon(sheet, id, r.name)
      local plus = (r.sr_plus and r.sr_plus > 0) and (" (+" .. r.sr_plus .. ")") or ""
      table.insert(out, "  " .. r.name .. " x" .. (r.rolls or 1) .. plus .. (won and " [WON]" or ""))
    end
  end
  return out
end

function M.Build()
  frame = CreateFrame("Frame", "ZugLootSheetFrame", UIParent)
  frame:SetWidth(460) frame:SetHeight(480)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetMovable(true) frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  frame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  frame:SetBackdropColor(0, 0, 0, 0.92)
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", frame, "TOP", 0, -10)
  title:SetText("ZugLoot — SR Sheet")
  content = frame:CreateFontString("ZugLootSheetContent", "OVERLAY", "GameFontHighlightSmall")
  content:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -40)
  content:SetWidth(428) content:SetJustifyH("LEFT")
  if content.SetJustifyV then content:SetJustifyV("TOP") end
  local importBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  importBtn:SetWidth(90) importBtn:SetHeight(22)
  importBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
  importBtn:SetText("Import")
  importBtn:SetScript("OnClick", function() Z.SRImport.ShowPaste() end)
  local fileBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  fileBtn:SetWidth(120) fileBtn:SetHeight(22)
  fileBtn:SetPoint("BOTTOM", frame, "BOTTOM", -30, 12)
  fileBtn:SetText("Load from File")
  fileBtn:SetScript("OnClick", function() Z.SRImport.LoadFromFile() end)
  local closeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  closeBtn:SetWidth(80) closeBtn:SetHeight(22)
  closeBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 12)
  closeBtn:SetText("Close")
  closeBtn:SetScript("OnClick", function() frame:Hide() end)
  frame:Hide()
end

function M.Refresh()
  if not frame then return end
  if not Z.DB or not Z.DB.sheet then
    content:SetText("(no sheet imported — ML/RL: /zl import or Load from File)")
    return
  end
  local text = table.concat(M.RenderText(Z.DB.sheet), "\n")
  -- In-game frame shows item links when available; text render is the fallback.
  content:SetText(text)
end

function M.Toggle()
  -- Delegates to the tabbed main window (Sheet tab); kept for API compat.
  if Z.MainWindow then Z.MainWindow.Toggle("sheet") return end
  if not frame then M.Build() end
  if frame:IsVisible() then frame:Hide() else M.Refresh() frame:Show() end
end
