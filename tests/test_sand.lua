-- tests/test_sand.lua
-- Hourglass Sand distributor (item 19183): lowest-ledger raider takes a
-- sand row, ledger evens out over the raid. No SR, no award window, no
-- sheet writes — handoff + ledger + DropLog only.
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
local logged = {}
ZugLoot.DropLog = { Add = function(itemID, link, source, outcome, winner)
  table.insert(logged, { itemID = itemID, outcome = outcome, winner = winner })
end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
time = time or os.time

SendChatMessage = function(msg, chan) table.insert(printed, "[" .. tostring(chan) .. "] " .. tostring(msg)) end
UnitName = function() return "SoloPlayer" end
local raidNames = {}
GetNumRaidMembers = function() return #raidNames end
GetRaidRosterInfo = function(i) return raidNames[i] end

local grouping = "raid"
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
  AmML = function() return true end,
  CanBroadcast = function() return true end,
}

ZugLoot.RaiderLootUI = {
  ShowItem = function(link, secs) end,
  OnRoll = function() end,
  Hide = function() end,
}
ZugLoot.Comm = { BroadcastAward = function() end,
  WarnGroup = function(m) table.insert(printed, m) end,
  SayGroup = function(m) table.insert(printed, m) end,
}

local lootSlots = {}
GetNumLootItems = function() return #lootSlots end
GetLootSlotLink = function(slot) return lootSlots[slot] and lootSlots[slot].link end
GetLootSlotInfo = function(slot)
  local s = lootSlots[slot]
  if not s then return nil end
  return "tex", s.link, s.quantity or 1, s.quality
end
GetItemInfo = function(link)
  for i = 1, #lootSlots do
    if lootSlots[i].link == link then
      return "Item" .. i, link, lootSlots[i].quality
    end
  end
  return nil
end
local masterGiven = {}
GiveMasterLoot = function(slot, idx) table.insert(masterGiven, { slot, idx }) end
GetMasterLootCandidate = function(slot, i)
  if raidNames[i] then return raidNames[i] end
  return nil
end
GetLootMethod = function() return "master" end
RandomRoll = function() end

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
dofile("Sim.lua")
local Sim = ZugLoot.Sim
local SRData = ZugLoot.SRData
local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow

local SAND = 19183

local function resetHarness()
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.running = false
  Sim.raid = nil
  ML.roll = nil
  ML.lastRound = nil
  ML.autoML = false
  ML.prevThreshold = nil
  ML.lootOpen = false
  ML.lootKey = nil
  ML.corpseCache = {}
  ML.corpseOrder = {}
  ML.pendingLoot = nil
  LW.Clear()
  printed, logged, masterGiven = {}, {}, {}
  grouping = "raid"
  raidNames = { "Aaa", "Bbb", "Ccc" }
  lootSlots = {}
  ZugLoot.DB = { sheet = SRData.NewSheet(), rollTime = 30, sand = {} }
  ZugLoot.DB.lootTakeover = true
  ML.lootOpen = true
end

