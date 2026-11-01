-- tests/test_remembered.lua
-- Remembered item defaults: ML ticks the top-right box on the roll
-- window (raid-roll, or award to a specific player); the decision is
-- stored per itemID (Z.DB.remembered) and applied when the row opens.
-- Setup "Remembered" section lists entries, selects one to show its
-- state in the textbox, and Remove forgets it.
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
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("ItemCards.lua")
dofile("Timer.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
time = time or os.time
CreateFrame = nil -- headless: data layer only
-- Neutralize corpse globals leaked by earlier suite files (sand/mlflow
-- stub a live corpse): this harness awards headless, where no corpse
-- session exists and every take applies without a slot read.
GetNumLootItems = nil
GetLootSlotLink = nil
GetLootSlotInfo = nil

ZugLoot.SRSecurity = {
  AmML = function() return true end,
  IsInRaid = function() return true end,
  IsInGroup = function() return true end,
  IsInParty = function() return false end,
  IsSolo = function() return false end,
}
ZugLoot.DropLog = { Add = function() end }
ZugLoot.Comm = {
  BroadcastAward = function() end,
  WarnGroup = function() end,
  SayGroup = function() end,
  Say = function() end,
}
GetNumRaidMembers = function() return 3 end
GetRaidRosterInfo = function(i) return ({"SoloPlayer", "Aaa", "Bbb"})[i] end
UnitName = function(u) return "SoloPlayer" end
RandomRoll = function() end

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
local LW = ZugLoot.LootWindow
local ML = ZugLoot.MasterLootUI

local function makeSheet(rolls)
  local s = ZugLoot.SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = rolls or {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2 },
  } }
  return s
end

local function reset()
  ZugLoot.DB = { sheet = makeSheet(), remembered = {} }
  ML.roll = nil
  ML.lastRound = nil
  ML.lootOpen = true
  LW.Clear()
  printed = {}
end

-- 1. Store primitives: raidroll stores, award needs a name, junk refuses.
reset()
ML.RememberedSet(19019, true, "raidroll", nil, "link-19019")
eq(ML.RememberedGet(19019).mode, "raidroll", "raidroll stored")
ML.RememberedSet(17063, true, "award", "Carbon", nil)
eq(ML.RememberedGet(17063).name, "Carbon", "award stored with name")
eq(ML.RememberedGet(123), nil, "nameless award refuses")
ML.RememberedSet(124, true, "bogus")
eq(ML.RememberedGet(124), nil, "junk mode refuses")
local list = ML.RememberedList()
eq(#list, 2, "two entries listed")
eq(list[1].itemID, 17063, "list sorted by itemID")
eq(ML.RememberedLine({ mode = "raidroll" }), "Raid-roll on open", "raidroll line")
eq(ML.RememberedLine({ mode = "award", name = "Carbon" }),
  "Award to Carbon on open", "award line")
eq(ML.RememberedBoxState(19019, "raidroll"), "raidroll", "box state matches")
eq(ML.RememberedBoxState(19019, "award", "X"), nil, "box state mismatches")
eq(ML.RememberedBoxState(19019, "raidroll", "Nobody"), "raidroll",
  "raidroll ignores the name")
ML.RememberedSet(19019, false)
eq(ML.RememberedGet(19019), nil, "forget drops the entry")
eq(#ML.RememberedList(), 1, "one entry left")

-- 2. Full raid-roll loop via the CHECKBOX (the reported bug: ticking
-- a context-free row silently did nothing, Setup stayed empty).
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.ToggleRemember(), true, "box tick stores raid-roll on a bare row")
eq(ML.RememberedGet(1001).mode, "raidroll", "Setup list gains the entry")
eq(LW.doAction(1001, "raidroll"), "rolling", "raid-roll starts")
ML.IntakeChatRoll("SoloPlayer rolls 2 (1-3)")
eq(ML.RememberedGet(1001).mode, "raidroll", "raid-roll finish keeps it")
-- Next drop: ApplyRemembered raid-rolls straight away.
ZugLoot.DB.sheet = makeSheet()
ML.roll = nil
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
eq(ML.ApplyRemembered(), "raidroll", "remembered raid-roll auto-starts on open")
ok(ML.roll ~= nil and ML.roll.mode == "RAIDROLL", "raid-roll mode live")

-- 3. Unticked raid-roll persists nothing.
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "raidroll"), "rolling", "unticked raid-roll starts")
ML.IntakeChatRoll("SoloPlayer rolls 2 (1-3)")
eq(ML.RememberedGet(1001), nil, "unticked raid-roll stores nothing")

