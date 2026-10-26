-- tests/test_settings_reset.lua
-- Factory reset: RequestResetAllSettings wipes SavedVariables (account +
-- character), clears session data and reapplies defaults, via confirm popup
-- when available and directly otherwise.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

-- Minimal frame mock for Core's Z.Init() at load.
local function blankFrame()
  local o = {}
  function o:RegisterEvent() end
  function o:SetScript() end
  return o
end
CreateFrame = function() return blankFrame() end
UIParent = {}
SlashCmdList = {}
DEFAULT_CHAT_FRAME = nil

ZugLoot = {}
dofile("Util.lua")
dofile("Constants.lua")
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Core.lua")
local Z = ZugLoot

local printed = {}
Z.Print = function(m) table.insert(printed, tostring(m)) end

local function seedDirty()
  ZugLootDB = {
    sheet = Z.SRData.NewSheet(),
    raidArchive = { { raidID = "R1" } },
    drops = { { itemID = 1 } },
    rollTime = 99,
    autoClose = false,
    customKey = "must-go",
  }
  ZugLootCharDB = { autoRoll = true, verSeen = { X = true }, customChar = 1 }
  Z.DB = ZugLootDB
  Z.CharDB = ZugLootCharDB
  Z.VersionGrid = { seen = { Y = true } }
  Z.MainWindow = nil
  Z.SRView = nil
  printed = {}
end

