-- tests/test_corpse_slot_shift.lua
-- Verification of corpse slot shifting, candidate dynamic re-resolution, and C-API fallback.
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
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")

local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow

-- Mock state
local loot = {}
local candidates = {}
local masterCalls = {}

GetNumLootItems = function() return #loot end
GetLootSlotLink = function(slot) return loot[slot] and loot[slot].link end
GetLootSlotInfo = function(slot)
  local item = loot[slot]
  if not item then return nil end
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
GetLootThreshold = function() return 2 end -- green+ is roll
UnitName = function(u) return u == "player" and "MasterLooter" or nil end

GetMasterLootCandidate = function(idx)
  return candidates[idx]
end

GiveMasterLoot = function(slot, candidateIdx)
  table.insert(masterCalls, { slot = slot, idx = candidateIdx, api = "GiveMasterLoot" })
end

ZugLoot.SRSecurity = {
  IsSolo = function() return false end,
  IsInRaid = function() return true end,
  IsInGroup = function() return true end,
  AmML = function() return true end,
  LootMethod = function() return "master" end,
}

-- 1. Test Corpse Slot Shift Reconciliation
-- Initial corpse:
-- Slot 1: 5001 (Grey Ruined Pelt)
-- Slot 2: 17001 (Epic Pants)
-- Slot 3: 17002 (Epic Robe)
loot = {
  { id = 5001, link = "item:5001:0:0:0", quality = 0 },
  { id = 17001, link = "item:17001:0:0:0", quality = 4 },
  { id = 17002, link = "item:17002:0:0:0", quality = 4 },
}
candidates = { "WarriorA", "PriestB", "MageC" }

ML.lootOpen = true
LW.SetItems({
  { itemID = 5001, link = "item:5001:0:0:0", quality = 0, slot = 1, free = true },
  { itemID = 17001, link = "item:17001:0:0:0", quality = 4, slot = 2 },
  { itemID = 17002, link = "item:17002:0:0:0", quality = 4, slot = 3 },
}, "loot")

