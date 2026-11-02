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

-- 9b. Master-loot gate: the walk stands down (its plain takes would
-- earn server "stealing" refusals on threshold+ corpses); the survey
-- + chain own those corpses instead. Request defers + queues AND kicks
-- the survey immediately; method flip-back re-runs the parked walk.
AL.Shutdown()
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = true,
  lootOnStop = true, lootInCombat = true }
AL.state.initialized = true
ZugLoot.MasterLootUI = {
  lootOpen = false, lootKey = nil, corpseCache = {},
  CurrentLootMethod = function() return "master" end,
}
ZugLoot.LootWindow = nil
scans = 0
C_Loot = {
  LootAllCorpses = function() scans = scans + 1 return true end,
  IsScanInProgress = function() return false end,
  GetNearbyLootableUnits = function()
    return { { guid = "guid-M1" }, { guid = "guid-M2" } }
  end,
  LootUnit = function(guid) table.insert(opened, guid) end,
}
opened = {}
AL.state.pendingLootReason = nil
AL.state.thresholdQueue = {}
AL.state.thresholdSkipped = {}
AL.state.thresholdActive = nil
eq(AL.IsMasterLoot(), true, "master method reads master")
eq(AL.RequestLoot("death"), false, "master: walk refused")
eq(scans, 0, "master: no walk issued (no stealing attempts)")
eq(AL.state.pendingLootReason, "death", "master: request parked for flip-back")
eq(#AL.state.thresholdQueue, 1, "master: second unit stays queued")
eq(opened[1], "guid-M1", "master: survey opened the first corpse")
eq(AL.state.thresholdActive, "guid-M1", "master: chain pinned")
-- Method flips back to group: the parked request re-runs the walk.
ZugLoot.MasterLootUI.CurrentLootMethod = function() return "group" end
ok(not AL.IsMasterLoot(), "group method reads non-master")
AL.state.lootWalkActive = false
AL.state.thresholdActive = nil -- chain idle: closed window re-services
scans = 0
AL.OnEvent("LOOT_CLOSED") -- closed window re-services the queue
eq(AL.state.lootRequestTimer ~= nil, true,
  "flip-back: parked death request scheduled into a walk")
ZugLoot.Timer.CancelAll()
-- Survey skip-logic: queued, skipped, active, and window-held guids
-- never re-queue; only the fresh corpse opens. StatusText names the
-- master-loot stand-down. (Flip-back section above left group live;
-- put master back for this block.)
ZugLoot.MasterLootUI.CurrentLootMethod = function() return "master" end
ok(string.find(AL.StatusText(), "opening for rolls", 1, true) ~= nil,
  "status names the master stand-down")
C_Loot.GetNearbyLootableUnits = function()
  return { { guid = "guid-M1" }, -- active: skip
    { guid = "guid-M2" }, -- queued: skip
    { guid = "guid-M3" }, -- skipped: skip
    { guid = "guid-M4" }, -- window-held: skip
    { guid = "guid-M5" } } -- fresh: queue
end
AL.state.thresholdActive = "guid-M1"
AL.state.thresholdQueue = { { guid = "guid-M2" } }
AL.state.thresholdSkipped = { ["guid-M3"] = true }
ZugLoot.MasterLootUI.corpseCache = { ["guid:guid-M4"] = true }
opened = {}
eq(AL.SurveyMasterLoot(), true, "survey ran with a fresh corpse")
eq(#AL.state.thresholdQueue, 1, "survey appended only the fresh guid")
eq(AL.state.thresholdQueue[1].guid, "guid-M5", "fresh guid appended")
eq(opened[1], "guid-M2", "head-first: oldest queued corpse opens first")
eq(AL.state.thresholdActive, "guid-M2", "chain pinned to the opened corpse")
-- Everything covered (active + skipped + handled + queued): quiet.
C_Loot.GetNearbyLootableUnits = function()
  return { { guid = "guid-M2" }, { guid = "guid-M3" },
    { guid = "guid-M4" }, { guid = "guid-M5" } }
end
eq(AL.SurveyMasterLoot(), false, "survey quiet when nothing new")
AL.state.thresholdActive = nil
ZugLoot.MasterLootUI.corpseCache = {}
-- Non-master survey absence: without the survey API the walk path is
-- untouched (results queue + open as before).
ZugLoot.MasterLootUI.CurrentLootMethod = function() return "group" end
C_Loot.GetNearbyLootableUnits = nil
AL.state.thresholdActive = nil
AL.Shutdown()
AL.state.initialized = true
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = true,
  lootOnStop = true, lootInCombat = true }

-- 10. Threshold chain: above-threshold corpses get their own window.
-- Master loot leaves threshold+ items on the corpse, so a walk that
-- touched a corpse but took nothing leaves no window at all — the
-- chain re-opens each touched guid via C_Loot.LootUnit and walks the
-- queue as corpses finish. Ignored guids never re-open (existing
-- corpse-cache + ignore list answer "already handled").
AL.Shutdown()
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = true,
  lootOnStop = true, lootInCombat = true }
