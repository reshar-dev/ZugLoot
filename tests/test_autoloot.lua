-- tests/test_autoloot.lua
-- Master-loot automation: per-category auto RAID-ROLL for trash (ZG
-- coins/bijous, MC mats, AQ scarabs/idols, Corrupted Sand, Dream
-- shards, Naxx scraps, Necrotic Runes — each OFF or raid-rolled by
-- the ML on loot) plus sub-threshold corpse auto-loot (free rows +
-- coin, never group-roll rows). No group-roll votes exist here.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
ZugLoot = {}
dofile("Util.lua")
dofile("Constants.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
time = time or os.time
UnitName = function() return "SoloPlayer" end

dofile("AutoRoll.lua")
local AR = ZugLoot.AutoRoll

ZugLoot.DB = { autoRaidRoll = {}, autoNeed = {}, autoLootBelow = false }
ZugLoot.SRSecurity = { AmML = function() return true end }

-- 1. Category tables: every trash ID resolves, junk doesn't.
eq(AR.CategoryFor(19698), "ZG", "ZG coin claimed")
eq(AR.CategoryFor(19715), "ZG", "ZG bijou claimed")
eq(AR.CategoryFor(11382), "MC", "MC mat claimed")
eq(AR.CategoryFor(17011), "MC", "MC core claimed")
eq(AR.CategoryFor(20858), "AQ", "AQ scarab claimed")
eq(AR.CategoryFor(20882), "AQ", "AQ idol claimed")
eq(AR.CategoryFor(50203), "SAND", "Corrupted Sand claimed")
eq(AR.CategoryFor(20381), "ES", "Dreamscale claimed")
eq(AR.CategoryFor(61198), "ES", "Dream shard claimed")
eq(AR.CategoryFor(22376), "NAXX", "Naxx scrap claimed")
eq(AR.CategoryFor(22484), "RUNE", "Necrotic Rune special-cased")
eq(AR.CategoryFor(19019), nil, "Thunderfury unclaimed")
eq(AR.CategoryFor(nil), nil, "nil unclaimed")
eq(AR.CategoryFor("junk"), nil, "junk unclaimed")

-- 2. Raid-roll toggle: OFF <-> RAID-ROLL, per category. Master-loot
-- only: no NEED/GREED/PASS votes exist here.
eq(AR.RaidRollFor("ZG"), nil, "ZG starts off")
eq(AR.Cycle("ZG"), true, "first toggle: RAID-ROLL")
eq(AR.RaidRollFor("ZG"), true, "ZG reads raid-roll")
eq(AR.Cycle("ZG"), nil, "second toggle: back OFF")
eq(AR.RaidRollFor("ZG"), nil, "ZG reads OFF again")
eq(AR.RaidRollLabel(nil), "OFF", "nil labels OFF")
eq(AR.RaidRollLabel(true), "RAID-ROLL", "true labels RAID-ROLL")
eq(AR.RaidRollLabel(false), "OFF", "false labels OFF")
-- Junk stored flags read as off, never enable a roll.
ZugLoot.DB.autoRaidRoll.MC = "bogus"
eq(AR.RaidRollFor("MC"), nil, "bogus flag reads off")
ZugLoot.DB.autoRaidRoll.MC = 0
eq(AR.RaidRollFor("MC"), nil, "zero reads off")
ZugLoot.DB.autoRaidRoll.MC = nil

-- 3. MaybeAutoRaidRoll: ML-only auto raid-roll on loot, guards first.
-- Headless has no ML/loot APIs without stubs: refuses cleanly.
eq(AR.MaybeAutoRaidRoll(nil), nil, "nil item refuses")
eq(AR.MaybeAutoRaidRoll("junk"), nil, "junk item refuses")
eq(AR.MaybeAutoRaidRoll(19019), nil, "uncategorized epic never rolls")
-- Disabled category refuses even with the world stubbed.
ZugLoot.DB.autoRaidRoll.ZG = nil
ZugLoot.MasterLootUI = {
  roll = nil, lootOpen = true,
  StartRaidRoll = function(itemID) return { itemID = itemID } end,
}
ZugLoot.SRSecurity.AmML = function() return true end
eq(AR.MaybeAutoRaidRoll(19698), nil, "ZG coin ignored when ZG off")
-- Enabled category starts the raid roll through the ML console.
ZugLoot.DB.autoRaidRoll.ZG = true
eq(AR.MaybeAutoRaidRoll(19698), true, "ZG coin raid-rolls when ZG on")
-- A running roll blocks a second start.
ZugLoot.MasterLootUI.roll = { itemID = 9999 }
eq(AR.MaybeAutoRaidRoll(19699), nil, "open roll blocks a second start")
ZugLoot.MasterLootUI.roll = nil
-- Non-ML clients never start rolls.
ZugLoot.SRSecurity.AmML = function() return false end
eq(AR.MaybeAutoRaidRoll(19698), nil, "non-ML refuses")
ZugLoot.SRSecurity.AmML = function() return true end
-- Necrotic Runes roll only under their own RUNE toggle (off here).
eq(AR.MaybeAutoRaidRoll(22484), nil, "rune needs its own toggle")
ZugLoot.DB.autoRaidRoll.RUNE = true
eq(AR.MaybeAutoRaidRoll(22484), true, "rune rolls when RUNE on")
ZugLoot.DB.autoRaidRoll.RUNE = nil
ZugLoot.DB.autoRaidRoll.ZG = nil
ZugLoot.MasterLootUI = nil

-- 4. Legacy vote-table migration: old NEED votes become raid-roll ON.
ZugLoot.DB.autoRaidRoll = nil
ZugLoot.DB.autoNeed = { ZG = 1, MC = 2, AQ = 0, SAND = nil }
AR.Config()
eq(ZugLoot.DB.autoRaidRoll.ZG, true, "NEED vote migrates to ON")
eq(ZugLoot.DB.autoRaidRoll.MC, true, "GREED vote migrates to ON")
eq(ZugLoot.DB.autoRaidRoll.AQ, nil, "PASS vote stays OFF")
eq(ZugLoot.DB.autoRaidRoll.SAND, nil, "absent stays OFF")
ZugLoot.DB.autoNeed = {}
ZugLoot.DB.autoRaidRoll = {}

-- 5. Auto-loot master switch: default OFF, explicit set sticks.
ZugLoot.DB.autoLootBelow = nil
eq(AR.AutoLootBelow(), false, "absent reads off")
eq(AR.SetAutoLootBelow(true), true, "set ON sticks")
eq(AR.AutoLootBelow(), true, "reads ON")
eq(AR.SetAutoLootBelow(false), false, "set OFF sticks")

if T.fail == 0 then
  print("autoloot passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
