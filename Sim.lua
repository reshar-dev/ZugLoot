-- ZugLoot/Sim.lua
-- Test rolls for the master-loot window: /zl sim <item> [n], /zl simboss,
-- /zl simraid, /zl simstop. Sim is ONLY a way to test master looting:
-- it opens the SAME roll window the raid uses, through the SAME
-- MasterLootUI roll (BeginRoll), with fake rolls landing instantly
-- alongside any real ones. No timers, no queues that outlive the window,
-- no background anything.
--
-- How it works: a test entry precomputes fake rolls (Resolver.FakeRolls).
-- RequestRoll opens the loot-window detail, starts the live roll, and
-- feeds every fake straight into MasterLootUI.AddRoll — no delay. The ML
-- finishes/awards exactly like a live roll.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Sim = M

M.pending = {} -- queued { itemID, link, rolls } (boss/raid staging)
M.FakeCount = nil -- tests pin the fake-roll count through here.
M.running = false -- a staged run is in progress (queue non-empty)
M.raid = nil -- active simraid staging: { key, instName, stages, at }
M.TIE_ROUNDS = 3 -- max tie re-roll rounds before giving up with a note

function M.RequireSheet()
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then
    Z.Print("Simulation requires a loaded sheet. Import one first: /zl import or Load from File.")
    return nil
  end
  return sheet
end

-- Display link for sim lines (never a bare item:id): the clickable
-- chat link, same as the raid sees. Prefers the warmed cache, else the
-- entry link, else a synthesized link off the resolved row.
local function dispName(itemID, link)
  if Z.MasterLootUI and Z.MasterLootUI.ChatItemLink then
    return Z.MasterLootUI.ChatItemLink(itemID, link)
  end
  if Z.MasterLootUI and Z.MasterLootUI.DisplayItemLink then
    return Z.MasterLootUI.DisplayItemLink(itemID, link)
  end
  return tostring(link or ("item:" .. tostring(itemID)))
end

-- Roll range per type (mirrors live caps): SR/MS 1-100, OS 1-99, TMOG 1-98.
function M.RangeFor(rtype)
  local caps = Z.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
  if rtype == "OS" then return 1, caps.OS or 99 end
  if rtype == "TMOG" then return 1, caps.TMOG or 98 end
  return 1, caps.SR or 100
end

-- Queue one item's test entry. Fake rolls are precomputed here; they land
-- the moment the roll opens (RequestRoll), never on a timer.
local function queueEntry(sheet, itemID, link, opts)
  opts = opts or {}
  local rolls = Z.Resolver.FakeRolls(sheet, itemID,
    { count = M.FakeCount, tmog = opts.tmog, srOnly = opts.srOnly,
      fillers = opts.fillers })
  local entry = { itemID = itemID, link = link, rolls = rolls }
  table.insert(M.pending, entry)
  M.running = true
  return entry
end

-- Resolve a sim row's name + link BEFORE SetItems: sim entries often
-- carry bare ids (simboss drops, simraid trash) that can never yield a
-- clickable chat link on their own. GetItemInfo by id fills both from
-- the client cache when warm; otherwise the sheet quality rides along
-- so the row (and the chat link built off it) still has a color.
local function resolveSimRow(itemID, link)
  local name, fullLink, q = nil, nil, 0
  if GetItemInfo then
    local ok, n, l, qq = pcall(GetItemInfo, tonumber(itemID))
    if ok then
      if n and n ~= "" then name = n end
      if l and string.find(tostring(l), "|Hitem:", 1, true) then fullLink = l end
      if qq then q = qq end
    end
    if (not name or not fullLink) and link and link ~= "" then
      local ok2, n2, l2, q2 = pcall(GetItemInfo, link)
      if ok2 then
        if not name and n2 and n2 ~= "" then name = n2 end
        if not fullLink and l2 and string.find(tostring(l2), "|Hitem:", 1, true) then fullLink = l2 end
        if (not q or q == 0) and q2 then q = q2 end
      end
    end
  end
  if not name and link and link ~= "" then
    local nm = string.match(tostring(link), "%[(.-)%]")
    if nm and nm ~= "" then name = nm end
  end
  if not fullLink and link and string.find(tostring(link), "|Hitem:", 1, true) then
    fullLink = link
  end
  local sheet = Z.DB and Z.DB.sheet
  if (not q or q == 0) and sheet and sheet.items and sheet.items[itemID] then
    q = tonumber(sheet.items[itemID].quality) or 0
  end
  return name, fullLink or link, q or 0
