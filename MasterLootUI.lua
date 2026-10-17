-- ZugLoot/MasterLootUI.lua
-- Master-loot console: ONE open roll window, rolls land, ML awards.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.MasterLootUI = M

-- THE roll. Exactly one exists at a time, and only while the ML roll
-- window for it is OPEN: { itemID, itemLink, mode, rolls={} }.
-- mode: "SR" (live master loot) | "RAIDROLL" | "SIM" (test rolls: sim +
-- rehearsal share the live path, flagged silent so other clients never
-- see them).
-- Any roll -- fake or real -- lands here while it is set. Closing the
-- roll window ends the roll: every path that closes/awards/finishes the
-- window (close, award, timeout) clears M.roll first, so a dead
-- roll can never collect rolls or auto-finish late. There are no parked
-- sessions, no pending menus, no background rolls. Ever.
M.roll = nil -- THE roll (or nil): { itemID, itemLink, mode, rolls, silent }
M.lastRound = nil -- last FINISHED round stamp (see FinishRoll)

-- Class-colored display name, shared by frames AND chat lines.
local function PName(name)
  if Z.ClassColors and Z.ClassColors.ColoredName then
    return Z.ClassColors.ColoredName(name)
  end
  return tostring(name or "")
end

-- Chat-bound player name: class-colored ("|cHEXname|r"), plain when the
-- class is unknown. Any existing "|c..name|r" wrap is stripped first so
-- names never double-wrap; stored data stays raw by contract.
local function ChatName(name)
  local s = tostring(name or "")
  local inner = string.match(s, "^|c%x%x%x%x%x%x%x%x(.+)|r$")
  if inner then s = inner end
  return PName(s)
end

-- The last FINISHED round, stamped by FinishRoll before the roll clears:
-- { itemID, itemLink, mode, silent, invented, roster, n }. Lets the award
-- window "Continue rolling": reopen intake on the same item with the
-- landed rolls kept. Item-checked on use, so a stale stamp never leaks
-- across items.

-- Loot console is universal: anyone who can SEE the loot runs the window
-- (solo, party/raid of any loot method, master looter or not). Rolling and
-- awarding never need master-looter rights — only sheet broadcast does.
function M.RequireML()
  return true
end