-- 4. Award loop via the CHECKBOX: ticked single-holder award persists;
-- next drop direct-awards on open (no roll started); unticked awards
-- persist nothing. Multi-holder ... picks adopt the scope when ticked.
reset()
ZugLoot.DB.sheet = makeSheet({ { name = "Solo", rolls = 1 } })
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
local d4 = LW.OpenDetail(1001)
eq(d4.single, true, "lone holder seeds the row")
eq(d4.rememberMode, "award", "award context seeded")
eq(d4.rememberName, "Solo", "holder prefilled")
eq(LW.ToggleRemember(), true, "box tick stores award-to-holder")
eq(LW.doAction(1001, "award"), "awarded Solo", "ticked direct award lands")
eq(ML.RememberedGet(1001).name, "Solo", "award persists the tick")
-- Next drop auto-awards on open.
ZugLoot.DB.sheet = makeSheet()
ML.roll = nil
ML.lootOpen = true
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
eq(ML.ApplyRemembered(), "awarded Solo", "remembered award auto-applies on open")
eq(LW.Find(1001), nil, "auto-awarded row leaves the list")
-- Unticked award: no store.
reset()
ZugLoot.DB.sheet = makeSheet({ { name = "Solo", rolls = 1 } })
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "award"), "awarded Solo", "unticked award lands")
eq(ML.RememberedGet(1001), nil, "unticked award stores nothing")
-- Multi-holder: tick the bare box (stores raid-roll), then ... award
-- Bbb — the ticked handling converges the entry to award-to-Bbb.
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
local d5 = LW.OpenDetail(1001)
eq(d5.rememberMode, nil, "multi-holder seeds no context")
eq(LW.ToggleRemember(), true, "bare-box tick stores the fallback")
eq(ML.RememberedGet(1001).mode, "raidroll", "fallback is raid-roll")
eq(LW.doAction(1001, "award-name", "Bbb"), "awarded Bbb", "... award lands")
eq(ML.RememberedGet(1001).name, "Bbb", "ticked handling converges to Bbb")
-- Untick forgets; re-tick re-stores the current decision. Reopening
-- re-seeds from the stored entry (tick on, award-to-Bbb context).
-- Bbb won, so the sheet now lists one live holder: untick resets to
-- THAT live seed (award-to-Aaa), and re-tick stores it.
LW.CloseDetail()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
local d6 = LW.OpenDetail(1001)
eq(d6.rememberChecked, true, "reopen shows the tick")
eq(d6.rememberMode, "award", "reopen context is the stored award")
eq(d6.rememberName, "Bbb", "reopen names the stored assignee")
eq(LW.ToggleRemember(), false, "untick forgets")
eq(ML.RememberedGet(1001), nil, "entry gone after untick")
eq(d6.rememberMode, "award", "untick resets to the live seed")
eq(d6.rememberName, "Aaa", "one live holder left after Bbb won")
eq(LW.ToggleRemember(), true, "re-tick stores again")
eq(ML.RememberedGet(1001).name, "Aaa", "live holder stored")

-- 5. Guards: sim rows never apply; nothing remembered = false.
reset()
ML.RememberedSet(2001, true, "raidroll")
ML.roll = nil
LW.SetItems({ { itemID = 2001, link = "item:2001", quality = 4 } }, "sim")
eq(ML.ApplyRemembered(), false, "sim rows never apply")
LW.SetItems({}, "loot")
eq(ML.ApplyRemembered(), false, "empty list applies nothing")

-- 6. One roll at a time: a live roll blocks the auto path.
reset()
ML.RememberedSet(1001, true, "raidroll")
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
ML.roll = { itemID = 9999, mode = "SR", rolls = {} }
eq(ML.ApplyRemembered(), false, "live roll blocks auto raid-roll")
ML.roll = nil

-- 7. Mid normal-roll tick arms (nothing storable yet); the award
-- converges it to the winner. Tied award windows offer nothing.
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "normal roll starts")
eq(LW.ToggleRemember(), true, "mid-roll tick arms")
eq(ML.RememberedGet(1001), nil, "armed tick stores nothing yet")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
eq(LW.doAction(1001, "finish"), "finished", "finish resolves")
eq(LW.doAction(1001, "award-name", "Aaa"), "awarded Aaa", "award lands")
eq(ML.RememberedGet(1001).name, "Aaa", "armed tick converges to the winner")

return T