end
-- Rebuild the sim loot window from the queue. keepListed=false (queue
-- building: fresh SimItem/SimBoss/stage) replaces the list wholesale.
-- keepListed=true (award-time re-sync via SyncLootWindow) ALSO carries
-- over listed-but-unqueued sim rows — ignored-by-mistake rows and (as
-- insurance) the active roll's row, whose entries were consumed at roll
-- start. Live parity: an ignored row stays listed across other items'
-- awards instead of vanishing. Flags are re-applied after SetItems
-- (which resets them); order is queue first, leftovers in list order.
local function syncWindow(keepListed)
  if not Z.LootWindow then return end
  local W = Z.LootWindow
  local sheet = Z.DB and Z.DB.sheet
  local rows = {}
  for i = 1, Z.Util.ArrayCount(M.pending) do
    local e = M.pending[i]
    if e and e.itemID then
      local badge = ""
      if sheet and Z.SRData.ReserveBadge then
        badge = Z.SRData.ReserveBadge(sheet, e.itemID)
      end
      local name, link, q = resolveSimRow(e.itemID, e.link)
      table.insert(rows, { itemID = e.itemID, link = link, name = name,
        quality = q, badge = badge })
    end
  end
  local reIgnore = {}
  if keepListed then
    local activeID = Z.MasterLootUI and Z.MasterLootUI.roll
      and Z.MasterLootUI.roll.itemID or nil
    for i = 1, Z.Util.ArrayCount(W.items) do
      local it = W.items[i]
      if it and it.itemID and it.source == "sim"
          and (it.ignored or it.itemID == activeID) then
        local queued = false
        for j = 1, Z.Util.ArrayCount(M.pending) do
          if M.pending[j] and M.pending[j].itemID == it.itemID then
            queued = true break
          end
        end
        if not queued then
          table.insert(rows, { itemID = it.itemID, link = it.link,
            name = it.name, quality = it.quality, badge = it.badge })
          if it.ignored then table.insert(reIgnore, it.itemID) end
        end
      end
    end
  end
  W.SetItems(rows, "sim")
  for i = 1, Z.Util.ArrayCount(reIgnore) do
    if W.MarkIgnored then W.MarkIgnored(reIgnore[i]) end
  end
end

