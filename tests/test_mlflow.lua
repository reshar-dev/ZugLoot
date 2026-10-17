-- tests/test_mlflow.lua
-- Live master-loot flow: corpse scan -> loot window -> ONE roll window ->
-- rolls land (fake or real) -> ML finishes -> award on the same window.
-- Closing the window ends the roll; awarding ends the roll; the timeout
-- ends the roll. No parked sessions, no pending menus, no background
-- rolls — the open window is the only roll state.
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
ZugLoot.DropLog = { Add = function() end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
time = time or os.time

SendChatMessage = function() end
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end

local grouping = "solo"
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
  AmML = function() return true end,
  MasterLooterName = function() return "SoloPlayer" end,
}

local shownItems = {}
ZugLoot.RaiderLootUI = {
  ShowItem = function(link) table.insert(shownItems, link) end,
  OnRoll = function() end,
  Hide = function() end,
}

local lootSlots = {}
GetNumLootItems = function() return #lootSlots end
GetLootSlotLink = function(slot) return lootSlots[slot] and lootSlots[slot].link end
GetLootSlotInfo = function(slot)
  local s = lootSlots[slot]
  if not s then return nil end
  return "tex", s.link, 1, s.quality
end
GetItemInfo = function(link)
  for i = 1, #lootSlots do
    if lootSlots[i].link == link then
      return "Item" .. i, link, lootSlots[i].quality
    end
  end
  return nil
end

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
dofile("Sim.lua")
local Sim = ZugLoot.Sim
local SRData = ZugLoot.SRData
local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow

local function makeSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2, sr_plus = nil },
  } }
  s.items[1002] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = nil },
    { name = "Ccc", rolls = 1, sr_plus = 50 },
  } }
  return s
end

local function resetHarness(rollTime)
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.running = false
  Sim.raid = nil
  Sim.rehearseRun = false
  ML.roll = nil
  ML.lootOpen = false
  ML.lootKey = nil
  ML.corpseCache = {}
  ML.corpseOrder = {}
  ML.pendingLoot = nil
  LW.Clear()
  printed, shownItems = {}, {}
  grouping = "solo"
  lootSlots = {}
  ZugLoot.DB = { sheet = makeSheet(), rollTime = rollTime or 30 }
  ZugLoot.DB.lootTakeover = true
end

-- 1. Corpse scan lists every slot; nothing auto-starts.
resetHarness()
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:1002:0:0:0", quality = 4 },
}
ML.OnLootOpened()
ok(ML.roll == nil, "no auto-start: ML initiates")
eq(#LW.items, 2, "loot window covers every slot")
eq(LW.items[1].itemID, 1001, "first roll row")
eq(LW.items[1].status, "open", "first drop open")
eq(LW.items[1].badge, "SR:2", "SR count badge")

-- 2. Full live roll: open -> rolls land -> finish -> award, same window.
resetHarness()
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "roll starts")
ok(ML.roll ~= nil and ML.roll.itemID == 1001, "the one roll is live")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
ML.IntakeChatRoll("Aaa rolls 50 (1-100)") -- first-roll-only
eq(#ML.roll.rolls, 2, "first rolls only")
eq(#LW.detail.rolls, 2, "window lists both rolls")
eq(LW.doAction(1001, "finish"), "finished", "finish resolves")
ok(ML.roll == nil, "finish ends the roll")
eq(LW.detail.phase, "award", "same window awards")
eq(LW.detail.menu.winners[1].name, "Aaa", "SR+ wins (90+10)")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "award won-marks")
ok(LW.Find(1001) == nil, "awarded row gone")
ok(LW.detail == nil, "window closed after award")

-- 3. One roll at a time. Switching rows closes the rolling window,
-- which ENDS its roll — then the new row can roll.
resetHarness()
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:1002:0:0:0", quality = 4 },
}
ML.OnLootOpened()
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "first roll starts")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
LW.OpenDetail(1002) -- switch: 1001's roll ends early
ok(ML.roll == nil, "switching rows ends the open roll")
ML.IntakeChatRoll("Bbb rolls 99 (1-100)")
ok(ML.roll == nil, "nothing collects for the closed roll")
eq(LW.doAction(1002, "roll"), "rolling", "new row rolls clean")
ok(ML.roll.itemID == 1002, "the one roll is the new item")
eq(LW.doAction(1002, "cancel"), "cancelled", "cancel ends it")
ok(ML.roll == nil, "cancel clears the roll")

