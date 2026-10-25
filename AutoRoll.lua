-- ZugLoot/AutoRoll.lua
-- Per-character auto-roll for SR'd items + LazyPig-style auto-need
-- for group-roll trash (ZG coins/bijous, MC mats, AQ scarabs/idols,
-- Corrupted Sand, Dream shards, Naxx scraps, Necrotic Runes) +
-- sub-threshold corpse auto-loot. All off by default except the
-- LazyPig-parity SAND=need default; every category cycles
-- OFF -> NEED -> GREED -> PASS from the Setup tab.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.AutoRoll = M

function M.IsOn() return Z.CharDB and Z.CharDB.autoRoll end

function M.Set(s)
  s = string.lower(Z.Util.Trim(s or ""))
  if s == "on" then Z.CharDB.autoRoll = true
  elseif s == "off" then Z.CharDB.autoRoll = false end
  Z.Print("auto-roll " .. (M.IsOn() and "ON" or "OFF"))
end

function M.PlayerSRd(itemID)
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return false end
  local me = UnitName("player")
  local rollers = Z.SRData.GetRollers(sheet, itemID)
  for i = 1, Z.Util.ArrayCount(rollers) do
    if rollers[i].name == me and not Z.SRData.HasWon(sheet, itemID, me) then
      return true
    end
  end
  return false
end

-- How many times the local player reserved this item (x2 = two rolls).
-- Spent SRs roll once like everyone else (see MasterLootUI.RollAllowance).
function M.PlayerAllowance(itemID)
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return 1 end
  local me = UnitName("player")
  local holders = Z.SRData.SRHolders(sheet, itemID)
  for i = 1, Z.Util.ArrayCount(holders) do
    if holders[i].name == me then
      local n = tonumber(holders[i].rolls) or 1
      if n < 1 then n = 1 end
      return n
    end
  end
  return 1
end

function M.MaybeAutoRoll(itemLink)
  if not M.IsOn() then return end
  local itemID = Z.Util.ItemID(itemLink)
  if not itemID then return end
  if M.PlayerSRd(itemID) then
    local n = M.PlayerAllowance(itemID)
    local k = 1
    while k <= n do
      Z.Print("Auto-rolling SR (" .. itemLink .. ")")
      RandomRoll(1, Z.Caps.SR)
      k = k + 1
    end
  end
end

-- Auto-resolve: true when every eligible SR roller is version-green + auto-on.
-- Skeleton heuristic: all known versions current (VersionGrid tracks flags).
function M.AllGreenAndAuto()
  if Z.VersionGrid and Z.VersionGrid.AllCurrent() then return true end
  return false
end

-- LazyPig auto-need tables (itemID -> true). Ported from LazyPig:
-- ZG coins/bijous, MC mats, AQ scarabs/idols, Corrupted Sand,
-- Dream shards, Naxx scraps. Necrotic Runes are hardcoded NEED
-- (LazyPig parity: no toggle, always need).
M.NEED_TABLES = {
  ZG = { [19698] = true, [19699] = true, [19700] = true, [19701] = true,
    [19702] = true, [19703] = true, [19704] = true, [19705] = true,
    [19706] = true, [19707] = true, [19708] = true, [19709] = true,
    [19710] = true, [19711] = true, [19712] = true, [19713] = true,
    [19714] = true, [19715] = true },
  MC = { [11382] = true, [17010] = true, [17011] = true },
  AQ = { [20858] = true, [20859] = true, [20860] = true, [20861] = true,
    [20862] = true, [20863] = true, [20864] = true, [20865] = true,
    [20866] = true, [20867] = true, [20868] = true, [20869] = true,
    [20870] = true, [20871] = true, [20872] = true, [20873] = true,
    [20874] = true, [20875] = true, [20876] = true, [20877] = true,
    [20878] = true, [20881] = true, [20882] = true },
  SAND = { [50203] = true },
  ES = { [20381] = true, [61197] = true, [61198] = true },
  NAXX = { [22373] = true, [22374] = true, [22375] = true, [22376] = true },
}
M.NECROTIC_RUNE = 22484
-- Setup cycle order for each category. Stored vote: nil = OFF,
-- 1 = NEED, 2 = GREED, 0 = PASS (RollOnLoot ids, LazyPig parity).
-- (No nil inside the array: ArrayCount stops at the first nil.)
M.VOTE_ORDER = { 1, 2, 0 }
M.VOTE_LABEL = { [1] = "NEED", [2] = "GREED", [0] = "PASS" }
M.CATEGORIES = { "ZG", "MC", "AQ", "SAND", "ES", "NAXX" }
M.CATEGORY_LABEL = {
  ZG = "ZG coins/bijous", MC = "MC mats", AQ = "AQ scarabs/idols",
  SAND = "Corrupted Sand", ES = "Dream shards", NAXX = "Naxx scraps",
}

