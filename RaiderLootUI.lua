-- ZugLoot/RaiderLootUI.lua
-- Raider roll window, LootBlare look-and-feel: compact dark frame, green
-- countdown bar on top, big item icon + quality-colored name, two-column
-- roll list (class-colored names left, "roll (min-max)" in roll-type color
-- right, grouped SR > MS > OS > TMOG), four dice buttons at the bottom,
-- top-screen winner banner. Master-loot rolls ONLY by default: the
-- window pops off the master looter's roll call (ROLL_REQ addon message
-- or their RW line) and stays shut in every other mode — group loot,
-- solo, or anyone else's chat. In group loot Blizzard's own Need/Greed
-- frames own the vote (mirroring them would double-vote or forfeit);
-- solo has nobody to roll against. Opt-out lives in Setup
-- (Z.DB.raiderFrame = "ml" | "all"): "all" restores the legacy
-- group-loot mirror + local preview. Nothing else reads that flag.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.RaiderLootUI = M

-- Frame policy: "ml" (default) = master-loot rolls only; "all" =
-- legacy (also mirror group-loot rolls + local preview). Pure helper
-- so tests pin the default without frames.
function M.FrameMode()
  if Z.DB and Z.DB.raiderFrame == "all" then return "all" end
  return "ml"
end

-- May the raider frame open for a MASTER-LOOT roll right now? Default
-- yes in a group under master loot; solo opens only in "all" mode
-- (local preview). The loot-method read is live (GetLootMethod first,
-- SRSecurity fallback) so a mid-raid method switch takes effect at
-- once. Headless (no loot APIs): group-absent reads as non-master,
-- which keeps headless preview tests on the explicit "all" opt-in.
function M.AllowMasterFrame()
  if M.FrameMode() == "all" then return true end
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return false end
  local method = nil
  if GetLootMethod then
    local ok, m = pcall(GetLootMethod)
    if ok then method = m end
  end
  if method == nil and Z.SRSecurity and Z.SRSecurity.LootMethod then
    local ok, m = pcall(Z.SRSecurity.LootMethod)
    if ok then method = m end
  end
  return method == "master"
end

local frame = nil
local itemIcon = nil
local iconButton = nil
local itemName = nil
local timerText = nil
local leftText = nil
local rightText = nil
local statusBar = nil
local statusText = nil
local resultFrame = nil
local resultText = nil

local timeLeft = 0
local duration = 15
local active = false
local lastSec = -1

M.rolls = {}

-- Class/kind colors live in the shared RollList view (same view the
-- master-looter detail paints through).
local ROLL_BUTTONS = {
  { label = "SR", type = "SR", capKey = "SR", color = "ffe5302d",
    rgb = { 0.898, 0.188, 0.176 }, tip = "Roll for Soft Reserve" },
  { label = "MS", type = "MS", capKey = "MS", color = "FFFFFF00",
    rgb = { 1.0, 1.0, 0.0 }, tip = "Roll for Main Spec" },
  { label = "OS", type = "OS", capKey = "OS", color = "FF00FF00",
    rgb = { 0.0, 1.0, 0.0 }, tip = "Roll for Off Spec" },
  { label = "TM", type = "TMOG", capKey = "TMOG", color = "FF00FFFF",
    rgb = { 0.0, 1.0, 1.0 }, tip = "Roll for Transmog" },
}

local function caps()
  if Z.Caps then return Z.Caps end
  return { SR = 100, MS = 100, OS = 99, TMOG = 98 }
end

local function rangeFor(rtype)
  local c = caps()
  if rtype == "OS" then return 1, (c.OS or 99) end
  if rtype == "TMOG" then return 1, (c.TMOG or 98) end
  return 1, (c.SR or 100)
end

-- Class name for roll-list coloring: raid roster first, then self, then
-- the SR sheet fallback (ClassColors.ClassOf). Anything missing falls
-- back to nil = white.
function M.PlayerClass(name)
  if not name then return nil end
  if Z.ClassColors and Z.ClassColors.ClassOf then
    return Z.ClassColors.ClassOf(name)
  end
  if GetNumRaidMembers and GetRaidRosterInfo and GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      local n, _, _, _, class = GetRaidRosterInfo(i)
      if n == name then return class end
    end
  end
  if UnitName and UnitClass and name == UnitName("player") then
    local class = UnitClass("player")
    return class
  end
  return nil
end

-- Re-render the two-column list through the shared RollList view
-- (same grouping/colors/ranges as the master-looter detail, capped at
-- 8 visible rows per LootBlare parity).
local function RenderRolls()
  if Z.RollList and Z.RollList.Paint then
    Z.RollList.Paint(leftText, rightText, M.rolls, { maxRows = 8 })
  end
