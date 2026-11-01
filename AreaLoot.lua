-- ZugLoot/AreaLoot.lua
-- Event-driven automatic nearby-corpse looting, imported from
-- ../AutoAreaLoot (Foulwerp). Same engine, ZugLoot-homed: settings live
-- in ZugLootDB.areaLoot with their own Setup group ("Area loot"),
-- scheduling runs on ZugLoot.Timer, and looted corpses keep flowing
-- through ZugLoot's own loot window (Core still sees LOOT_OPENED).
-- ClassicAPI DLL required: without C_Loot.LootAllCorpses the whole
-- feature is inert (settings persist, nothing ever scans).
-- Headless-testable: pure gates + injectable state; the client frame
-- (events, movement polling) only builds when CreateFrame exists.
-- Lua 5.0-safe: no #, no %, no goto, numeric loops via Util.ArrayCount.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.AreaLoot = M

-- Tunings (AutoAreaLoot parity — same beats, same bounds).
local LOOT_REQUEST_DELAY = 0.10
local DEATH_LOOT_REQUEST_DELAY = 0.15
local EMPTY_SCAN_RETRY_DELAY = 0.60
local EMPTY_SCAN_MAX_RETRIES = 2
local POST_SCAN_SETTLE_MIN = 0.25
local POST_SCAN_SETTLE_MAX = 1.25
local POST_SCAN_SETTLE_CUSHION = 0.25
local POST_SCAN_SETTLE_MULTIPLIER = 2
local STOP_LOOT_GRACE = 0.10
local STOP_LOOT_GRACE_MOVEMENT_TOLERANCE = 0.20
local MOVEMENT_SPEED_EPSILON = 0.01
local STOP_LOOT_SAME_AREA_INTERVAL = 0.50
local STOP_LOOT_MOVEMENT_DISTANCE = 5
local SPELLCAST_STALE_TIMEOUT = 2.0
local RETICLE_PLACEMENT_GRACE = 0.5
local PLAYER_STATE_SAMPLE_INTERVAL = 0.10
local LOOT_SCAN_TIMEOUT = 6.0
local DEATH_TRIGGER_DISTANCE_LIMIT = 8
local PENDING_LOOT_PRIORITY = { retry = 1, combat = 2, moved = 3, death = 4 }

-- Runtime only (never persisted): mirrors the walk/schedule state of
-- the donor engine. Reset by Shutdown (factory reset calls it).
local function freshState()
  return {
    initialized = false,
    manualLootOpen = false,
    autoLootWindowOpen = false,
    pendingLootReason = nil,
    lootAfterCombat = false,
    lootRequestTimer = nil,
    settleUntil = nil,
    lootWalkActive = false,
    lootWalkStartedAt = nil,
    lootWalkSource = nil,
    emptyScanStreak = 0,
    useSpeedMovement = false,
    movementStateKnown = false,
    playerMoving = false,
    playerStateSampleElapsed = 0,
    playerSpellcastActive = false,
    playerSpellcastStartedAt = nil,
    playerReticleActive = false,
    playerControlLost = false,
    stopGraceTimer = nil,
    lastStopLootRequestAt = nil,
    lastStopPositionX = nil,
    lastStopPositionY = nil,
    lastStopPositionZ = nil,
  }
end
M.state = freshState()
M.debug = false -- M.Debug lines print via Z.Print when true
M._warnedNoAPI = false -- one-time ClassicAPI-missing warning

local function DebugLog(message)
  if M.debug and Z.Print then
    Z.Print("arealoot: " .. tostring(message))
  end
end

local function now()
  if type(GetTime) == "function" then return GetTime() end
  return nil
end

-- ClassicAPI probe (pure, no warning): the DLL gate for everything.
function M.Available()
  return C_Loot ~= nil and type(C_Loot.LootAllCorpses) == "function"
end