-- Open the roll and land every fake instantly. Real /rolls landing while
-- the window is open join the same list. Returns true when rolling.
function M.RequestRoll(itemID)
  local MLUI = Z.MasterLootUI
  if MLUI and MLUI.roll then
    Z.Print("A roll is already running — finish, award, or close it first.")
    return false
  end
  local at = nil
  for i = 1, Z.Util.ArrayCount(M.pending) do
    if M.pending[i] and M.pending[i].itemID == itemID then at = i break end
  end
  -- Roll button on a non-queued row (manual pick): sim needs a queue
  -- entry; anything else refuses.
  local entry = at and M.pending[at] or nil
  if not entry then
      -- Ignored-by-mistake sim row: the row is still listed AND flagged
      -- ignored, but Ignore dropped its queue entry. Rebuild standard
      -- fakes from the sheet and roll — Roll, Raid roll, Award, ...
      -- all work on it again; the ignored mark clears via MarkRolling
      -- below, exactly like the live path. Scoped to ignored rows
      -- ONLY: a listed-but-unflagged row with no entry (tie re-roll,
      -- consumed queue) still refuses — manual /rolls from there.
      -- (Rebuilt fakes are standard: simtmog-style TMOG or filler
      -- counts from the original queue are not preserved.)
      local sheet = Z.DB and Z.DB.sheet
      local W = Z.LootWindow
      local row = W and W.Find and W.Find(itemID)
      if sheet and row and row.source == "sim" and row.ignored then
        entry = queueEntry(sheet, itemID,
          row.link or ("item:" .. tostring(itemID)), {})
        -- queueEntry stages; this roll consumes the entry at once
        -- (same as table.remove on the normal path) — otherwise the
        -- item would stay queued AND roll now, rolling twice. No
        -- syncWindow: pending membership is unchanged (staged then
        -- consumed), and re-syncing here would wipe the still-listed
        -- ignored row off the window before MarkRolling clears it.
        for i = Z.Util.ArrayCount(M.pending), 1, -1 do
          if M.pending[i] == entry then table.remove(M.pending, i) break end
        end
        M.running = true
        Z.Print("SIM: " .. dispName(itemID, row.link)
          .. " was ignored — re-queued, rolling again.")
      else
        Z.Print("SIM: item " .. tostring(itemID) .. " is not in the test queue.")
        return false
      end
  else
    table.remove(M.pending, at)
  end
  local link = entry.link or ("item:" .. tostring(itemID))
  local roll = MLUI and MLUI.BeginRoll(itemID, link, "SIM", true)
  if not roll then return false end
  -- The window IS the roll: open it rolling, then land every fake at
  -- once. No timers, no scheduling — the ML finishes when ready.
  if Z.LootWindow and Z.LootWindow.OpenDetail then
    local d = Z.LootWindow.OpenDetail(itemID)
    if d then
      d.phase = "rolling"
      d.rolls = {}
      d.menu = nil
      d.status = "rolling"
      Z.LootWindow.RefreshDetail()
      if Z.LootWindow.MarkRolling then Z.LootWindow.MarkRolling(itemID) end
    end
  end
  local n = 0
  for i = 1, Z.Util.ArrayCount(entry.rolls) do
    local rv = entry.rolls[i]
    if rv then
      -- Same intake as live rolls (MasterLootUI.AddRoll) AND the same
      -- chat line it emits — sim output and raid output share the path,
      -- only the channel differs (Comm.Say: solo local, party PARTY,
      -- raid RAID). Verifiable: tests pin the line text per grouping.
      local minR, maxR = M.RangeFor(rv.type)
      MLUI.AddRoll(rv.name, rv.roll, minR, maxR, { announce = true })
      n = n + 1
    end
  end
  if n == 0 then
    Z.Print("SIM: no fake rolls queued — roll yourself (/roll) or Finish to award.")
  else
    Z.Print("SIM: " .. n .. " roll(s) in — roll yourself (/roll), then Finish to award.")
  end
  return true
end

-- Drop a queued entry (pre-roll award AND ignore paths): an ignored
-- sim row must not stay rollable either. True when dropped.
function M.DropSim(itemID)
  local dropped = false
  for i = Z.Util.ArrayCount(M.pending), 1, -1 do
    local e = M.pending[i]
    if e and e.itemID == itemID then
      table.remove(M.pending, i)
      dropped = true
    end
  end
  return dropped
end

-- Anything staged, live, or rolling counts as busy.
function M.Busy()
  if M.running then return true end
  if Z.Util.ArrayCount(M.pending) > 0 then return true end
  if Z.MasterLootUI and Z.MasterLootUI.roll then return true end
  return false
end

-- Full stop: drop the queue, end any open roll, close the windows.
function M.Stop()
  local wasRunning = M.running or Z.Util.ArrayCount(M.pending) > 0
    or (Z.MasterLootUI and Z.MasterLootUI.roll ~= nil)
  M.pending = {}
  M.running = false
  M.raid = nil
  if Z.MasterLootUI and Z.MasterLootUI.EndRoll then
    Z.MasterLootUI.EndRoll()
  end
  if Z.LootWindow then
    if Z.LootWindow.Hide then Z.LootWindow.Hide() end
  end
  if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
  if wasRunning then
    Z.Print("Sim stopped (windows closed, everything reset).")
  else
    Z.Print("No sim running.")
  end
end