-- 1. Identity + pure pick/totals.
eq(ML.SAND_ITEM_ID, 19183, "sand item id")
ok(ML.IsSandItem(19183), "19183 is sand")
ok(ML.IsSandItem("19183"), "string id is sand")
ok(not ML.IsSandItem(1001), "other items are not sand")
ok(not ML.IsSandItem(nil), "nil is not sand")
local ledger = { Aaa = 5, Bbb = 2, Ccc = 2 }
eq(ML.SandPick({ "Aaa", "Bbb", "Ccc" }, ledger), "Bbb", "lowest total wins")
eq(ML.SandPick({ "Ccc", "Bbb", "Aaa" }, ledger), "Ccc", "ties break by roster order")
eq(ML.SandPick({ "Aaa", "Bbb", "Ccc" }, {}), "Aaa", "empty ledger: first roster name")
eq(ML.SandPick({}, ledger), nil, "empty roster: nobody")
eq(ML.SandPick(nil, ledger), nil, "nil roster: nobody")
eq(ML.SandTotal(ledger, "Nope"), 0, "unknown name totals zero")
local totals = ML.SandTotals({ Aaa = 1, Bbb = 5, Ccc = 3 })
eq(totals[1].name, "Bbb", "totals sorted highest first")
eq(totals[3].name, "Aaa", "lowest last")
eq(#ML.SandTotals({}), 0, "empty ledger: empty totals")

-- 2. Full distribute: lowest-ledger raider takes the row via handoff,
-- ledger += quantity, row gone, window closed, no sheet writes.
resetHarness()
ZugLoot.DB.sand = { Aaa = 10, Bbb = 1, Ccc = 4 }
lootSlots = { { link = "item:19183:0:0:0", quality = 3, quantity = 5 } }
ML.OnLootOpened()
ok(LW.Find(SAND) ~= nil, "sand row listed")
LW.OpenDetail(SAND)
ok(ML.SandDistribute(SAND, "loot"), "sand distributes")
eq(masterGiven[1][1], 1, "handoff issued on the sand slot")
eq(ZugLoot.DB.sand.Bbb, 6, "ledger += stack quantity (1+5)")
ok(LW.Find(SAND) == nil, "sand row gone")
ok(LW.detail == nil, "window closed after distribute")
ok(ZugLoot.DB.sheet.items[SAND] == nil, "no sheet stub for sand")
eq(SRData.RollCount(ZugLoot.DB.sheet, SAND), 0, "no roll history for sand")
local sandEntry = nil
for i = 1, #logged do
  if logged[i].outcome == "sand" then sandEntry = logged[i] break end
end
ok(sandEntry ~= nil, "DropLog records sand")
eq(sandEntry and sandEntry.winner, "Bbb", "DropLog names the recipient")
local sawLine = false
for i = 1, #printed do
  if string.find(printed[i], "Bbb", 1, true)
      and string.find(printed[i], "6 total", 1, true) then sawLine = true break end
end
ok(sawLine, "announce names recipient + running total")

-- 3. Evens out over repeated distributions.
resetHarness()
ZugLoot.DB.sand = {}
for round = 1, 4 do
  lootSlots = { { link = "item:19183:0:0:0", quality = 3, quantity = 1 } }
  ML.OnLootOpened()
  ok(ML.SandDistribute(SAND, "loot"), "round " .. round .. " distributes")
end
eq(ZugLoot.DB.sand.Aaa, 2, "Aaa Evans out at 2")
eq(ZugLoot.DB.sand.Bbb, 1, "Bbb holds 1")
eq(ZugLoot.DB.sand.Ccc, 1, "Ccc holds 1")

-- 4. doAction + DetailActions wiring: Sand button on sand rows (pick),
-- nowhere else; non-sand rows never offer it.
resetHarness()
lootSlots = { { link = "item:19183:0:0:0", quality = 3, quantity = 2 } }
ML.OnLootOpened()
LW.OpenDetail(SAND)
local acts = LW.DetailActions()
local hasSand = false
for i = 1, #acts do if acts[i].id == "sand" then hasSand = true break end end
ok(hasSand, "Sand action on sand rows")
eq(LW.doAction(SAND, "sand"), "sand " .. SAND, "doAction distributes sand")
eq(ZugLoot.DB.sand.Aaa, 2, "first roster name takes it (empty ledger)")
ok(LW.Find(SAND) == nil, "row gone via doAction")
ZugLoot.DB.sheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
LW.SetItems({ { itemID = 1001, link = "item:1001" } }, "loot")
LW.OpenDetail(1001)
local acts2 = LW.DetailActions()
local leakSand = false
for i = 1, #acts2 do if acts2[i].id == "sand" then leakSand = true break end end
ok(not leakSand, "no Sand action on non-sand rows")
eq(LW.doAction(1001, "sand"), "sand failed", "doAction refuses non-sand")
-- Sand mid-roll: refused paths stay clean (a roll for sand is nonsense,
-- but the button never shows there anyway).
resetHarness()
lootSlots = { { link = "item:19183:0:0:0", quality = 3, quantity = 1 } }
ML.OnLootOpened()
LW.OpenDetail(SAND)
LW.doAction(SAND, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
eq(LW.doAction(SAND, "ignore"), "ignored " .. SAND, "mid-roll ignore still works")
ok(ML.roll == nil, "ignore ends the roll")

-- 5. Guards: non-sand id, empty raid, busy corpse (walked away keeps row).
resetHarness()
ok(not ML.SandDistribute(1001, "loot"), "non-sand id refused")
-- Solo (no raid): roster falls back to self, tracked like anyone else.
raidNames = {}
grouping = "solo"
lootSlots = { { link = "item:19183:0:0:0", quality = 3, quantity = 1 } }
ML.OnLootOpened()
ok(ML.SandDistribute(SAND, "loot"), "solo distributes to self")
eq(ZugLoot.DB.sand.SoloPlayer, 1, "solo self tracked")
raidNames = { "Aaa", "Bbb" }
grouping = "raid"
ML.lootOpen = false
lootSlots = { { link = "item:19183:0:0:0", quality = 3, quantity = 1 } }
-- Fake a live corpse row with a slot: slot tracked, corpse closed.
LW.SetItems({ { itemID = SAND, link = "item:19183:0:0:0", quality = 3, slot = 1 } }, "loot")
ok(not ML.SandDistribute(SAND, "loot"), "closed corpse keeps the row")
ok(LW.Find(SAND) ~= nil, "row kept for re-loot")

-- 6. /zl sand ledger + reset (permission-gated like the roll log).
resetHarness()
ZugLoot.DB.sand = { Aaa = 3, Bbb = 1 }
printed = {}
ok(ML.SandCommand(""), "ledger prints")
local sawBbb, sawTotal = false, false
for i = 1, #printed do
  if string.find(printed[i], "|Hplayer:Bbb|h[Bbb]|h", 1, true)
      and string.find(printed[i], "x1", 1, true) then sawBbb = true end
  if string.find(printed[i], "Sand total: x4", 1, true) then sawTotal = true end
end
ok(sawBbb and sawTotal, "ledger lines + grand total")
printed = {}
ok(ML.SandCommand("reset"), "solo reset allowed")
eq(ZugLoot.DB.sand.Aaa, nil, "ledger cleared")
grouping = "party"
ZugLoot.SRSecurity.CanBroadcast = function() return false end
ZugLoot.DB.sand = { Aaa = 2 }
printed = {}
ok(not ML.SandCommand("reset"), "non-ML reset refused")
eq(ZugLoot.DB.sand.Aaa, 2, "refused reset keeps data")
ZugLoot.SRSecurity.CanBroadcast = function() return true end
ok(ML.SandCommand("reset"), "leader reset allowed")
printed = {}
ok(ML.SandCommand(""), "empty ledger prints the empty line")
ok(string.find(printed[1], "No sand", 1, true) ~= nil, "empty ledger message")
ok(not ML.SandCommand("bogus"), "bad subcommand refused")

-- 7. Issue #18: a flipped loot method freezes distribution (no move,
-- no ledger write), START of any new roll is refused too, and
-- restoring the method resumes cleanly.
resetHarness()
local liveMethod = "master"
ZugLoot.SRSecurity.LootMethod = function() return liveMethod end
lootSlots = { { link = "item:19183:0:0:0", quality = 3, quantity = 5 } }
ML.OnLootOpened()
LW.OpenDetail(SAND)
liveMethod = "group"
ok(not ML.SandDistribute(SAND, "loot"), "sand refuses while frozen")
ok(LW.Find(SAND) ~= nil, "sand row kept")
eq(ZugLoot.DB.sand.Bbb, nil, "ledger untouched by refused distribute")
eq(LW.doAction(SAND, "sand"), "sand failed", "window reports the refusal")
ok(LW.Find(SAND) ~= nil, "window keeps the sand row")
ok(ML.BeginRoll(SAND, "item:19183:0:0:0", "SR", false) == nil,
  "sand row starts no roll while frozen")
liveMethod = "master"
ok(ML.SandDistribute(SAND, "loot"), "sand distributes after restore")
eq(ZugLoot.DB.sand.Aaa, 5, "ledger lands after restore")
ok(LW.Find(SAND) == nil, "sand row gone after restore")
ZugLoot.SRSecurity.LootMethod = nil

return T
