-- tests/test_multipage.lua
-- Issue #25: multi-page corpses (Rag/Onyxia scale: 8+ slots with
-- duplicates, coin, blues) must never lock up the addon. Covers the
-- full wave: scan -> roll -> award x N with slot collapse, plus the
-- adversarial client modes (page-gated nil reads, erroring reads).
-- ScanSlot is the last unguarded reader: a slot that ERRORS must read
-- as empty, never abort the scan mid-list (the lockup).
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else
    T.pass = T.pass + 1
  end
end

local function ok(v, msg)
  if not v then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else
    T.pass = T.pass + 1
  end
end

ZugLoot = {}
ZugLoot.Print = function() end
dofile("Constants.lua")
dofile("Util.lua")
dofile("ClassColors.lua")
dofile("Timer.lua")
dofile("RollList.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
dofile("Sim.lua")

local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow
local SRData = ZugLoot.SRData

-- Corpse model with 1.12 slot collapse + configurable read faults.
local loot = {}
local readMode = "global" -- "global" | "page5nil" | "page5err"
local masterCalls = {}
local lootCalls = {}
local candidates = { "Aaa", "Bbb", "Ccc" }

GetNumLootItems = function() return #loot end
GetLootSlotLink = function(slot)
  if readMode == "page5err" and slot > 5 then error("slot off page") end
  if readMode == "page5nil" and slot > 5 then return nil end
  return loot[slot] and loot[slot].link
end
GetLootSlotInfo = function(slot)
  if readMode == "page5err" and slot > 5 then error("slot off page") end
  if readMode == "page5nil" and slot > 5 then return nil end
  local item = loot[slot]
  if not item then return nil end
  -- Coin slots report the amount text as the name, like the client.
  if item.coin then return "texture", item.coinName or "27 Silver", 1, 0 end
  return "texture", item.link, 1, item.quality
end
GetItemInfo = function(link)
  for _, item in ipairs(loot) do
    if item.link == link then
      return "Item " .. item.id, item.link, item.quality
    end
  end
  return nil
end
GetLootMethod = function() return "master" end
GetLootThreshold = function() return 2 end
LootSlotIsCoin = function(slot)
  if readMode == "page5err" and slot > 5 then error("slot off page") end
  if readMode == "page5nil" and slot > 5 then return nil end
  return loot[slot] and loot[slot].coin and 1 or nil
end
LootSlotIsItem = function(slot)
  if readMode == "page5err" and slot > 5 then error("slot off page") end
  if readMode == "page5nil" and slot > 5 then return nil end
  return loot[slot] and not loot[slot].coin and 1 or nil
end
UnitName = function(u) return u == "player" and "MasterLooter" or nil end
GetMasterLootCandidate = function(idx) return candidates[idx] end
GiveMasterLoot = function(slot, idx)
  table.insert(masterCalls, { slot = slot, idx = idx })
  table.remove(loot, slot) -- server clears + collapse
  return true
end
LootSlot = function(slot)
  table.insert(lootCalls, slot)
  table.remove(loot, slot)
  return true
end

ZugLoot.SRSecurity = {
  IsSolo = function() return false end,
  IsInRaid = function() return true end,
  IsInGroup = function() return true end,
  AmML = function() return true end,
  LootMethod = function() return "master" end,
}
ZugLoot.DB = { sheet = SRData.NewSheet(), rollTime = 30 }
ZugLoot.DB.lootTakeover = true
ZugLoot.RaiderLootUI = {
  ShowItem = function() end, OnRoll = function() end, Hide = function() end,
}
ZugLoot.Comm = ZugLoot.Comm or { BroadcastAward = function() end }
ZugLoot.DropLog = { Add = function() end }

local function ragCorpse()
  -- Rag scale: duplicate epics, blues, coin. Coin LAST like a real boss.
  return {
    { id = 17001, link = "item:17001:0:0:0", quality = 4 },
    { id = 17002, link = "item:17002:0:0:0", quality = 4 },
    { id = 17001, link = "item:17001:0:0:0", quality = 4 }, -- duplicate id, own slot
    { id = 17003, link = "item:17003:0:0:0", quality = 4 },
    { id = 17004, link = "item:17004:0:0:0", quality = 4 },
    { id = 17005, link = "item:17005:0:0:0", quality = 3 },
    { id = 17006, link = "item:17006:0:0:0", quality = 3 },
    { id = 17007, link = "item:17007:0:0:0", quality = 2 },
    -- Coin LAST with a real amount text, like the live client (a
    -- nil/empty name reads as a zero-copper phantom and skips).
    { id = "Coin", link = nil, quality = 0, coin = true, coinName = "27 Silver" },
  }
end

local function sheetFor(ids)
  local s = SRData.NewSheet()
  for _, id in ipairs(ids) do
    s.items[id] = { quality = 4, rollers = {
      { name = "Aaa", rolls = 1 }, { name = "Bbb", rolls = 1 } } }
  end
  return s
end

local function awardAll(maxN)
  -- Roll + finish + award every roll row, firing the client event
  -- storm (LOOT_SLOT_CLEARED per take) like the live flow.
  local n = 0
  while n < (maxN or 20) do
    local target = nil
    for i = 1, ZugLoot.Util.ArrayCount(LW.items) do
      local it = LW.items[i]
      if it and it.itemID ~= "Coin" and not it.ignored then target = it break end
    end
    if not target then break end
    n = n + 1
    LW.OpenDetail(target.itemID)
    if LW.doAction(target.itemID, "roll") ~= "rolling" then
      return n, "roll failed for " .. tostring(target.itemID)
    end
    ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
    ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
    if LW.doAction(target.itemID, "finish") ~= "finished" then
      return n, "finish failed for " .. tostring(target.itemID)
    end
    if ML.Award(target.itemID, "Aaa", "raid") ~= true then
      return n, "award failed for " .. tostring(target.itemID)
    end
    ML.OnEvent("LOOT_SLOT_CLEARED")
    LW.OnEvent("LOOT_SLOT_CLEARED")
  end
  return n, nil
end

-- 1. Baseline: global reads, Rag-scale corpse, full clear converges.
readMode = "global"
loot = ragCorpse()
masterCalls, lootCalls = {}, {}
ZugLoot.DB.sheet = sheetFor({ 17001, 17002, 17003, 17004, 17005 })
ML.lootOpen = false
ML.roll = nil
ML.OnLootOpened()
eq(#LW.items, 9, "all 9 slots listed in one scan")
local ids = {}
for i = 1, #LW.items do ids[LW.items[i].itemID] = (ids[LW.items[i].itemID] or 0) + 1 end
eq(ids[17001], 2, "duplicate epic keeps both rows")
ok(LW.Find("Coin") ~= nil, "coin listed")
local t0 = os.clock()
local n, err = awardAll()
eq(err, nil, "full clear runs clean" .. (err and (": " .. err) or ""))
eq(n, 8, "8 roll rows awarded, coin left")
eq(#LW.items, 1, "only the coin row remains")
eq(#loot, 1, "only coin left on corpse")
ok(os.clock() - t0 < 5, "Rag-scale clear is instant, no lockup")
eq(#masterCalls, 8, "one handoff per award")

-- 2. Page-gated reads (nil past slot 5): scan completes partial, and
-- the list CONVERGES as slots collapse into view — awardAll drains
-- straight through the waves (each LOOT_SLOT_CLEARED rescan appends
-- newly visible slots), ending coin-only with no re-loot.
readMode = "page5nil"
loot = ragCorpse()
masterCalls, lootCalls = {}, {}
ML.lootOpen = false
ML.roll = nil
ML.OnLootOpened()
eq(#LW.items, 5, "partial scan lists the readable page")
local t1 = os.clock()
local n2, err2 = awardAll()
eq(err2, nil, "paged awards run clean" .. (err2 and (": " .. err2) or ""))
eq(n2, 8, "all 8 roll rows drain across waves")
eq(#loot, 1, "corpse converges to coin-only")
ok(os.clock() - t1 < 5, "paged clear is instant, no lockup")

-- 3. RAISING reads past slot 5: scan must complete, nothing propagates.
readMode = "page5err"
loot = ragCorpse()
masterCalls, lootCalls = {}, {}
ML.lootOpen = false
ML.roll = nil
local scanOk = pcall(ML.OnLootOpened)
ok(scanOk, "erroring slots never abort the scan")
eq(#LW.items, 5, "readable page still listed")
-- VerifySlot + LiveCorpseKey survive the same hostility.
local vOk = pcall(ML.VerifySlot, 17001, 1)
ok(vOk, "VerifySlot never raises")
local kOk = pcall(ML.LiveCorpseKey)
ok(kOk, "LiveCorpseKey never raises")
readMode = "global"

-- 4. Scan-gap diagnostic fires exactly when readable < reported.
-- Fresh corpse key (walk-away-and-back would restore+rescan instead
-- of scanning: clear the key so this block takes the scan path).
ZugLoot.LootWindow.lootDebug = true
local logged = {}
local oldPrint = ZugLoot.Print
ZugLoot.Print = function(m) table.insert(logged, tostring(m)) end
readMode = "page5nil"
loot = ragCorpse()
ML.lootOpen = false
ML.lootKey = nil
ML.lootGUID = nil
ML.lootTarget = nil
ML.corpseCache = {}
ML.corpseOrder = {}
ML.OnLootOpened()
local sawGap = false
for i = 1, #logged do
  if string.find(logged[i], "scan gap", 1, true) then sawGap = true break end
end
ok(sawGap, "scan gap logged under lootdebug")
ok(ML.lastScanGap ~= nil and ML.lastScanGap.reported == 9, "gap numbers kept")
readMode = "global"
loot = ragCorpse()
logged = {}
ML.OnLootOpened()
sawGap = false
for i = 1, #logged do
  if string.find(logged[i], "scan gap", 1, true) then sawGap = true break end
end
ok(not sawGap, "no gap logged on a clean scan")
ok(ML.lastScanGap == nil, "gap state cleared")
ZugLoot.Print = oldPrint
ZugLoot.LootWindow.lootDebug = false
readMode = "global"

return T