-- Now slot 1 (trash) is looted off corpse! Slots collapse in WoW engine!
table.remove(loot, 1)
-- Now corpse is:
-- Slot 1: 17001
-- Slot 2: 17002
eq(#loot, 2, "corpse collapsed to 2 slots")

-- Award item 17002 (was slot 3 at scan time, now slot 2) to PriestB
masterCalls = {}
local res = ML.Award(17002, "PriestB")
ok(res ~= false, "award succeeded")
eq(#masterCalls, 1, "exactly one master loot call issued")
eq(masterCalls[1].slot, 2, "corpse slot shift reconciled: targeted slot 2, not stale slot 3")
eq(masterCalls[1].idx, 2, "PriestB candidate index matched")

-- 2. Test Candidate Index Shift (Player in front released spirit / moved out of range)
-- WarriorA leaves range, so PriestB shifts from candidate 2 to candidate 1
candidates = { "PriestB", "MageC" }
masterCalls = {}
-- Award remaining item 17001 (which is at slot 1) to PriestB
local res2 = ML.Award(17001, "PriestB")
ok(res2 ~= false, "award succeeded")
eq(#masterCalls, 1, "master loot call issued")
eq(masterCalls[1].slot, 1, "targeted correct slot 1")
eq(masterCalls[1].idx, 1, "dynamically re-resolved candidate index 1 for PriestB, not stale index 2")

-- 3. Test Candidate Disconnected / Out of Range
candidates = { "MageC" } -- PriestB has zoned out
LW.SetItems({ { itemID = 17001, link = "item:17001:0:0:0", quality = 4, slot = 1 } }, "loot")
local res3 = ML.Award(17001, "PriestB")
eq(res3, false, "award refused when player is not a valid loot candidate")

-- 4. Test GiveMasterLootCandidate API Fallback
GiveMasterLoot = nil
GiveMasterLootCandidate = function(slot, candidateIdx)
  table.insert(masterCalls, { slot = slot, idx = candidateIdx, api = "GiveMasterLootCandidate" })
end

masterCalls = {}
loot = { { id = 17001, link = "item:17001:0:0:0", quality = 4 } }
candidates = { "MageC" }
LW.SetItems({ { itemID = 17001, link = "item:17001:0:0:0", quality = 4, slot = 1 } }, "loot")
local res4 = ML.Award(17001, "MageC")
ok(res4 ~= false, "award succeeded with GiveMasterLootCandidate")
eq(#masterCalls, 1, "call issued")
eq(masterCalls[1].api, "GiveMasterLootCandidate", "used GiveMasterLootCandidate fallback")
eq(masterCalls[1].slot, 1, "slot 1")
eq(masterCalls[1].idx, 1, "candidate 1")

-- 5. Ignore-first, then clear the rest through the corpse path: ignoring
-- 17001 up front leaves 17002 actionable; a LOOT_SLOT_CLEARED confirm
-- for 17002 (dropped by RescanLeftovers, which never closed out) must
-- close the whole window since only ignored rows remain.
loot = {
  { id = 17001, link = "item:17001:0:0:0", quality = 4 },
  { id = 17002, link = "item:17002:0:0:0", quality = 4 },
}
ZugLoot.DropLog = { Add = function() end }
LW.SetItems({
  { itemID = 17001, link = "item:17001:0:0:0", quality = 4, slot = 1 },
  { itemID = 17002, link = "item:17002:0:0:0", quality = 4, slot = 2 },
}, "loot")
ML.lootOpen = true
LW.OpenDetail(17001)
ML.Ignore(17001, "loot")
ok(LW.Find(17001) ~= nil and LW.Find(17001).ignored, "first row ignored, still listed")
ok(LW.detail ~= nil, "detail stays open: 17002 still actionable")
-- 17002 leaves the corpse (manual take / another client's loot):
-- only the ignored row still matches the corpse.
loot = { { id = 17001, link = "item:17001:0:0:0", quality = 4 } }
local hideCalls, closeCalls = 0, 0
local realHide = LW.Hide
LW.Hide = function() hideCalls = hideCalls + 1 return realHide() end
CloseLoot = function() closeCalls = closeCalls + 1 end
ML.RescanLeftovers()
eq(#LW.items, 1, "rescan dropped the looted row, ignored row stays")
ok(LW.Find(17001).ignored, "remaining row is the ignored one")
ok(LW.detail == nil, "detail closed: only ignored rows left")
ok(hideCalls >= 1, "loot window closed after rescan left only ignored rows")
ok(closeCalls >= 1, "loot session closed after rescan left only ignored rows")
CloseLoot = nil
LW.Hide = realHide
ok(LW.LootingFinished(), "ignore-first + corpse-path finishes looting")

-- 6. Second chance: re-looting the corpse brings the ignored row back
-- WITHOUT closing. A no-change rescan (reopen) must never close — only
-- a rescan that DROPPED rows may.
loot = { { id = 17001, link = "item:17001:0:0:0", quality = 4 } }
ML.lootOpen = true
hideCalls, closeCalls = 0, 0
LW.Hide = function() hideCalls = hideCalls + 1 return realHide() end
CloseLoot = function() closeCalls = closeCalls + 1 end
ML.RescanLeftovers() -- reopen onto the still-present ignored row: no drop
eq(#LW.items, 1, "reopen rescan keeps the ignored row")
ok(LW.Find(17001).ignored, "reopened row still flagged ignored")
eq(hideCalls, 0, "reopen does not close the loot window")
eq(closeCalls, 0, "reopen does not close the loot session")
CloseLoot = nil
LW.Hide = realHide
-- …and the looter can roll the previously-ignored item after all:
-- starting its roll clears the mark and it is actionable again.
ZugLoot.DB = ZugLoot.DB or {}
ZugLoot.DB.sheet = ZugLoot.DB.sheet or ZugLoot.SRData.NewSheet()
LW.OpenDetail(17001)
eq(LW.doAction(17001, "roll"), "rolling", "ignored row re-rollable on second chance")
ok(not LW.Find(17001).ignored, "roll clears the ignored mark")
ok(not LW.LootingFinished(), "actionable again: looting not finished")

-- 7. Issue #25 (Nefarian): a hostile client-side range reading must
-- never refuse a real award. Corpse open, slot verified, target still
-- the corpse — CheckInteractDistance says out of range (huge-boss
-- hitbox disagrees with the open loot session), but the handoff needs
-- no range and the corpse is readable, so the award must go through.
loot = { { id = 18001, link = "item:18001:0:0:0", quality = 4 } }
candidates = { "MageC" }
ML.lootOpen = true
ML.lootGUID = "guid-nef"
ML.lootTarget = "Nefarian"
UnitExists = function(u)
  if u == "target" then return true, "guid-nef" end
  return nil
end
CheckInteractDistance = function() return false end
LW.SetItems({ { itemID = 18001, link = "item:18001:0:0:0", quality = 4, slot = 1 } }, "loot")
masterCalls = {}
local logged = {}
local realPrint = ZugLoot.Print
ZugLoot.Print = function(m) table.insert(logged, tostring(m)) end
local res7 = ML.Award(18001, "MageC")
ZugLoot.Print = realPrint
ok(res7 ~= false, "award succeeds despite out-of-range reading")
eq(#masterCalls, 1, "handoff issued on the verified slot")
local movedMsg = false
for i = 1, #logged do
  if string.find(logged[i], "moved away", 1, true) then movedMsg = true end
end
ok(not movedMsg, "no moved-away refusal on a readable corpse")
UnitExists = nil
CheckInteractDistance = nil
ML.lootGUID, ML.lootTarget = nil, nil

if T.fail == 0 then
  print("corpse slot shift and candidate invariants passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