-- 4. Closing the rolling window ENDS the roll early. Late rolls die,
-- the clock disarms, and nothing finishes behind the close.
resetHarness()
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "roll starts")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
eq(LW.doAction(1001, "close"), "closed", "close ends the roll")
ok(ML.roll == nil, "no roll survives the close")
ML.IntakeChatRoll("Bbb rolls 99 (1-100)")
ok(ML.roll == nil, "late roll lands nowhere")
ok(ZugLoot.Timer.Pending() == 0, "close disarms the clock")
-- Reopening shows a fresh pick window, not phantom award rows.
local d = LW.OpenDetail(1001)
eq(d.phase, "pick", "reopen is a fresh pick")
ok(d.menu == nil and #d.rolls == 0, "no resurrected state")

-- 5. ... award ends the roll early and awards at once.
resetHarness()
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "roll starts")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
eq(LW.doAction(1001, "award-name", "Bbb"), "awarded Bbb", "... award lands")
ok(ML.roll == nil, "... award ends the roll")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Bbb"), "... award won-marks")
ok(LW.Find(1001) == nil, "awarded row gone")

-- 6. Raid roll button: ends the old roll, numbers the raid, the ML's
-- number wins and the item goes straight out (no award window).
resetHarness()
GetNumRaidMembers = function() return 3 end
GetRaidRosterInfo = function(i)
  return ({ "Pysanka", "Tenshiy", "Bluefelon" })[i]
end
UnitName = function(u)
  if u == "player" then return "Pysanka" end
  return "Pysanka"
end
local rolledRanges = {}
RandomRoll = function(lo, hi) table.insert(rolledRanges, { lo, hi }) end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "normal roll starts")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
-- Raid roll from its own button replaces it (... carries awards only).
local ch = LW.MoreChoices()
local hasRaid = false
for i = 1, #ch do if ch[i].id == "raidroll" then hasRaid = true break end end
ok(not hasRaid, "... no longer carries raid-roll")
local acts6 = LW.DetailActions()
local hasRaidBtn = false
for i = 1, #acts6 do if acts6[i].id == "raidroll" then hasRaidBtn = true break end end
ok(hasRaidBtn, "Raid roll is its own button")
eq(LW.doAction(1001, "raidroll"), "rolling", "raid-roll replaces the roll")
eq(ML.roll.mode, "RAIDROLL", "raid-roll mode live")
eq(#ML.roll.rolls, 0, "old rolls wiped, not merged")
eq(rolledRanges[1][2], 3, "ML rolls 1-N")
ML.IntakeChatRoll("Tenshiy rolls 99 (1-3)") -- raider roll ignored
ok(ML.roll ~= nil, "raider roll ignored")
ML.IntakeChatRoll("Pysanka rolls 2 (1-3)") -- ML number resolves + awards
ok(ML.roll == nil, "raid-roll number ends the roll")
ok(LW.detail == nil, "raid-roll awards directly, window closed")
ok(LW.Find(1001) == nil, "raid-roll winner takes the row")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Tenshiy"), "raid-roll winner awarded")
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
UnitName = function() return "SoloPlayer" end
RandomRoll = function() end

-- 7. Roll kind: 1-100 is SR only with the reserve, else MS; 1-99 OS,
-- 1-98 TMOG. MS loses to SR by priority, never by validity.
resetHarness()
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Stranger rolls 95 (1-100)")
ML.IntakeChatRoll("Offspec rolls 88 (1-99)")
ML.IntakeChatRoll("Tmog rolls 15 (1-98)")
local kinds = {}
for i = 1, #ML.roll.rolls do kinds[ML.roll.rolls[i].name] = ML.roll.rolls[i].type end
eq(kinds["Aaa"], "SR", "reserve + 1-100 = SR")
eq(kinds["Stranger"], "MS", "no reserve + 1-100 = MS")
eq(kinds["Offspec"], "OS", "1-99 = OS")
eq(kinds["Tmog"], "TMOG", "1-98 = TMOG")
eq(LW.doAction(1001, "finish"), "finished", "finish")
eq(LW.detail.menu.winners[1].name, "Aaa", "SR wins by priority")
eq(LW.detail.menu.perType.MS.entry.name, "Stranger", "stranger owns MS")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)