-- Start the one roll. Refuses when a roll is already open (finish,
-- award, or close it first). silent=true skips the addon-message
-- broadcast (sim/rehearse must not pop other clients' roller windows).
function M.BeginRoll(itemID, itemLink, mode, silent)
  if M.roll then return nil end
  local roll = { itemID = itemID, itemLink = itemLink, mode = mode,
    rolls = {}, silent = silent and true or false }
  M.roll = roll
  local dispName = M.ChatItem(itemID, itemLink)
  local label = dispName
  if mode == "RAIDROLL" then label = "Raid rolling " .. dispName .. "..." end
  if Z.Comm and Z.Comm.WarnGroup then
    Z.Comm.WarnGroup(label)
  end
  if not roll.silent and Z.Comm then
    Z.Comm.SendRollReq(itemID, itemLink, mode)
  end
  if Z.RaiderLootUI then
    Z.RaiderLootUI.ShowItem(itemLink, Z.DB.rollTime)
  end
  Z.Print("Roll started (" .. tostring(mode) .. ") " .. tostring(dispName))
  M.BeginRollTimer(roll)
  return roll
end

-- End the roll if it is THIS item's. Every window-close, award, and
-- timeout path funnels through here: disarm the clock, clear the
-- table. A dead roll collects nothing and finishes nothing.
-- NOTE: the finish stamp (M.lastRound) is NOT cleared here — the award
-- window needs it for "Continue rolling" after the finish ended the
-- roll. Award paths clear it when the item leaves (see Award).
function M.EndRoll(itemID)
  local r = M.roll
  if not r then return end
  if itemID and r.itemID ~= itemID then return end
  M.CancelRollTimer(r)
  M.roll = nil
end


-- Raid roster for raid-roll numbering: ordered raid member names
-- (RollFor parity: [1]:Name, [2]:Name, ...). Solo falls back to self.
function M.RaidRoster()
  local names = {}
  if GetNumRaidMembers and GetNumRaidMembers() > 0 and GetRaidRosterInfo then
    for i = 1, GetNumRaidMembers() do
      local name = GetRaidRosterInfo(i)
      if name and name ~= "" then table.insert(names, name) end
    end
  elseif UnitName then
    local me = UnitName("player")
    if me and me ~= "" then table.insert(names, me) end
  end
  return names
end

-- Raid-roll (RollFor parity + Pysanka's raid flow): the raid is numbered
-- [1..N], the ML rolls 1-N with /roll, the number IS the winner.
-- Announce: "Raid rolling <link>..." + one "[i]:Name" line per raider
-- (chunked to chat line limits). Intake: ONLY the ML's own system roll
-- in range 1-N counts (everyone else's chat rolls are ignored); the
-- number indexes the frozen roster. Finish distributes at once
-- (the item goes straight out, no award window).
function M.StartRaidRoll(itemID)
  if not M.RequireML() then return end
  itemID = Z.Util.ItemID(itemID)
  if not itemID then Z.Print("Usage: /zl rr <itemlink>") return end
  if M.roll then
    Z.Print("A roll is already running — finish, award, or close it first.")
    return
  end
  local link = "item:" .. tostring(itemID)
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it and it.link then link = it.link end
  end
  local roster = M.RaidRoster()
  if Z.Util.ArrayCount(roster) == 0 then
    Z.Print("Nobody in the raid to roll for.")
    return
  end
  local roll = M.BeginRoll(itemID, link, "RAIDROLL", false)
  if not roll then return end
  roll.roster = roster -- frozen: leavers/joiners mid-roll change nothing
  roll.n = Z.Util.ArrayCount(roster)
  -- Numbered raid, chunked so no chat line exceeds limits. Names are
  -- class-colored; the chunk math measures the COLORED bit (color codes
  -- count against the 255-byte chat line too).
  local buf = ""
  for i = 1, Z.Util.ArrayCount(roster) do
    local bit = "[" .. i .. "]:" .. ChatName(roster[i])
    if buf == "" then buf = bit
    elseif string.len(buf) + string.len(bit) + 2 > 200 then
      if Z.Comm and Z.Comm.SayGroup then Z.Comm.SayGroup(buf) else Z.Print(buf) end
      buf = bit
    else
      buf = buf .. ", " .. bit
    end
  end
  if buf ~= "" then
    if Z.Comm and Z.Comm.SayGroup then Z.Comm.SayGroup(buf) else Z.Print(buf) end
  end
  -- The ML rolls 1-N: RandomRoll pops the standard roll frame AND the
  -- system message our intake reads (same as any /roll).
  if RandomRoll then RandomRoll(1, roll.n) end
  return roll
end

-- ML initiates a roll for one loot-window item (loot list Roll button or
-- /zl roll <item>). Live corpse rows only; sim rows go via Sim.
-- kind = SR/MS/OS/TMOG (the dice the raiders roll) or RAID (raid-roll:
-- ML rolls 1-N over the numbered raid, winner = candidates[N]).
-- Sequential holds: exactly one roll runs at a time. A finished roll is
-- parked (not live), so rolling ANOTHER item is fine — but re-rolling the
-- same item needs finish/cancel first.
-- ML initiates a roll for one loot-window item (loot list Roll button).
-- Live corpse rows only; sim rows go via Sim. Exactly one roll runs at
-- a time: an open roll refuses (finish, award, or close it first).
function M.StartItemRoll(itemIDorLink)
  if not M.RequireML() then return end
  local itemID = Z.Util.ItemID(itemIDorLink)
  if not itemID then Z.Print("Usage: /zl roll <itemlink|itemID>") return end
  if M.roll then
    Z.Print("A roll is already running — finish, award, or close it first.")
    return
  end
  local link = itemIDorLink
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if not it then
      Z.Print("Item " .. tostring(itemID) .. " is not in the loot window.")
      return
    end
    link = it.link or link
    Z.LootWindow.MarkRolling(itemID)
  end
  if type(link) ~= "string" or not string.find(link, "item:") then
    link = "item:" .. tostring(itemID)
  end
  return M.BeginRoll(itemID, link, "SR", false)
end

-- Chat intake. Rolls land on THE roll while its window is open --
-- fake or real, no difference. Window closed (M.roll nil) = no intake.
-- "Name rolls 42 (1-100)" -> player, roll, minR, maxR.
function M.IntakeChatRoll(line)
  local roll = M.roll
  if not roll then return end
  local player, rv, minR, maxR =
    string.match(tostring(line or ""), "(.+) rolls (%d+) %((%d+)%-(%d+)%)")
  if not player then return end
  rv, minR, maxR = tonumber(rv), tonumber(minR), tonumber(maxR)
  -- Raid-roll: ONLY the ML's own number in range 1-N counts; it picks
  -- the frozen roster winner and the item goes straight out at once
  -- (FinishRoll awards directly, no award window).
  if roll.mode == "RAIDROLL" then
    local n = roll.n or Z.Util.ArrayCount(roll.roster or {})
    if roll.done or minR ~= 1 or maxR ~= n then return end
    local me = UnitName and UnitName("player") or nil
    local mlName = Z.SRSecurity and Z.SRSecurity.MasterLooterName
      and Z.SRSecurity.MasterLooterName() or nil
    if player ~= me and player ~= mlName then return end
    if not roll.roster or not roll.roster[rv] then return end
    roll.done = true
    M.AddRoll(roll.roster[rv], rv, 1, Z.Caps.SR)
    M.FinishRoll()
    return
  end
  M.AddRoll(player, rv, minR, maxR)
end

-- SR+ bonus for a reserve holder's SR roll, else 0. Single lookup so
-- the stored roll, both windows, and the award all see one number.
function M.SRBonus(itemID, player, rtype)
  if rtype ~= "SR" then return 0 end
  if Z.DB.sheet and Z.SRData.GetRollers then
    local rollers = Z.SRData.GetRollers(Z.DB.sheet, itemID)
    for i = 1, Z.Util.ArrayCount(rollers) do
      if rollers[i].name == player then return rollers[i].sr_plus or 0 end
    end
  end
  return 0
end

-- One roll lands on the open roll (up to the player's allowance). The
-- RANGE the player chose decides the kind; 1-100 is SR only for reserve
-- holders, otherwise MS. Sheet lookups here so window, award, and
-- resolver all see the same kind.
--
-- Allowance: a player may roll as many times as they SR'd the item
-- (sheet `rolls`: x2 = two rolls, default one). The resolver judges
-- every roll but keeps each player's best, so extra rolls are extra
-- chances, never extra winners. Anything past the allowance is ignored.
function M.RollAllowance(itemID, player)
  if Z.DB and Z.DB.sheet and Z.SRData.GetRollers then
    local rollers = Z.SRData.GetRollers(Z.DB.sheet, itemID)
    for i = 1, Z.Util.ArrayCount(rollers) do
      if rollers[i].name == player then
        local n = tonumber(rollers[i].rolls) or 1
        if n < 1 then n = 1 end
        return n
      end
    end
  end
  return 1
end
function M.AddRoll(player, rv, minR, maxR)
  local roll = M.roll
  if not roll or (roll.itemID == nil) then return end
  local seen = 0
  for i = 1, Z.Util.ArrayCount(roll.rolls) do
    if roll.rolls[i].name == player then seen = seen + 1 end
  end
  if seen >= M.RollAllowance(roll.itemID, player) then return end
  local rtype = "MS"
  if minR == 1 and maxR == Z.Caps.OS then rtype = "OS"
  elseif minR == 1 and maxR == Z.Caps.TMOG then rtype = "TMOG"
  elseif minR == 1 and maxR == Z.Caps.SR then
    rtype = "MS"
    if Z.DB.sheet and Z.SRData.GetRollers then
      local rollers = Z.SRData.GetRollers(Z.DB.sheet, roll.itemID)
      for i = 1, Z.Util.ArrayCount(rollers) do
        if rollers[i].name == player then rtype = "SR" break end
      end
    end
  end
  local bonus = M.SRBonus(roll.itemID, player, rtype)
  table.insert(roll.rolls, { name = player, roll = rv, type = rtype,
    min = minR, max = maxR, effective = rv + bonus })
  if Z.RaiderLootUI then
    local excluded = rtype == "SR" and Z.DB.sheet and Z.SRData.HasWon
      and Z.SRData.HasWon(Z.DB.sheet, roll.itemID, player) or false
    Z.RaiderLootUI.OnRoll(player, rv, rtype, excluded)
  end
  -- The ML window mirrors the same roll (missed updates resync it whole).
  if Z.LootWindow and Z.LootWindow.SyncRoll then
    Z.LootWindow.SyncRoll(roll, "feed:" .. tostring(player))
  end
end


-- Continue rolling a FINISHED round: reopen intake on the same window
-- with the landed rolls kept (unlike "Roll again", which starts fresh).
-- Only from the award phase: needs the finish stamp (same item) and no
-- live roll. Carries mode/silent/invented/roster over; SIM rounds feed
-- no auto-fakes (the queue entry was consumed at start — the ML collects
-- manual /rolls from here). Refuses cross-item, mid-roll, and stamps
-- gone (awarded/closed/cancelled). Returns the reopened roll or nil.
function M.ContinueRoll(itemID)
  if M.roll then
    Z.Print("A roll is already running — finish, award, or close it first.")
    return nil
  end
  local stamp = M.lastRound
  itemID = Z.Util.ItemID(itemID)
  if not itemID or not stamp or stamp.itemID ~= itemID then
    Z.Print("Nothing to continue — finish a roll first.")
    return nil
  end
  local LW = Z.LootWindow
  local d = LW and LW.detail or nil
  if not d or d.itemID ~= itemID or (d.phase or "pick") ~= "award" then
    Z.Print("Nothing to continue — finish a roll first.")
    return nil
  end
  local kept = {}
  for i = 1, Z.Util.ArrayCount(d.rolls or {}) do
    local r = d.rolls[i]
    if r and r.name then table.insert(kept, r) end
  end
  local roll = M.BeginRoll(itemID, stamp.itemLink or ("item:" .. tostring(itemID)),
    stamp.mode or "SR", stamp.silent)
  if not roll then return nil end
  if stamp.invented then roll.invented = stamp.invented end
  if stamp.roster then roll.roster = stamp.roster end
  if stamp.n then roll.n = stamp.n end
  -- Landed rolls, kept: live truth in the intake's own shape
  -- ({name, roll, type, min, max, effective}); allowance guards
  -- still apply to newcomers AND re-rollers.
  for i = 1, Z.Util.ArrayCount(kept) do
    local r = kept[i]
    table.insert(roll.rolls, { name = r.name, roll = r.roll,
      type = r.rollType, min = r.min, max = r.max,
      effective = r.effective or r.roll })
  end
  M.lastRound = nil -- consumed: one continue per finish
  return roll
end

-- Cancel the open roll: intake dead, clock dead, row back to open. The
-- window itself is LootWindow's job (it drops back to pick for a
-- re-roll choice). Cancelling kills the clock: a dead roll must never
-- auto-finish late. A cancelled item has no finished round: the stamp
-- for THIS item dies here (other items never share a window anyway).
function M.Cancel(itemID)
  local roll = M.roll
  if not roll then Z.Print("No active roll.") return end
  if itemID and roll.itemID ~= itemID then Z.Print("No active roll.") return end
  itemID = roll.itemID
  M.CancelRollTimer(roll)
  M.roll = nil
  if M.lastRound and M.lastRound.itemID == itemID then M.lastRound = nil end
  Z.Print("Roll cancelled.")
  if Z.RaiderLootUI then Z.RaiderLootUI.Hide() end
  if Z.LootWindow and Z.LootWindow.MarkOpen then
    Z.LootWindow.MarkOpen(itemID)
  end
end

-- The roll clock. Arms at BeginRoll; timeout finishes the roll.
-- Cancel/Award/End disarm. Guard: only the CURRENT open roll for THIS
-- item may fire -- anything else is a dead handle from a closed window.
-- Headless-safe: without the Timer module there is no auto-finish.
function M.RollDuration()
  return (Z.DB and tonumber(Z.DB.rollTime)) or 15
end
function M.BeginRollTimer(roll)
  if not roll then return end
  M.CancelRollTimer(roll)
  if not (Z.Timer and Z.Timer.After) then return end
  local dur = M.RollDuration()
  roll.rollDur = dur
  roll.rollLeft = dur
  local function autoFinish()
    roll.rollTimer = nil
    if M.roll ~= roll then return end -- window closed: dead handle
    M.FinishRoll()
  end
  roll.rollTimer = Z.Timer.After(dur, autoFinish)
  if Z.LootWindow then
    local LW = Z.LootWindow
    local d = LW.detail
    if d and d.itemID == roll.itemID and (d.phase or "pick") == "rolling" then
      d.countdown = dur
      d.countdownDur = dur
      if LW.RefreshDetail then LW.RefreshDetail() end
    end
  end
  local function tick()
    roll.clockTick = nil
    if M.roll ~= roll then return end -- window closed: dead handle
    roll.rollLeft = (roll.rollLeft or dur) - 1
    if roll.rollLeft < 0 then roll.rollLeft = 0 end
    if Z.LootWindow then
      local LW = Z.LootWindow
      local d = LW.detail
      if d and d.itemID == roll.itemID and (d.phase or "pick") == "rolling" then
        d.countdown = roll.rollLeft
        d.countdownDur = dur
      end
      if LW.RefreshDetail then LW.RefreshDetail() end
    end
    if roll.rollLeft > 0 and Z.Timer and Z.Timer.After then
      roll.clockTick = Z.Timer.After(1, tick)
    end
  end
  roll.clockTick = Z.Timer.After(1, tick)
end
function M.CancelRollTimer(roll)
  if roll and roll.rollTimer then
    if Z.Timer and Z.Timer.Cancel then Z.Timer.Cancel(roll.rollTimer) end
    roll.rollTimer = nil
  end
  if roll and roll.clockTick then
    if Z.Timer and Z.Timer.Cancel then Z.Timer.Cancel(roll.clockTick) end
    roll.clockTick = nil
  end
end

-- Finish the open roll: resolve it and hand the award to the ML on
-- the SAME window (rolling view flips to winners). Ties stay open for
-- a re-roll round. The roll ends here either way for intake purposes:
-- FinishRoll clears M.roll FIRST so no late roll can land mid-resolve;
-- the window keeps the landed rolls for the award. The finished round
-- is stamped on M.lastRound (mode/silent/invented/roster carried over)
-- so "Continue rolling" can reopen intake on the same window with
-- the landed rolls kept. Returns "tie" (still
-- open for re-rolls) or "awarded"/"finished".
function M.FinishRoll(itemID)
  local roll = M.roll
  if not roll then Z.Print("No active roll.") return "closed" end
  if itemID and roll.itemID ~= itemID then return "closed" end
  M.lastRound = { itemID = roll.itemID, itemLink = roll.itemLink,
    mode = roll.mode, silent = roll.silent, invented = roll.invented,
    roster = roll.roster, n = roll.n }
  M.EndRoll()
  local sheet = Z.DB and Z.DB.sheet
  local res = Z.Resolver.ResolveItem(sheet or { items = {}, won = {} },
    roll.itemID, roll.rolls, { cap = Z.Caps.SR })
  M.AnnounceResult(roll, res)
  -- Raid-roll distributes at once: the ML's number IS the winner, so
  -- the item goes straight out (no award window). Falls back to the
  -- award window when there is no winner (ties resolve live to one
  -- winner, so this is the no-rolls case) or the corpse handoff fails
  -- (ML retries the award from the still-open window).
  if roll.mode == "RAIDROLL" then
    local winners = res.winners or {}
    if Z.Util.ArrayCount(winners) == 0
        or Z.Util.ArrayCount(res.tied or {}) > 0 then
      -- No award: show the result (announced above) on the window so
      -- the ML sees why nothing went out, then offer re-roll/close.
      local data = M.AwardMenu(roll.itemID, roll.itemLink, res)
      if Z.LootWindow and Z.LootWindow.DetailOnFinish then
        Z.LootWindow.DetailOnFinish(roll.itemID, data)
      end
      if Z.Util.ArrayCount(res.tied) > 0 then
        Z.Print("Tie at top — tied players re-roll.")
        return "tie"
      end
      return "finished"
    end
    local nm = winners[1].name
    local row = Z.LootWindow and Z.LootWindow.Find(roll.itemID) or nil
    local source = (row and row.source == "sim") and "sim" or "raid"
    local ok = M.Award(roll.itemID, nm, source, M.AwardInvented(roll.itemID))
    if ok then return "awarded " .. tostring(nm) end
    -- Handoff failed (non-candidate, walked away, dead call): the row
    -- and window stay up with the winner on it for a manual retry.
    local data = M.AwardMenu(roll.itemID, roll.itemLink, res)
    if Z.LootWindow and Z.LootWindow.DetailOnFinish then
      Z.LootWindow.DetailOnFinish(roll.itemID, data)
    end
    return "finished"
  end
  local data = M.AwardMenu(roll.itemID, roll.itemLink, res)
  if Z.LootWindow and Z.LootWindow.DetailOnFinish then
    Z.LootWindow.DetailOnFinish(roll.itemID, data)
  end
  if Z.Util.ArrayCount(res.tied) > 0 then
    Z.Print("Tie at top — tied players re-roll.")
    return "tie"
  end
  return "finished"
end

-- One line per finished roll: who won (or tie / no winner). The window
-- already shows every roll with its kind — chat gets the verdict only.
function M.AnnounceResult(roll, res)
  local itemTxt = M.ChatItem(roll.itemID, roll.itemLink)
  local winners = res.winners or {}
  if Z.Util.ArrayCount(winners) > 0 then
    local w = {}
    for i = 1, Z.Util.ArrayCount(winners) do
      table.insert(w, ChatName(winners[i].name) .. " (" .. tostring(winners[i].effective) .. ")")
    end
    local line = tostring(itemTxt) .. " won by " .. table.concat(w, ", ")
    if Z.Comm and Z.Comm.SayGroup then Z.Comm.SayGroup(line) else Z.Print(line) end
    if Z.RaiderLootUI and Z.RaiderLootUI.ShowResult then
      local bw = {}
      for i = 1, Z.Util.ArrayCount(winners) do table.insert(bw, PName(winners[i].name)) end
      Z.RaiderLootUI.ShowResult("The winner is " .. table.concat(bw, ", ") .. " !")
    end
  elseif Z.Util.ArrayCount(res.tied) > 0 then
    local t = {}
    for i = 1, Z.Util.ArrayCount(res.tied) do table.insert(t, ChatName(res.tied[i].name)) end
    local line = tostring(itemTxt) .. ": tie between " .. table.concat(t, ", ") .. " — re-roll."
    if Z.Comm and Z.Comm.SayGroup then Z.Comm.SayGroup(line) else Z.Print(line) end
  else
    local line = tostring(itemTxt) .. ": no eligible rolls."
    if Z.Comm and Z.Comm.SayGroup then Z.Comm.SayGroup(line) else Z.Print(line) end
    if Z.RaiderLootUI and Z.RaiderLootUI.ShowResult then
      Z.RaiderLootUI.ShowResult("No winner this time.")
    end
  end
  -- Persist the roll into per-item roll history. Same shape the sim
  -- writes (Resolver.ToHistoryEntry). Rehearsal rolls skip this
  -- entirely: invented rolls must never enter the real sheet's history
  -- (or plant unreserved stubs on it). Below rare (known quality < 3)
  -- logs nothing at all — no stub, no history: such items never enter
  -- the sheet. Unknown quality proceeds (unclassifiable, no data loss).
  -- Quality 0 counts as unknown: poor items are always free rows and can
  -- never roll, so 0 at finish time means "no data" (sim rows default
  -- to it), not "grey".
  if roll.invented then
    if Z.MainWindow then Z.MainWindow.Refresh() end
  elseif Z.DB and Z.DB.sheet and Z.SRData.RecordRolls then
    local q = nil
    if GetItemInfo then
      local _, _, qq = GetItemInfo(tonumber(roll.itemID))
      q = qq
    end
    if q == nil and Z.LootWindow and Z.LootWindow.Find then
      local row = Z.LootWindow.Find(roll.itemID)
      if row then q = tonumber(row.quality) end
    end
    if q == nil and Z.DB.sheet.items then
      local it = Z.DB.sheet.items[roll.itemID]
      if it then q = tonumber(it.quality) end
    end
    if q == 0 then q = nil end -- never a real rolled quality (see above)
    if Z.SRData.LoggableQuality and not Z.SRData.LoggableQuality(q) then
      if Z.MainWindow then Z.MainWindow.Refresh() end
    else
      -- Item rolled but never SR'd: stub it onto the sheet so it shows at the
      -- bottom, flagged as not SR'd. Only when rolls actually happened.
      if Z.Util.ArrayCount(res.entries or {}) > 0 and Z.SRData.EnsureUnreserved then
        if Z.SRData.EnsureUnreserved(Z.DB.sheet, roll.itemID, q) then
          Z.Print("Note: " .. tostring(roll.itemLink or roll.itemID) .. " was not on the SR sheet — added below, marked not SR'd.")
        end
      end
      Z.SRData.RecordRolls(Z.DB.sheet, roll.itemID,
        Z.Resolver.ToHistoryEntry(res, roll.mode, (time and time()) or 0))
      if Z.MainWindow then Z.MainWindow.Refresh() end
    end
  end
end

-- Award menu data (RollFor RollController-finish style, pure data for
-- tests + text/headless render; a client frame shows the same rows).
-- Returns { winners, groups, perType, candidates, res, none }.
--
-- winners: overall winner(s) by priority SR > MS > OS (+effective).
-- perType: each kind judged by itself — { SR={entry,tied}, MS=..., OS=...,
--   TMOG=... } — so the menu can award each kind's own winner. The ML
--   awards the SR, MS, OS or TMOG winner directly; what happens to the
--   item afterwards (e.g. a trade) is outside the addon.
-- groups: SR>MS>OS>TMOG full lists {name, rollType, effective}.
-- candidates: class-sorted full roster the ML can award any raider from
--   when something is wrong with the rolls.
-- none: true when nobody eligible rolled.
-- Live name -> raw class map: raid roster, party units, self (shared with
-- the roll window via ClassColors). Values are client-reported; callers
-- normalize. Nil-safe: {} with no client APIs.

function M.BuildCandidates(sheet, sessRolls)
  -- Class-sorted roster: sheet players + seen rollers + raid roster, unique.
  local seen = {}
  local names = {}
  local function add(n)
    if n and n ~= "" and not seen[n] then seen[n] = true table.insert(names, n) end
  end
  for i = 1, Z.Util.ArrayCount(sessRolls or {}) do
    if sessRolls[i] then add(sessRolls[i].name) end
  end
  if sheet then
    local all = Z.SRData.AllPlayerNames(sheet)
    for i = 1, Z.Util.ArrayCount(all) do add(all[i]) end
    local function addEntries(ents)
      for e = 1, Z.Util.ArrayCount(ents or {}) do add(ents[e].name) end
    end
    for _, h in pairs(sheet.rolls or {}) do
      if type(h) == "table" then
        if h.entries ~= nil then addEntries(h.entries) -- single record
        else -- array of records (itemID -> { rec, ... })
          for r = 1, Z.Util.ArrayCount(h) do
            if type(h[r]) == "table" then addEntries(h[r].entries) end
          end
        end
      end
    end
  end
  local classes = (Z.ClassColors and Z.ClassColors.RosterMap and Z.ClassColors.RosterMap()) or {}
  for n in pairs(classes) do add(n) end
  local out = {}
  for i = 1, Z.Util.ArrayCount(names) do
    local raw = classes[names[i]]
    local canon = raw
    if Z.ClassColors and Z.ClassColors.NormalizeClass then
      canon = Z.ClassColors.NormalizeClass(raw)
    end
    -- Sheet fallback: the live roster may not know everyone.
    if not canon and sheet and Z.SRData and Z.SRData.PlayerClass then
      canon = Z.SRData.PlayerClass(sheet, names[i])
    end
    table.insert(out, { name = names[i], class = canon })
  end
  -- Class first (unknown last), then name — RollFor's roster ordering.
  table.sort(out, function(a, b)
    local ca, cb = a.class or "~~~", b.class or "~~~"
    if ca ~= cb then return ca < cb end
    return (a.name or "") < (b.name or "")
  end)
  return out
end

local function entryRollType(e)
  local t = e.rollType or "SR"
  if t ~= "SR" and t ~= "MS" and t ~= "OS" and t ~= "TMOG" then t = "MS" end
  return t
end

-- Max of the /roll command behind a kind (56/98 for a TMOG roll).
-- M.RollCap so the loot window reaches it without duplicating caps.
function M.RollCap(rtype)
  if Z.Resolver and Z.Resolver.TypeCap then return Z.Resolver.TypeCap(rtype) end
  if Z.Caps then
    if rtype == "OS" then return Z.Caps.OS or 99 end
    if rtype == "TMOG" then return Z.Caps.TMOG or 98 end
    return Z.Caps.SR or 100
  end
  return 100
end

-- "90/100" for a roll, with " (=110)" when an SR bonus applies.
-- Public so the loot window paints the same ranges as the menu lines.
function M.RollRange(base, rtype, eff)
  local cap = M.RollCap(rtype)
  local s = tostring(base) .. "/" .. tostring(cap)
  if eff ~= nil and eff ~= base then
    s = s .. " (=" .. tostring(eff) .. ")"
  end
  return s
end

-- Award data for the open window: winners, kind groups, per-type
-- contests, class-sorted candidates. Pure data (itemID in, table out) --
-- no sessions, no pending menus. The window owns it via DetailOnFinish.
function M.AwardMenu(itemID, itemLink, res)
  local data = { winners = {}, groups = { SR = {}, MS = {}, OS = {}, TMOG = {} },
    perType = {}, candidates = {}, res = res, none = false,
    itemID = itemID, itemLink = itemLink, sessionID = nil }
  local entries = res.entries or {}
  for i = 1, Z.Util.ArrayCount(entries) do
    local e = entries[i]
    if not e.missroll and not e.excludedWon and not e.overCap then
      table.insert(data.groups[entryRollType(e)],
        { name = e.name, rollType = entryRollType(e), base = e.base,
          effective = e.effective or e.base })
    end
  end
  -- Rank groups best-first (ties by name).
  for _, g in pairs(data.groups) do
    table.sort(g, function(a, b)
      if (a.effective or 0) ~= (b.effective or 0) then return (a.effective or 0) > (b.effective or 0) end
      return (a.name or "") < (b.name or "")
    end)
  end
  -- Per-type contests straight from the resolver (each kind by itself).
  data.perType = res.perType or {}
  local winners = res.winners or {}
  for i = 1, Z.Util.ArrayCount(winners) do
    local w = winners[i]
    table.insert(data.winners, { name = w.name, rollType = w.rollType or "SR",
      base = w.base, effective = w.effective })
  end
    if Z.Util.ArrayCount(data.winners) == 0 then data.none = true end
  -- Candidates are the awardable non-rollers (any raider, for when
  -- something is wrong with the rolls): everyone already listed with
  -- a roll shows only there, never again bare.
  local rolled = {}
  for i = 1, Z.Util.ArrayCount(entries) do
    if entries[i] and entries[i].name then rolled[entries[i].name] = true end
  end
  local cands = M.BuildCandidates(Z.DB and Z.DB.sheet, res.entries)
  data.candidates = {}
  for i = 1, Z.Util.ArrayCount(cands) do
    if cands[i] and cands[i].name and not rolled[cands[i].name] then
      table.insert(data.candidates, cands[i])
    end
  end
  return data
end



-- Display link for award UI: the readable name, never a bare item:id.
-- Prefers the LootWindow row name (resolved at scan), else the [Name] in a
-- full link, else the sheet name via GetItemInfo, else the link as-is.
function M.DisplayItemLink(itemID, itemLink)
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it and Z.LootWindow.DisplayName then
      local nm = Z.LootWindow.DisplayName(it)
      if nm and nm ~= "" and nm ~= ("item:" .. tostring(itemID)) then
        return nm
      end
    elseif it and it.name and it.name ~= "" then
      return tostring(it.name)
    end
  end
  local link = tostring(itemLink or "")
  local nm = string.match(link, "%[(.-)%]")
  if nm and nm ~= "" then return nm end
  if GetItemInfo and Z.LootWindow and Z.LootWindow.ResolveItemInfo then
    local rName = Z.LootWindow.ResolveItemInfo(itemID, itemLink, nil, nil, nil)
    if rName and rName ~= "" then return tostring(rName) end
  end
  if link ~= "" then return link end
  return "item:" .. tostring(itemID)
end

-- Chat-bound item: the FULL clickable link ("|cHEX|Hitem:id:...|h[Name]|h|r").
-- Shift-clickable, hover tooltip, quality-colored in every client —
-- including non-ZugLoot ones. Source order: the passed link when already
-- full, the loot-window row link (scan-time GetLootSlotLink is always
-- full), the client cache via ResolveItemInfo, else a synthesized
-- BuildLink from name + quality (RollFor parity). Last resort: the plain
-- colored name — never a bare item:id.
function M.ChatItem(itemID, itemLink, quality)
  local name = M.DisplayItemLink(itemID, itemLink)
  local link = tostring(itemLink or "")
  if string.find(link, "|Hitem:", 1, true) == nil then link = "" end
  if link == "" and Z.LootWindow then
    if Z.LootWindow.Find then
      local row = Z.LootWindow.Find(itemID)
      if row and string.find(tostring(row.link or ""), "|Hitem:", 1, true) then
        link = row.link
      end
    end
    if link == "" and Z.LootWindow.ResolveItemInfo
        and name ~= "" and name ~= ("item:" .. tostring(itemID)) then
      local _, full = Z.LootWindow.ResolveItemInfo(itemID, itemLink, quality, nil, name)
      if string.find(tostring(full or ""), "|Hitem:", 1, true) then link = full end
    end
  end
  if link ~= "" then return link end
  -- No full link anywhere (uncached item, bare id): synthesize a REAL
  -- clickable link from the name + quality (RollFor parity) so the line
  -- still shift-clicks/tooltips. Never a bare item:id.
  -- Quality order: the loot-window row is authoritative (scan-time slot
  -- quality + list input), the explicit arg next, then cache, then
  -- sheet. A cold/incorrect cache entry must never repaint the link.
  local q = nil
  if Z.LootWindow and Z.LootWindow.Find then
    local row = Z.LootWindow.Find(itemID)
    if row then q = tonumber(row.quality) end
  end
  if (q == nil or q == 0) and tonumber(quality) then q = tonumber(quality) end
  if q == nil and GetItemInfo then
    local _, _, qq = GetItemInfo(tonumber(itemID))
    q = qq
  end
  if q == nil and Z.DB and Z.DB.sheet and Z.DB.sheet.items then
    local it = Z.DB.sheet.items[itemID]
    if it then q = tonumber(it.quality) end
  end
  if Z.LootWindow and Z.LootWindow.BuildLink
      and name ~= "" and name ~= ("item:" .. tostring(itemID)) then
    local built = Z.LootWindow.BuildLink(itemID, name, q)
    if built then return built end
  end
  return M.QualityColor(q) .. tostring(name) .. "|r"
end

-- "|cHEX" for a quality number: client colors when present, else the
-- classic quality hexes (keeps headless/tests deterministic). Unknown
-- quality reads white, never grey (grey = poor = free loot).
function M.QualityColor(q)
  if GetItemQualityColor then
    local r, g, b = GetItemQualityColor(tonumber(q) or 0)
    if r then
      return string.format("|cFF%02X%02X%02X",
        math.floor((r or 1) * 255), math.floor((g or 1) * 255), math.floor((b or 1) * 255))
    end
  end
  local hexes = { "|cff9d9d9d", "|cffffffff", "|cff1eff00",
    "|cff0070dd", "|cffa335ee", "|cffff8000" }
  local i = tonumber(q)
  if i ~= nil and hexes[i + 1] ~= nil then return hexes[i + 1] end
  return "|cffffffff"
end

-- Loot one corpse slot through Blizzard's loot frame (nil-safe: no-ops
-- headless and when the slot can't be resolved). Master loot hands the
-- corpse item to the winner; any other method loots it to us. Either way
-- OUR window stays the visible loot window: the item leaves the corpse
-- and our row drops (RemoveItem), never Blizzard's frame popping back.
-- Three outcomes: true = loot call ISSUED (slot resolved + API present);
-- "noslot" = no corpse slot/API involved (sim rows, /rf rolls, headless
-- award tests) — the caller proceeds without corpse interaction; false =
-- REFUSED (master-loot non-candidate) — the caller aborts and keeps row.
-- The row leaves the list only on LOOT_SLOT_CLEARED for that slot — never
-- optimistically here — so a failed LootSlot (locked, full bags, range)
-- leaves the row up for retry.
function M.LootCorpseSlot(link, itemID, winnerName, slotHint)
  -- Loot gate FIRST: no open corpse (walked away, corpse closed)
  -- means no call can possibly land. Report "nolooot" so the caller logs
  -- + keeps the list intact — never touch VerifySlot/rescan, which would
  -- read an empty corpse and wipe every row.
  if not M.lootOpen then return "nolooot" end
  -- LIVE-resolve the slot at call time: stored slot numbers go stale the
  -- moment anything shifts the corpse (earlier loot, page change), and a
  -- stale LootSlot() is a silent server-side no-op — exactly the reported
  -- "gray [done], nothing looted, no error" ghost. When the hinted slot
  -- no longer holds THIS item, re-scan the corpse for it; when the item
  -- is gone entirely, report "gone" (caller leaves the row for rescan).
  -- Range gate SECOND: a moved-away player must never issue the call —
  -- report "norange" so the caller logs + keeps the list intact.
  if M.CheckLootRange() == "norange" then return "norange" end
  local slot = M.VerifySlot(itemID, slotHint)
  if slot == "gone" then return "gone" end
  if not slot then return "noslot" end
  local method = nil
  if GetLootMethod then local ok, m = pcall(GetLootMethod) if ok then method = m end end
  if method == nil and Z.SRSecurity and Z.SRSecurity.LootMethod then
    local ok, m = pcall(Z.SRSecurity.LootMethod) if ok then method = m end
  end
  -- BoP items need a second call: LootSlot raises the LOOT_BIND_CONFIRM
  -- popup, ConfirmLootSlot(slot) takes it. Without it BoP loot sits on
  -- the corpse forever. The confirm lands in OnEvent (Core routes
  -- LOOT_BIND_CONFIRM) and confirms every armed pending slot.
  -- SuperWoW hook (Turtle client): LootSlot takes an optional second arg
  -- (force). A plain LootSlot(slot) from script context is silently
  -- dropped by this client — verified live: direct call, correct slot,
  -- freeforall, no error, no loot. RollFor documents the same class of
  -- limitation for coins. Pass force=1 (verified strings: SuperWoWhook
  -- exports "LootSlot(slot [, force])"). pcall-guarded: a stock 1.12
  -- client ignores extra C-API args, so this stays compatible.
  local function superLoot(s)
    if LootSlot then return pcall(LootSlot, s, 1) end
  end
  local function callLoot()
    -- Routing (stock rule: the PARTY threshold gates the loot method):
    -- threshold+ takes under master loot go through the handoff
    -- (RollFor parity: GetMasterLootCandidate(slot, i) -> index, never
    -- by name) — awards to others AND self-awards (plain LootSlot is a
    -- silent server-side no-op for those: verified live). Below-threshold
    -- takes, coin, and unknown-quality rows loot straight to the player
    -- via LootSlot in ANY method — under master loot those are free loot
    -- (that's what the threshold MEANS), anyone including the ML takes
    -- them off the corpse directly.
    -- Vanilla quirk: one-arg GetMasterLootCandidate(i) ignores the slot.
    -- ML SELF-TAKE under master loot (winner == me == the ML): plain
    -- LootSlot is a silent no-op here too (verified live via the debug
    -- log: LOOT-ISSUED ok=true, server ignores it, row strands [done]).
    -- So a below-threshold take to SELF under master loot goes through
    -- the handoff with the ML's own candidate index — same as a
    -- threshold+ self-award. No amML gate: only the ML ever calls this
    -- path with winner == self (raiders click free rows with winner ==
    -- self too, but GiveMasterLoot errors for non-ML — pcall-guarded,
    -- falls back to LootSlot).
    local me = nil
    if UnitName then local ok, nm = pcall(UnitName, "player") if ok then me = nm end end
    local liveQ = nil
    if GetLootSlotInfo then
      local ok, _a, _b, _c, d = pcall(GetLootSlotInfo, slot)
      liveQ = ok and tonumber(d) or nil
    end
    if liveQ == nil and GetItemInfo and link then
      local ok, _n, _l, q = pcall(GetItemInfo, link)
      if ok then liveQ = tonumber(q) end
    end
    if liveQ == nil then
      local row = Z.LootWindow and Z.LootWindow.Find
        and Z.LootWindow.Find(itemID) or nil
      if row then liveQ = tonumber(row.quality) end
    end
    -- Poor (0) is NEVER a roll row (ScanSlot parity); unknown quality
    -- (cold cache, no slot quality) isn't either.
    local thresh = M.LootThreshold()
    local isRoll = itemID ~= "Coin" and liveQ ~= nil and liveQ > 0
      and liveQ >= thresh
    -- Routing inputs for the debug line (printed BEFORE the call, so a
    -- dead call still leaves its decision behind).
    local amML, mlName = nil, nil
    if Z.SRSecurity and Z.SRSecurity.AmML then
      local ok, v = pcall(Z.SRSecurity.AmML)
      if ok then amML = v end
    end
    if GetLootMaster then
      local ok, v = pcall(GetLootMaster)
      if ok then mlName = v end
    end
    local function dbgLine(call)
      return "lootdebug: call=" .. tostring(call)
        .. " slot=" .. tostring(slot)
        .. " winner=" .. tostring(winnerName)
        .. " amML=" .. tostring(amML) .. " ml=" .. tostring(mlName)
        .. " method=" .. tostring(method)
        .. " liveQ=" .. tostring(liveQ) .. " thresh=" .. tostring(thresh)
        .. " link=" .. tostring(link)
    end
    local dbg = Z.LootWindow and Z.LootWindow.lootDebug
    -- Debug trace (chat + CustomData/ZugLoot_debug.txt): routing inputs
    -- BEFORE the call, the issued call + pcall result AFTER. A dead
    -- (silent-drop) call still leaves its full decision behind.
    local function trace(line)
      if dbg and Z.Print then Z.Print(line) end
      if Z.FileIO and Z.FileIO.Log then Z.FileIO.Log(line) end
    end
    -- Trace every master-loot-path decision, and every call while
    -- lootdebug is on. (Plain LootSlot takes log on debug only.)
    local selfTake = (method == "master" and me and winnerName
      and winnerName ~= "" and winnerName == me and itemID ~= "Coin")
    local isMasterPath = (method == "master" and winnerName
      and winnerName ~= "" and (isRoll or selfTake))
    if isMasterPath or dbg then trace(dbgLine(isMasterPath and "MASTER?" or "LOOT?")) end
    if method == "master" and winnerName and winnerName ~= "" and (isRoll or selfTake) then
      local idx = M.MasterLootIndex(slot, winnerName)
      trace(dbgLine("MASTER") .. " idx=" .. tostring(idx)
        .. " selfTake=" .. tostring(selfTake and true or false))
      local giveML = GiveMasterLoot or GiveMasterLootCandidate
      if not idx then
        if selfTake then
          -- Not on the candidate list (or list unreadable): fall back
          -- to the plain call rather than strand the row. pcall-guarded
          -- below; a dead call un-dims via the watchdog.
          if dbg then trace(dbgLine("MASTER-FALLBACK")) end
        else
          if Z.Print then Z.Print("Can't award " .. tostring(winnerName) .. ": not a loot candidate.") end
          return false
        end
      elseif giveML then
        local okM, errM = pcall(giveML, slot, idx)
        trace(dbgLine("MASTER-ISSUED") .. " ok=" .. tostring(okM)
          .. " err=" .. tostring(errM))
        -- Self-take handoff that the client rejects (non-ML caller,
        -- bad index): fall through to the plain call, don't strand.
        if not (selfTake and not okM) then
          return okM, errM
        end
        if dbg then trace(dbgLine("MASTER-FALLBACK")) end
      elseif not selfTake then
        -- Corpse open, handoff certain, but no API: never fake the award
        -- (won-mark + vanished row while the item sits on the corpse).
        -- Refuse with the row kept.
        if Z.Print then Z.Print("Can't award " .. tostring(winnerName) .. ": master loot unavailable.") end
        return false
      end
      -- selfTake with no usable handoff: plain LootSlot below.
    end
    if dbg then trace(dbgLine("LOOT")) end
    if LootSlot then
      local okL, errL = superLoot(slot)
      if dbg then trace(dbgLine("LOOT-ISSUED") .. " ok=" .. tostring(okL)
        .. " err=" .. tostring(errL)) end
      return okL, errL
    end
    return "noslot"
  end
  local okCall, errCall = callLoot()
  if okCall == "noslot" then return "noslot" end
  if not okCall then
    -- The pcall itself blew up (bad slot, tainted call): NEVER dim the
    -- row — surface the error so a dead loot call can't masquerade as
    -- "done" (the reported ghost: gray row, nothing looted). Refusals
    -- above already said why (errCall nil): stay quiet here.
    if errCall ~= nil then
      Z.Print("Loot failed (slot " .. tostring(slot) .. "): " .. tostring(errCall))
    end
    return false
  end
  -- Armed, not done: the row drops when LOOT_SLOT_CLEARED confirms the
  -- slot left the corpse (post-confirm rescan prunes anything stale).
  if Z.LootWindow and Z.LootWindow.Find then
    local row = Z.LootWindow.Find(itemID)
    if row and (slotHint == nil or row.slot == slot) then
      M.pendingLoot = M.pendingLoot or {}
      M.pendingLoot[slot] = row
    end
  end
  return true
end

-- Corpse identity, strongest key first:
-- 1. Creature GUID via UnitExists("target") -> (exists, guid). This
--    client (Nampower/SuperWoW hooks) extends UnitExists with a second
--    GUID return (DoiteAuras/Luna/Aegis_SBR/MageTools all rely on it),
--    and GUIDs double as unit tokens. A GUID pins the UNIQUE corpse —
--    two same-named Plainstriders never share a window. Nil-safe: the
--    stock 1.12 UnitExists returns only exists (no guid), and headless
--    tests may define neither.
-- 2. Fallback: loot-target name + loot fingerprint (sorted itemIDs +
--    coin flag). Same corpse re-looted after walking back still matches;
--    same-named/same-loot twins may share (rescan reconciles correctly).
-- Pure helper for tests: pass guid, name + id list.
function M.TargetGUID()
  if not UnitExists then return nil end
  local ok, exists, guid = pcall(UnitExists, "target")
  if ok and exists and guid and guid ~= "" then return guid end
  return nil
end

function M.CorpseKey(targetGUID, targetName, itemIDs, hasCoin)
  if targetGUID and targetGUID ~= "" then
    return "guid:" .. tostring(targetGUID)
  end
  local ids = {}
  for i = 1, Z.Util.ArrayCount(itemIDs) do
    table.insert(ids, tostring(itemIDs[i]))
  end
  table.sort(ids)
  return "fp:" .. tostring(targetName or "?") .. "|" .. table.concat(ids, ",")
    .. (hasCoin and "|+coin" or "")
end

function M.LiveCorpseKey()
  local guid = M.TargetGUID()
  local target = nil
  if UnitName then
    local ok, nm = pcall(UnitName, "target")
    if ok then target = nm end
  end
  local ids, coin = {}, false
  if GetNumLootItems and GetLootSlotLink then
    local n = GetNumLootItems() or 0
    for s = 1, n do
      if Z.LootWindow and Z.LootWindow.IsCoinSlot
          and Z.LootWindow.IsCoinSlot(s) then
        coin = true
      else
        local ok, l = pcall(GetLootSlotLink, s)
        if ok and l then
          local id = Z.Util.ItemID(l)
          if id then table.insert(ids, id) end
        end
      end
    end
  end
  return M.CorpseKey(guid, target, ids, coin)
end

-- Range gate: block a loot attempt when the player has moved away from
-- the looted corpse. 1.12 has no movement event, so the signal is
-- CheckInteractDistance("target", 1) (loot range) against the corpse
-- pinned at scan time — by GUID when available (unique corpse), else by
-- target name. Same corpse + out of range = moved away: block early
-- ("norange"), list untouched, caller logs. Anything unverifiable (no
-- live corpse, target changed/cleared, GUID-less different corpse with
-- the same name) allows the attempt — the server has the final say.
-- Only live corpse loot is gated (GetNumLootItems() > 0); sim/award
-- bookkeeping never is.
function M.CheckLootRange()
  if not (GetNumLootItems and (GetNumLootItems() or 0) > 0) then
    return true
  end
  if not (CheckInteractDistance and UnitName) then return true end
  local pinnedGUID, pinnedName = M.lootGUID, M.lootTarget
  if not (pinnedGUID or pinnedName) then return true end
  local guid = M.TargetGUID()
  if pinnedGUID then
    -- GUID-pinned: a different GUID (or none) is a different corpse —
    -- allow, the key check owns identity. Same GUID + out of range =
    -- moved away from THIS corpse: block.
    if not guid or guid ~= pinnedGUID then return true end
  else
    local okCur, cur = pcall(UnitName, "target")
    if not okCur or cur ~= pinnedName then return true end
  end
  local okR, inRange = pcall(CheckInteractDistance, "target", 1)
  if okR and not inRange then return "norange" end
  return true
end

-- Verify a stored slot still holds the expected item, live from the
-- corpse. Returns the (possibly re-resolved) slot number, "gone" when
-- the item is nowhere on the corpse, or nil when the corpse can't be
-- read at all. Coin rows (itemID "Coin") verify via IsCoinSlot since
-- they carry no link.
function M.VerifySlot(itemID, slotHint)
  if not (GetNumLootItems and GetLootSlotLink) then
    if slotHint then return slotHint end
    return nil
  end
  local n = GetNumLootItems() or 0
  local function slotHolds(s)
    if itemID == "Coin" then
      return Z.LootWindow and Z.LootWindow.IsCoinSlot
        and Z.LootWindow.IsCoinSlot(s)
    end
    local ok, l = pcall(GetLootSlotLink, s)
    return ok and l and Z.Util.ItemID(l) == itemID
  end
  if slotHint and slotHint >= 1 and slotHint <= n and slotHolds(slotHint) then
    return slotHint -- still valid: cheapest path, no scan
  end
  for s = 1, n do
    if s ~= slotHint and slotHolds(s) then return s end -- shifted: re-resolve
  end
  if slotHint then return "gone" end -- was tracked, now absent
  return nil
end

-- Click confirmations in flight: [slot] = row, armed by LootCorpseSlot,
-- cleared by the LOOT_SLOT_CLEARED confirmation (same slot) or the LOOT
-- re-scan (slot gone = looted elsewhere / corpse closed). Rows leave the
-- list ONLY through confirmation — never optimistically at click time.
M.pendingLoot = nil

-- Candidate index of a player for one corpse slot (nil when absent).
-- RollFor parity: vanilla 1.12 takes ONE arg (index); backports/retail
-- take (slot, index). One-arg first — a two-arg call on vanilla would
-- silently misread (extra C-API args ignored, slot mistaken for index).
-- GetMasterLootCandidate errors with no candidate list (solo /
-- non-master methods) — pcall-guarded, never raises.
function M.MasterLootIndex(slot, playerName)
  if not GetMasterLootCandidate or not playerName then return nil end
  for i = 1, 40 do
    local ok, nm = pcall(GetMasterLootCandidate, i)
    if ok and nm ~= nil and nm ~= "" then
      if nm == playerName then return i end
    else
      local ok2, nm2 = pcall(GetMasterLootCandidate, slot, i)
      if ok2 and nm2 ~= nil and nm2 ~= "" then
        if nm2 == playerName then return i end
      else
        break -- end of the candidate list (either form)
      end
    end
  end
  return nil
end

-- Award the item: corpse take (live) or straight apply (sim/test),
-- then won mark, broadcast, log, print. Handed out = gone: the row
-- leaves the list and the window closes. Awarding ends any open roll
-- for the item FIRST (EndRoll), so deciding off the ... menu can never
-- leave a roll collecting behind the award.
-- invented (rehearsal): fake roller names that must never hit the sheet.
function M.Award(itemID, winnerName, source, invented)
  if not M.RequireML() then return end
  if not itemID or not winnerName or winnerName == "" then
    Z.Print("Pick a recipient first.")
    return
  end
  M.EndRoll(itemID)
  -- Awarded = gone: no finished round left to continue on this item.
  if M.lastRound and M.lastRound.itemID == itemID then M.lastRound = nil end
  local link = "item:" .. tostring(itemID)
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it and it.link then link = it.link end
  end
  -- Live distribution of a CORPSE row needs the corpse OPEN (the
  -- master-loot handoff moves a corpse slot; walked-away corpse =
  -- nothing to hand). Block early with a log and keep the row — the ML
  -- re-loots and awards from the still-open window. Sim rows and
  -- headless awards have no corpse slot: always apply.
  -- Headless note: tests drive the award path with an open detail but
  -- no corpse session (lootOpen false, no slot APIs); only block when
  -- the window holds a LIVE corpse row for this item (slot ~= nil).
  -- Killed-corpse slots are nil, so headless/raid-roll awards apply.
  local row0 = Z.LootWindow and Z.LootWindow.Find(itemID) or nil
  local liveRow = row0 and row0.slot ~= nil
  if source ~= "sim" and not M.lootOpen and liveRow then
    Z.Print("Not awarding " .. tostring(winnerName)
      .. ": no loot open. Loot the corpse again, then award.")
    return false
  end
  -- Sim rows and items with no tracked corpse slot skip the take
  -- (sim queue, /rf rolls, headless award tests). Rows WITH a slot
  -- need the take FIRST — EXCEPT headless: no slot APIs at all means
  -- no call can land, and VerifySlot would read "gone" off an empty
  -- corpse. Live always has the APIs, so live always takes.
  if source ~= "sim" and row0 and row0.slot ~= nil
      and GetNumLootItems and GetLootSlotLink then
    local rc = M.LootCorpseSlot(link, itemID, winnerName, row0.slot)
    if rc == false then return false end
  end
  if not Z.DB then Z.DB = {} end
  if not Z.DB.sheet then Z.DB.sheet = (Z.SRData and Z.SRData.NewSheet and Z.SRData.NewSheet()) or {} end
  source = source or "raid"
  local skipWon = false
  if invented then
    for i = 1, Z.Util.ArrayCount(invented) do
      if invented[i] == winnerName then skipWon = true break end
    end
  end
  if not skipWon then
    -- Sheet log floor: a known below-rare award still loots, broadcasts,
    -- and clears the row — it just leaves no won mark behind.
    local wq = nil
    if row0 then wq = tonumber(row0.quality) end
    if wq == nil and GetItemInfo then
      local _, _, qq = GetItemInfo(tonumber(itemID))
      wq = qq
    end
    if wq == nil and Z.DB.sheet.items then
      local it = Z.DB.sheet.items[itemID]
      if it then wq = tonumber(it.quality) end
    end
    if wq == 0 then wq = nil end -- list default, never a rolled quality
    Z.SRData.MarkWon(Z.DB.sheet, itemID, winnerName, wq)
  end
  if Z.Comm then Z.Comm.BroadcastAward(itemID, winnerName) end
  if Z.DropLog then Z.DropLog.Add(itemID, link, source, "award", winnerName) end
  local disp = M.ChatItem(itemID, link)
  if Z.Comm and Z.Comm.SayGroup and source ~= "sim" then
    Z.Comm.SayGroup(ChatName(winnerName) .. " wins " .. tostring(disp) .. ".")
  else
    Z.Print("Awarded " .. disp .. " to " .. PName(winnerName))
  end
  if Z.SRView then Z.SRView.Refresh() end
  if Z.LootWindow and Z.LootWindow.RemoveItem then Z.LootWindow.RemoveItem(itemID) end
  if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
  if Z.LootWindow and Z.LootWindow.CloseDetail then Z.LootWindow.CloseDetail() end
  -- Boss fully looted after OUR auto-switch? Flip back to group loot.
  M.MaybeGroupAfterBoss(source)
  -- Test queue bookkeeping: an awarded sim row must not stay rollable.
  if Z.Sim then
    if Z.Sim.DropRehearsal and Z.Sim.DropRehearsal(itemID) then
      if Z.Sim.Rehearsing and Z.Sim.Rehearsing()
          and Z.Sim.afterRehearsal then
        Z.Sim.afterRehearsal()
      end
    end
    if source == "sim" then
      if Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(itemID) end
      if Z.Sim.SyncLootWindow then Z.Sim.SyncLootWindow() end
    end
  end
  return true
end

-- Auto loot-method switching (party-leader boss flow, Setup options):
-- mlOnBoss flips to master loot when the leader selects a boss;
-- backToGroup flips back to group loot once the boss is fully looted
-- (every row gone). Only ever acts on the leader's own client, only
-- when WE made the switch (M.autoML), so a manual change by anyone is
-- never yanked back. All client calls pcall-guarded + nil-safe.
M.autoML = false

-- Boss at the cursor? worldboss flag OR high HP. UnitClassification is
-- too weak alone: indoor raid bosses usually report plain elite (and
-- elite can't be the trigger — in raids every trash mob is elite and
-- trash wants group loot). So: worldboss always wins; otherwise the
-- target's max HP must clear BOSS_HP_MIN. Classic numbers: raid bosses
-- bottom out ~200k (ZG priests) up to millions (Naxx); raid trash sits
-- far below — except AQ40 Anubisath sentinels (~300k), which trip the
-- floor too (harmless: AQ40 guilds run ML through trash anyway).
-- Raid-only on top: the flow is a raid flow. Pure shape, WoW globals
-- nil-safe.
M.BOSS_HP_MIN = 100000
function M.IsBossTarget()
  if not (UnitExists and UnitClassification) then return false end
  if not (Z.SRSecurity and Z.SRSecurity.IsInRaid
      and Z.SRSecurity.IsInRaid()) then return false end
  local okE, exists = pcall(UnitExists, "target")
  if not (okE and exists) then return false end
  local okC, cls = pcall(UnitClassification, "target")
  if okC and cls == "worldboss" then return true end
  if not UnitHealthMax then return false end
  local okH, hp = pcall(UnitHealthMax, "target")
  return okH and type(hp) == "number" and hp >= M.BOSS_HP_MIN
end

function M.CanAutoSwitch()
  if not (Z.DB and Z.DB.mlOnBoss) then return false end
  if not (Z.SRSecurity and Z.SRSecurity.AmLeader
      and Z.SRSecurity.AmLeader()) then return false end
  if not (Z.SRSecurity and Z.SRSecurity.IsInGroup
      and Z.SRSecurity.IsInGroup()) then return false end
  return true
end

function M.TrySetLoot(method, masterName)
  if not SetLootMethod then return false end
  if method == "master" then
    local ok = pcall(SetLootMethod, "master", masterName)
    return ok and true or false
  end
  local ok = pcall(SetLootMethod, method)
  return ok and true or false
end

function M.CurrentLootMethod()
  if Z.SRSecurity and Z.SRSecurity.LootMethod then
    local ok, m = pcall(Z.SRSecurity.LootMethod)
    if ok then return m end
  end
  return nil
end

-- Boss threshold (Setup dropdown): the loot threshold applied with the
-- auto-switch to master loot. 1 common .. 4 epic. Pure data + validated
-- setter (headless-testable); the client call runs inside the switch.
M.THRESHOLDS = {
  { value = 1, label = "Common" },
  { value = 2, label = "Uncommon" },
  { value = 3, label = "Rare" },
  { value = 4, label = "Epic" },
}
function M.ThresholdChoices()
  local out = {}
  for i = 1, Z.Util.ArrayCount(M.THRESHOLDS) do
    local t = M.THRESHOLDS[i]
    table.insert(out, { value = t.value,
      label = t.label .. " (" .. t.value .. ")" })
  end
  return out
end
function M.BossThreshold()
  local n = Z.DB and tonumber(Z.DB.bossThreshold) or nil
  if n and n >= 1 and n <= 4 then return math.floor(n) end
  return 4 -- default: bosses drop epics, threshold follows
end
function M.ThresholdLabel(n)
  n = tonumber(n)
  for i = 1, Z.Util.ArrayCount(M.THRESHOLDS) do
    local t = M.THRESHOLDS[i]
    if t.value == n then return t.label .. " (" .. t.value .. ")" end
  end
  return "Epic (4)"
end
-- Validated setter: stores the preference (1-4). Anything else refuses.
-- Applies live ONLY through the boss auto-switch, never here.
function M.SetBossThreshold(n)
  n = tonumber(n)
  if not (n and n >= 1 and n <= 4) then return false end
  n = math.floor(n)
  if Z.DB then Z.DB.bossThreshold = n end
  return true
end
function M.CurrentThreshold()
  if GetLootThreshold then
    local ok, t = pcall(GetLootThreshold)
    if ok and type(t) == "number" then return t end
  end
  return nil
end
function M.TrySetThreshold(n)
  if not SetLootThreshold then return false end
  local ok = pcall(SetLootThreshold, n)
  return ok and true or false
end

-- Leader selected a boss: flip to master loot (once — already-master
-- or already-switched is a no-op). Master is self: only the leader's
-- own client runs this, so handing master to self is always right.
-- The Setup threshold rides along (previous one remembered for the
-- switch-back).
function M.MaybeMasterOnBoss()
  if not M.CanAutoSwitch() then return false end
  if M.autoML then return false end
  if not M.IsBossTarget() then return false end
  if M.CurrentLootMethod() == "master" then return false end
  local me = nil
  if UnitName then local ok, nm = pcall(UnitName, "player") if ok then me = nm end end
  if M.TrySetLoot("master", me) then
    M.autoML = true
    M.prevThreshold = M.CurrentThreshold()
    local want = M.BossThreshold()
    if M.TrySetThreshold(want) then
      Z.Print("Boss selected — loot method set to master loot, threshold "
        .. M.ThresholdLabel(want) .. ".")
    else
      Z.Print("Boss selected — loot method set to master loot.")
    end
    return true
  end
  return false
end

-- A row left the list (award) or was marked ignored: with backToGroup on
-- and OUR switch active, a finished list (empty, or only ignored rows)
-- means the boss is fully looted — flip back to group loot and restore
-- the remembered threshold. Sim rows never count (no corpse, no method).
function M.MaybeGroupAfterBoss(source)
  if source == "sim" then return false end
  if not M.autoML then return false end
  if not (Z.DB and Z.DB.backToGroup) then return false end
  if not (Z.SRSecurity and Z.SRSecurity.AmLeader
      and Z.SRSecurity.AmLeader()) then return false end
  if Z.LootWindow and Z.LootWindow.LootingFinished
      and not Z.LootWindow.LootingFinished() then return false end
  if M.TrySetLoot("group") then
    M.autoML = false
    if M.prevThreshold then
      M.TrySetThreshold(M.prevThreshold)
      M.prevThreshold = nil
    end
    Z.Print("Boss fully looted — loot method set back to group loot.")
    return true
  end
  return false
end

-- Ignore the item: mark the row ignored (it stays listed) with no award,
-- no won mark, no corpse take, no roll history. Ends any open roll for
-- the item FIRST (same as awarding). The item stays on the corpse for
-- manual handling; the audit trail records it as ignored. When nothing
-- actionable remains (empty list, or only ignored rows), looting is
-- finished: the detail closes and the boss auto-switch flips back to
-- group loot when it should. Sim rows advance the queue like an award
-- (an ignored sim row must not stay rollable either).
function M.Ignore(itemID, source)
  if not M.RequireML() then return end
  if not itemID then
    Z.Print("Nothing to ignore.")
    return
  end
  M.EndRoll(itemID)
  -- Ignored = gone: no finished round left to continue on this item.
  if M.lastRound and M.lastRound.itemID == itemID then M.lastRound = nil end
  local link = "item:" .. tostring(itemID)
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it and it.link then link = it.link end
  end
  source = source or "raid"
  if Z.DropLog then Z.DropLog.Add(itemID, link, source, "ignored", nil) end
  local disp = M.ChatItem(itemID, link)
  Z.Print("Ignored " .. disp .. " (left on the corpse).")
  if Z.LootWindow and Z.LootWindow.MarkIgnored then
    Z.LootWindow.MarkIgnored(itemID)
  end
  if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
  -- Looting finished (no rows left, or only ignored rows): close the
  -- whole window and the loot via the shared close-out — CloseDetail
  -- alone would strand the overview open on ignored leftovers.
  -- (Ignore just marked a row: that IS the drop-like event here.)
  if Z.LootWindow and Z.LootWindow.CloseIfFinished then
    Z.LootWindow.CloseIfFinished(true)
  end
  M.MaybeGroupAfterBoss(source)
  -- Queue bookkeeping: an ignored sim row must not stay rollable,
  -- so its queue entry drops (the row itself stays listed, ignored).
  if Z.Sim then
    -- Plain sim entries never rehearse: just drop the queue entry.
    if Z.Sim.DropSim then Z.Sim.DropSim(itemID) end
    if Z.Sim.DropRehearsal and Z.Sim.DropRehearsal(itemID) then
      if Z.Sim.Rehearsing and Z.Sim.Rehearsing()
          and Z.Sim.afterRehearsal then
        Z.Sim.afterRehearsal()
      end
    end
    if source == "sim" then
      if Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(itemID) end
    end
  end
  return true
end

-- Hourglass Sand distributor (item 19183): the ML hands a sand stack to
-- the raid member with the lowest running total, so sand evens out over
-- the raid. Ledger lives in Z.DB.sand ({ [name] = count }, SavedVariables)
-- and is independent of the SR sheet: sand is never SR'd, never won-
-- marked, never roll-logged. One corpse slot = one handoff = the whole
-- stack to a single recipient; fairness comes from the ledger, not from
-- splitting (a corpse slot cannot be split).
M.SAND_ITEM_ID = 19183
M.SAND_NAME = "Hourglass Sand"
function M.IsSandItem(itemID)
  return tonumber(itemID) == M.SAND_ITEM_ID
end
-- Ledger table, created on demand. Falls back to a transient table when
-- there is no DB (headless tests driving the flow without InitDB).
M._sandFallback = {}
function M.SandLedger()
  if Z.DB then
    Z.DB.sand = Z.DB.sand or {}
    return Z.DB.sand
  end
  return M._sandFallback
end
function M.SandTotal(ledger, name)
  return tonumber((ledger or {})[name]) or 0
end
-- Pick the recipient: lowest ledger total, ties broken by roster order
-- (stable, same ethos as the frozen raid-roll roster). Pure.
function M.SandPick(roster, ledger)
  local best, bestTotal = nil, nil
  for i = 1, Z.Util.ArrayCount(roster or {}) do
    local nm = roster[i]
    if nm and nm ~= "" then
      local t = M.SandTotal(ledger, nm)
      if best == nil or t < bestTotal then
        best, bestTotal = nm, t
      end
    end
  end
  return best
end
-- Sorted ledger for display: highest total first, name tiebreak. Pure.
function M.SandTotals(ledger)
  local out = {}
  for nm, c in pairs(ledger or {}) do
    table.insert(out, { name = nm, count = tonumber(c) or 0 })
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return (a.name or "") < (b.name or "")
  end)
  return out
end
-- Distribute one sand row: lowest-ledger raider takes the whole stack
-- via the master-loot handoff, ledger += quantity, announced + logged.
-- Ends any open roll for the item first (same as awarding). Returns
-- true on success, false when refused (row kept).
function M.SandDistribute(itemID, source)
  if not M.RequireML() then return false end
  itemID = Z.Util.ItemID(itemID)
  if not itemID then
    Z.Print("Nothing to distribute.")
    return false
  end
  if not M.IsSandItem(itemID) then
    Z.Print("Sand distribution is only for " .. M.SAND_NAME .. ".")
    return false
  end
  local roster = M.RaidRoster()
  if Z.Util.ArrayCount(roster) == 0 then
    Z.Print("Nobody in the raid to give sand to.")
    return false
  end
  local ledger = M.SandLedger()
  local winnerName = M.SandPick(roster, ledger)
  if not winnerName or winnerName == "" then
    Z.Print("Nobody in the raid to give sand to.")
    return false
  end
  M.EndRoll(itemID)
  -- Distributed = gone: no finished round left to continue on this item.
  if M.lastRound and M.lastRound.itemID == itemID then M.lastRound = nil end
  local link = "item:" .. tostring(itemID)
  local qty = 1
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it then
      if it.link then link = it.link end
      if tonumber(it.quantity) and tonumber(it.quantity) > 0 then
        qty = math.floor(tonumber(it.quantity))
      end
    end
  end
  -- Same corpse-open gate as the award path: walked-away corpse means
  -- no handoff can land; re-loot and distribute from the open window.
  -- Headless rows (no slot) skip the gate like headless awards do.
  local row0 = Z.LootWindow and Z.LootWindow.Find(itemID) or nil
  local liveRow = row0 and row0.slot ~= nil
  if source ~= "sim" and not M.lootOpen and liveRow then
    Z.Print("Not distributing sand to " .. tostring(winnerName)
      .. ": no loot open. Loot the corpse again, then distribute.")
    return false
  end
  if source ~= "sim" and row0 and row0.slot ~= nil
      and GetNumLootItems and GetLootSlotLink then
    local rc = M.LootCorpseSlot(link, itemID, winnerName)
    if rc == false then return false end
  end
  source = source or "raid"
  ledger[winnerName] = M.SandTotal(ledger, winnerName) + qty
  if Z.DropLog then Z.DropLog.Add(itemID, link, source, "sand", winnerName) end
  local disp = M.ChatItem(itemID, link)
  local line = "Sand x" .. tostring(qty) .. " -> " .. ChatName(winnerName)
    .. " (" .. tostring(ledger[winnerName]) .. " total)"
  if Z.Comm and Z.Comm.SayGroup and source ~= "sim" then
    Z.Comm.SayGroup(line .. " [" .. tostring(disp) .. "]")
  else
    Z.Print(line)
  end
  if Z.SRView then Z.SRView.Refresh() end
  if Z.LootWindow and Z.LootWindow.RemoveItem then Z.LootWindow.RemoveItem(itemID) end
  if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
  if Z.LootWindow and Z.LootWindow.CloseDetail then Z.LootWindow.CloseDetail() end
  M.MaybeGroupAfterBoss(source)
  -- Queue bookkeeping, same as the award path.
  if Z.Sim then
    if Z.Sim.DropRehearsal and Z.Sim.DropRehearsal(itemID) then
      if Z.Sim.Rehearsing and Z.Sim.Rehearsing()
          and Z.Sim.afterRehearsal then
        Z.Sim.afterRehearsal()
      end
    end
    if source == "sim" then
      if Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(itemID) end
      if Z.Sim.SyncLootWindow then Z.Sim.SyncLootWindow() end
    end
  end
  return true
end
-- /zl sand: print the ledger (highest first, grand total last).
-- /zl sand reset: clear it (solo always; in group ML/leader only,
-- same gate as the roll-log reset). Returns counts for feedback.
function M.SandReset()
  local ledger = M.SandLedger()
  local nNames, nUnits = 0, 0
  for _, c in pairs(ledger) do
    nNames = nNames + 1
    nUnits = nUnits + (tonumber(c) or 0)
  end
  for _nm in pairs(ledger) do ledger[_nm] = nil end
  return { names = nNames, units = nUnits }
end
function M.SandCommand(argText)
  local sub = Z.Util and Z.Util.Trim(argText or "") or tostring(argText or "")
  if sub == "" then
    local totals = M.SandTotals(M.SandLedger())
    if Z.Util.ArrayCount(totals) == 0 then
      Z.Print("No sand distributed yet.")
      return true
    end
    local grand = 0
    for i = 1, Z.Util.ArrayCount(totals) do
      local t = totals[i]
      grand = grand + t.count
      Z.Print("Sand: " .. tostring(t.name) .. " x" .. tostring(t.count))
    end
    Z.Print("Sand total: x" .. tostring(grand))
    return true
  end
  if string.lower(sub) == "reset" then
    local allowed = false
    if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then
      allowed = true
    elseif Z.SRSecurity and Z.SRSecurity.CanBroadcast and Z.SRSecurity.CanBroadcast() then
      allowed = true
    end
    if not allowed then
      Z.Print("Only the master looter or raid leader can reset the sand ledger.")
      return false
    end
    local c = M.SandReset()
    Z.Print("Sand ledger cleared (" .. tostring(c.units) .. " sand across "
      .. tostring(c.names) .. " raiders).")
    return true
  end
  Z.Print("Usage: /zl sand [reset]")
  return false
end

-- Old names, same single award path above. invented resolves off the
-- open roll (rolled rehearsal) or the rehearsal queue (pre-roll award),
-- so fake names never hit the sheet either way.
function M.AwardInvented(itemID)
  -- The window owns it: stamped at roll open, survives the finish.
  local d = Z.LootWindow and Z.LootWindow.detail
  if d and d.itemID == itemID and d.invented then return d.invented end
  if M.roll and M.roll.itemID == itemID then return M.roll.invented end
  if Z.Sim and Z.Sim.InventedFor then return Z.Sim.InventedFor(itemID) end
  return nil
end
function M.AwardDirect(itemID, winnerName, source)
  return M.Award(itemID, winnerName, source, M.AwardInvented(itemID))
end
function M.AwardChosen(choice, itemID, source)
  local nm = choice and choice.name
  itemID = itemID or M.AwardItemID()
  if not itemID or not nm or nm == "" then
    Z.Print("Pick a recipient first.")
    return
  end
  if not source then
    local row = Z.LootWindow and Z.LootWindow.Find(itemID) or nil
    source = (row and row.source == "sim") and "sim" or "raid"
  end
  return M.Award(itemID, nm, source, M.AwardInvented(itemID))
end
-- Award context reads off the OPEN window, not stored state. Item = the
-- open detail's item (fallback: explicit id).
function M.AwardItemID(itemID)
  if itemID then return itemID end
  if Z.LootWindow and Z.LootWindow.detail then
    return Z.LootWindow.detail.itemID
  end
  return nil
end

-- Universal loot scan: whoever opens a corpse runs the window — solo,
-- party/raid, any loot method. EVERY corpse slot gets a row (RollFor
-- parity): coin first, then roll-worthy items (quality >= the party's
-- GetLootThreshold, SR/HR badge, announce + log `loot`/`seen`), then
-- below-threshold leftovers (grey quality 0 always) as one-click free
-- rows that loot straight to the player via LootSlot, even under master
-- loot. No Blizzard fallback — our window IS the loot UI.
-- Further items go through /rf (or the sim loot window in sim).
-- Scan one corpse slot into a row entry (nil when the slot is empty or
-- unreadable). Coin slots carry no link: { itemID="Coin" }.
-- threshold: the PARTY's loot threshold (GetLootThreshold: 1 common ..
-- 4 epic). Nil = read it live via M.LootThreshold().
-- Row kinds: coin (always click-loot) | roll (>= threshold: SR detail,
-- master-lootable under master loot) | group (group-loot method AND
-- at/above threshold: Blizzard's Need/Greed frames own it — we list it
-- but never loot it) | free (below threshold, grey quality 0 included:
-- one click loots straight to the player).
-- The PARTY's loot threshold (GetLootThreshold: 1 common .. 4 epic):
-- the single cutoff for roll rows. At/above it rolls (master loot hands
-- it out, group loot Needs/Greeds it); below it — grey quality 0 always
-- — loots straight to the player via LootSlot, in any loot method.
-- Single reader so scan, rescan, and open can never disagree; falls back
-- to the client default (uncommon) headless or when the API is absent.
function M.LootThreshold()
  if Z.LootWindow and Z.LootWindow.GroupRollThreshold then
    return Z.LootWindow.GroupRollThreshold()
  end
  if GetLootThreshold then
    local ok, t = pcall(GetLootThreshold)
    if ok and type(t) == "number" then return t end
  end
  return (Z.Limits and Z.Limits.LOOT_THRESHOLD_DEFAULT) or 2
end
function M.ScanSlot(slot, threshold)
  if not GetNumLootItems then return nil end
  -- Coin first: no link, texture + amount text from the slot info.
  -- Zero-copper corpses still carry an (empty) coin slot client-side —
  -- skip it so wolves etc. don't grow a phantom "0 Copper" row.
  -- Texture fallback chain: slot texture, then the stock gold-coin icon
  -- (never the "?" placeholder — coin always has art on 1.12).
  if Z.LootWindow and Z.LootWindow.IsCoinSlot
      and Z.LootWindow.IsCoinSlot(slot) then
    local tex, slotName = nil, nil
    if GetLootSlotInfo then
      local a, b = GetLootSlotInfo(slot)
      if type(a) == "string" then tex = a end
      if type(b) == "string" then slotName = b end
    end
    if Z.LootWindow.IsEmptyCoin and Z.LootWindow.IsEmptyCoin(slotName) then
      return nil
    end
    tex = tex or "Interface\\Icons\\INV_Misc_Coin_01"
    return { itemID = "Coin", link = nil, quality = 0,
      texture = tex, quantity = nil, slot = slot,
      name = slotName or "Coin", coin = true }
  end
  if not GetLootSlotLink then return nil end
  local link = GetLootSlotLink(slot)
  if not link then return nil end
  -- RollFor reads everything off the slot: GetLootSlotInfo gives
  -- texture + quantity in one call, GetItemInfo gives quality.
  -- Quality prefers the SLOT's 4th return (always present client-side)
  -- over the item cache (uncached GetItemInfo lies 0 and would
  -- misclassify an epic as free loot).
  local tex, qty, slotName, slotQ = nil, nil, nil, nil
  if GetLootSlotInfo then
    -- Vanilla: (texture, name, quantity, quality); retail adds args.
    local a, b, c, d = GetLootSlotInfo(slot)
    tex, slotName, qty = a, b, c
    if type(qty) ~= "number" then qty = nil end
    if type(tex) ~= "string" then tex = nil end
    if type(d) == "number" then slotQ = d end
  end
  local q = slotQ
  if q == nil and GetItemInfo then
    local _, _, qq = GetItemInfo(link)
    q = qq
  end
  q = tonumber(q) or 0
  local entry = { link = link, quality = q,
    texture = tex, quantity = qty, slot = slot, name = slotName }
  entry.itemID = Z.Util.ItemID(link)
  -- Poor (quality 0) is NEVER a roll row: always free, whatever the
  -- party threshold reads (even 0). Matches the bag-addon scale the
  -- user sees (grey = 0 = below everything).
  if q <= 0 then
    entry.free = true
    return entry
  end
  local thresh = threshold or M.LootThreshold()
  if q >= thresh then
    if Z.LootWindow and Z.LootWindow.IsGroupRollItem
        and Z.LootWindow.IsGroupRollItem(q) then
      entry.group = true -- Blizzard's Need/Greed owns it: list, don't touch
      return entry
    end
    return entry -- roll row (badge added below)
  end
  -- Below threshold (grey quality 0 always lands here): loots straight
  -- to the player via LootSlot, even under master loot.
  entry.free = true
  return entry
end

-- Re-scan the corpse and patch the TRACKED rows (LOOT_SLOT_CLEARED /
-- Close path): drop rows whose slots went empty, keep badge/status of the
-- rest, append genuinely new slots. M.items here is the LootWindow list
-- (MasterLootUI owns no row list of its own). Returns the live row count.
-- Nil-safe headless.
-- Corpse-open flag: true between LOOT_OPENED and LOOT_CLOSED. A rescan
-- with no open corpse must keep every row — GetNumLootItems reads empty
-- with no corpse, which otherwise looks exactly like "all looted" and
-- wipes the window (the reported walk-away wipe).
M.lootOpen = false
function M.RescanLeftovers()
  local rows = (Z.LootWindow and Z.LootWindow.items) or M.items
  local before = Z.Util.ArrayCount(rows)
  if not GetNumLootItems then return Z.Util.ArrayCount(rows) end
  if not M.lootOpen then return Z.Util.ArrayCount(rows) end
  local threshold = M.LootThreshold()
  local n = GetNumLootItems()
  -- Slot NUMBERS shift when a slot is looted (old slot 2 becomes slot 1),
  -- so reconciliation matches by identity multiset, not slot index:
  -- corpse entries { key, entry } in slot order; each tracked row consumes
  -- one equal-key corpse entry. Rows with no match left the corpse.
  -- key: "coin" | "id:<itemID>" (free rows included — a grey is a grey).
  local corpse = {}
  for slot = 1, n do
    local e = M.ScanSlot(slot, threshold)
    if e then
      local key = e.coin and "coin"
        or ((e.group and "group:") or "id:") .. tostring(e.itemID)
      table.insert(corpse, { key = key, entry = e })
    end
  end
  local function rowKey(it)
    if not it then return nil end
    if it.coin then return "coin" end
    return ((it.group and "group:") or "id:") .. tostring(it.itemID)
  end
  -- First pass: match armed click-to-loot rows. An armed row WITH a corpse
  -- match is a failed LootSlot (locked, full bags, range): keep the row
  -- (retryable), un-dim it. An armed row with NO match is a confirmed
  -- loot: drop it. Arms always clear — and a confirm also clears the
  -- kill-switch watch for that slot (a working path must never trip it).
  local armed = {}
  if M.pendingLoot then
    for slot in pairs(M.pendingLoot) do armed[slot] = true end
    M.pendingLoot = nil
  end
  local function clearSilentWatch(slot, itemID)
    local W = Z.LootWindow and Z.LootWindow.silentLootArms
    if not W then return end
    for i = Z.Util.ArrayCount(W), 1, -1 do
      local a = W[i]
      if a and (slot == nil or a.slot == slot)
          and (itemID == nil or a.itemID == itemID) then
        table.remove(W, i)
      end
    end
  end
  local corpseUsed = {}
  local keepRow = {}
  for i = 1, Z.Util.ArrayCount(rows) do
    local it = rows[i]
    local matched = nil
    if it then
      for c = 1, Z.Util.ArrayCount(corpse) do
        if not corpseUsed[c] and corpse[c].key == rowKey(it) then
          matched = c break
        end
      end
    end
    if matched then
      corpseUsed[matched] = true
      keepRow[i] = true
      -- Refresh the slot number: slots shift after each loot.
      rows[i].slot = corpse[matched].entry.slot
      -- Armed + still present = FAILED call (server answered by keeping
      -- the slot), never silent: clear its kill-switch watch. A retry is
      -- a fresh first arm, not a second silent strike.
      if armed[rows[i].slot] or (it and armed[it.slot]) then
        clearSilentWatch(nil, it and it.itemID)
      end
    elseif it and armed[it.slot] then
      keepRow[i] = false -- confirmed click: row leaves
      clearSilentWatch(it.slot, it.itemID) -- working path: never trip switch
      if Z.LootWindow and Z.LootWindow.DropParked then
        Z.LootWindow.DropParked(it.itemID)
      end
    elseif it then
      keepRow[i] = false -- looted outside our rows: row leaves
    else
      keepRow[i] = false
    end
  end
  local fresh = {}
  for c = 1, Z.Util.ArrayCount(corpse) do
    if not corpseUsed[c] then table.insert(fresh, corpse[c].entry) end
  end
  for i = Z.Util.ArrayCount(rows), 1, -1 do
    if not keepRow[i] then table.remove(rows, i) end
  end
  -- Failed clicks (armed but still on the corpse) return to open state.
  for i = 1, Z.Util.ArrayCount(rows) do
    local it = rows[i]
    if it and it.status == "done" then it.status = "open" end
  end
  -- Badge + append genuinely new slots (same shaping as OnLootOpened).
  for i = 1, Z.Util.ArrayCount(fresh) do
    local e = fresh[i]
    local badge = ""
    if not e.coin and not e.free and not e.group and e.itemID
        and Z.DB and Z.DB.sheet and Z.SRData.ReserveBadge then
      badge = Z.SRData.ReserveBadge(Z.DB.sheet, e.itemID)
    end
    e.badge = badge
    e.index = Z.Util.ArrayCount(rows) + 1
    e.status = "open"
    e.source = "loot"
    if Z.LootWindow and Z.LootWindow.EnsureResolved then
      Z.LootWindow.EnsureResolved(e)
    end
    table.insert(rows, e)
  end
  -- Rows dropped by this reconcile? A reopen-rescan that changed nothing
  -- must NEVER close (the looter gets ignored rows back for a second
  -- chance to roll them); only the transition to finished closes.
  local dropped = Z.Util.ArrayCount(rows) ~= before
  for i = 1, Z.Util.ArrayCount(rows) do rows[i].index = i end
  if Z.LootWindow and Z.LootWindow.Refresh then Z.LootWindow.Refresh() end
  -- Reconciling may have dropped the last actionable row while ignored
  -- rows stay (ignore-first, loot/award the rest): close out here too.
  if Z.LootWindow and Z.LootWindow.CloseIfFinished then
    Z.LootWindow.CloseIfFinished(dropped)
  end
  return Z.Util.ArrayCount(rows)
end

-- Row-only corpse cache, keyed by corpse key (guid: preferred,
-- fp: fallback — see CorpseKey). NEVER persisted: plain module tables,
-- empty at load, no SavedVariables touch. Each entry owns EVERYTHING for
-- one not-fully-looted corpse so walk-away-and-back resumes exactly:
-- rows (with statuses), open detail, click arms. Sim rows
-- (source "sim", no corpse) live outside the cache on the live tables
-- as before.
-- Entry: { key, guid, target, rows, detail, pendingLoot }
-- Bounded: abandoned corpses (parked, never re-looted) evict oldest-first
-- past M.CORPSE_CACHE_MAX. Rows only either way — never persisted.
M.CORPSE_CACHE_MAX = 5
M.corpseCache = {}
M.corpseOrder = {}
M.lootGUID = nil -- pinned corpse GUID (nil when client offers none)
M.lootTarget = nil -- pinned loot target name (fallback path)
M.lootKey = nil -- active corpse key (cache key while a corpse is open)
-- Stash the open corpse's rows into its cache entry (copied row-wise
-- so later mutation can't alias).
local function snapshotRows(rows)
  local out = {}
  for i = 1, Z.Util.ArrayCount(rows) do
    local r = rows[i]
    if r then
      local c = {}
      for k, v in pairs(r) do c[k] = v end
      table.insert(out, c)
    end
  end
  return out
end
-- Stash the open corpse's ROWS so walking away and back resumes the
-- list. Rolls never park: if the roll window is open it stays live and
-- keeps collecting (the window IS the roll); closing it ends the roll.
-- Detail parks with the rows (a rolling detail keeps its countdown);
-- awarded rows already left the list.
function M.ParkCorpse()
  local key = M.lootKey
  if not key then return end
  local W = Z.LootWindow
  M.corpseCache = M.corpseCache or {}
  M.corpseOrder = M.corpseOrder or {}
  for i = Z.Util.ArrayCount(M.corpseOrder), 1, -1 do
    if M.corpseOrder[i] == key then table.remove(M.corpseOrder, i) end
  end
  table.insert(M.corpseOrder, key)
  while Z.Util.ArrayCount(M.corpseOrder) > (M.CORPSE_CACHE_MAX or 5) do
    local oldest = table.remove(M.corpseOrder, 1)
    if oldest then M.corpseCache[oldest] = nil end
  end
  M.corpseCache[key] = {
    key = key, guid = M.lootGUID, target = M.lootTarget,
    rows = W and snapshotRows(W.items) or {},
    detail = W and W.detail or nil,
    pendingLoot = M.pendingLoot,
  }
end
-- Restore a cached corpse's rows onto the live list. Caller reconciles.
-- TAKE semantics: the entry leaves the cache on restore (the live tables
-- own the state from here; walking away re-parks fresh). Stale copies
-- must never linger beside live state.
-- Restore a cached corpse's rows onto the live list. TAKE semantics:
-- the entry leaves the cache on restore. The roll (if any) was never
-- parked and needs no restore: an open window kept collecting, a closed
-- one ended its roll.
function M.RestoreCorpse(key)
  local e = M.corpseCache and M.corpseCache[key]
  if not e then return false end
  M.corpseCache[key] = nil
  if M.corpseOrder then
    for i = Z.Util.ArrayCount(M.corpseOrder), 1, -1 do
      if M.corpseOrder[i] == key then table.remove(M.corpseOrder, i) end
    end
  end
  local W = Z.LootWindow
  if W then
    if Z.Util.ArrayCount(W.items) == 0 then
      W.items = snapshotRows(e.rows)
    end
    if not W.detail then W.detail = e.detail end
  end
  if not M.pendingLoot then M.pendingLoot = e.pendingLoot end
  M.lootGUID = e.guid
  M.lootTarget = e.target
  M.lootKey = e.key
  return true
end
-- Drop a corpse from the cache once fully looted (no rows left after a
-- reconcile, or Close with an empty list). Distributed corpses must not
-- linger — the cache is for NOT-fully-looted mobs only.
function M.ForgetCorpse(key)
  if M.corpseCache and key then M.corpseCache[key] = nil end
  if M.corpseOrder and key then
    for i = Z.Util.ArrayCount(M.corpseOrder), 1, -1 do
      if M.corpseOrder[i] == key then table.remove(M.corpseOrder, i) end
    end
  end
end
function M.OnLootOpened()
  if not GetNumLootItems then return end
  M.lootOpen = true -- loot is definitionally open inside this handler
  local key = M.LiveCorpseKey()
  -- Cached corpse (walked away, now back): restore its rows, then
  -- reconcile against the live corpse. Rolls never parked: an open
  -- window kept collecting, a closed one ended its roll.
  if key and M.corpseCache and M.corpseCache[key] then
    if M.lootKey and M.lootKey ~= key then M.ParkCorpse() end
    M.RestoreCorpse(key)
    M.RescanLeftovers()
    if Z.LootWindow then
      if Z.Util.ArrayCount(Z.LootWindow.items) == 0 then
        M.ForgetCorpse(key)
        if M.lootKey == key then
          M.lootKey, M.lootGUID, M.lootTarget = nil, nil, nil
        end
        Z.LootWindow.Hide()
      else
        Z.LootWindow.Show()
        Z.Print("Loot window resumed.")
      end
    end
    return
  end
  -- New corpse while another is open: park the active one's rows,
  -- then build fresh below.
  if M.lootKey and M.lootKey ~= key then M.ParkCorpse() end
  local threshold = M.LootThreshold()
  local found, coin, free, grouped = {}, {}, {}, {}
  local n = GetNumLootItems()
  for slot = 1, n do
    local e = M.ScanSlot(slot, threshold)
    if e then
      if e.coin then table.insert(coin, e)
      elseif e.group then table.insert(grouped, e)
      elseif e.free then table.insert(free, e)
      else table.insert(found, e) end
    end
  end
  if Z.Util.ArrayCount(found) == 0
      and Z.Util.ArrayCount(coin) == 0
      and Z.Util.ArrayCount(free) == 0
      and Z.Util.ArrayCount(grouped) == 0 then
    return -- corpse unreadable/empty: nothing to cover, stay out of the way
  end
  -- Pysanka-style drop call (raid-roll parity): mob name + count, then
  -- one numbered line per roll item. Full clickable item links —
  -- shift-clickable, hover tooltip, quality-colored in every client.
  -- Target pins below; read the name NOW (re-targeting later loses it).
  local mobName = nil
  if UnitName then
    local ok, nm = pcall(UnitName, "target")
    if ok and nm and nm ~= "" then mobName = nm end
  end
  mobName = mobName or M.lootTarget or "Loot"
  if Z.Util.ArrayCount(found) > 0 and Z.Comm and Z.Comm.WarnGroup then
    Z.Comm.WarnGroup(mobName .. " dropped " .. Z.Util.ArrayCount(found)
      .. " item" .. (Z.Util.ArrayCount(found) == 1 and ":" or "s:"))
    for i = 1, Z.Util.ArrayCount(found) do
      local f = found[i]
      Z.Comm.WarnGroup(i .. ". " .. M.ChatItem(Z.Util.ItemID(f.link), f.link, f.quality))
    end
  end
  for i = 1, Z.Util.ArrayCount(found) do
    local f = found[i]
    if Z.DropLog then Z.DropLog.Add(Z.Util.ItemID(f.link), f.link, "loot", "seen", nil) end
  end
  -- Fresh corpse: the previous window (if any) closes first — an open
  -- roll ends with it — then the new rows build below. Guarded: closing
  -- must never abort the scan (a corpse with loot open takes priority).
  if Z.LootWindow and Z.LootWindow.CloseDetail then
    pcall(Z.LootWindow.CloseDetail)
  end
  -- Ours is the loot window now — UNLESS the kill-switch stood us down
  -- (persisted lootTakeover=false): then stay out of the way entirely so
  -- Blizzard's frame handles the corpse (no rows, no detach, no announce
  -- spam — the stock UI is the loot UI until the user re-arms).
  if Z.LootWindow and not Z.LootWindow.TakeoverWanted() then return end
  -- (Re-)detach Blizzard's frame — hiding once is not enough, FrameXML
  -- re-shows it on every loot — while our rows cover this corpse.
  -- Detach is idempotent (safe to repeat per loot).
  if Z.LootWindow and Z.LootWindow.DetachBlizzardLoot then
    pcall(Z.LootWindow.DetachBlizzardLoot)
  end
  -- Pin the corpse for the walk-away-and-back flow (GUID > name +
  -- fingerprint). GUID survives re-targeting; name does not.
  M.lootGUID = M.TargetGUID()
  if UnitName then
    local ok, nm = pcall(UnitName, "target")
    M.lootTarget = (ok and nm) or nil
  else
    M.lootTarget = nil
  end
  M.lootKey = M.LiveCorpseKey()
  -- RollFor-style loot window: coin first, roll rows next, group-roll
  -- items (Blizzard's Need/Greed owns those) after, free leftovers last.
  -- The ML works each roll row from the list; coin/free rows loot on
  -- click; group rows are display-only until Blizzard's roll resolves.
  if Z.LootWindow then
    local rows = {}
    local function push(e, badge)
      table.insert(rows, { itemID = e.itemID, link = e.link,
        name = e.name, texture = e.texture,
        quality = e.quality, quantity = e.quantity,
        slot = e.slot, badge = badge or "", coin = e.coin,
        free = e.free, group = e.group })
    end
    for i = 1, Z.Util.ArrayCount(coin) do push(coin[i]) end
    for i = 1, Z.Util.ArrayCount(found) do
      local id = Z.Util.ItemID(found[i].link)
      local badge = ""
      if Z.DB and Z.DB.sheet and id and Z.SRData.ReserveBadge then
        badge = Z.SRData.ReserveBadge(Z.DB.sheet, id)
      end
      push(found[i], badge)
    end
    for i = 1, Z.Util.ArrayCount(grouped) do push(grouped[i], "ROLL") end
    for i = 1, Z.Util.ArrayCount(free) do push(free[i]) end
    Z.LootWindow.SetItems(rows, "loot")
    Z.LootWindow.Show("Boss loot")
  end
  Z.Print("Loot window open — click a row, then Award / ... / Close.")
  -- Solo rehearsal takeover: queue every non-coin row for the invented-
  -- roller pipeline and auto-play the head. No-ops unless the flag is on
  -- (StartRehearsal guards solo/idle/rows/sheet-module itself).
  if Z.Sim and Z.Sim.StartRehearsal then
    pcall(Z.Sim.StartRehearsal)
  end
end

function M.OnEvent(event, a1, _a2)
  if event == "CHAT_MSG_SYSTEM" and M.roll then
    -- "Name rolls 42 (1-100)" lands on the open roll, or nowhere.
    M.IntakeChatRoll(a1)
  elseif event == "LOOT_OPENED" then
    M.lootOpen = true
    M.OnLootOpened()
  elseif event == "LOOT_CLOSED" then
    M.lootOpen = false
  elseif event == "PLAYER_TARGET_CHANGED" then
    -- Party-leader boss flow: selecting a boss flips to master loot
    -- (Setup option, leader only, no-op unless everything lines up).
    M.MaybeMasterOnBoss()
  elseif event == "LOOT_BIND_CONFIRM" then
    -- BoP take: confirm every armed click-to-loot slot. a1 is the slot
    -- on 1.12 (nil-safe: confirm all armed slots when it isn't).
    if ConfirmLootSlot then
      if type(a1) == "number" and M.pendingLoot and M.pendingLoot[a1] then
        pcall(ConfirmLootSlot, a1)
      elseif M.pendingLoot then
        for slot in pairs(M.pendingLoot) do pcall(ConfirmLootSlot, slot) end
      end
    end
  elseif event == "UI_ERROR_MESSAGE" then
    -- A dead loot call (locked, full bags, range, coin-in-master-mode)
    -- must NEVER strand a dimmed row: drop the arms AND un-dim every
    -- "done" row back to open immediately (don't wait for a rescan that
    -- may never come — no LOOT_SLOT_CLEARED fires on failure). The client
    -- already shows the error itself; stay quiet here. Also drops the
    -- kill-switch watch: a REFUSED call is answered (not silent), so it
    -- must never count toward the dead-path trip.
    M.pendingLoot = nil
    if Z.LootWindow then Z.LootWindow.silentLootArms = nil end
    if Z.LootWindow and Z.LootWindow.items then
      local touched = false
      for i = 1, Z.Util.ArrayCount(Z.LootWindow.items) do
        local it = Z.LootWindow.items[i]
        if it and it.status == "done" then it.status = "open" touched = true end
      end
      if touched and Z.LootWindow.Refresh then Z.LootWindow.Refresh() end
    end
  end
end