AL.state.initialized = true
ZugLoot.MasterLootUI = nil
ZugLoot.LootWindow = nil
local opened = {}
C_Loot = {
  LootAllCorpses = function() return true end,
  IsScanInProgress = function() return false end,
  -- Real DLL contract (src/loot/Unit.cpp): the call returns NOTHING
  -- (fires LOOT_OPENED async); only a Lua error means failure.
  LootUnit = function(guid) table.insert(opened, guid) end,
  GetLastScanResults = function()
    return { { guid = "guid-A", items = {} }, { guid = "guid-B", items = {} } }
  end,
}
GetTime = function() return 100 end
-- No DLL opener: chain inert, queue drains.
C_Loot.LootUnit = nil
ok(not AL.CanLootUnit(), "no LootUnit: probe false")
eq(AL.OpenNextThreshold(), false, "no LootUnit: nothing opens")
C_Loot.LootUnit = function(guid) table.insert(opened, guid) end
ok(AL.CanLootUnit(), "LootUnit present: probe true")
-- Pure queue collection: dedupe + skip ignored + skip active.
AL.state.thresholdActive = "guid-B"
local q = AL.CollectThresholdQueue(
  { { guid = "guid-A" }, { guid = "guid-A" }, { guid = nil },
    { guid = "guid-B" }, { guid = "" } },
  { ["guid-C"] = true })