-- One item, rolled now: queue it, open it, land the fakes.
function M.SimItem(argText)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  local link, n = string.match((argText or ""), "(%S+)%s*(%d*)")
  local itemID = Z.Util.ItemID(link or "")
  if not itemID then Z.Print("Usage: /zl sim <itemlink|itemID> [fillers]") return end
  M.pending = {}
  local entry = queueEntry(sheet, itemID, link, { fillers = tonumber(n) or 0 })
  Z.Print("SIM item " .. dispName(itemID, link) .. " ("
    .. Z.Util.ArrayCount(entry.rolls) .. " rolls, replaying live):")
  syncWindow()
  M.RequestRoll(entry.itemID)
end

-- Queue one boss's drops WITHOUT resetting (simraid stages share it).
function M.QueueBossRun(sheet, raidKey, boss, drops, keep)
  if not keep then M.pending = {} end
  local data = Z.AtlasLoot and Z.AtlasLoot.Data()
  local raidName = (data and data[raidKey] and data[raidKey].Name) or raidKey
  if Z.Util.ArrayCount(drops) == 0 then
    Z.Print("SIM boss " .. tostring(boss.name) .. " [" .. tostring(raidName) .. "] rolled no drops this run — try again.")
    return 0
  end
  local ids = {}
  for i = 1, Z.Util.ArrayCount(drops) do table.insert(ids, tostring(drops[i])) end
  Z.Print("SIM boss " .. tostring(boss.name) .. " [" .. tostring(raidName) .. "] drops (Atlas-CFM): " .. table.concat(ids, ", "))
  for i = 1, Z.Util.ArrayCount(drops) do
    local itemID = drops[i]
    queueEntry(sheet, itemID, tostring(itemID), {})
  end
  M.running = true
  syncWindow()
  if Z.LootWindow then Z.LootWindow.Show("Simulated loot: " .. tostring(boss.name)) end
  return Z.Util.ArrayCount(drops)
end

local function StartRun(sheet, raidKey, boss, drops)
  M.QueueBossRun(sheet, raidKey, boss, drops, false)
end

function M.SimBoss(argText)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  if not (Z.AtlasLoot and Z.AtlasLoot.Available()) then
    Z.Print("Atlas-CFM is not loaded — boss drops come from its loot tables. Enable Atlas-CFM and try again.")
    return
  end
  local text = Z.Util.Trim(argText or "")
  local raidKey, boss = Z.AtlasLoot.FindBoss(text)
  local hintRaid = nil
  if not boss then
    local words = {}
    string.gsub(text, "(%S+)", function(w) table.insert(words, w) end)
    for i = Z.Util.ArrayCount(words) - 1, 1, -1 do
      local bp, rp = {}, {}
      for w = 1, i do table.insert(bp, words[w]) end
      for w = i + 1, Z.Util.ArrayCount(words) do table.insert(rp, words[w]) end
      local rk = Z.AtlasLoot.FindRaid(table.concat(rp, " "))
      if rk then
        if hintRaid == nil then hintRaid = rk end
        local b2 = Z.AtlasLoot.FindRaidBoss(rk, table.concat(bp, " "))
        if b2 then raidKey, boss = rk, b2 break end
      end
    end
  end
  if not boss then
    if hintRaid then
      local data = Z.AtlasLoot.Data()
      local rname = (data and data[hintRaid] and data[hintRaid].Name) or hintRaid
      Z.Print("Unknown boss '" .. text .. "'. Bosses in " .. rname .. ": "
        .. table.concat(Z.AtlasLoot.BossNames(hintRaid), ", "))
    else
      Z.Print("Unknown boss '" .. text .. "'. Usage: /zl simboss <boss> [raid] — or a whole raid: /zl simraid <raid>.")
    end
    return
  end
  StartRun(sheet, raidKey, boss, Z.AtlasLoot.BossDrops(raidKey, boss.name or boss.id))
end