-- One-time missing-DLL warning (donor parity: warn, don't spam).
function M.RequireAPI()
  if M.Available() then return true end
  if not M._warnedNoAPI then
    M._warnedNoAPI = true
    if Z.Print then
      Z.Print("Area loot requires the ClassicAPI DLL "
        .. "(C_Loot.LootAllCorpses) — area looting disabled.")
    end
  end
  return false
end

-- Stored config (Z.DB.areaLoot). Nil-safe: the DB may predate the
-- feature (InitDB backfills); headless falls back to module state.
function M.Config()
  if Z.DB then
    if type(Z.DB.areaLoot) ~= "table" then Z.DB.areaLoot = {} end
    local c = Z.DB.areaLoot
    if c.enabled == nil then c.enabled = false end
    if c.lootOnDeath == nil then c.lootOnDeath = true end
    if c.lootOnStop == nil then c.lootOnStop = true end
    if c.lootInCombat == nil then c.lootInCombat = true end
    return c
  end
  M._fallback = M._fallback or
    { enabled = false, lootOnDeath = true, lootOnStop = true,
      lootInCombat = true }
  return M._fallback
end

function M.IsOn() return M.Config().enabled and true or false end
function M.DeathOn() return M.Config().lootOnDeath and true or false end
function M.StopOn() return M.Config().lootOnStop and true or false end
function M.CombatOn() return M.Config().lootInCombat and true or false end

-- Master switch + per-trigger toggles. Only writers of their flags.
-- Switching OFF tears down runtime state (donor SetEnabled parity:
-- a disabled engine holds no walk, no timers, no pending reason).
function M.SetEnabled(on)
  M.Config().enabled = on and true or false
  if not M.Config().enabled then M.ResetRuntime() end
  return M.IsOn()
end
function M.SetDeath(on)
  M.Config().lootOnDeath = on and true or false
  return M.DeathOn()
end
function M.SetStop(on)
  M.Config().lootOnStop = on and true or false
  return M.StopOn()
end
function M.SetCombat(on)
  M.Config().lootInCombat = on and true or false
  return M.CombatOn()
end

-- Setup info line: API readiness + master state in one glance.
function M.StatusText()
  if not M.Available() then
    return "ClassicAPI missing — area looting disabled"
  end
  if M.IsOn() then return "ClassicAPI: ready — Area loot: ON" end
  return "ClassicAPI: ready — Area loot: OFF"
end

-- Clear runtime (walk, timers, pending, transient flags). Config kept.
-- Factory reset + master-off both funnel through here. Headless-safe:
-- CloseLoot only fires when the client provides it.
function M.ResetRuntime()
  local st = M.state
  st.manualLootOpen = false
  st.autoLootWindowOpen = false
  st.pendingLootReason = nil
  st.lootAfterCombat = false
  st.lootRequestTimer = nil
  st.settleUntil = nil
  st.lootWalkActive = false
  st.lootWalkStartedAt = nil
  st.lootWalkSource = nil
  st.emptyScanStreak = 0
  st.stopGraceTimer = nil
  st.lastStopLootRequestAt = nil
  st.lastStopPositionX = nil
  st.lastStopPositionY = nil
  st.lastStopPositionZ = nil
  st.playerMoving = false
  st.movementStateKnown = false
  st.playerStateSampleElapsed = 0
  st.playerSpellcastActive = false
  st.playerSpellcastStartedAt = nil
  st.playerReticleActive = false
  st.playerControlLost = false
  if type(CloseLoot) == "function" then pcall(CloseLoot) end
end

function M.Shutdown()
  M.ResetRuntime()
end

-- -- Trigger inputs -------------------------------------------------------
-- Event availability probe (Nampower/ClassicAPI extended events): same
-- shape as the donor (C_EventUtils may not exist at all).
local function IsEventAvailable(eventName)
  return C_EventUtils
    and type(C_EventUtils.IsEventValid) == "function"
    and C_EventUtils.IsEventValid(eventName)
end

local function IsPlayerInCombat()
  return type(UnitAffectingCombat) == "function"
    and UnitAffectingCombat("player") or false
end

local function IsBattleLooting()
  return IsPlayerInCombat() and M.CombatOn()
end

local function IsPlayerChanneling()
  if type(UnitChannelInfo) == "function" then
    local ok, channelName = pcall(UnitChannelInfo, "player")
    if ok and channelName ~= nil then return true end
  end
  if C_Spell and type(C_Spell.UnitChannelInfo) == "function" then
    local ok, channelName = pcall(C_Spell.UnitChannelInfo, "player")
    if ok and channelName ~= nil then return true end
  end
  if C_Spell and type(C_Spell.ChannelInfo) == "function" then
    local ok, channelName = pcall(C_Spell.ChannelInfo)
    if ok and channelName ~= nil then return true end
  end
  return false
end

local function IsPlayerCasting()
  if type(UnitCastingInfo) == "function" then
    local ok, castName = pcall(UnitCastingInfo, "player")
    if ok and castName ~= nil then return true end
  end
  if C_Spell and type(C_Spell.UnitCastingInfo) == "function" then
    local ok, castName = pcall(C_Spell.UnitCastingInfo, "player")
    if ok and castName ~= nil then return true end
  end
  if C_Spell and type(C_Spell.CastingInfo) == "function" then
    local ok, castName = pcall(C_Spell.CastingInfo)
    if ok and castName ~= nil then return true end
  end
  return false
end

local function IsPlayerDeadOrGhost()
  if type(UnitIsDeadOrGhost) ~= "function" then return false end
  local ok, deadOrGhost = pcall(UnitIsDeadOrGhost, "player")
  return ok and deadOrGhost and true or false
end

local function SafeUnitExists(unit)
  if type(UnitExists) ~= "function" then return false end
  local ok, exists = pcall(UnitExists, unit)
  return ok and exists and true or false
end

local function SafeUnitIsDead(unit)
  if type(UnitIsDead) ~= "function" then return false end
  local ok, dead = pcall(UnitIsDead, unit)
  return ok and dead and true or false
end

local function SafeUnitName(unit)
  if type(UnitName) ~= "function" then return nil end
  local ok, name = pcall(UnitName, unit)
  if not ok or type(name) ~= "string" or name == "" then return nil end
  return name
end

local function SafeUnitIsUnit(a, b)
  if type(UnitIsUnit) ~= "function" then return false end
  local ok, same = pcall(UnitIsUnit, a, b)
  return ok and same and true or false
end

-- Pin the live target as focus before the walk, so the post-walk
-- restore has something to return to even with no manual /focus.
-- Never pins a corpse; only pins what the player can attack.
local function PinLiveTargetAsFocus()
  if type(FocusUnit) ~= "function" then return end
  if not SafeUnitExists("target") or SafeUnitIsDead("target") then return end
  if SafeUnitIsUnit("target", "focus") then return end
  if type(UnitCanAttack) == "function" then
    local ok, attackable = pcall(UnitCanAttack, "player", "target")
    if not ok or not attackable then return end
  end
  pcall(FocusUnit, "target")
  local name = SafeUnitName("focus")
  DebugLog("Pinned live target as focus before loot walk"
    .. (name and (": " .. name) or ""))
end

local function RestoreFocusTargetAfterWalk()
  -- Never steal a live target the player chose (or that survived).
  if SafeUnitExists("target") and not SafeUnitIsDead("target") then
    return
  end
  -- Only the focus enemy is worth retargeting; anything else is a guess.
  if not SafeUnitExists("focus") or SafeUnitIsDead("focus") then
    if type(ClearTarget) == "function" and SafeUnitIsDead("target") then
      pcall(ClearTarget)
      DebugLog("Corpse target cleared after loot walk")
    end
    return
  end
  -- Same primitive as the TARGETFOCUS keybind.
  if type(TargetUnit) == "function" then
    pcall(TargetUnit, "focus")
    if SafeUnitExists("target") and not SafeUnitIsDead("target") then
      local name = SafeUnitName("focus")
      DebugLog("Focus target restored after loot walk"
        .. (name and (": " .. name) or ""))
    else
      DebugLog("Focus target restore failed; leaving target as-is")
    end
  end
end

local function GetUnitWorldPosition(unit)
  if type(UnitPosition) ~= "function" then return nil end
  local ok, first, second, third = pcall(UnitPosition, unit)
  if not ok then return nil end
  local x = tonumber(first)
  local y = tonumber(second)
  local z = tonumber(third) or 0
  if not x or not y then return nil end
  -- ClassicAPI and SuperWoW differ in axis labels, but Euclidean
  -- distance is unchanged when the first two world axes are swapped.
  return x, y, z
end

local function GetPlayerWorldPosition()
  return GetUnitWorldPosition("player")
end

local function GetUnitDistanceFromPlayer(unit)
  if type(UnitDistanceSquared) == "function" then
    local ok, distanceSquared, checked = pcall(UnitDistanceSquared, unit)
    distanceSquared = tonumber(distanceSquared)
    if ok and checked and distanceSquared and distanceSquared >= 0 then
      return math.sqrt(distanceSquared)
    end
  end
  local unitX, unitY, unitZ = GetUnitWorldPosition(unit)
  local playerX, playerY, playerZ = GetPlayerWorldPosition()
  if not unitX or not playerX then return nil end
  local dx = unitX - playerX
  local dy = unitY - playerY
  local dz = unitZ - playerZ
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function ShouldAcceptDeathTrigger(guid)
  if type(guid) ~= "string" then return true, nil end
  local distance = GetUnitDistanceFromPlayer(guid)
  if not distance then return true, nil end
  return distance <= DEATH_TRIGGER_DISTANCE_LIMIT, distance
end

-- A ZugLoot-handled corpse window counts as a manual window: the walk
-- must never fire into a corpse the player is already working.
function M.ManualLootOpen()
  if M.state.manualLootOpen then return true end
  if M.state.lootWalkActive then return false end
  return Z.MasterLootUI and Z.MasterLootUI.lootOpen and true or false
end

local function GetPlayerLootRestriction()
  if M.state.playerControlLost then return "player control is lost" end
  if IsPlayerDeadOrGhost() then return "player is dead or a ghost" end
  if M.state.playerReticleActive then
    return "player targeting reticle is open"
  end
  if M.state.playerSpellcastActive then
    return "player spellcast is active"
  end
  if IsPlayerChanneling() then return "player is channeling" end
  if IsPlayerCasting() then return "player is casting" end
  return nil
end

local function GetPlayerSpeedMovementState()
  if type(GetUnitSpeed) ~= "function" then return nil end
  local ok, speed = pcall(GetUnitSpeed, "player")
  speed = tonumber(speed)
  if not ok or not speed then return nil end
  return speed > MOVEMENT_SPEED_EPSILON
end

local function IsPlayerCurrentlyMoving()
  local moving = GetPlayerSpeedMovementState()
  if moving ~= nil then return moving end
  return M.state.playerMoving and true or false
end

local function IsLootScanInProgress()
  if not C_Loot or type(C_Loot.IsScanInProgress) ~= "function" then
    return false
  end
  local ok, inProgress = pcall(C_Loot.IsScanInProgress)
  return ok and inProgress and true or false
end

-- -- Scheduling (ZugLoot.Timer; the 1.12 client has no C_Timer) ----------
local function NormalizePendingLootReason(source)
  local reason = source
  if reason ~= "death" and reason ~= "moved" and reason ~= "combat" then
    reason = "retry"
  end
  return reason
end

local function QueuePendingLootRequest(source)
  local reason = NormalizePendingLootReason(source)
  local currentPriority = PENDING_LOOT_PRIORITY[M.state.pendingLootReason] or 0
  if PENDING_LOOT_PRIORITY[reason] > currentPriority then
    M.state.pendingLootReason = reason
  end
end

local function GetLootSettleDelay()
  local untilT = M.state.settleUntil
  local t = now()
  if not untilT or not t then return 0 end
  local remaining = untilT - t
  if remaining <= 0 then
    M.state.settleUntil = nil
    return 0
  end
  return remaining
end

local function GetAdaptiveLootSettleDuration()
  local latency
  if type(GetNetStats) == "function" then
    local ok, _bandwidthIn, _bandwidthOut, thirdLatency, fourthLatency =
      pcall(GetNetStats)
    if ok then
      -- Vanilla reports latency as the third value. Clients exposing the
      -- newer home/world pair use the fourth value for world latency.
      latency = tonumber(fourthLatency) or tonumber(thirdLatency)
    end
  end
  local duration = POST_SCAN_SETTLE_MIN
  if latency and latency >= 0 then
    duration = POST_SCAN_SETTLE_CUSHION
      + (latency / 1000) * POST_SCAN_SETTLE_MULTIPLIER
  end
  if duration < POST_SCAN_SETTLE_MIN then duration = POST_SCAN_SETTLE_MIN end
  if duration > POST_SCAN_SETTLE_MAX then duration = POST_SCAN_SETTLE_MAX end
  return duration, latency
end

local function After(sec, fn)
  if Z.Timer and Z.Timer.After then return Z.Timer.After(sec, fn) end
  if fn then fn() end -- no scheduler (lean headless): run inline
  return nil
end

-- -- Walk completion ------------------------------------------------------
function M.CompleteActiveLootWalk()
  local st = M.state
  if not st.lootWalkActive then
    DebugLog("Completion ignored: no local corpse walk is active")
    return false
  end
  local walkSource = st.lootWalkSource
  local completedAt = now()
  local scanDuration
  if completedAt and st.lootWalkStartedAt then
    scanDuration = math.max(0, completedAt - st.lootWalkStartedAt)
  end
  st.lootWalkActive = false
  st.lootWalkStartedAt = nil
  st.lootWalkSource = nil
  DebugLog("Completing local corpse walk")
  local results = {}
  if C_Loot and type(C_Loot.GetLastScanResults) == "function" then
    local resultsOK, returnedResults = pcall(C_Loot.GetLastScanResults)
    if resultsOK and type(returnedResults) == "table" then
      results = returnedResults
      DebugLog("GetLastScanResults returned "
        .. Z.Util.ArrayCount(results) .. " corpse result(s)")
    else
      DebugLog("GetLastScanResults failed or returned no table: "
        .. tostring(returnedResults))
    end
  else
    DebugLog("GetLastScanResults is unavailable")
  end
  if Z.Util.ArrayCount(results) > 0 and type(GetTime) == "function" then
    local settleDuration, latency = GetAdaptiveLootSettleDuration()
    st.settleUntil = GetTime() + settleDuration
    DebugLog("Non-empty scan: latency=" .. tostring(latency or "unknown")
      .. " scanTime=" .. string.format("%.3f", scanDuration or 0)
      .. "s settling=" .. string.format("%.3f", settleDuration)
      .. " seconds")
    if st.pendingLootReason == "retry" then
      st.pendingLootReason = nil
      DebugLog("Discarded redundant stop/combat follow-up after successful scan")
    end
    st.emptyScanStreak = 0
  else
    -- Empty scan after a real trigger: the corpses were probably not
    -- loot-flagged yet (or the player edged out of range). One short
    -- follow-up catches them; the streak bound keeps chained triggers
    -- from rescanning forever.
    local isTriggerSource = walkSource == "death"
      or walkSource == "moved"
      or walkSource == "combat"
      or walkSource == "stop"
    if isTriggerSource
        and st.emptyScanStreak < EMPTY_SCAN_MAX_RETRIES then
      st.emptyScanStreak = st.emptyScanStreak + 1
      QueuePendingLootRequest(walkSource)
      DebugLog("Empty scan after " .. tostring(walkSource)
        .. ": scheduling follow-up "
        .. st.emptyScanStreak .. "/" .. EMPTY_SCAN_MAX_RETRIES)
      M.ScheduleLootRequest(EMPTY_SCAN_RETRY_DELAY, walkSource)
    else
      st.emptyScanStreak = 0
      if isTriggerSource then
        DebugLog("Empty scan follow-ups exhausted; waiting for next trigger")
      end
    end
  end
  if st.autoLootWindowOpen then
    -- The walk ended with a window still open: release it now that the
    -- engine is done, so the character is never left in the loot pose.
    st.autoLootWindowOpen = false
    DebugLog("Loot window still open after walk; releasing it")
    if type(CloseLoot) == "function" then
      pcall(CloseLoot)
    end
  end
  RestoreFocusTargetAfterWalk()
  return true
end

-- -- Core request path ----------------------------------------------------
function M.RequestLoot(source)
  source = source or "retry"
  local st = M.state
  DebugLog("Loot request entered: source=" .. source .. " enabled="
    .. tostring(M.IsOn()) .. " manual=" .. tostring(M.ManualLootOpen())
    .. " localWalk=" .. tostring(st.lootWalkActive)
    .. " apiScan=" .. tostring(IsLootScanInProgress())
    .. " combat=" .. tostring(IsPlayerInCombat()))
  if not st.initialized then
    DebugLog("Loot request stopped: addon not initialized")
    return false
  end
  if not M.IsOn() then
    DebugLog("Loot request stopped: area loot disabled")
    return false
  end
  if not M.RequireAPI() then
    DebugLog("Loot request stopped: ClassicAPI loot API unavailable")
    return false
  end
  if st.stopGraceTimer then
    QueuePendingLootRequest(source)
    DebugLog("Loot request deferred: waiting for stable-stop grace; source="
      .. source)
    return false
  end
  -- Battle looting: while in combat with the option on, scans run even
  -- on the move; the cast, channel, reticle, manual-window, and
  -- one-scan-at-a-time gates below still hold — only the movement
  -- deferral is lifted here.
  if not IsBattleLooting() and IsPlayerCurrentlyMoving() then
    QueuePendingLootRequest(source)
    DebugLog("Loot request deferred: player is moving; source=" .. source)
    return false
  end
  local restriction = GetPlayerLootRestriction()
  if restriction then
    QueuePendingLootRequest(source)
    DebugLog("Loot request deferred: " .. restriction .. "; source="
      .. source)
    return false
  end
  if source == "stop" and st.lootRequestTimer then
    DebugLog("Stop request coalesced into pending scheduled request")
    return false
  end
  if IsPlayerInCombat() and not M.CombatOn() then
    QueuePendingLootRequest(source)
    DebugLog("Loot request deferred: combat looting disabled")
    return false
  end
  if M.ManualLootOpen() then
    QueuePendingLootRequest(source)
    DebugLog("Loot request deferred: manual loot window is open")
    return false
  end
  if st.lootWalkActive then
    if IsLootScanInProgress() then
      QueuePendingLootRequest(source)
      DebugLog("Loot request deferred: our walk is still active; source="
        .. source)
      return false
    end
    -- Recover if a later trigger notices that the completion event was
    -- missed after ClassicAPI already returned to idle.
    DebugLog("Recovering local walk after ClassicAPI returned idle")
    M.CompleteActiveLootWalk()
    if st.pendingLootReason then
      local pendingReason = st.pendingLootReason
      st.pendingLootReason = nil
      DebugLog("Recovered completion: preserving queued request; source="
        .. pendingReason)
      M.ScheduleLootRequest(
        pendingReason == "death" and DEATH_LOOT_REQUEST_DELAY or nil,
        pendingReason)
      return false
    end
  end
  if IsLootScanInProgress() then
    QueuePendingLootRequest(source)
    DebugLog("Loot request deferred: another scan is active")
    return false
  end
  local settleDelay = GetLootSettleDelay()
  if settleDelay > 0 then
    local sourceReason = NormalizePendingLootReason(source)
    if sourceReason == "retry" then
      if st.pendingLootReason then
        local pendingReason = st.pendingLootReason
        st.pendingLootReason = nil
        DebugLog("Successful scan is settling; scheduling queued request; source="
          .. pendingReason)
        M.ScheduleLootRequest(settleDelay, pendingReason)
        return false
      end
      DebugLog("Loot request coalesced: successful scan is still settling; source="
        .. source)
      return false
    end
    QueuePendingLootRequest(source)
    DebugLog("Loot request deferred: waiting "
      .. string.format("%.3f", settleDelay)
      .. " seconds for corpse state to settle")
    M.ScheduleLootRequest(settleDelay, source)
    return false
  end
  st.pendingLootReason = nil
  PinLiveTargetAsFocus()
  st.lootWalkActive = true
  st.lootWalkStartedAt = now()
  st.lootWalkSource = source
  DebugLog("Calling C_Loot.LootAllCorpses")
  local callOK, callResult = pcall(C_Loot.LootAllCorpses)
  local started = callOK and callResult and true or false
  DebugLog("LootAllCorpses returned: callOK=" .. tostring(callOK)
    .. " result=" .. tostring(callResult)
    .. " apiScan=" .. tostring(IsLootScanInProgress()))
  if not started then
    st.lootWalkSource = nil
    st.lootWalkActive = false
    st.lootWalkStartedAt = nil
    if IsLootScanInProgress() then
      QueuePendingLootRequest(source)
      DebugLog("Failed call left API scan active; queued one follow-up")
    end
  end
  return started
end

function M.ScheduleLootRequest(delay, source)
  source = source or "retry"
  local st = M.state
  if not st.initialized then
    DebugLog("Schedule skipped: addon not initialized")
    return
  end
  if not M.IsOn() then
    DebugLog("Schedule skipped: area loot disabled")
    return
  end
  if not IsBattleLooting() and IsPlayerCurrentlyMoving() then
    QueuePendingLootRequest(source)
    DebugLog("Schedule deferred while player is moving; source=" .. source)
    return
  end
  local restriction = GetPlayerLootRestriction()
  if restriction then
    QueuePendingLootRequest(source)
    DebugLog("Schedule deferred while " .. restriction .. "; source=" .. source)
    return
  end
  local settleDelay = GetLootSettleDelay()
  local sourceReason = NormalizePendingLootReason(source)
  if settleDelay > 0 and sourceReason == "retry" then
    DebugLog("Schedule coalesced: successful scan is settling; source="
      .. source)
    return
  end
  if st.lootRequestTimer then
    local timerReason = NormalizePendingLootReason(st.lootRequestTimer.source)
    if PENDING_LOOT_PRIORITY[sourceReason] > PENDING_LOOT_PRIORITY[timerReason] then
      DebugLog("Scheduled request upgraded: " .. timerReason
        .. " -> " .. sourceReason)
      if st.lootRequestTimer.handle then
        st.lootRequestTimer.handle.dead = true
      end
      st.lootRequestTimer = nil
    else
      DebugLog("Schedule coalesced: request timer already pending; source="
        .. st.lootRequestTimer.source)
      return
    end
  end
  if not M.RequireAPI() then
    DebugLog("Schedule skipped: ClassicAPI loot API unavailable")
    return
  end
  local requestedDelay = math.max(0, tonumber(delay) or LOOT_REQUEST_DELAY)
  local effectiveDelay = math.max(requestedDelay, settleDelay)
  -- One timer per burst; invalidated handles cannot service a later request.
  local token = { source = source, handle = nil }
  st.lootRequestTimer = token
  DebugLog("Loot request scheduled in "
    .. string.format("%.3f", effectiveDelay) .. " seconds; source=" .. source)
  token.handle = After(effectiveDelay, function()
    if st.lootRequestTimer ~= token then
      DebugLog("Scheduled request discarded: timer token invalidated")
      return
    end
    st.lootRequestTimer = nil
    DebugLog("Scheduled loot request fired; source=" .. token.source)
    M.RequestLoot(token.source)
  end)
end

local function ScheduleStableStopLoot(source)
  source = source or "stop"
  local st = M.state
  local startX, startY, startZ = GetPlayerWorldPosition()
  local token = { source = source, startX = startX, startY = startY,
    startZ = startZ, handle = nil }
  st.stopGraceTimer = token
  DebugLog("Waiting " .. string.format("%.3f", STOP_LOOT_GRACE)
    .. " seconds for a stable stop; source=" .. source)
  token.handle = After(STOP_LOOT_GRACE, function()
    if st.stopGraceTimer ~= token then
      DebugLog("Stable-stop request discarded: token invalidated")
      return
    end
    st.stopGraceTimer = nil
    local stopBattleLooting = IsBattleLooting()
    if not stopBattleLooting and IsPlayerCurrentlyMoving() then
      QueuePendingLootRequest(token.source)
      DebugLog("Stable-stop request deferred: movement-start event received")
      return
    end
    local currentX, currentY, currentZ = GetPlayerWorldPosition()
    if token.startX and currentX then
      local dx = currentX - token.startX
      local dy = currentY - token.startY
      local dz = currentZ - token.startZ
      local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
      if moved > STOP_LOOT_GRACE_MOVEMENT_TOLERANCE then
        st.playerMoving = true
        QueuePendingLootRequest(token.source)
        DebugLog("Stable-stop request deferred: moved "
          .. string.format("%.2f", moved)
          .. " yards during grace")
        return
      end
    end
    local effectiveSource = token.source
    local pendingReason = st.pendingLootReason
    local effectiveReason = NormalizePendingLootReason(effectiveSource)
    if pendingReason and PENDING_LOOT_PRIORITY[pendingReason]
        > PENDING_LOOT_PRIORITY[effectiveReason] then
      effectiveSource = pendingReason
    end
    DebugLog("Stable stop confirmed; servicing source=" .. effectiveSource)
    M.RequestLoot(effectiveSource)
  end)
end

function M.ServicePendingLootRequest()
  local st = M.state
  if not st.pendingLootReason then
    DebugLog("No queued loot request to service")
    return
  end
  if not IsBattleLooting() and IsPlayerCurrentlyMoving() then
    DebugLog("Queued loot request retained while player is moving; source="
      .. st.pendingLootReason)
    return
  end
  local restriction = GetPlayerLootRestriction()
  if restriction then
    DebugLog("Queued loot request retained while " .. restriction .. "; source="
      .. st.pendingLootReason)
    return
  end
  if st.stopGraceTimer then
    DebugLog("Queued loot request retained during stable-stop grace; source="
      .. st.pendingLootReason)
    return
  end
  if st.lootWalkActive then
    if IsLootScanInProgress() then
      DebugLog("Queued loot request retained behind active scan; source="
        .. st.pendingLootReason)
      return
    end
    -- Recover if the scan completed but its completion event was missed.
    DebugLog("Recovering queued request after ClassicAPI returned idle")
    M.CompleteActiveLootWalk()
  end
  if IsLootScanInProgress() then
    DebugLog("Queued loot request retained behind active scan; source="
      .. st.pendingLootReason)
    return
  end
  local source = st.pendingLootReason
  st.pendingLootReason = nil
  DebugLog("Servicing queued loot request; source=" .. source)
  M.ScheduleLootRequest(
    source == "death" and DEATH_LOOT_REQUEST_DELAY or nil, source)
end

local function RecoverTimedOutLootWalk()
  local st = M.state
  if not st.lootWalkActive or not st.lootWalkStartedAt
      or type(GetTime) ~= "function" then
    return
  end
  local elapsed = GetTime() - st.lootWalkStartedAt
  if elapsed < LOOT_SCAN_TIMEOUT then return end
  if IsLootScanInProgress() then
    DebugLog("Loot walk exceeded timeout but ClassicAPI still reports it active")
    return
  end
  DebugLog("Recovering loot walk after "
    .. string.format("%.3f", elapsed)
    .. " seconds without a completion event")
  M.CompleteActiveLootWalk()
  M.ServicePendingLootRequest()
end

-- -- Trigger entries ------------------------------------------------------
-- NPC death: the fastest pass (corpses loot-flag a beat after UNIT_DIED).
function M.OnDeath(guid)
  if not M.DeathOn() then
    DebugLog("Death trigger ignored: setting disabled")
    return
  end
  local accepted, distance = ShouldAcceptDeathTrigger(guid)
  if not accepted then
    DebugLog("Death trigger ignored: guid too far ("
      .. (distance and string.format("%.2f", distance) or "unknown")
      .. " yards)")
    return
  end
  DebugLog("Death trigger accepted")
  if IsPlayerInCombat() then
    M.state.lootAfterCombat = true
    DebugLog("Death trigger marked a post-combat pass")
  end
  if M.state.stopGraceTimer or M.state.lootWalkActive
      or IsLootScanInProgress() then
    QueuePendingLootRequest("death")
    DebugLog("Death trigger queued behind active scan or stop grace")
  elseif M.state.lootRequestTimer then
    -- A newer, higher-value trigger pre-empts a stale scheduled pass
    -- instead of stacking behind it.
    local timerReason = NormalizePendingLootReason(
      M.state.lootRequestTimer.source)
    if PENDING_LOOT_PRIORITY["death"] > PENDING_LOOT_PRIORITY[timerReason] then
      M.state.lootRequestTimer = nil
      DebugLog("Death trigger pre-empted scheduled "
        .. timerReason .. "; scheduling sooner")
      M.ScheduleLootRequest(DEATH_LOOT_REQUEST_DELAY, "death")
    else
      DebugLog("Death trigger kept the pending scheduled request")
    end
  else
    M.ScheduleLootRequest(DEATH_LOOT_REQUEST_DELAY, "death")
  end
end

local function GetDistanceFromLastStop(x, y, z)
  local st = M.state
  if not x or not st.lastStopPositionX then return nil end
  local dx = x - st.lastStopPositionX
  local dy = y - st.lastStopPositionY
  local dz = z - st.lastStopPositionZ
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function HandlePlayerMovementStarted(source)
  local st = M.state
  st.playerMoving = true
  st.movementStateKnown = true
  if st.stopGraceTimer then
    -- In combat with battle looting on, the grace timer no longer
    -- refuses while moving, so let it ride instead of cancelling it.
    if IsBattleLooting() then
      DebugLog("Movement resumed: keeping stable-stop grace for battle looting; source="
        .. source)
    else
      QueuePendingLootRequest(st.stopGraceTimer.source)
      st.stopGraceTimer = nil
      DebugLog("Movement resumed: cancelled stable-stop grace; source="
        .. source)
    end
  else
    DebugLog("Movement started; source=" .. source)
  end
end

local function HandlePlayerMovementStopped(source)
  local st = M.state
  st.playerMoving = false
  st.movementStateKnown = true
  if M.StopOn() then
    DebugLog("Stop trigger accepted; source=" .. source)
    local t = now()
    local x, y, z = GetPlayerWorldPosition()
    local moved = GetDistanceFromLastStop(x, y, z)
    local elapsed = t and st.lastStopLootRequestAt
      and t - st.lastStopLootRequestAt or nil
    local withinSameArea = not moved
      or moved < STOP_LOOT_MOVEMENT_DISTANCE
    local withinCooldown = elapsed
      and elapsed < STOP_LOOT_SAME_AREA_INTERVAL
    local coalesced = withinSameArea and withinCooldown
    if coalesced then
      DebugLog("Stop trigger coalesced: elapsed="
        .. (elapsed and string.format("%.3f", elapsed) or "unknown")
        .. " moved=" .. (moved and string.format("%.2f", moved)
          or "unknown") .. " yards")
      if st.pendingLootReason then
        ScheduleStableStopLoot(st.pendingLootReason)
      end
      return
    end
    st.lastStopLootRequestAt = t
    if x then
      st.lastStopPositionX = x
      st.lastStopPositionY = y
      st.lastStopPositionZ = z
    end
    if moved then
      DebugLog("Stop trigger position accepted: moved="
        .. string.format("%.2f", moved) .. " yards")
    end
    if IsPlayerInCombat() then
      st.lootAfterCombat = true
      DebugLog("Stop trigger marked a post-combat pass")
    end
    local stopSource = moved
      and moved >= STOP_LOOT_MOVEMENT_DISTANCE and "moved" or "stop"
    ScheduleStableStopLoot(stopSource)
  else
    DebugLog("Stop trigger ignored: setting disabled")
    if st.pendingLootReason then
      ScheduleStableStopLoot(st.pendingLootReason)
    end
  end
end

-- Movement poll: speed sampling (donor parity — RMB strafing, jumping
-- and other displacement never depend on forward/back move events).
-- Headless tests drive this directly (frame OnUpdate calls it live).
function M.Poll(dt)
  local st = M.state
  if not st.initialized then return end
  st.playerStateSampleElapsed = st.playerStateSampleElapsed + (dt or 0)
  if st.playerStateSampleElapsed >= PLAYER_STATE_SAMPLE_INTERVAL then
    st.playerStateSampleElapsed = 0
    RecoverTimedOutLootWalk()
    -- Reconcile the event-driven cast flag with live cast state so a
    -- missed end event can never suppress looting forever. The flag is
    -- only cleared once no cast has been visible for the stale timeout.
    if st.playerSpellcastActive and not st.playerReticleActive
        and type(GetTime) == "function"
        and st.playerSpellcastStartedAt then
      if GetTime() - st.playerSpellcastStartedAt
          >= SPELLCAST_STALE_TIMEOUT
          and not IsPlayerCasting() and not IsPlayerChanneling() then
        st.playerSpellcastActive = false
        st.playerSpellcastStartedAt = nil
        DebugLog("Stale spellcast flag cleared; servicing deferred loot")
        M.ServicePendingLootRequest()
      end
    end
  end
  if not st.useSpeedMovement then return end
  local moving = GetPlayerSpeedMovementState()
  if moving == nil then return end
  if not st.movementStateKnown then
    st.playerMoving = moving
    st.movementStateKnown = true
    DebugLog("Speed movement baseline: moving=" .. tostring(moving))
    return
  end
  if moving == st.playerMoving then return end
  if moving then
    HandlePlayerMovementStarted("speed")
  else
    HandlePlayerMovementStopped("speed")
  end
end

-- Spellcast / reticle / control inputs (donor parity: cast intent blocks,
-- end events re-service; RETICLE_CLEAR right after a cast-start still
-- counts as placement, keeping the block).
function M.SpellcastStarted()
  local st = M.state
  st.playerSpellcastActive = true
  local t = now()
  if t then st.playerSpellcastStartedAt = t end
  DebugLog("Player spellcast started; automatic loot blocked")
end
function M.SpellcastReticleTarget()
  M.state.playerReticleActive = true
  M.SpellcastStarted()
  -- Placing the reticle starts the cast, which implies the reticle
  -- closed; don't let a missed RETICLE_CLEAR stick.
  M.state.playerReticleActive = false
end
function M.SpellcastEnded(reticleClear)
  local st = M.state
  if reticleClear then st.playerReticleActive = false end
  -- End events can fire for a queued/rejected cast while the real cast
  -- is still running, so only drop the block when nothing is actually
  -- casting anymore. RETICLE_CLEAR is additionally ambiguous (cancel
  -- vs. placed-and-casting), so a clear right after a cast-start event
  -- keeps the block.
  local stillCasting = IsPlayerCasting() or IsPlayerChanneling()
  local placedReticle = false
  local t = now()
  if reticleClear and t and st.playerSpellcastStartedAt then
    placedReticle = t - st.playerSpellcastStartedAt
      < RETICLE_PLACEMENT_GRACE
  end
  if not stillCasting and not placedReticle then
    st.playerSpellcastActive = false
    st.playerSpellcastStartedAt = nil
    DebugLog("Player spellcast ended; servicing deferred loot")
  else
    DebugLog("Spellcast end event ignored; cast still in progress")
  end
  M.ServicePendingLootRequest()
end

-- -- Client frame + event routing -----------------------------------------
M.frame = nil

function M.OnEvent(event, a1)
  local st = M.state
  if event == "LOOT_OPENED" then
    if st.lootWalkActive then
      -- Walk-owned window: the engine opens, loots and releases each
      -- corpse itself — never touch it (closing one races the engine
      -- and can stall the walk). ZugLoot's own window still lists it.
      st.autoLootWindowOpen = true
      DebugLog("Loot window opened during automatic walk; leaving it for the engine")
    else
      st.manualLootOpen = true
      DebugLog("Manual loot window marked open")
    end
    return
  end
  if event == "LOOT_CLOSED" then
    st.manualLootOpen = false
    st.autoLootWindowOpen = false
    DebugLog("Loot window marked closed")
    M.ServicePendingLootRequest()
    return
  end
  if event == "PLAYER_LEAVING_WORLD" then
    DebugLog("Leaving world: clearing transient loot state")
    M.ResetRuntime()
    return
  end
  if event == "PLAYER_ENTERING_WORLD" then
    st.playerMoving = false
    st.movementStateKnown = false
    st.playerStateSampleElapsed = 0
    st.playerSpellcastActive = false
    st.playerSpellcastStartedAt = nil
    st.playerReticleActive = false
    st.playerControlLost = false
    st.stopGraceTimer = nil
    st.lastStopLootRequestAt = nil
    st.lastStopPositionX = nil
    st.lastStopPositionY = nil
    st.lastStopPositionZ = nil
    DebugLog("Entered world: transient loot state cleared")
    return
  end
  if event == "PLAYER_REGEN_ENABLED" then
    if st.lootAfterCombat or st.pendingLootReason then
      DebugLog("Combat ended: preserving one deferred loot request")
      if st.lootAfterCombat then
        QueuePendingLootRequest("combat")
      end
      st.lootAfterCombat = false
      M.ServicePendingLootRequest()
    else
      DebugLog("Combat ended: no deferred loot request")
    end
    return
  end
  if event == "PLAYER_CONTROL_LOST" then
    st.playerControlLost = true
    DebugLog("Player control lost; deferring loot")
    return
  end
  if event == "PLAYER_CONTROL_GAINED" then
    st.playerControlLost = false
    DebugLog("Player control gained; servicing deferred loot")
    M.ServicePendingLootRequest()
    return
  end
  if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
    M.OnDeath(event == "UNIT_DIED" and a1 or nil)
    return
  end
  if event == "LOOT_SCAN_COMPLETED" then
    DebugLog("ClassicAPI reported LOOT_SCAN_COMPLETED")
    M.CompleteActiveLootWalk()
    M.ServicePendingLootRequest()
    return
  end
  if event == "SPELLCAST_START" or event == "SPELLCAST_CHANNEL_START"
      or event == "UNIT_SPELLCAST_SENT"
      or event == "UNIT_SPELLCAST_START"
      or event == "UNIT_SPELLCAST_CHANNEL_START"
      or event == "UNIT_SPELLCAST_RETICLE_TARGET" then
    if string.sub(event, 1, 5) ~= "UNIT_" or a1 == "player" then
      if event == "UNIT_SPELLCAST_RETICLE_TARGET" then
        M.SpellcastReticleTarget()
      else
        M.SpellcastStarted()
      end
      if st.lootWalkActive or IsLootScanInProgress() then
        DebugLog("Cast began during an active loot walk; "
          .. "the in-flight walk cannot be aborted")
      end
    end
    return
  end
  if event == "SPELLCAST_STOP" or event == "SPELLCAST_CHANNEL_STOP"
      or event == "SPELLCAST_INTERRUPTED" or event == "SPELLCAST_FAILED"
      or event == "UNIT_SPELLCAST_STOP"
      or event == "UNIT_SPELLCAST_SUCCEEDED"
      or event == "UNIT_SPELLCAST_FAILED"
      or event == "UNIT_SPELLCAST_FAILED_QUIET"
      or event == "UNIT_SPELLCAST_INTERRUPTED"
      or event == "UNIT_SPELLCAST_RETICLE_CLEAR" then
    if string.sub(event, 1, 5) ~= "UNIT_" or a1 == "player" then
      M.SpellcastEnded(event == "UNIT_SPELLCAST_RETICLE_CLEAR")
    end
    return
  end
  if event == "UNIT_SPELLCAST_CHANNEL_STOP"
      or event == "UNIT_SPELLCAST_CHANNEL_INTERRUPTED"
      or event == "UNIT_SPELLCAST_CHANNEL_FAILED" then
    if a1 == "player" then
      if not IsPlayerCasting() and not IsPlayerChanneling() then
        st.playerSpellcastActive = false
        st.playerSpellcastStartedAt = nil
        DebugLog("Player channel ended; servicing deferred loot")
      else
        DebugLog("Channel end event ignored; cast still in progress")
      end
      M.ServicePendingLootRequest()
    end
    return
  end
end

function M.Init()
  if M.state.initialized then return end
  M.Config() -- backfill defaults before anything reads them
  M.state.useSpeedMovement = type(GetUnitSpeed) == "function"
  M.state.initialized = true
  if not CreateFrame then return end -- headless: logic only
  local f = CreateFrame("Frame", "ZugLootAreaLootFrame")
  if type(f) ~= "table" or type(f.RegisterEvent) ~= "function" then return end
  f:RegisterEvent("LOOT_OPENED")
  f:RegisterEvent("LOOT_CLOSED")
  f:RegisterEvent("PLAYER_LEAVING_WORLD")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  if IsEventAvailable("LOOT_SCAN_COMPLETED") then
    f:RegisterEvent("LOOT_SCAN_COMPLETED")
  end
  -- Death scans: Nampower UNIT_DIED when the client offers it, else the
  -- combat-text fallback (donor parity: death detection never hard-fails).
  if IsEventAvailable("UNIT_DIED") then
    f:RegisterEvent("UNIT_DIED")
  else
    f:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
  end
  -- Cast/channel/reticle/control gates (UNIT_ variants only when the
  -- client offers them; the 1.12 SPELLCAST_* set always registers).
  if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_STOP") then
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
  end
  if IsEventAvailable("UNIT_SPELLCAST_START") then
    f:RegisterEvent("UNIT_SPELLCAST_START")
  end
  if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_START") then
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
  end
  if IsEventAvailable("UNIT_SPELLCAST_STOP") then
    f:RegisterEvent("UNIT_SPELLCAST_STOP")
  end
  if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_INTERRUPTED") then
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_INTERRUPTED")
  end
  if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_FAILED") then
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_FAILED")
  end
  if IsEventAvailable("UNIT_SPELLCAST_SENT") then
    f:RegisterEvent("UNIT_SPELLCAST_SENT")
  end
  if IsEventAvailable("UNIT_SPELLCAST_SUCCEEDED") then
    f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  end
  if IsEventAvailable("UNIT_SPELLCAST_FAILED") then
    f:RegisterEvent("UNIT_SPELLCAST_FAILED")
  end
  if IsEventAvailable("UNIT_SPELLCAST_FAILED_QUIET") then
    f:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
  end
  if IsEventAvailable("UNIT_SPELLCAST_INTERRUPTED") then
    f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
  end
  if IsEventAvailable("UNIT_SPELLCAST_RETICLE_TARGET") then
    f:RegisterEvent("UNIT_SPELLCAST_RETICLE_TARGET")
  end
  if IsEventAvailable("UNIT_SPELLCAST_RETICLE_CLEAR") then
    f:RegisterEvent("UNIT_SPELLCAST_RETICLE_CLEAR")
  end
  f:RegisterEvent("SPELLCAST_START")
  f:RegisterEvent("SPELLCAST_CHANNEL_START")
  f:RegisterEvent("SPELLCAST_STOP")
  f:RegisterEvent("SPELLCAST_CHANNEL_STOP")
  f:RegisterEvent("SPELLCAST_INTERRUPTED")
  f:RegisterEvent("SPELLCAST_FAILED")
  if IsEventAvailable("PLAYER_CONTROL_LOST") then
    f:RegisterEvent("PLAYER_CONTROL_LOST")
  end
  if IsEventAvailable("PLAYER_CONTROL_GAINED") then
    f:RegisterEvent("PLAYER_CONTROL_GAINED")
  end
  f:SetScript("OnEvent", function() M.OnEvent(event, arg1, arg2, arg3, arg4) end)
  f:SetScript("OnUpdate", function() M.Poll(arg1) end)
  M.frame = f
  M.RequireAPI() -- one-time missing-DLL note, like the donor
end

if ZugLoot then ZugLoot.AreaLoot = M end
return M