eq(#q, 1, "one queued guid after dedupe/skip/active")
eq(q[1].guid, "guid-A", "scan order kept")
AL.state.thresholdActive = nil
-- Walk completion queues touched corpses when the engine area-loots
-- them (LootUnit unavailable there) and opens the first directly
-- (no walk-owned window open).
opened = {}
AL.state.thresholdQueue = {}
AL.state.thresholdSkipped = {}
AL.state.lootWalkActive = true
AL.state.lootWalkSource = "death"
alias = AL.state
AL.CompleteActiveLootWalk()
ok(not alias.lootWalkActive, "threshold walk completed")
eq(#alias.thresholdQueue, 1, "second corpse stays queued")
eq(opened[1], "guid-A", "first touched corpse opened via LootUnit")
eq(alias.thresholdActive, "guid-A", "active guid pinned")
-- Finishing the corpse (no rows left) chains to the next mob.
ZugLoot.LootWindow = { LootingFinished = function() return true end }
AL.OnEvent("LOOT_CLOSED")
eq(opened[2], "guid-B", "next corpse opens after finish")
eq(alias.thresholdActive, "guid-B", "active advances")
-- Walk-away with rows left: keep the corpse, don't advance.
ZugLoot.LootWindow = { LootingFinished = function() return false end }
opened = {}
AL.OnEvent("LOOT_CLOSED")
eq(#opened, 0, "walk-away opens nothing")
eq(alias.thresholdActive, "guid-B", "walk-away keeps the corpse active")
-- Ignoring parks the guid: never re-opens, queue advances past it.
ZugLoot.LootWindow = { LootingFinished = function() return true end }
AL.IgnoreThresholdCorpse("guid-B")
eq(alias.thresholdActive, nil, "ignore clears the active corpse")
eq(alias.thresholdSkipped["guid-B"], true, "ignore parks the guid")
-- Re-scan touching the ignored guid never re-queues it.
local q2 = AL.CollectThresholdQueue({ { guid = "guid-B" } },
  alias.thresholdSkipped)
eq(#q2, 0, "ignored guid never re-queues")
-- Already-handled corpse-cache keys never queue (IsCorpseHandled +
-- live lootKey both read the SAME cache MasterLoot uses to remember
-- rolls: guid: keys for GUID corpses, lootKey for the live corpse).
ok(AL.IsCorpseHandled({ ["guid:g-A"] = {} }, "guid:g-A"),
  "parked cache key reads handled")
ok(not AL.IsCorpseHandled({}, "guid:g-A"), "absent key reads fresh")
ok(not AL.IsCorpseHandled(nil, "guid:g-A"), "nil cache reads fresh")
ZugLoot.MasterLootUI = { lootOpen = true, lootKey = "guid:g-A",
  corpseCache = { ["guid:g-A"] = {} } }
local q3 = AL.CollectThresholdQueue({ { guid = "g-A" } }, {},
  { ["guid:g-A"] = true })
eq(#q3, 0, "cached corpse never re-queues")
-- DLL contract regression: C_Loot.LootUnit returns NOTHING (fires
-- LOOT_OPENED async; src/loot/Unit.cpp). The chain must treat a clean
-- pcall as "request sent", not as a refusal — the old
-- `if callOK and callResult` check parked/skipped every corpse, so
-- stop-then-stand-still opened nothing after the first guid.
ZugLoot.MasterLootUI = nil
ZugLoot.LootWindow = nil
AL.state.thresholdActive = nil
AL.state.thresholdSkipped = {}
AL.state.thresholdQueue = { { guid = "guid-V" } }
C_Loot.LootUnit = function(guid) table.insert(opened, guid) end -- void, like the DLL
opened = {}
eq(AL.OpenNextThreshold(), true, "void LootUnit return still counts as sent")
eq(opened[1], "guid-V", "void-call guid opened")
eq(AL.state.thresholdActive, "guid-V", "void-call guid pinned active")
eq(#AL.state.thresholdQueue, 0, "void-call guid dequeued")
eq(AL.state.thresholdSkipped["guid-V"], nil, "void-call guid never parked")
-- A Lua error (bad arg) keeps the guid queued for the next trigger.
C_Loot.LootUnit = function(guid) error("bad guid") end
AL.state.thresholdActive = nil
AL.state.thresholdQueue = { { guid = "guid-W" } }
eq(AL.OpenNextThreshold(), false, "erroring LootUnit reports failure")
eq(AL.state.thresholdQueue[1].guid, "guid-W", "errored guid stays queued")
eq(AL.state.thresholdSkipped["guid-W"], nil, "errored guid not parked")
eq(AL.state.thresholdActive, nil, "errored guid not pinned")
C_Loot.LootUnit = function(guid) table.insert(opened, guid) end
-- Own chained window is not a manual window (chain keeps driving),
-- a foreign window still blocks.
AL.state.thresholdActive = "guid-X"
ZugLoot.MasterLootUI = { lootOpen = true, lootKey = "guid:guid-X" }
ok(not AL.ManualLootOpen(), "own chained window never blocks")
-- Raw-guid lootKey (older cache shape) also matches.
ZugLoot.MasterLootUI = { lootOpen = true, lootKey = "guid-X" }
ok(not AL.ManualLootOpen(), "own raw-guid key never blocks")
ZugLoot.MasterLootUI = { lootOpen = true, lootKey = "guid-other" }
ok(AL.ManualLootOpen(), "foreign window still blocks")
ZugLoot.MasterLootUI = nil
AL.state.thresholdActive = nil
-- Ignore guards: nil clears nothing; a mismatched pin parks but
-- keeps the active chain; a queued-but-never-opened guid parks +
-- dequeues (walk-away ignored from a manual window).
AL.state.thresholdActive = "guid-K"
AL.state.thresholdQueue = { { guid = "guid-K" } }
AL.state.thresholdSkipped = {}
AL.IgnoreThresholdCorpse(nil)
eq(AL.state.thresholdActive, "guid-K", "nil ignore keeps the active chain")
eq(#AL.state.thresholdQueue, 1, "nil ignore dequeues nothing")
AL.IgnoreThresholdCorpse("guid-other")
eq(AL.state.thresholdActive, "guid-K", "mismatched pin keeps the chain")
ok(AL.state.thresholdSkipped["guid-other"], "mismatched guid still parked")
AL.state.thresholdActive = nil
AL.state.thresholdQueue = { { guid = "guid-Q" } }
AL.IgnoreThresholdCorpse("guid-Q")
eq(#AL.state.thresholdQueue, 0, "queued guid dequeued on ignore")
ok(AL.state.thresholdSkipped["guid-Q"], "queued guid parked")
ZugLoot.MasterLootUI = nil
-- ResetRuntime drops the chain like every other walk field.
AL.state.thresholdQueue = { { guid = "g" } }
AL.state.thresholdSkipped = { g = true }
AL.Shutdown()
eq(#AL.state.thresholdQueue, 0, "shutdown drops the threshold queue")
eq(AL.state.thresholdActive, nil, "shutdown drops the active corpse")
eq(AL.state.thresholdSkipped.g, nil, "shutdown drops the ignore list")

-- 11. Attack snapshot: pin stores melee swing + ranged repeat slots +
-- states; restore re-arms what was running (start-only first), never
-- starts what was off, clears on every exit path.
AL.Shutdown()
ZugLoot.DB.areaLoot = { enabled = true, lootOnDeath = true,
  lootOnStop = true, lootInCombat = true }
AL.state.initialized = true
ZugLoot.MasterLootUI = nil
ZugLoot.LootWindow = nil
local meleeOn, rangedOn = false, false
local startedMelee, startedRanged, usedAction = nil, nil, nil
FocusUnit = function(u) _focusSet = true end
UnitExists = function(u)
  if u == "target" then return _targetExists ~= false end
  if u == "focus" then return _focusSet and true or false end
  return false
end
UnitIsDead = function(u)
  if u == "target" then return _targetDead and true or false end
  return false
end
UnitCanAttack = function() return true end
UnitIsUnit = function() return false end
IsAttackAction = function(s) return s == 12 end
IsAutoRepeatAction = function(s)
  if s == 24 then return rangedOn and true or nil end
  return nil
end
IsCurrentAction = function(s)
  if s == 12 then return meleeOn and true or nil end
  return nil
end
GetActionText = function(s)
  if s == 24 then return "Auto Shot" end
  return nil
end
TargetUnit = function(u) _focusSet = true _targetExists = true _targetDead = false end
ClearTarget = function() _targetExists = false end
StartAttack = function() meleeOn = true startedMelee = true end
CastSpellNoToggle = function(n) rangedOn = true startedRanged = n end
UseAction = function(s)
  usedAction = s
  if s == 12 then meleeOn = true end
  if s == 24 then rangedOn = true end
end
SpellIsTargeting = function() return false end
UnitName = function(u)
  if u == "focus" then return "Mob" end
  return "SoloPlayer"
end
C_Loot = {
  LootAllCorpses = function() return true end,
  IsScanInProgress = function() return false end,
  GetLastScanResults = function() return {} end,
}
GetTime = function() return 100 end
-- Both running, both drop mid-walk: start-only re-arms, plain press
-- never fires (would toggle OFF a live action).
_focusSet, _targetExists, _targetDead = nil, true, false
meleeOn, rangedOn = true, true
startedMelee, startedRanged, usedAction = nil, nil, nil
AL.RequestLoot("death")
eq(AL.attackState and AL.attackState.slot, 12, "melee slot pinned")
eq(AL.attackState and AL.attackState.on, true, "swinging pinned on")
eq(AL.rangedState and AL.rangedState.slot, 24, "ranged slot pinned")
eq(AL.rangedState and AL.rangedState.on, true, "repeating pinned on")
meleeOn, rangedOn, _targetDead = false, false, true -- corpse target now
AL.OnEvent("LOOT_SCAN_COMPLETED")
eq(startedMelee, true, "melee re-armed via StartAttack")
eq(startedRanged, "Auto Shot", "ranged re-armed via CastSpellNoToggle")
eq(usedAction, nil, "no plain press while start-only APIs work")
ok(AL.attackState == nil and AL.rangedState == nil, "snapshot cleared after restore")
-- Survivors need nothing: liveness re-check short-circuits.
_focusSet, _targetExists, _targetDead = nil, true, false
meleeOn, rangedOn = true, true
startedMelee, startedRanged, usedAction = nil, nil, nil
AL.RequestLoot("death")
_targetDead = true
AL.OnEvent("LOOT_SCAN_COMPLETED")
eq(startedMelee, nil, "live swing never re-pressed")
eq(startedRanged, nil, "live repeat never re-pressed")
eq(usedAction, nil, "no press for live actions")
-- OFF stays OFF: nothing is ever started that was not running.
_focusSet, _targetExists, _targetDead = nil, true, false
meleeOn, rangedOn = false, false
AL.RequestLoot("death")
ok(AL.attackState ~= nil, "melee snapshot taken even when off")
eq(AL.attackState.on, false, "melee pinned off")
eq(AL.rangedState, nil, "ranged unslotted/off pins nothing")
_targetDead = true
AL.OnEvent("LOOT_SCAN_COMPLETED")
eq(startedMelee, nil, "stopped swing never started")
eq(usedAction, nil, "off action never pressed")
-- Stock client (no start-only APIs): guarded UseAction re-press.
StartAttack, CastSpellNoToggle = nil, nil
_focusSet, _targetExists, _targetDead = nil, true, false
meleeOn, rangedOn = true, false
IsAutoRepeatAction = function(s) return nil end -- ranged unslotted: skip
AL.RequestLoot("death")
meleeOn, _targetDead = false, true
AL.OnEvent("LOOT_SCAN_COMPLETED")
eq(usedAction, 12, "stock client re-presses the dropped swing")
-- Live target survives: snapshot clears, nothing re-arms.
StartAttack = function() meleeOn = true startedMelee = true end
_focusSet, _targetExists, _targetDead = nil, true, false
meleeOn = true
startedMelee, usedAction = nil, nil
AL.RequestLoot("death")
_targetDead = false -- target still alive
AL.OnEvent("LOOT_SCAN_COMPLETED")
eq(startedMelee, nil, "live target re-arms nothing")
ok(AL.attackState == nil, "snapshot cleared on live-target exit")
-- Focus dead/missing: snapshot clears, corpse still released.
_focusSet, _targetExists, _targetDead = nil, true, false
meleeOn = true
AL.RequestLoot("death")
ok(AL.attackState ~= nil, "snapshot taken before walk")
UnitIsDead = function(u) return true end -- focus dead too
UnitExists = function(u)
  if u == "target" then return true end
  if u == "focus" then return true end
  return false
end
AL.OnEvent("LOOT_SCAN_COMPLETED")
ok(AL.attackState == nil, "snapshot cleared with dead focus")
-- Stale snapshots never leak across walks: a pin that cannot pin
-- (corpse target) clears instead of inheriting.
AL.attackState = { slot = 12, on = true }
AL.rangedState = { slot = 24, on = true }
UnitIsDead = function(u)
  if u == "target" then return true end -- corpse: cannot pin
  return false
end
AL.state.lootWalkActive = false
C_Loot.LootAllCorpses = function() return true end
AL.RequestLoot("death") -- pin refuses the corpse; walk still runs
ok(AL.attackState == nil and AL.rangedState == nil,
  "un pinnable walk clears stale snapshot")
-- Reset drops snapshots like every other walk field.
AL.attackState = { slot = 12, on = true }
AL.rangedState = { slot = 24, on = true }
AL.Shutdown()
ok(AL.attackState == nil and AL.rangedState == nil,
  "shutdown drops attack snapshots")
FocusUnit = nil
UnitExists = nil
UnitIsDead = nil
UnitCanAttack = nil
UnitIsUnit = nil
IsAttackAction = nil
IsAutoRepeatAction = nil
IsCurrentAction = nil
GetActionText = nil
TargetUnit = nil
ClearTarget = nil
StartAttack = nil
CastSpellNoToggle = nil
UseAction = nil
SpellIsTargeting = nil
UnitName = function() return "SoloPlayer" end
_focusSet, _targetExists, _targetDead = nil, nil, nil

C_Loot = nil
GetTime = nil
GetUnitSpeed = nil
ZugLoot.MasterLootUI = nil
ZugLoot.LootWindow = nil
ZugLoot.Timer.CancelAll()

if T.fail == 0 then
  print("area loot passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