-- 1. Direct path (no popup API): everything wiped, defaults reapplied.
StaticPopupDialogs = nil
StaticPopup_Show = nil
seedDirty()
Z.RequestResetAllSettings()
eq(Z.DB.rollTime, Z.Limits.ROLL_TIMEOUT_DEFAULT, "rollTime default restored")
eq(Z.DB.autoClose, true, "autoClose default restored")
eq(Z.DB.sheet, nil, "sheet cleared")
eq(#Z.DB.raidArchive, 0, "archive cleared")
eq(#Z.DB.drops, 0, "drops cleared")
eq(Z.DB.customKey, nil, "unknown account keys wiped")
eq(Z.CharDB.autoRoll, false, "autoRoll default restored")
eq(Z.CharDB.customChar, nil, "unknown char keys wiped")
ok(next(Z.CharDB.verSeen) == nil, "verSeen cleared")
ok(next(Z.VersionGrid.seen) == nil, "runtime version cache cleared")
ok(string.find(printed[#printed], "reset to defaults"), "confirmation printed")

-- 2. Second reset on clean state is a safe no-op.
printed = {}
Z.RequestResetAllSettings()
eq(Z.DB.rollTime, Z.Limits.ROLL_TIMEOUT_DEFAULT, "defaults hold")
ok(string.find(printed[#printed], "reset to defaults"), "still reports")

-- 3. Confirm path: popup defined, OnAccept performs the reset.
seedDirty()
StaticPopupDialogs = {}
local shown = nil
StaticPopup_Show = function(name) shown = name end
printed = {}
Z.RequestResetAllSettings()
eq(shown, "ZUGLOOT_RESET_ALL", "confirm popup shown")
-- nothing wiped yet (user hasn't confirmed):
eq(Z.DB.rollTime, 99, "no reset before confirm")
ok(StaticPopupDialogs["ZUGLOOT_RESET_ALL"] ~= nil, "dialog registered")
StaticPopupDialogs["ZUGLOOT_RESET_ALL"].OnAccept()
eq(Z.DB.rollTime, Z.Limits.ROLL_TIMEOUT_DEFAULT, "reset on accept")
eq(Z.DB.sheet, nil, "sheet cleared on accept")
StaticPopupDialogs = nil
StaticPopup_Show = nil

-- 4. Aggressive reset: runtime session artifacts beyond SavedVariables
-- are dropped too. Regression: timers, open rolls, sim staging, pending
-- network chunks and the stale import-box text survived the wipe, so the
-- NEXT import failed byte-identically ("reset did nothing").
-- Rollover-safe headless: Z.Init() built Core's frame on blank stubs;
-- all modules below load on those same stubs.
dofile("Timer.lua")
dofile("SRSecurity.lua")
dofile("Sim.lua")
dofile("Comm.lua")
dofile("MasterLootUI.lua")
dofile("LootWindow.lua")
dofile("RaiderLootUI.lua")
dofile("SRImport.lua")
Z.Print = function(m) table.insert(printed, tostring(m)) end
seedDirty()
-- Seed session dirt (none of this lives in SavedVariables).
Z.Timer.After(60, function() end)
Z.MasterLootUI.roll = { itemID = 1001, mode = "SR" }
Z.MasterLootUI.lastRound = { itemID = 1001, mode = "SR" }
Z.MasterLootUI.pendingLoot = { [1] = true }
Z.MasterLootUI.lootKey = "corpse:1"
Z.MasterLootUI.corpseCache = { ["corpse:1"] = {} }
Z.MasterLootUI.corpseOrder = { "corpse:1" }
Z.MasterLootUI.autoML = true
Z.Sim.pending = { { itemID = 1001 } }
Z.Sim.running = true
Z.Sim.raid = { key = "R" }
Z.Comm.chunkBuffers = { R1 = { count = 1 } }
Z.Comm.rollChunkBuffers = { ["R1#1001"] = { count = 1 } }
Z._hush = 2
Z.LootWindow.items = { { itemID = 1001, status = "done" } }
Z.LootWindow.silentLootArms = { [1] = true }
Z.RequestResetAllSettings()
eq(Z.Timer.Pending(), 0, "timers drained")
eq(Z.MasterLootUI.roll, nil, "open roll dropped")
eq(Z.MasterLootUI.lastRound, nil, "finish stamp dropped")
eq(Z.MasterLootUI.pendingLoot, nil, "loot arms dropped")
eq(Z.MasterLootUI.lootKey, nil, "corpse key dropped")
eq(next(Z.MasterLootUI.corpseCache), nil, "corpse cache dropped")
eq(Z.MasterLootUI.corpseOrder[1], nil, "corpse order dropped")
eq(Z.MasterLootUI.autoML, false, "autoML disarmed")
eq(Z.Sim.pending[1], nil, "sim queue dropped")
eq(Z.Sim.running, false, "sim stopped")
eq(Z.Sim.raid, nil, "sim raid dropped")
eq(next(Z.Comm.chunkBuffers), nil, "sheet chunks dropped")
eq(next(Z.Comm.rollChunkBuffers), nil, "roll chunks dropped")
eq(Z._hush, 0, "hush counter dropped")
eq(Z.LootWindow.items[1], nil, "loot rows dropped")
eq(Z.LootWindow.silentLootArms, nil, "silent arms dropped")
eq(Z.DB.sheet, nil, "sheet still cleared")
ok(string.find(printed[#printed], "reset to defaults"), "still reports")

-- 5. Roll-timeout policy: single source of truth, 1..30 clamp,
-- 10s default. Every clock reads RollTimeout; SetRollTimeout is
-- the only writer (slider + box + /zl time all funnel through it).
local ML = Z.MasterLootUI
eq(Z.Limits.ROLL_TIMEOUT_DEFAULT, 10, "default is 10s")
eq(Z.Limits.ROLL_TIMEOUT_MIN, 1, "min is 1s")
eq(Z.Limits.ROLL_TIMEOUT_MAX, 30, "max is 30s")
Z.DB.rollTime = nil
eq(ML.RollTimeout(), 10, "missing store reads default")
Z.DB.rollTime = 99
eq(ML.RollTimeout(), 30, "stale 99 clamps to max on read")
Z.DB.rollTime = 0
eq(ML.RollTimeout(), 1, "stale 0 clamps to min on read")
eq(ML.SetRollTimeout(17), 17, "stores seconds")
eq(Z.DB.rollTime, 17, "writer is the store")
eq(ML.SetRollTimeout(99), 30, "clamps high")
eq(ML.SetRollTimeout(-5), 1, "clamps low")
eq(ML.SetRollTimeout("abc"), nil, "garbage refused")
eq(Z.DB.rollTime, 1, "refused write keeps the store")
eq(ML.RollDuration(), 1, "clock reads the clamped store")

return T