end

local function ClearRolls()
  M.rolls = {}
  if leftText then leftText:SetText("") end
  if rightText then rightText:SetText("") end
end

local function SetItemInfo(link)
  local iconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
  local name, quality = nil, nil
  if link then
    -- Sheet-style resolution via the shared link-first chain
    -- (GetItemInfo(link), then GetItemInfo(id), then [Name] parse): the
    -- bare-ID call alone misses whenever the cache key is the full link.
    -- A bare item NAME (Pysanka-style roll call, no link/id at all)
    -- skips resolution entirely: the name IS the display.
    local isBareName = not string.find(tostring(link), "|Hitem:", 1, true)
      and not string.find(tostring(link), "item:", 1, true)
    if isBareName then
      name = tostring(link)
    elseif Z.LootWindow and Z.LootWindow.ResolveItemInfo then
      local id = string.match(tostring(link), "item:(%d+)")
      local n, fullLink, q, tex = Z.LootWindow.ResolveItemInfo(
        id and tonumber(id), link, nil, nil, nil)
      if n then
        name, quality = n, q
        if fullLink and fullLink ~= "" then
          link = fullLink -- full color link for tooltip/shift-click parity
        end
        if tex then iconPath = tex end
      end
    elseif GetItemInfo then
      local id = string.match(tostring(link), "item:(%d+)")
      if id then
        local n, _, q, _, _, _, _, _, tex = GetItemInfo(tonumber(id))
        if n then
          name, quality = n, q
          if tex then iconPath = tex end
        end
      end
    end
    if not name then
      name = string.match(tostring(link), "%[(.-)%]")
    end
    -- A bare item NAME (Pysanka-style roll call, no link) has no cache
    -- entry: keep the name itself instead of falling back to "?".
    if not name and not string.find(tostring(link), "|Hitem:", 1, true)
        and not string.find(tostring(link), "item:", 1, true) then
      name = tostring(link)
    end
  end
  if itemIcon then itemIcon:SetTexture(iconPath) end
  if iconButton and iconButton.SetNormalTexture then iconButton:SetNormalTexture(iconPath) end
  M.iconPath = iconPath -- exposed for tests/headless
  M.itemNameText = (name and tostring(name)) or nil
  if itemName then
    if name and quality and GetItemQualityColor then
      local _, _, _, hex = GetItemQualityColor(quality)
      itemName:SetText((hex or "") .. tostring(name) .. "|r")
    elseif name then
      itemName:SetText(tostring(name))
    else
      itemName:SetText(tostring(link or "?"))
    end
  end
  if frame then
    if quality and GetItemQualityColor then
      local r, g, b = GetItemQualityColor(quality)
      frame:SetBackdropBorderColor(r or 0.2, g or 0.2, b or 0.2)
    else
      frame:SetBackdropBorderColor(0.2, 0.2, 0.2)
    end
  end
  M.itemLink = link
end

