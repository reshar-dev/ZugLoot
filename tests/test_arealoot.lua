-- tests/test_arealoot.lua
-- Area-loot engine (ported from AutoAreaLoot): master switch + per-trigger
-- toggles, ClassicAPI DLL gate (inert without it), and the request /
-- schedule / walk state machine driven by ZugLoot.Timer.
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

dofile("Timer.lua")
dofile("AreaLoot.lua")
local AL = ZugLoot.AreaLoot

-- 1. ClassicAPI gate: nothing scans without C_Loot.LootAllCorpses.
C_Loot = nil
ZugLoot.DB = nil
ok(not AL.Available(), "no DLL: unavailable")
eq(AL.RequireAPI(), false, "no DLL: refused")
ok(#printed == 1 and string.find(printed[1], "ClassicAPI", 1, true),
  "no DLL: one-time warning names the DLL")
eq(AL.RequireAPI(), false, "still refused")
eq(#printed, 1, "warning fires once, never spams")

-- 2. Config defaults + toggles (headless DB + fallback DB).
ZugLoot.DB = nil
eq(AL.IsOn(), false, "absent store reads OFF")
eq(AL.SetEnabled(true), true, "master ON sticks")
eq(AL.IsOn(), true, "reads ON")
eq(AL.DeathOn(), true, "death defaults ON")
eq(AL.StopOn(), true, "stop defaults ON")
eq(AL.CombatOn(), true, "combat defaults ON")
eq(AL.SetDeath(false), false, "death OFF sticks")
eq(AL.SetStop(false), false, "stop OFF sticks")
eq(AL.SetCombat(false), false, "combat OFF sticks")
eq(AL.SetEnabled(false), false, "master OFF sticks")
ZugLoot.DB = { areaLoot = {} }
eq(AL.IsOn(), false, "DB backfills OFF")
eq(AL.DeathOn(), true, "DB backfills death ON")
eq(AL.StopOn(), true, "DB backfills stop ON")
eq(AL.CombatOn(), true, "DB backfills combat ON")
eq(ZugLoot.DB.areaLoot.enabled, false, "OFF persisted")
eq(ZugLoot.DB.areaLoot.lootOnDeath, true, "death persisted")
-- Status line names the DLL state.
C_Loot = nil
ok(string.find(AL.StatusText(), "missing", 1, true) ~= nil, "status names missing DLL")

-- 3. Request path without the DLL: inert (false), never scans.
ZugLoot.DB = { areaLoot = { enabled = true } }
C_Loot = nil
AL.state.initialized = true
eq(AL.RequestLoot("death"), false, "no DLL: request refused")
eq(AL.state.lootWalkActive, false, "no DLL: no walk started")
eq(AL.state.pendingLootReason, nil, "no DLL: nothing queued")

-- 4. Request path with a stubbed DLL: scan fires, walk state set.
local scans = 0
C_Loot = {
  LootAllCorpses = function() scans = scans + 1 return true end,
  IsScanInProgress = function() return false end,
}
GetTime = function() return 100 end
AL.state.initialized = true
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = true,
  lootOnStop = true, lootInCombat = true }
eq(AL.RequestLoot("death"), true, "DLL present: request starts")
eq(scans, 1, "exactly one scan issued")
ok(AL.state.lootWalkActive, "walk active")
-- LOOT_SCAN_COMPLETED completes the walk (stand-in for the client event).
AL.OnEvent("LOOT_SCAN_COMPLETED")
ok(not AL.state.lootWalkActive, "walk completed")
eq(AL.state.emptyScanStreak, 1, "empty scan schedules one follow-up")
-- Follow-up path runs through ZugLoot.Timer.
eq(ZugLoot.Timer.Pending() > 0, true, "follow-up scheduled")
ZugLoot.Timer.Update(10)
eq(scans, 2, "follow-up scan issued")

-- 5. Gating: moving players defer, combat respects its toggle.
AL.Shutdown()
AL.state.initialized = true
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = true,
  lootOnStop = true, lootInCombat = false }
GetUnitSpeed = function() return 5 end
scans = 0
AL.state.pendingLootReason = nil
eq(AL.RequestLoot("death"), false, "moving: deferred, not scanned")
eq(scans, 0, "moving: no scan")
eq(AL.state.pendingLootReason, "death", "moving: reason queued")
GetUnitSpeed = nil
AL.state.playerMoving = false
AL.state.pendingLootReason = nil
UnitAffectingCombat = function() return true end
eq(AL.RequestLoot("death"), false, "combat off: deferred")
eq(AL.state.pendingLootReason, "death", "combat: reason queued")
ZugLoot.DB.areaLoot.lootInCombat = true
AL.state.pendingLootReason = nil
eq(AL.RequestLoot("death"), true, "combat on: scans")
UnitAffectingCombat = nil

-- 6. Death trigger entry: disabled setting ignores, enabled schedules.
AL.Shutdown()
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = false,
  lootOnStop = true, lootInCombat = true }
AL.state.lootRequestTimer = nil
AL.OnDeath(nil)
eq(AL.state.lootRequestTimer, nil, "death off: nothing scheduled")
ZugLoot.DB.areaLoot.lootOnDeath = true
AL.OnDeath(nil)
ok(AL.state.lootRequestTimer ~= nil, "death on: pass scheduled")
AL.state.lootRequestTimer = nil
ZugLoot.Timer.CancelAll()

-- 7. Manual-loot guard: a corpse ZugLoot already shows defers the walk.
AL.Shutdown()
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = true,
  lootOnStop = true, lootInCombat = true }
ZugLoot.MasterLootUI = { lootOpen = true }
scans = 0
AL.state.pendingLootReason = nil
eq(AL.RequestLoot("death"), false, "open corpse: deferred")
eq(AL.state.pendingLootReason, "death", "open corpse: queued behind it")
ZugLoot.MasterLootUI = nil

-- 8. Shutdown drops runtime, keeps config.
AL.state.lootWalkActive = true
AL.state.pendingLootReason = "death"
AL.Shutdown()
eq(AL.state.lootWalkActive, false, "shutdown drops the walk")
eq(AL.state.pendingLootReason, nil, "shutdown drops the queue")
eq(ZugLoot.DB.areaLoot.enabled, true, "shutdown keeps config")

-- 9. Status line when ready.
C_Loot = {
  LootAllCorpses = function() return true end,
  IsScanInProgress = function() return false end,
}
ok(string.find(AL.StatusText(), "ON", 1, true) ~= nil, "status shows ON")
AL.SetEnabled(false)
ok(string.find(AL.StatusText(), "OFF", 1, true) ~= nil, "status shows OFF")

C_Loot = nil
GetTime = nil
GetUnitSpeed = nil
ZugLoot.MasterLootUI = nil
ZugLoot.Timer.CancelAll()

if T.fail == 0 then
  print("area loot passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