-- 8. Direct award: single holder, no roll needed, row gone.
resetHarness()
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OpenDetail(1002)
-- 1002 has two holders (Aaa, Ccc): needs a choice.
eq(LW.doAction(1002, "award"), "needs choice (...)", "multi holder refuses direct")
eq(LW.doAction(1002, "award-name", "Ccc"), "awarded Ccc", "named award lands")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "named award won-marks")

-- 9. Corpse take: master loot hands to the winner by candidate index;
-- non-candidates refuse; slot resolved live at award time.
resetHarness()
local masterGiven = {}
GetLootMethod = function() return "master" end
LootSlot = function() error("must not plain-loot under master loot") end
GiveMasterLoot = function(slot, who) table.insert(masterGiven, { slot, who }) end
GetMasterLootCandidate = function(slot, i)
  if i == 1 then return "SoloPlayer" elseif i == 2 then return "SomebodyElse" end
  return nil
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
ML.AwardDirect(1001, "SomebodyElse", "loot")
eq(#masterGiven, 1, "master loot handed to the winner")
eq(masterGiven[1][2], 2, "correct candidate index")
-- Self-award under master loot ALSO hands off by candidate index:
-- plain LootSlot is a silent server no-op for threshold+ items, so
-- awarding yourself must go through GiveMasterLoot (own index).
ML.OnLootOpened()
ML.AwardDirect(1001, "SoloPlayer", "loot")
eq(#masterGiven, 2, "self-award hands off too")
eq(masterGiven[2][2], 1, "own candidate index")
ML.OnLootOpened()
local refusedBefore = #masterGiven
ML.AwardDirect(1001, "NobodyHere", "loot")
eq(#masterGiven, refusedBefore, "non-candidate issues no loot call")
ok(LW.Find(1001) ~= nil, "refused award keeps the row")
-- Below-threshold item that "dropped for me": the ML takes it through
-- the handoff with their own candidate index (verified live: plain
-- LootSlot under master loot issues ok=true but the server ignores it
-- and the row strands [done]).
ML.OnLootOpened()
lootSlots = { { link = "item:5001:0:0:0", quality = 0 } }
ML.OnLootOpened()
local plain = 0
LootSlot = function(slot, force) plain = plain + 1 end
ML.lootOpen = true
ok(ML.LootCorpseSlot("item:5001:0:0:0", 5001, "SoloPlayer") == true,
  "below-threshold self-loot issues")
eq(plain, 0, "no dead plain LootSlot for ML self-take")
eq(#masterGiven, refusedBefore + 1, "grey self-take hands off via master loot")
eq(masterGiven[#masterGiven][2], 1, "own candidate index for grey")
GetMasterLootCandidate = nil
GetLootMethod = nil
LootSlot = nil
GiveMasterLoot = nil

-- 10. Walk-away parks ROWS only: the open roll keeps collecting (window
-- open), and re-looting resumes the list.
resetHarness()
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
LW.OnEvent("LOOT_CLOSED") -- walk away: rows park, window stays live
ok(ML.roll ~= nil and ML.roll.itemID == 1001, "open roll survives walk-away")
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
eq(#ML.roll.rolls, 2, "parked window keeps collecting")
ML.OnLootOpened() -- walk back: rows resume around the live roll
ok(LW.Find(1001) ~= nil, "rows resume")
ok(ML.roll ~= nil, "roll still live after walk-back")
eq(LW.doAction(1001, "finish"), "finished", "finish after walk-back")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "award after walk-back")

-- 11. Chat links the item, never a bare item:id. (Full links contain
-- an "item:<id>" substring by shape — the check is for the bare
-- fallback: a line that IS "item:1001" with no [Name] and no link.)
resetHarness()
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
printed = {}
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
local leaked = nil
for i = 1, #printed do
  local line = tostring(printed[i])
  if line == "item:1001"
      or (string.find(line, "item:1001", 1, true)
        and not string.find(line, "|Hitem:", 1, true)
        and not string.find(line, "%[", 1, true)) then
    leaked = printed[i] break
  end
end
ok(leaked == nil, "no bare item:id in chat, got: " .. tostring(leaked))
local sawNamed = false
for i = 1, #printed do
  if string.find(printed[i], "Dragonfang Blade", 1, true) then sawNamed = true break end
end
ok(sawNamed, "chat names the item")

-- 12. Sheet log floor: below rare (green here) never enters the sheet —
-- no stub, no history, no won mark — while the roll/award flow itself
-- still works (item loots, row clears).
resetHarness()
lootSlots = { { link = "item:6001:0:0:0", quality = 2 } }
ML.OnLootOpened()
ok(LW.Find(6001) ~= nil, "green row listed")
LW.OpenDetail(6001)
eq(LW.doAction(6001, "roll"), "rolling", "green roll starts")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
eq(LW.doAction(6001, "finish"), "finished", "green finish resolves")
ok(ZugLoot.DB.sheet.items[6001] == nil, "green never stubbed onto the sheet")
eq(SRData.RollCount(ZugLoot.DB.sheet, 6001), 0, "green roll history never recorded")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 6001)
ok(not SRData.HasWon(ZugLoot.DB.sheet, 6001, "Aaa"), "green award leaves no won mark")
ok(LW.Find(6001) == nil, "green row still clears on award")
-- Rare and above still log: stub + history + won mark.
resetHarness()
lootSlots = { { link = "item:6002:0:0:0", quality = 3 } }
ML.OnLootOpened()
LW.OpenDetail(6002)
LW.doAction(6002, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
LW.doAction(6002, "finish")
ok(ZugLoot.DB.sheet.items[6002] ~= nil, "rare stubbed onto the sheet")
eq(SRData.RollCount(ZugLoot.DB.sheet, 6002), 1, "rare roll history recorded")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 6002)
ok(SRData.HasWon(ZugLoot.DB.sheet, 6002, "Aaa"), "rare award won-marks")

-- 13. Award menu data: winners + kind groups + TMOG row + candidates.
resetHarness()
local res = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001,
  { { name = "Aaa", roll = 90, type = "SR" }, { name = "Bbb", roll = 80, type = "SR" } },
  { cap = 100 })
local menu = ML.AwardMenu(1001, "item:1001", res)
eq(menu.winners[1].name, "Aaa", "menu top winner")
eq(menu.winners[1].rollType, "SR", "menu winner kind")
eq(menu.groups.SR[1].name, "Aaa", "SR group ranked")
local candNames = {}
for i = 1, #menu.candidates do candNames[menu.candidates[i].name] = true end
ok(not candNames["Aaa"] and not candNames["Bbb"], "rollers never repeat as candidates")

-- 14. Auto loot-method switching (raid-leader boss flow): option off =
-- nothing happens; option on + leader + raid + worldboss target = master
-- loot with self as master; fully looting (last row gone) flips back to
-- group. Non-leaders, non-raid groups, elite trash, and solo never switch
-- (in raids every trash mob is elite and wants group loot).
resetHarness()
local lootCalls = {}
SetLootMethod = function(m, master) table.insert(lootCalls, { m, master }) return true end
local targetCls = "worldboss"
UnitExists = function(u) return u == "target" end
UnitClassification = function(u) return targetCls end
grouping = "raid"
ZugLoot.SRSecurity.AmLeader = function() return true end
ZugLoot.SRSecurity.LootMethod = function() return "group" end
ZugLoot.DB.mlOnBoss = true
ZugLoot.DB.backToGroup = true
ML.autoML = false
ok(ML.MaybeMasterOnBoss(), "leader + raid boss target switches")
eq(lootCalls[1][1], "master", "master loot method")
eq(lootCalls[1][2], "SoloPlayer", "self as master")
ok(ML.autoML, "auto-switch flagged")
ok(not ML.MaybeMasterOnBoss(), "second select is a no-op")
eq(#lootCalls, 1, "no double switch")
-- Elite trash in a raid: NEVER switches (group loot stays).
targetCls = "elite"
UnitHealthMax = function(u) return 15000 end -- trash HP
ML.autoML = false
ok(not ML.MaybeMasterOnBoss(), "raid trash elite never switches")
eq(#lootCalls, 1, "still one call")
-- High-HP elite (indoor boss without the worldboss flag): switches.
UnitHealthMax = function(u) return 400000 end -- boss HP
ok(ML.MaybeMasterOnBoss(), "high-HP elite switches")
eq(lootCalls[2][1], "master", "boss HP triggers master")
ML.autoML = false
table.remove(lootCalls)
-- Worldboss flag still switches regardless of HP API presence.
UnitHealthMax = nil
targetCls = "worldboss"
ok(ML.MaybeMasterOnBoss(), "worldboss flag switches without HP API")
ML.autoML = false
table.remove(lootCalls)
UnitHealthMax = function(u) return 400000 end
-- Non-boss target: no switch.
targetCls = "normal"
UnitHealthMax = function(u) return 3000 end -- critter HP
ok(not ML.MaybeMasterOnBoss(), "trash target never switches")
eq(#lootCalls, 1, "still one call")
-- Party (not raid): no switch even on a worldboss.
targetCls = "worldboss"
grouping = "party"
ok(not ML.MaybeMasterOnBoss(), "party never switches")
eq(#lootCalls, 1, "still one call")
grouping = "raid"
-- Non-leader: no switch even on a boss.
targetCls = "worldboss"
ZugLoot.SRSecurity.AmLeader = function() return false end
ok(not ML.MaybeMasterOnBoss(), "non-leader never switches")
eq(#lootCalls, 1, "still one call")
-- Option off: no switch.
ZugLoot.SRSecurity.AmLeader = function() return true end
ZugLoot.DB.mlOnBoss = false
ok(not ML.MaybeMasterOnBoss(), "option off never switches")
eq(#lootCalls, 1, "still one call")
-- Switch-back: last row gone after OUR switch flips to group.
ZugLoot.DB.mlOnBoss = true
ML.autoML = true
LW.SetItems({ { itemID = 1001, link = "item:1001" } }, "loot")
ok(not ML.MaybeGroupAfterBoss("raid"), "rows left: no switch-back")
eq(#lootCalls, 1, "still one call")
LW.RemoveItem(1001)
ok(ML.MaybeGroupAfterBoss("raid"), "emptied list switches back")
eq(lootCalls[2][1], "group", "back to group loot")
ok(not ML.autoML, "flag cleared")
-- Sim rows never trigger the switch-back.
ML.autoML = true
ok(not ML.MaybeGroupAfterBoss("sim"), "sim never switches back")
eq(#lootCalls, 2, "still two calls")
ok(ML.autoML, "sim keeps the flag")
-- Awarding the last row switches back through the award path.
ML.autoML = true
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
ML.AwardDirect(1001, "Aaa", "loot")
eq(lootCalls[3][1], "group", "award-emptied list switches back")
ok(not ML.autoML, "award clears the flag")
-- Ignoring the last row switches back through the ignore path.
ML.autoML = true
ML.OnLootOpened()
ML.Ignore(1001, "loot")
eq(lootCalls[4][1], "group", "ignore-emptied list switches back")
-- 15. Boss threshold: choices, validated setter, applied on switch,
-- restored on switch-back.
local tc = ML.ThresholdChoices()
eq(#tc, 4, "four thresholds")
eq(tc[1].value, 1, "common first")
eq(tc[4].label, "Epic (4)", "epic labeled")
ok(ML.SetBossThreshold(3), "rareaccepted")
eq(ZugLoot.DB.bossThreshold, 3, "rare stored")
ok(not ML.SetBossThreshold(0), "0 refused")
ok(not ML.SetBossThreshold(5), "5 refused")
ok(not ML.SetBossThreshold("epic"), "non-number refused")
eq(ZugLoot.DB.bossThreshold, 3, "refusals keep rare")
eq(ML.BossThreshold(), 3, "setter read back")
eq(ML.ThresholdLabel(1), "Common (1)", "common labeled")
ZugLoot.DB.bossThreshold = 99
eq(ML.BossThreshold(), 4, "out-of-range falls back to epic")
ZugLoot.DB.bossThreshold = nil
eq(ML.BossThreshold(), 4, "absent falls back to epic")
-- Applied on switch, restored on switch-back.
ZugLoot.DB.bossThreshold = 4
local threshCalls = {}
SetLootThreshold = function(n) table.insert(threshCalls, n) return true end
GetLootThreshold = function() return 2 end
ML.autoML = false
grouping = "raid"
ZugLoot.SRSecurity.AmLeader = function() return true end
targetCls = "worldboss"
ZugLoot.DB.mlOnBoss = true
ok(ML.MaybeMasterOnBoss(), "switch with threshold")
eq(threshCalls[1], 4, "epic applied on switch")
eq(ML.prevThreshold, 2, "previous threshold remembered")
LW.SetItems({}, "loot")
ZugLoot.DB.backToGroup = true
ok(ML.MaybeGroupAfterBoss("raid"), "switch-back with restore")
eq(threshCalls[2], 2, "previous threshold restored")
ok(ML.prevThreshold == nil, "remembered threshold cleared")
SetLootThreshold = nil
GetLootThreshold = nil
SetLootMethod = nil
UnitExists = nil
UnitClassification = nil
UnitHealthMax = nil
ZugLoot.SRSecurity.AmLeader = function() return true end
grouping = "solo"

return T