function M.Build()
  frame = CreateFrame("Frame", "ZugLootLootFrame", UIParent)
  frame:SetWidth(220) frame:SetHeight(250)
  -- Default RIGHT of center (clear of the ML roll detail at ~+90):
  -- raiders look right, the ML's windows tile center-left. Draggable.
  frame:SetPoint("CENTER", UIParent, "CENTER", 320, 100)
  frame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:SetBackdropBorderColor(0.2, 0.2, 0.2)
  frame:SetMovable(true) frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end

  local xb = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  xb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
  xb:SetScript("OnClick", function() M.Hide() end)

  -- Countdown bar floating above the frame (LootBlare placement).
  statusBar = CreateFrame("StatusBar", nil, frame)
  statusBar:SetWidth(200) statusBar:SetHeight(16)
  statusBar:SetPoint("TOP", frame, "TOP", 0, 20)
  statusBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  statusBar:SetStatusBarColor(0.2, 0.7, 0.2, 1)
  statusBar:Hide()
  statusText = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusText:SetPoint("CENTER", statusBar, "CENTER", 0, 0)

  -- Item icon + name header.
  itemIcon = frame:CreateTexture(nil, "ARTWORK")
  itemIcon:SetWidth(40) itemIcon:SetHeight(40)
  itemIcon:SetPoint("TOP", frame, "TOP", 0, -10)
  iconButton = CreateFrame("Button", nil, frame)
  iconButton:SetWidth(40) iconButton:SetHeight(40)
  iconButton:SetPoint("TOP", frame, "TOP", 0, -10)
  -- Item icon: shared handlers (ItemIcon.lua) — same hover/ctrl/shift
  -- as every other icon in the addon. Live state at event time (the
  -- detail flips items under this button while rolling).
  if Z.ItemIcon and Z.ItemIcon.Wire and iconButton then
    Z.ItemIcon.Wire(iconButton, function()
      return { itemID = Z.Util and Z.Util.ItemID(M.itemLink),
        link = M.itemLink, name = M.itemNameText,
        onLink = function(full) M.itemLink = full end }
    end)
  end

  timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  timerText:SetPoint("CENTER", frame, "TOPLEFT", 30, -32)
  if timerText.SetFont then
    local f = timerText:GetFont()
    if f then timerText:SetFont(f, 20) end
  end

  itemName = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  itemName:SetPoint("TOP", itemIcon, "BOTTOM", 0, -10)
  itemName:SetWidth(200)
  itemName:SetJustifyH("CENTER")

  -- Two-column roll list.
  leftText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  leftText:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -73)
  leftText:SetJustifyH("LEFT")
  leftText:SetWidth(130)
  leftText:SetHeight(150)
  rightText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rightText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -73)
  rightText:SetJustifyH("RIGHT")
  rightText:SetWidth(120)
  rightText:SetHeight(150)

  -- Dice buttons along the bottom.
  local panelW = 220
  local bw, n = 32, 4
  local spacing = (panelW - (n * bw)) / (n + 1)
  for i = 1, n do
    local b = ROLL_BUTTONS[i]
    local btn = CreateFrame("Button", nil, frame)
    btn:SetWidth(bw + 10) btn:SetHeight(bw + 6)
    btn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT",
      i * spacing + (i - 1) * bw - 6, 5)
    btn:SetText(b.label)
    local font = btn:GetFontString()
    if font then
      -- Keep the template font (never hardcode a Fonts\ path: file
      -- layout varies across clients and a missing file blanks the
      -- text); only shrink + outline via the font's own path.
      if font.GetFont and font.SetFont then
        local okF, fpath = pcall(font.GetFont, font)
        if okF and fpath and fpath ~= "" then
          pcall(font.SetFont, font, fpath, 8, "OUTLINE")
        end
      end
      font:SetPoint("TOP", btn, "TOP", 0, -3)
      font:SetTextColor(0.7, 0.7, 0.7)
    end
    btn:SetBackdrop({ edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      edgeSize = 12, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    local rgb = b.rgb
    btn:SetBackdropBorderColor(rgb[1] * 0.7, rgb[2] * 0.7, rgb[3] * 0.7, 1)
    btn:SetScript("OnEnter", function()
      btn:SetBackdropBorderColor(rgb[1], rgb[2], rgb[3], 1)
      if font then font:SetTextColor(1, 1, 1) end
      if GameTooltip then
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        local cap = (caps()[b.capKey] or 100)
        GameTooltip:SetText(b.tip .. " (1-" .. cap .. ")", 1, 1, 1, 1, true)
        GameTooltip:Show()
      end
    end)
    btn:SetScript("OnLeave", function()
      btn:SetBackdropBorderColor(rgb[1] * 0.7, rgb[2] * 0.7, rgb[3] * 0.7, 1)
      if font then font:SetTextColor(0.7, 0.7, 0.7) end
      if GameTooltip then GameTooltip:Hide() end
    end)
    local btype, bcap = b.type, (caps()[b.capKey] or 100)
    btn:SetScript("OnClick", function() M.DoRoll(btype, bcap) end)
  end

  frame:SetScript("OnUpdate", function()
    if not active then return end
    timeLeft = timeLeft - (arg1 or 0)
    local remaining = timeLeft
    if remaining < 0 then remaining = 0 end
    local curSec = math.floor(remaining)
    if statusBar and statusBar:IsShown() then
      statusBar:SetValue(remaining)
      if statusText and curSec ~= lastSec then statusText:SetText(string.format("%.0fs", remaining)) end
      local pct = (duration > 0) and (remaining / duration) or 0
      if pct < 0.25 then
        statusBar:SetStatusBarColor(1, 0.1, 0.1)
      elseif pct < 0.5 then
        statusBar:SetStatusBarColor(1, 0.6, 0)
      else
        statusBar:SetStatusBarColor(0.2, 0.7, 0.2)
      end
      if remaining <= 5 and remaining > 0 and GetTime then
        statusBar:SetAlpha(0.5 + 0.5 * math.sin(GetTime() * 15))
      else
        statusBar:SetAlpha(1)
      end
    end
    if timerText and curSec ~= lastSec then timerText:SetText(string.format("%.0f", remaining)) end
    lastSec = curSec
    if timeLeft <= 0 then
      if statusBar then statusBar:Hide() statusBar:SetAlpha(1) end
      local autoClose = (Z.DB and Z.DB.autoClose ~= false)
      if autoClose then M.Hide()
      else active = false end
    end
  end)
  frame:Hide()
end

-- Top-screen winner banner (LootBlare ShowRollResultMessage parity).
function M.ShowResult(message)
  if not resultFrame then
    resultFrame = CreateFrame("Frame", "ZugLootRollResultFrame", UIParent)
    resultFrame:SetWidth(600) resultFrame:SetHeight(80)
    resultFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    resultText = resultFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    resultText:SetAllPoints()
    resultText:SetJustifyH("CENTER")
    if resultText.SetJustifyV then resultText:SetJustifyV("MIDDLE") end
    resultFrame:Hide()
  end
  resultText:SetText(message or "")
  resultFrame:Show()
  if GetTime then
    local startTime = GetTime()
    resultFrame:SetScript("OnUpdate", function()
      if GetTime() - startTime >= 5 then
        resultFrame:Hide()
        resultFrame:SetScript("OnUpdate", nil)
      end
    end)
  end
end

-- Gatekeeper: every frame-open funnels through here. Master-loot
-- rolls open when AllowMasterFrame says so; the group-loot mirror
-- (START_LOOT_ROLL) opens only in "all" mode. Returns true when the
-- frame showed, false when policy kept it shut (callers stay silent).
function M.MayShow(mirror)
  if mirror then return M.FrameMode() == "all" end
  return M.AllowMasterFrame()
end

function M.ShowItem(itemLink, seconds)
  if not M.MayShow(false) then return false end
  if not frame then M.Build() end
  duration = seconds or (Z.DB and Z.DB.rollTime) or 15
  timeLeft = duration
  lastSec = -1
  ClearRolls()
  SetItemInfo(itemLink)
  if statusBar then
    statusBar:SetMinMaxValues(0, duration)
    statusBar:SetValue(duration)
    statusBar:SetAlpha(1)
    if statusText then statusText:SetText(duration .. "s") end
    statusBar:Show()
  end
  if UIFrameFadeIn and frame.SetAlpha then
    frame:SetAlpha(0)
    UIFrameFadeIn(frame, 0.5, 0, 1)
  end
  active = true
  frame:Show()
  -- Auto-roll path.
  if Z.AutoRoll and Z.AutoRoll.MaybeAutoRoll then Z.AutoRoll.MaybeAutoRoll(itemLink) end
  return true
end

function M.OnRoll(player, roll, rtype, excluded)
  if not frame or not frame:IsVisible() then return end
  local minR, maxR = rangeFor(rtype)
  table.insert(M.rolls, { player = player, roll = roll, rtype = rtype,
    minR = minR, maxR = maxR, excluded = excluded,
    class = M.PlayerClass(player) })
  RenderRolls()
  timeLeft = (Z.DB and Z.DB.rollTime) or 15 -- refresh on activity (LootBlare parity)
end

-- Dice vote: group-roll mirror votes Need/Greed/Pass through Blizzard's
-- RollOnLoot (the ONLY legal vote — RandomRoll would just spam chat and
-- forfeit the roll); ZugLoot master-loot sessions roll /roll as before.
-- RollOnLoot ids: 1 = Need, 2 = Greed, 0 = Pass (LazyPig parity).
local GROUP_VOTE = { SR = 1, MS = 1, OS = 2, TMOG = 2 }
function M.DoRoll(rtype, cap)
  if M.groupRollID then
    if RollOnLoot then
      pcall(RollOnLoot, M.groupRollID, GROUP_VOTE[rtype] or 2)
    end
    return
  end
  RandomRoll(1, cap)
end

function M.OnRollReq(msg, sender)
  -- ROLL_REQ:<itemID>:<link>:<mode>; verify sender is ML (LootBlare rule).
  local link = string.match(msg, "ROLL_REQ:%d+:(.+):%w+$")
  if Z.SRSecurity.IsML(sender) or sender == nil then
    M.ShowItem(link or msg, (Z.DB and Z.DB.rollTime) or 15)
  end
end

-- Group-loot Need/Greed frames (Blizzard's GroupLootFrame1..N) stay alive
-- (see LootWindow NOTE): a group roll is a server-side roll, and the ONLY
-- way to vote is RollOnLoot(rollID, 1/2/0) — suppressing the frames would
-- strand the item. So in "all" mode our window mirrors the roll:
-- START_LOOT_ROLL shows OUR dice frame for the item (same frame as
-- master-loot rolls, LootBlare parity), the dice vote through RollOnLoot,
-- CANCEL_LOOT_ROLL hides it. Default ("ml"): the mirror stays shut —
-- Blizzard's own frames own the group-loot vote, no double UI.
-- RollOnLoot is guarded: without it (headless) the dice are inert.
M.groupRollID = nil
-- Roll-call matching: the ML's RW line for one item. Pysanka-style calls
-- are the plain item NAME ("Nemesis Gloves"), possibly with an (SR)-style
-- suffix and kind dice ("Roll for X: /roll (MS) or /roll 99 (OS) ...").
-- Pure helper (headless-testable): text + optional sender -> item text.
-- Empty string = not a roll call (never pop the window on raid chatter).
function M.MatchRollCall(text, sender)
  local t = tostring(text or "")
  if t == "" then return "" end
  -- ML-only (raid-safe): never pop on anyone else's chat. Nil sender =
  -- untrusted in-client (tests pass explicit nil through the ML path).
  if sender and Z.SRSecurity and not Z.SRSecurity.IsML(sender) then return "" end
  -- Full item link anywhere in the line: the item, verbatim.
  local link = string.match(t, "(|c%x+|Hitem.-|h%[.-%]|h|r)")
  if link then return link end
  -- "Roll for <item>[: ...]" — strip the kind-dice suffix. This is the
  -- ONLY chat shape that opens the window (Pysanka's actual roll call).
  local item = string.match(t, "^[Rr]oll for (.+)$")
  if item then
    item = string.gsub(item, "%s*:%s*/roll.*$", "")
    item = string.gsub(item, "%s+%([Ss][Rr]%s*[^)]*%)%s*$", "")
    item = Z.Util.Trim(item)
    if item ~= "" then return item end
  end
  -- Everything else (drop lists, winners, countdowns, stop-rolls,
  -- raid-roll numbering, plain chatter) NEVER opens the window — no
  -- bare-name guessing.
  return ""
end

function M.OnEvent(event, a1, a2)
  if event == "CHAT_MSG_RAID_WARNING" then
    -- ML/RL roll call in RW (Pysanka style): plain item name, "Roll for
    -- X: ..." dice line, or full link (LootBlare trigger). Verify sender.
    -- ShowItem enforces the master-loot gate (group-loot RW chatter
    -- never pops the frame by default).
    local item = M.MatchRollCall(a1, a2)
    if item ~= "" then
      M.ShowItem(item, (Z.DB and Z.DB.rollTime) or 15)
    end
  elseif event == "START_LOOT_ROLL" then
    -- a1 = rollID (1.12 passes the roll id as first arg). Default
    -- ("ml"): the group-loot mirror stays SHUT — Blizzard's own
    -- Need/Greed frames own the vote. Only "all" mode mirrors the
    -- roll into our dice frame (dice vote via RollOnLoot).
    if M.FrameMode() ~= "all" then return end
    local rollID = tonumber(a1)
    M.groupRollID = rollID
    local link = nil
    if rollID and GetLootRollItemLink then
      local ok, l = pcall(GetLootRollItemLink, rollID)
      if ok then link = l end
    end
    local secs = rollID and GetLootRollTimeLeft
      and (function() local ok, t = pcall(GetLootRollTimeLeft, rollID) if ok then return t end end)()
      or nil
    M.ShowItem(link or ("Group roll #" .. tostring(rollID)), secs)
  elseif event == "CANCEL_LOOT_ROLL" then
    if tonumber(a1) == M.groupRollID or a1 == nil then
      M.groupRollID = nil
      M.Hide()
    end
  end
end

-- Test hook: icon hover + click scripts (mock frames record handlers).
function M.DebugIconScripts()
  if not iconButton or not iconButton.GetScript then return nil end
  return { OnEnter = iconButton:GetScript("OnEnter"),
    OnLeave = iconButton:GetScript("OnLeave"),
    OnClick = iconButton:GetScript("OnClick") }
end

function M.Show() if not frame then M.Build() end frame:Show() end
function M.Hide()
  if frame then frame:Hide() end
  active = false
  ClearRolls()
end

function M.SetTime(n)
  if n and n > 0 then Z.DB.rollTime = n Z.Print("Roll time set to " .. n .. "s") end
end

function M.SetAutoClose(s)
  s = string.lower(Z.Util.Trim(s or ""))
  if s == "on" then Z.DB.autoClose = true
  elseif s == "off" then Z.DB.autoClose = false end
  Z.Print("autoclose " .. tostring(Z.DB.autoClose))
end
