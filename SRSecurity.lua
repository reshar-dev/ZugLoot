-- ZugLoot/SRSecurity.lua
-- Master-looter checks (RollFor parity). Gates sheet broadcasts + receipt.
-- The ONE question this module answers: is this client (or the named
-- player) the master looter? GetLootMethod()'s second return is the ML's
-- party/raid index; 0 means self ("player"). Leader rank is IRRELEVANT:
-- a raid leader who is not the ML has no ML rights, and an ML who is not
-- the leader has them all.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
ZugLoot.SRSecurity = M

function M.IsInRaid()
  if GetNumRaidMembers and GetNumRaidMembers() > 0 then return true end
  return false
end

function M.IsInParty()
  if GetNumPartyMembers and GetNumPartyMembers() > 0 then return true end
  return false
end

function M.IsInGroup()
  return M.IsInRaid() or M.IsInParty()
end

-- Out of party/raid (solo): no one to broadcast to, but local
-- preview/sim must still work (see CanImport/CanBroadcast).
function M.IsSolo()
  return not M.IsInGroup()
end

function M.LootMethod()
  if GetLootMethod then return GetLootMethod() end
  return nil
end

-- ML party/raid index (RollFor parity): 0 = self ("player"), 1..n =
-- group slot of the ML, nil = no master loot (or no client API).
-- Self (player nil/"player"/own name) is the ML exactly when the index
-- is 0. Any OTHER named player resolves through the live roster
-- (GetRaidRosterInfo in raid, UnitName("party"..id) in party).
function M.MLOffset(player)
  if not GetLootMethod then return nil end
  local ok, method, id = pcall(GetLootMethod)
  if not ok or method ~= "master" then return nil end
  if type(id) ~= "number" then return nil end
  local me = UnitName and UnitName("player") or nil
  if player == nil or player == "player" or player == me then
    -- Self: ML exactly when the index is 0 (GetLootMethod contract).
    if id ~= 0 then return nil end
    return id
  end
  -- Named remote player: resolve their name through the live roster
  -- (GetRaidRosterInfo in raid, UnitName("party"..id) in party).
  local nm = nil
  if M.IsInRaid() and GetNumRaidMembers and GetRaidRosterInfo then
    local okR, rnm = pcall(GetRaidRosterInfo, id)
    if okR then nm = rnm end
  elseif GetNumPartyMembers and UnitName then
    local okP, pnm = pcall(UnitName, "party" .. id)
    if okP then nm = pnm end
  end
  if nm ~= player then return nil end
  return id
end

function M.IsML(player)
  player = player or (UnitName and UnitName("player"))
  if not player then return false end
  -- Master looter = GetLootMethod() reports "master" with OUR index.
  -- No leader fallback: leader rank confers no ML rights.
  return M.MLOffset(player) ~= nil
end

-- Should this client act as master looter? Self-only. Leader rank is
-- not consulted: only the ML (GetLootMethod index) may speak/push for
-- the group.
function M.AmML() return M.IsML() end

-- May this client use RAID_WARNING? Vanilla only lets the raid leader
-- and assistants send /rw — a master looter WITHOUT assist gets an
-- error (or silent drop) on that channel. Warn traffic must fall back
-- to plain RAID in that case. Nil-safe headless (no client API =
-- false: never assume warn rights without proof).
function M.CanRaidWarn()
  if not M.IsInRaid() then return false end
  if IsRaidLeader then
    local ok, v = pcall(IsRaidLeader)
    if ok and v then return true end
  end
  if IsRaidOfficer then
    local ok, v = pcall(IsRaidOfficer)
    if ok and v then return true end
  end
  return false
end

-- Rank probe pins: leader warns, assist warns, plain member (even the
-- ML) falls back, solo never warns, missing API never warns.

-- May this client load a sheet locally (import = parse + store + view/sim)?
-- ALWAYS: anyone can import for their own view (raiders want to see the
-- sheet too). Importing never pushes anything (see CanBroadcast) and
-- never overwrites trust: synced sheets still only come from the ML
-- (see CanAcceptFrom). Kept as a function (not a constant) so callers
-- and tests keep working.
function M.CanImport()
  return true
end

-- May this client push the sheet to the group? Never solo (no channel),
-- otherwise ML only. Leader rank confers no broadcast rights.
function M.CanBroadcast()
  if M.IsSolo() then return false end
  return M.AmML()
end

-- Should we accept a sheet from this sender? Receiver-side guard.
-- ONLY the master looter — never anyone else, no matter what the
-- message claims.
function M.CanAcceptFrom(sender)
  if not sender then return false end
  return M.IsML(sender)
end

-- Do we hold a sheet worth answering a SHEET_REQ with? Any loaded sheet
-- counts (imported or received — both passed the trust rules on the way
-- in, so re-serving them is safe).
-- Do we hold a sheet worth answering a SHEET_REQ with? Empty sheets
-- (thin import, blank paste) are never shared: answering with one would
-- blank every requester's sheet tab for no gain.
function M.AnySheet()
  local s = Z.DB and Z.DB.sheet or nil
  if not s then return nil end
  if Z.SRData and Z.SRData.SheetIsEmpty and Z.SRData.SheetIsEmpty(s) then return nil end
  return s
end

-- SHEET_REQ answer policy (called on every group member that hears the
-- request; Comm routes here). Only the ML answers broadcast requests
-- (at once, when they hold a sheet). Nobody else does — group policy is
-- ML-only. Returns "ml" / nil (pure decision, testable); the Comm-side
-- wrapper below performs the send.
function M.SheetReqAnswer()
  if M.IsSolo() then return nil end
  if M.AnySheet() == nil then return nil end -- nothing to share
  if M.AmML() then return "ml" end
  return nil -- non-ML never answers
end

-- Comm calls this on SHEET_REQ. The ML answers at once; everyone else
-- stays silent on broadcast requests.
-- targeted = true for "/zl sync <name>" requests: the named player
-- answers DIRECTLY when they hold a sheet (anyone may hold one) — no
-- role check, no delay. Trust stays on RECEIVE (CanAcceptFrom).
function M.ShouldAnswerSheetReq(_requester, targeted, channel)
  if targeted then
    if M.AnySheet() == nil then return nil end
    M.AnswerSheetReq("direct", channel)
    return "direct"
  end
  local role = M.SheetReqAnswer()
  if role == "ml" then
    M.AnswerSheetReq("ml", channel)
  end
  return role
end

-- Perform the approved answer: broadcast our sheet to the group.
-- role "direct" = named /zl sync answer (no role needed, sheet only).
function M.AnswerSheetReq(role, channel)
  local sheet = M.AnySheet()
  if not sheet then return false end
  if role ~= "ml" and role ~= "direct" then return false end
  if Z.Comm and Z.Comm.BroadcastSheet then
    local raidID = sheet.meta and sheet.meta.raidID or "sheet"
    Z.Comm.BroadcastSheet(sheet, raidID, channel)
    local me = (UnitName and UnitName("player")) or "?"
    local disp = tostring(me)
    if Z.ClassColors and Z.ClassColors.PlayerLink then
      disp = Z.ClassColors.PlayerLink(me)
    end
    Z.Print("Sheet sent to the group by " .. disp
      .. " (" .. tostring(role) .. ").")
    return true
  end
  return false
end

function M.RoleLabel()
  if M.IsSolo() then return "Solo (preview)" end
  if M.AmML() then return "Master Looter" end
  return "Raider"
end
