-- tests/test_autoloot.lua
-- Issue #17: LazyPig-style automated raid loot. Per-category auto-need
-- (ZG coins/bijous, MC mats, AQ scarabs/idols, Corrupted Sand, Dream
-- shards, Naxx scraps, hardcoded Necrotic-Rune need) votes silently on
-- group rolls — no chat — plus sub-threshold corpse auto-loot (free
-- rows + coin, never group-roll rows). Setup-tab options gate it all.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
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

ZugLoot.DB = { autoNeed = {}, autoLootBelow = false }
ZugLoot.SRSecurity = { AmML = function() return true end }

-- 1. Category tables: every LazyPig ID resolves, junk doesn't.
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

-- 2. Vote cycle: OFF -> NEED -> GREED -> PASS -> OFF, per category.
eq(AR.VoteFor("ZG"), nil, "ZG starts off")
eq(AR.Cycle("ZG"), 1, "first cycle: NEED")
eq(AR.VoteFor("ZG"), 1, "ZG reads NEED")
eq(AR.Cycle("ZG"), 2, "second cycle: GREED")
eq(AR.Cycle("ZG"), 0, "third cycle: PASS")
eq(AR.Cycle("ZG"), nil, "fourth cycle: back OFF")
eq(AR.VoteFor("ZG"), nil, "ZG reads OFF again")
eq(AR.VoteLabel(nil), "OFF", "nil labels OFF")
eq(AR.VoteLabel(1), "NEED", "1 labels NEED")
eq(AR.VoteLabel(2), "GREED", "2 labels GREED")
eq(AR.VoteLabel(0), "PASS", "0 labels PASS")
-- Junk stored votes read as off, never crash the voter.
ZugLoot.DB.autoNeed.MC = "bogus"
eq(AR.VoteFor("MC"), nil, "bogus vote reads off")

-- 3. OnGroupRoll: silent background votes, no chat.
local votes = {}
RollOnLoot = function(rollID, vote) table.insert(votes, { rollID, vote }) end
local rollLinks = {}
GetLootRollItemLink = function(id) return rollLinks[id] end
rollLinks[11] = "|cffffffff|Hitem:19698:0:0:0|h[Zulian Coin]|h|r"
ZugLoot.DB.autoNeed.ZG = 1
eq(AR.OnGroupRoll(11), 1, "ZG coin NEEDs under ZG=need")
eq(#votes, 1, "one vote issued")
eq(votes[1][1], 11, "vote targets the roll")
eq(votes[1][2], 1, "vote is NEED")
eq(#printed, 0, "no chat on auto-need")
-- Configured GREED passes through; OFF votes nothing.
votes = {}
ZugLoot.DB.autoNeed.ZG = 2
eq(AR.OnGroupRoll(11), 2, "ZG coin GREEDs under ZG=greed")
ZugLoot.DB.autoNeed.ZG = nil
votes = {}
eq(AR.OnGroupRoll(11), nil, "ZG coin ignored when ZG off")
eq(#votes, 0, "no vote when off")
-- Unknown items never vote.
rollLinks[12] = "|cffa335ee|Hitem:19019:0:0:0|h[Thunderfury]|h|r"
eq(AR.OnGroupRoll(12), nil, "epic never auto-voted")
eq(#votes, 0, "no vote for unknown")
-- Necrotic Runes always NEED (LazyPig parity: no toggle).
rollLinks[13] = "|cff0070dd|Hitem:22484:0:0:0|h[Necrotic Rune]|h|r"
votes = {}
eq(AR.OnGroupRoll(13), 1, "Necrotic Rune NEEDs unconditionally")
eq(votes[1][2], 1, "rune vote is NEED")
-- Bad rollIDs refuse cleanly.
eq(AR.OnGroupRoll(nil), nil, "nil rollID refuses")
eq(AR.OnGroupRoll("junk"), nil, "junk rollID refuses")
GetLootRollItemLink = function(id) return nil end
eq(AR.OnGroupRoll(99), nil, "unresolvable roll refuses")
RollOnLoot = nil
GetLootRollItemLink = nil

-- 4. BoP popup confirm: clicks the matching popup, ignores the rest.
local clicked = {}
_G = _G or {}
StaticPopup = {}
STATICPOPUP_NUMDIALOGS = 2
_G["StaticPopup1"] = { IsShown = function() return true end,
  which = "CONFIRM_LOOT_ROLL", data = 11, data2 = 1 }
_G["StaticPopup1Button1"] = { Click = function() clicked[1] = true end }
_G["StaticPopup2"] = { IsShown = function() return true end,
  which = "CONFIRM_LOOT_ROLL", data = 99, data2 = 1 }
_G["StaticPopup2Button1"] = { Click = function() clicked[2] = true end }
AR.ConfirmBoPPopup(11, 1)
ok(clicked[1], "matching BoP popup clicked")
ok(not clicked[2], "other popup untouched")
AR.ConfirmBoPPopup(nil, nil) -- never errors headless
StaticPopup = nil
STATICPOPUP_NUMDIALOGS = nil
_G["StaticPopup1"] = nil
_G["StaticPopup1Button1"] = nil
_G["StaticPopup2"] = nil
_G["StaticPopup2Button1"] = nil

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