-- Usage: /zl simraid <raid>. One boss at a time through the SAME simboss
-- starter; when a boss's queue drains, the next stage queues.
function M.SimRaid(argText)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  if not (Z.AtlasLoot and Z.AtlasLoot.Available()) then
    Z.Print("Atlas-CFM is not loaded — raid drops come from its loot tables. Enable Atlas-CFM and try again.")
    return
  end
  local text = Z.Util.Trim(argText or "")
  local raidKey, inst = Z.AtlasLoot.FindRaid(text)
  if not raidKey then
    local names = {}
    local raids = Z.AtlasLoot.ListRaids()
    for i = 1, Z.Util.ArrayCount(raids) do table.insert(names, raids[i].name) end
    Z.Print("Unknown raid '" .. text .. "'. Usage: /zl simraid <raid>. Raids: " .. table.concat(names, ", "))
    return
  end
  local names = Z.AtlasLoot.BossNames(raidKey)
  if Z.Util.ArrayCount(names) == 0 then
    Z.Print("SIM raid " .. tostring(inst.Name) .. " has no bosses with loot tables.")
    return
  end
  M.pending = {}
  M.raid = { key = raidKey, instName = inst.Name, stages = names, at = 0 }
  Z.Print("SIM raid " .. tostring(inst.Name) .. ": " .. Z.Util.ArrayCount(names)
    .. " bosses, one at a time — Roll each from the list.")
  M.NextRaidStage()
end

function M.NextRaidStage()
  local raid = M.raid
  if not raid then return end
  raid.at = (raid.at or 0) + 1
  local bossName = raid.stages and raid.stages[raid.at]
  if not bossName then
    M.raid = nil
    M.running = false
    Z.Print("SIM raid done — window closed, see the Sheet tab.")
    if Z.LootWindow and Z.LootWindow.Hide then Z.LootWindow.Hide() end
    return
  end
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return end
  local boss = Z.AtlasLoot.FindRaidBoss(raid.key, bossName)
  if not boss then return end
  Z.Print("SIM raid " .. tostring(raid.instName) .. ": boss " .. raid.at
    .. "/" .. Z.Util.ArrayCount(raid.stages))
  -- Trash pack before the boss (mobs cleared walking up to it).
  local trashID = 1004
  queueEntry(sheet, trashID, tostring(trashID), {})
  Z.Print("SIM boss Trash Mobs-" .. tostring(raid.instName) .. " [" .. tostring(raid.instName) .. "] drops (Atlas-CFM): " .. trashID)
  M.QueueBossRun(sheet, raid.key, boss,
    Z.AtlasLoot.BossDrops(raid.key, boss.name or boss.id), true)
end

-- Transmog demo: the first sheet roller rolls TMOG instead of SR.
function M.SimTmog(argText)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  local link = string.match((argText or ""), "(%S+)")
  local itemID = Z.Util.ItemID(link or "")
  if not itemID then Z.Print("Usage: /zl simtmog <itemlink|itemID>") return end
  if sheet.items[itemID] == nil then
    Z.Print("simtmog needs an SR'd item (got " .. tostring(itemID) .. ").")
    return
  end
  local rollers = sheet.items[itemID].rollers or {}
  if not rollers[1] then Z.Print("simtmog needs an SR'd item with rollers.") return end
  local tmogName = rollers[1].name
  M.pending = {}
  local entry = queueEntry(sheet, itemID, link,
    { tmog = { tmogName }, srOnly = true })
  Z.Print("SIM-TMOG item " .. dispName(itemID, link) .. " (" .. tostring(tmogName) .. " rolls TMOG instead of SR):")
  syncWindow()
  M.RequestRoll(entry.itemID)
end

-- Called after every sim award: nothing queued and nothing rolling ends
-- the run; a staged raid advances.
function M.AfterAward()
  if Z.Util.ArrayCount(M.pending) == 0 and not (Z.MasterLootUI and Z.MasterLootUI.roll) then
    if M.raid and M.NextRaidStage() then return end
    if M.running then
      M.running = false
      Z.Print("SIM done — window closed, see the Sheet tab.")
    end
    if Z.LootWindow and Z.LootWindow.Hide then Z.LootWindow.Hide() end
    if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
  end
end

function M.OnSimAwarded(_itemID) M.AfterAward() end
-- Award-time re-sync: keep listed-but-unqueued (ignored) sim rows on
-- the window across other items' awards — live parity. Queue-building
-- callers use the fresh syncWindow() above.
function M.SyncLootWindow() syncWindow(true) end

if ZugLoot then ZugLoot.Sim = M end
return M
