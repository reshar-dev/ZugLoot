-- ZugLoot/AutoRoll.lua
-- Per-character auto-roll for SR'd items + per-category auto
-- RAID-ROLL for trash (ZG coins/bijous, MC mats, AQ scarabs/idols,
-- Corrupted Sand, Dream shards, Naxx scraps, Necrotic Runes) +
-- sub-threshold corpse auto-loot. This addon is master-loot only:
-- there are no group-roll votes here, so each trash category is
-- either OFF or auto raid-rolled by the ML when the corpse opens.
-- All off by default; every category toggles OFF <-> RAID-ROLL
-- from the Setup tab.
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

-- Trash item tables (itemID -> true), category membership for auto
-- raid-roll: ZG coins/bijous, MC mats, AQ scarabs/idols, Corrupted
-- Sand, Dream shards, Naxx scraps. Necrotic Runes claim RUNE.
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
M.CATEGORIES = { "ZG", "MC", "AQ", "SAND", "ES", "NAXX", "RUNE" }
M.CATEGORY_LABEL = {
  ZG = "ZG coins/bijous", MC = "MC mats", AQ = "AQ scarabs/idols",
  SAND = "Corrupted Sand", ES = "Dream shards", NAXX = "Naxx scraps",
  RUNE = "Necrotic Runes",
}

-- Stored config table (Z.DB.autoRaidRoll = { ZG=true, ... }).
-- Nil-safe: the DB may predate the feature (InitDB backfills).
-- Migrates the old NEED-vote table (autoNeed = { ZG=1, ... }): any
-- nonzero vote becomes raid-roll ON, OFF stays OFF.
function M.Config()
  if Z.DB then
    if not Z.DB.autoRaidRoll then
      Z.DB.autoRaidRoll = {}
      local old = Z.DB.autoNeed
      if old then
        for i = 1, Z.Util.ArrayCount(M.CATEGORIES) do
          local cat = M.CATEGORIES[i]
          if tonumber(old[cat]) and tonumber(old[cat]) ~= 0 then
            Z.DB.autoRaidRoll[cat] = true
          end
        end
      end
    end
    return Z.DB.autoRaidRoll
  end
  M._fallback = M._fallback or {}
  return M._fallback
end
-- Raid-roll enabled for a category: boolean true = auto raid-roll
-- on loot. Anything else (nil, false, legacy numbers, junk) reads
-- as off — the Setup toggle is the only writer, and it stores bools.
-- Pure state, headless-testable.
function M.RaidRollFor(cat)
  if M.Config()[cat] == true then return true end
  return nil
end
-- Toggle a category OFF <-> RAID-ROLL. Returns the new state
-- (true = RAID-ROLL, nil = OFF). Pure state, headless-testable.
function M.Cycle(cat)
  local cfg = M.Config()
  if cfg[cat] then cfg[cat] = nil else cfg[cat] = true end
  if cfg[cat] then return true end
  return nil
end
function M.RaidRollLabel(v)
  if v then return "RAID-ROLL" end
  return "OFF"
end
-- Which category (if any) claims this itemID. Necrotic Runes report
-- as RUNE (their own auto-raid-roll toggle, off by default like
-- every other category). Pure, headless-testable.
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
-- Auto raid-roll (loot-opened path): when a corpse opens holding a
-- trash item whose category is enabled, the ML raid-rolls it straight
-- away — no clicks, no award window (the roll distributes at once).
-- Guards: ML only, no roll already running, corpse actually open.
-- Returns true when a roll started, false/nil otherwise.
-- Headless-safe: without the ML/loot APIs nothing starts.
function M.MaybeAutoRaidRoll(itemID)
  itemID = Z.Util and Z.Util.ItemID(itemID) or tonumber(itemID)
  if not itemID then return nil end
  local cat = M.CategoryFor(itemID)
  if not cat then return nil end
  if not M.RaidRollFor(cat) then return nil end
  local MLUI = Z.MasterLootUI
  if not (MLUI and MLUI.StartRaidRoll) then return nil end
  if MLUI.roll then return nil end -- a roll is already running
  if Z.SRSecurity and Z.SRSecurity.AmML and not Z.SRSecurity.AmML() then
    return nil
  end
  if MLUI.lootOpen == false then return nil end
  local roll = MLUI.StartRaidRoll(itemID)
  if roll then return true end
  return nil
end
-- Sub-threshold auto-loot master switch (Setup tab). Default OFF.
function M.AutoLootBelow()
  return Z.DB and Z.DB.autoLootBelow and true or false
end
function M.SetAutoLootBelow(on)
  if Z.DB then Z.DB.autoLootBelow = on and true or false end
  return M.AutoLootBelow()
end