-- Stored config table (Z.DB.autoNeed = { ZG=1, ... }). Nil-safe: the
-- DB may predate the feature (InitDB backfills).
function M.Config()
  if Z.DB then
    Z.DB.autoNeed = Z.DB.autoNeed or {}
    return Z.DB.autoNeed
  end
  M._fallback = M._fallback or {}
  return M._fallback
end
-- Vote for a category: nil (off) or 1/2/0. Anything else reads as off.
function M.VoteFor(cat)
  local v = tonumber(M.Config()[cat])
  if v == 1 or v == 2 or v == 0 then return v end
  return nil
end
-- Cycle a category OFF -> NEED -> GREED -> PASS -> OFF. Returns the
-- new vote (nil = OFF). Pure state, headless-testable.
function M.Cycle(cat)
  local cfg = M.Config()
  local cur = M.VoteFor(cat)
  local next = nil
  if cur == nil then
    next = M.VOTE_ORDER[1] -- OFF -> NEED
  else
    for i = 1, Z.Util.ArrayCount(M.VOTE_ORDER) do
      if M.VOTE_ORDER[i] == cur then
        local n = i + 1
        if n > Z.Util.ArrayCount(M.VOTE_ORDER) then next = nil -- PASS -> OFF
        else next = M.VOTE_ORDER[n] end
        break
      end
    end
    if next == nil and cur ~= nil then
      -- Unknown stored vote: restart the cycle at NEED. (A known cur
      -- at the last position also lands here with next == nil, which
      -- is the intended PASS -> OFF wrap.)
      local known = false
      for i = 1, Z.Util.ArrayCount(M.VOTE_ORDER) do
        if M.VOTE_ORDER[i] == cur then known = true break end
      end
      if not known then next = M.VOTE_ORDER[1] end
    end
  end
  cfg[cat] = next
  return next
end
function M.VoteLabel(v)
  if v == nil then return "OFF" end
  return M.VOTE_LABEL[v] or "OFF"
end
-- Which category (if any) claims this itemID. Necrotic Runes report
-- as SAND-class hardcoded NEED (handled first in OnGroupRoll).
-- Pure, headless-testable.
function M.CategoryFor(itemID)
  local id = tonumber(itemID)
  if not id then return nil end
  if id == M.NECROTIC_RUNE then return "RUNE" end
  for i = 1, Z.Util.ArrayCount(M.CATEGORIES) do
    local cat = M.CATEGORIES[i]
    if M.NEED_TABLES[cat] and M.NEED_TABLES[cat][id] then return cat end
  end
  return nil
end
-- Group-roll auto-vote (START_LOOT_ROLL path): vote the configured
-- action for known trash, silently (no chat — LazyPig parity: chat
-- stays clean, the issue's core ask). Necrotic Runes always NEED.
-- Returns the vote issued (1/2/0) or nil when nothing applied.
-- Headless-safe: without RollOnLoot / roll APIs, resolves the vote
-- without issuing (dry-run returns what WOULD be voted).
function M.OnGroupRoll(rollID)
  local id = tonumber(rollID)
  if not id then return nil end
  -- Item identity comes from the roll link (GetLootRollItemLink);
  -- GetLootRollItemInfo carries texture/name/count/quality, no id.
  local itemID = nil
  if GetLootRollItemLink then
    local ok, l = pcall(GetLootRollItemLink, id)
    if ok and l and Z.Util and Z.Util.ItemID then
      itemID = Z.Util.ItemID(l)
    end
  end
  itemID = tonumber(itemID)
  if not itemID then return nil end
  local vote = nil
  if itemID == M.NECROTIC_RUNE then
    vote = 1 -- hardcoded NEED (LazyPig parity)
  else
    local cat = M.CategoryFor(itemID)
    if cat then vote = M.VoteFor(cat) end
  end
  if vote == nil then return nil end
  if RollOnLoot then pcall(RollOnLoot, id, vote) end
  M.ConfirmBoPPopup(id, vote)
  return vote
end
-- BoP group-roll confirm: RollOnLoot raises CONFIRM_LOOT_ROLL;
-- click it (LazyPig parity) so auto-need on BoP trash doesn't stall.
-- Nil-safe: headless (no StaticPopup) is a no-op.
function M.ConfirmBoPPopup(rollID, vote)
  if not (StaticPopup and type(StaticPopup) == "table") then return end
  for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
    local frame = _G and _G["StaticPopup" .. i] or nil
    if frame and frame.IsShown and frame:IsShown()
        and frame.which == "CONFIRM_LOOT_ROLL"
        and frame.data == rollID and frame.data2 == vote then
      local btn = _G["StaticPopup" .. i .. "Button1"]
      if btn and btn.Click then pcall(btn.Click, btn) end
      return
    end
  end
end
-- Sub-threshold auto-loot master switch (Setup tab). Default OFF.
function M.AutoLootBelow()
  return Z.DB and Z.DB.autoLootBelow and true or false
end
function M.SetAutoLootBelow(on)
  if Z.DB then Z.DB.autoLootBelow = on and true or false end
  return M.AutoLootBelow()
end
