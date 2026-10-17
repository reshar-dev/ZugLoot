-- ZugLoot/LootWindow.lua
-- RollFor-LootFrame-style (modern skin) loot list — universal: whoever
-- opens the corpse runs it (solo, any loot method, ML or not):
-- a numbered list covering EVERY corpse slot (RollFor parity): coin plus
-- all qualities. Threshold+ items (quality >= the party's GetLootThreshold)
-- are roll rows (SR/HR badge on the right; clicking opens the row detail);
-- coin and below-threshold items (grey quality 0 always) are free rows
-- (one click loots the slot straight to the player, no rolling, any loot
-- method). The detail STAYS OPEN as
-- the roll window (RollFor preview ->
-- rolling -> winners flow): choose SR (direct award on a single holder) /
-- Roll / Close; while rolling it lists every valid roll with its kind
-- (SR/MS/OS/TMOG); when the roll finishes it becomes the award window
-- (winner rows + ... for anyone else). Close returns to the overview.
--
-- Data layer (M.items, M.detail) is plain tables so tests drive it
-- headless; frames are client-only (nil-guarded, mock-safe).
-- Item: { itemID, link, texture, quality, quantity, slot, badge, status,
--         source, index, ignored }
--   badge: "HR" | "SR" | "SR:n" | ""; status: "open"|"rolling"|"done";
--   source: "loot"|"sim"; index: 1-based row number (RollFor modern skin).
--   ignored: true once the ML marks the row ignored — the row STAYS listed
--   ([ignored]) instead of leaving. Looting is finished when the list is
--   empty or every row is ignored.
-- Detail: BuildDetail fields + phase ("pick"|"rolling"|"award"),
--   rolls ({name, roll, rollType, effective}), menu (award data once
--   finished), countdown (seconds left) + countdownDur (full window,
--   bar paint denominator).
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.LootWindow = M

M.items = {}
M.title = "ZugLoot Loot"
M.frame = nil
M.rows = {}

-- Class-colored display name (data stays raw everywhere).
local function PName(name)
  if Z.ClassColors and Z.ClassColors.ColoredName then
    return Z.ClassColors.ColoredName(name)
  end
  return tostring(name or "")
end

-- Row detail state (plain data): { itemID, link, badge, rollers={names},
-- single=bool (exactly one SR/HR holder), status, source }.
-- Only ONE detail exists at a time: the open window. Closing it ends any
-- open roll — there is no parked state anywhere.
M.detail = nil
M.detailFrame = nil

M.ROW_HEIGHT = 24
M.ICON_SIZE = 20
-- Button bar: floating flow layout (justify each row, wrap when narrow).
M.BTN_HEIGHT = 22
M.BTN_GAP = 8
M.BTN_MARGIN = 10
M.BTN_MORE_W = 44
-- Wide enough for "Award <name>" on ONE line (RollFor sizes rows to the
-- widest content). 320 fits ~35-char names next to the ... button.
-- (Close lives top-right as X, no bar width needed.)
M.DETAIL_WIDTH = 220 -- raider-window width (was 320)
-- Detail auto-height: header block + roll rows + button bar. The roll
-- list grows one line per roll instead of clipping at a fixed height —
-- a 40-man raid roll shows every roller without scrolling.
M.DETAIL_HEADER_H = 130 -- icon + title + sub + top padding
M.DETAIL_ROLL_H = 12 -- one roll-list line (FontString line height)
M.DETAIL_BASE_H = 250 -- the old fixed height: windows never shrink,
-- only grow past ~7 rolls
M.DETAIL_MAX_H = 650 -- cap: a full 40-man list still fits
-- Pure (headless-testable): frame height for a roll count + bar rows.
function M.DetailHeight(nRolls, barRows)
  local rows = math.max(0, tonumber(nRolls) or 0)
  local barH = (math.max(1, tonumber(barRows) or 1)) * M.BTN_HEIGHT
    + (math.max(1, tonumber(barRows) or 1) - 1) * M.BTN_GAP + M.BTN_MARGIN + 4
  local h = M.DETAIL_HEADER_H + rows * M.DETAIL_ROLL_H + barH
  if h < M.DETAIL_BASE_H then h = M.DETAIL_BASE_H end
  if h > M.DETAIL_MAX_H then h = M.DETAIL_MAX_H end
  return h
end

function M.Clear()
  M.items = {}
  M.detail = nil
  -- Watchdogs parked while walking away must NOT die with the list:
  -- the row they guard re-parks and resumes, and the watch must still
  -- un-dim it if the server dropped the call (else a silent call
  -- strands a grey [done] row that only a rescan can clear). Pending
  -- arms live in MasterLootUI.pendingLoot and park/restore with the
  -- corpse, so the watch re-checks the right arm on fire.
  M.Refresh()
  M.RefreshDetail()
end

-- Watchdog: when a click-to-loot call goes silent (issued clean, row
-- dimmed, but no LOOT_SLOT_CLEARED within a few seconds and no error),
-- poke the corpse — re-read the clicked slot. If the item is STILL there
-- the call died server-side: un-dim the row at once and say so (don't
-- wait for a confirm that never comes, don't strand grey rows). If the
-- slot emptied without an event, reconcile. Timer-driven (vanilla-safe);
-- headless no-op without corpse APIs. One watchdog per click; disarmed
-- by confirm (RescanLeftovers clears the arm), error (UI_ERROR_MESSAGE),
-- or firing. Survives Clear()/walk-away: the arm lives in
-- MasterLootUI.pendingLoot (parked/restored with the corpse) and the
-- row resumes on re-loot, so a late fire still finds and un-dims it.
-- Corpse-scoped: a parked arm from an OLD corpse must not un-dim a row
-- on the new one — the watch keys on the corpse key pinned at click
-- time and no-ops after a corpse change.
M.watchdogs = nil
function M.WatchClick(slot, itemID, rowName)
  if not (GetNumLootItems and Z.Timer and Z.Timer.After) then return end
  M.watchdogs = M.watchdogs or {}
  local key = Z.MasterLootUI and Z.MasterLootUI.lootKey or nil
  local wd = { slot = slot, itemID = itemID, dead = false, corpse = key }
  table.insert(M.watchdogs, wd)
  Z.Timer.After(4, function()
    wd.dead = true
    if M.watchdogs then
      for i = Z.Util.ArrayCount(M.watchdogs), 1, -1 do
        if M.watchdogs[i] == wd then table.remove(M.watchdogs, i) break end
      end
    end
    -- Corpse changed since the click (walk-away onto something else):
    -- this arm belongs to the old corpse, never touch the new list.
    local curKey = Z.MasterLootUI and Z.MasterLootUI.lootKey or nil
    if wd.corpse ~= curKey then return end
    -- Armed click still pending AND row still dimmed = silent ignore.
    local armed = Z.MasterLootUI and Z.MasterLootUI.pendingLoot
      and Z.MasterLootUI.pendingLoot[slot]
    local row = M.Find(itemID)
    if not (armed and row and row.status == "done") then return end
    -- Re-read the corpse slot: gone = late confirm arrived unordered,
    -- reconcile; present = server dropped the call, un-dim + report.
    if Z.MasterLootUI and Z.MasterLootUI.VerifySlot then
      local v = Z.MasterLootUI.VerifySlot(itemID, slot)
      if v == "gone" or v == nil then
        -- RescanLeftovers closes itself when it actually dropped rows.
        if Z.MasterLootUI.RescanLeftovers then Z.MasterLootUI.RescanLeftovers() end
        return
      end
    end
    if Z.MasterLootUI then Z.MasterLootUI.pendingLoot[slot] = nil end
    row.status = "open"
    M.Refresh()
    Z.Print("Loot didn't go through for " .. tostring(rowName or itemID)
      .. " (slot " .. tostring(slot) .. ") — click again to retry.")
  end)
end
function M.DisarmWatchdogs()
  M.watchdogs = nil
end

-- Replace the list (loot scan / sim queue). Plain array of
-- { itemID, link, texture, quality, quantity, slot, badge, sr, coin, free };
-- status starts "open", index follows list order (RollFor modern skin
-- numbering). badge wins over sr; sr feeds the legacy badge derivation.
-- Coin rows use itemID "Coin" (no link); free rows are below-threshold
-- items looted with one click instead of rolled.
function M.SetItems(list, source)
  M.items = {}
  local n = Z.Util.ArrayCount(list or {})
  for i = 1, n do
    local e = (list or {})[i]
    if e and e.itemID then
      local badge = e.badge
      if (badge == nil or badge == "") and e.sr and e.sr > 0 then
        badge = (e.sr == 1) and "SR" or ("SR:" .. e.sr)
      end
      local row = {
        index = i,
        itemID = e.itemID,
        link = e.link or ((not e.coin) and ("item:" .. tostring(e.itemID)) or nil),
        name = e.name,
        texture = e.texture,
        quality = e.quality or 0,
        quantity = e.quantity,
        slot = e.slot,
        badge = badge or "",
        coin = e.coin and true or false,
        free = (not e.coin and not e.group) and (e.free and true or false) or false,
        group = (not e.coin) and (e.group and true or false) or false,
        status = "open",
        ignored = false,
        source = source or "loot",
      }
      M.EnsureResolved(row) -- sheet-style name/icon/link, not "item:<id>"
      table.insert(M.items, row)
    end
  end
  M.Refresh()
end

function M.Find(itemID)
  for i = 1, Z.Util.ArrayCount(M.items) do
    if M.items[i].itemID == itemID then return M.items[i] end
  end
  return nil
end

function M.SetStatus(itemID, status)
  local it = M.Find(itemID)
  if it then it.status = status end
  M.Refresh()
end

function M.MarkRolling(itemID)
  -- Rolling an ignored row handles it after all: the mark clears.
  local it = M.Find(itemID)
  if it then it.ignored = nil end
  M.SetStatus(itemID, "rolling")
end
function M.MarkDone(itemID) M.SetStatus(itemID, "done") end
function M.MarkOpen(itemID)
  -- Reopening handles it after all: the mark clears.
  local it = M.Find(itemID)
  if it then it.ignored = nil end
  M.SetStatus(itemID, "open")
end
-- Ignore the item: the row STAYS listed, flagged ([ignored]) — nothing
-- awarded, looted, won-marked, or logged (the caller writes the audit
-- entry). Status returns to open: no roll runs behind an ignored row.
-- The open detail mirrors the flag so the window shows it too.
function M.MarkIgnored(itemID)
  local it = M.Find(itemID)
  if not it then return end
  it.ignored = true
  it.status = "open"
  if M.detail and M.detail.itemID == itemID then
    M.detail.ignored = true
    M.detail.status = "open"
  end
  M.Refresh()
  M.RefreshDetail()
end
-- Looting is finished when no rows remain OR every remaining row is
-- ignored: nothing left to roll or award, so the window can close (and
-- a raid-boss auto-switch flips back to group loot).
function M.LootingFinished()
  local n = Z.Util.ArrayCount(M.items)
  if n == 0 then return true end
  for i = 1, n do
    local it = M.items[i]
    if not (it and it.ignored) then return false end
  end
  return true
end
-- Shared close-out: when looting just finished (rows dropped and nothing
-- actionable remains), close the whole window and the loot. Every path
-- that drops rows funnels through here, so no ordering can strand the
-- overview open: ignore-first then award/loot the rest closes here just
-- like ignore-last does.
--
-- Reopening NEVER closes: the looter re-looting the corpse gets the
-- ignored rows back as a second chance to roll them. Only a rescan that
-- DROPPED something (or an ignore that just marked) may close — a rescan
-- that changed nothing (reopen, unrelated slot) must leave the window up.
-- Returns true when it closed.
function M.CloseIfFinished(dropped)
  if not dropped then return false end
  if not M.LootingFinished() then return false end
  M.Hide()
  if CloseLoot then pcall(CloseLoot) end
  return true
end

-- Blizzard frame takeover (RollFor parity): Blizzard's `LootFrame` is a
-- real FrameXML window that pops itself on LOOT_OPENED. Hiding it once is
-- not enough — it re-shows on every loot (page changes, re-opens, group
-- updates). So on login we DETACH it for the whole session:
-- UnregisterAllEvents (it never hears LOOT_OPENED again) + strip its
-- OnHide script (FrameXML hides itself via that hook). From then on OUR
-- loot window is the loot window, always, in every looting situation.
-- All client-global access is nil-guarded so headless/tests never touch it.
-- Session detach flag: once ADDON_LOADED fires the takeover is armed;
-- re-armed per LOOT_OPENED (repeat detach is cheap and idempotent).
M.blizzardTakeover = false
-- takeOver=true detaches (hide Blizzard's frame, ours takes over);
-- takeOver=false restores (re-register LOOT_* events, show on next loot).
-- Events unregistered on 1.12: LOOT_OPENED, LOOT_CLOSED, LOOT_SLOT_CLEARED,
-- plus the OnHide CloseLoot hook — the full set FrameXML subscribes.
-- Restoring ONLY re-registers: Blizzard repopulates itself on the next
-- loot (or immediately if a loot session is currently open).
-- Takeover preference: Z.DB.lootTakeover (persisted). The kill-switch
-- sets it false; the user re-arms via Setup tab or /zl lootframe.
-- takeOver arg forces a direction for this call AND persists it.
function M.TakeoverWanted()
  if Z.DB and Z.DB.lootTakeover == false then return false end
  return true
end
function M.SetTakeoverWanted(want)
  if Z.DB then Z.DB.lootTakeover = want and true or false end
  M.DetachBlizzardLoot(want and true or false)
end
function M.DetachBlizzardLoot(takeOver)
  if takeOver == nil then takeOver = M.TakeoverWanted() end
  local function frameTakeover(f)
    if not f then return end
    if takeOver then
      if f.UnregisterAllEvents then pcall(f.UnregisterAllEvents, f) end
      if f.SetScript then pcall(f.SetScript, f, "OnHide", nil) end
      if f.Hide then pcall(f.Hide, f) end
    else
      if f.RegisterEvent then
        pcall(f.RegisterEvent, f, "LOOT_OPENED")
        pcall(f.RegisterEvent, f, "LOOT_CLOSED")
        pcall(f.RegisterEvent, f, "LOOT_SLOT_CLEARED")
      end
      -- Re-arm FrameXML's own close hook so its window behaves stock.
      if f.SetScript and CloseLoot then
        pcall(f.SetScript, f, "OnHide", function() pcall(CloseLoot) end)
      end
      -- Do NOT Show() here: a frame detached before this loot session
      -- never ran LootFrame_OnShow, its internal page state is nil, and
      -- forcing Show() crashes FrameXML (LootFrame.lua arithmetic on nil
      -- page). The re-registered LOOT_OPENED repopulates it on the NEXT
      -- loot; the CURRENT corpse must be re-looted (close it: walking
      -- away / CloseLoot ends the broken session cleanly).
      -- NOTE: CloseLoot is deliberately NOT auto-called: ending the
      -- player's loot session out from under them would drop loot access
      -- entirely. Print the recovery step instead (once, at restore).
    end
  end
  frameTakeover(LootFrame) -- client global; nil headless (tests never define it)
  M.blizzardTakeover = takeOver
end
-- Per-loot safety net: keep Blizzard's frame down while OUR rows cover
-- the corpse (post-detach this is normally already hidden; cheap to repeat).
-- Safe headless (LootFrame is a client global that tests never define).
function M.HideBlizzardLoot()
  M.DetachBlizzardLoot()
end
-- NOTE: group-loot Need/Greed popups (GroupLootFrame1..N) are deliberately
-- LEFT ALONE: detaching them without rewiring the dice to RollOnLoot would
-- leave group-rolled items unrollable. The takeover scope is the corpse
-- loot window (LootFrame), in every loot method — the master-loot frame
-- replaces Blizzard's in all looting situations.

-- Slot-kind check: coin slots carry no item link. Vanilla exposes
-- LootSlotIsCoin AND LootSlotIsItem (1.12 FrameXML convention, cf.
-- Gatherhud/BigWigs/Aegis_Exchange usage across this client); backported
-- clients expose GetLootSlotType (LOOT_SLOT_MONEY == 2). Nil-safe: false
-- with no client APIs (headless).
function M.IsCoinSlot(slot)
  if LootSlotIsCoin then
    local ok, v = pcall(LootSlotIsCoin, slot)
    if ok and v == 1 then return true end
  end
  if LootSlotIsItem then
    local ok, v = pcall(LootSlotIsItem, slot)
    if ok then return v ~= 1 end
  end
  if GetLootSlotType then
    local ok, t = pcall(GetLootSlotType, slot)
    if ok and t ~= nil then
      if t == 2 then return true end
      if LOOT_SLOT_MONEY and t == LOOT_SLOT_MONEY then return true end
      return false
    end
  end
  return false
end

-- Empty-coin check: the client keeps a coin slot on corpses with no money
-- ("0 Copper"). The slot name from GetLootSlotInfo is the amount text —
-- nil/blank or an all-zero amount means nothing to loot, so the row is
-- skipped instead of showing a phantom coin entry. Matches gold/silver/
-- copper wording in any client locale by digit: any nonzero digit = money.
-- Pure (string in, bool out) for headless tests.
function M.IsEmptyCoin(slotName)
  local s = tostring(slotName or "")
  if s == "" or s == "Coin" then return true end
  return string.find(s, "[1-9]") == nil
end

-- The PARTY's roll threshold (green 2 .. epic 4): items BELOW it never
-- enter a group roll — Blizzard hands them out via plain LootSlot, no
-- Need/Greed frames. Reads the live client setting; falls back to the
-- client default (uncommon) headless or when the API is absent.
function M.GroupRollThreshold()
  if GetLootThreshold then
    local ok, t = pcall(GetLootThreshold)
    if ok and type(t) == "number" then return t end
  end
  return (Z.Limits and Z.Limits.LOOT_THRESHOLD_DEFAULT) or 2
end

-- Should this item go through a GROUP roll (Need/Greed frames) rather
-- than plain LootSlot? Only in a group, only under group loot, only at
-- or above the party's threshold. Everything else is directly lootable.
-- quality: GetLootSlotInfo 4th return (nil-safe: unknown -> not rollable).
function M.IsGroupRollItem(quality)
  if not (Z.SRSecurity and Z.SRSecurity.IsSolo
      and not Z.SRSecurity.IsSolo()) then return false end
  local method = nil
  if GetLootMethod then
    local ok, m = pcall(GetLootMethod)
    if ok then method = m end
  end
  if method == nil and Z.SRSecurity and Z.SRSecurity.LootMethod then
    local ok, m = pcall(Z.SRSecurity.LootMethod)
    if ok then method = m end
  end
  if method ~= "group" then return false end
  if type(quality) ~= "number" then return false end
  return quality >= M.GroupRollThreshold()
end

-- Handed out = gone: drop the row from the list (by itemID; scanning the
-- corpse again re-adds the odd leftover). A list with zero rows
-- left is not a record — history lives in the Sheet tab.
-- slotHint narrows to the CLICKED row when duplicate itemIDs share the
-- corpse (two of the same grey): looting one leaves the other listed.
function M.RemoveItem(itemID, slotHint)
  local n = Z.Util.ArrayCount(M.items)
  for i = n, 1, -1 do
    local it = M.items[i]
    if it and it.itemID == itemID
        and (slotHint == nil or it.slot == slotHint) then
      table.remove(M.items, i)
      if slotHint ~= nil then break end
    end
  end
  -- Renumber: rows are the 1-based RollFor modern-skin list order.
  for i = 1, Z.Util.ArrayCount(M.items) do
    M.items[i].index = i
  end
  if M.detail and M.detail.itemID == itemID then
    M.detail = nil
    if M.detailFrame and M.detailFrame.Hide then M.detailFrame:Hide() end
    M.detailFrame = nil
  end
  M.Refresh()
  -- Nothing actionable left (empty, or only ignored rows): the corpse is
  -- fully distributed. Close the window and the loot (Clear() also fires
  -- on a fresh LOOT_OPENED, so the next corpse starts clean).
  M.CloseIfFinished(true) -- a row just left the list
end

function M.AllDone()
  for i = 1, Z.Util.ArrayCount(M.items) do
    if M.items[i].status ~= "done" then return false end
  end
  return true
end

function M.Hide()
  if M.frame and M.frame.Hide then M.frame:Hide() end
  M.CloseDetail()
end

-- The overview Close button: reconcile with the corpse (confirmed loots
-- drop, failed clicks stay) instead of blindly hiding. Finished (empty
-- or only ignored rows) closes the loot out; leftovers stay listed so
-- nothing undistributed is lost by dismissing the window.
function M.CloseOverview()
  if Z.MasterLootUI and Z.MasterLootUI.RescanLeftovers then
    Z.MasterLootUI.RescanLeftovers()
  end
  -- The X button is an explicit dismiss: a finished list closes the loot
  -- out, anything else parks. (No drop happened here — the explicit
  -- close IS the event.)
  local finishedNow = M.LootingFinished()
  M.Hide()
  if finishedNow then
    if CloseLoot then pcall(CloseLoot) end
    return "closed"
  end
  return "parked"
end

-- No Blizzard fallback: every corpse slot (coin, greys, green+) has a row
-- in OUR window with a click-to-loot path, so Blizzard's frame is never
-- needed and stays detached. Kept as no-op shims (callers/tests may
-- reference them). Nil-safe headless.
function M.MaybeBlizzardFallback() return false end

function M.HideBlizzardFallback() end

-- Corpse-side refresh: re-scan whatever is left. LOOT_SLOT_CLEARED is the
-- CONFIRMATION that a slot left the corpse (our click or anyone else's):
-- the slot-keyed rescan drops exactly that row and keeps the rest.
-- LOOT_CLOSED with an empty tracked list hides the window.
-- Nil-safe headless (no corpse APIs -> no-op).
function M.OnEvent(event, _arg1)
  if event == "LOOT_CLOSED" then
    -- Walk-away with leftovers: park the rows so re-looting resumes the
    -- list. An open roll keeps collecting (its window is open); a closed
    -- one already ended. Only a fully-distributed corpse hides the window.
    if Z.Util.ArrayCount(M.items or {}) == 0 then
      M.Hide()
    elseif Z.MasterLootUI and Z.MasterLootUI.ParkCorpse then
      Z.MasterLootUI.ParkCorpse()
    end
  elseif event == "LOOT_SLOT_CLEARED" then
    -- Slots confirmed off the corpse: the last actionable row may just
    -- have left while ignored rows stay (ignore-first, loot-rest).
    -- RescanLeftovers closes itself when it actually dropped rows.
    if Z.MasterLootUI and Z.MasterLootUI.RescanLeftovers then
      Z.MasterLootUI.RescanLeftovers()
    end
  end
end

function M.Show(title)
  if title then M.title = title end
  if not CreateFrame then return end
  if not M.frame then M.BuildFrame() end
  if not M.frame then return end
  M.Refresh()
  if M.frame then M.frame:Show() end
end

function M.BuildFrame()
  if M.frame then return M.frame end
  if not CreateFrame then return nil end
  local f = CreateFrame("Frame", "ZugLootMasterLootFrame", UIParent)
  if type(f) ~= "table" or type(f.SetWidth) ~= "function"
      or type(f.CreateFontString) ~= "function" then
    return nil -- no usable client frame (minimal test stubs)
  end
  -- Raider-window style: compact dark frame (same palette/backdrop).
  f:SetWidth(220) f:SetHeight(120)
  f:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
  f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0, 0, 0, 0.85)
  f:SetBackdropBorderColor(0.2, 0.2, 0.2)
  f:SetMovable(true) f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  f:SetClampedToScreen(true)
  -- No header/title: rows start at the top edge (more room for loot).
  -- f.title stays nil; Refresh guards it.
  -- X in the top-right corner (standard close button, same action as the
  -- old bottom Close button: reconcile + park, never strand loot).
  local closeB = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  closeB:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
  closeB:SetScript("OnClick", function() M.CloseOverview() end)
  f.closeB = closeB
  M.frame = f
  return f
end

-- Row display line (headless/text): "[name] SR" (+status tag).
-- Mirrors what the client row paints: icon, name, right-side badge
-- (raider-window style — no row numbers).
function M.RowText(it)
  local s = M.DisplayName(it)
  if it.badge and it.badge ~= "" then s = s .. " " .. it.badge end
  if it.status == "rolling" then s = s .. " [rolling]"
  elseif it.status == "done" then s = s .. " [done]" end
  if it.ignored then s = s .. " [ignored]" end
  return s
end

-- Item presentation (RollFor ItemUtils parity):
-- DisplayName: the readable name — never the raw link. Prefers the slot
-- name captured at scan time, else parses "[Name]" out of the link, else
-- the itemID fallback.
-- TooltipLink: the "item:...." part for SetHyperlink.
function M.DisplayName(it)
  if it.name and it.name ~= "" then return tostring(it.name) end
  local link = tostring(it.link or "")
  local nm = string.match(link, "%[(.-)%]")
  if nm and nm ~= "" then return nm end
  if it.coin then return "Coin" end
  return "item:" .. tostring(it.itemID)
end

function M.TooltipLink(it)
  local link = tostring(it.link or "")
  local inner = string.match(link, "|H(item:[^|]+)|h")
  if inner then return inner end
  local id = tonumber(it.itemID)
  if id then return "item:" .. id .. ":0:0:0" end
  return link ~= "" and link or nil
end

-- Shared item resolution: the sheet list reads name, full link, quality
-- and texture from GetItemInfo(tonumber(itemID)) — the loot list does the
-- same here. Slot/scan data is only a fallback; without it a row degrades
-- to "item:<id>" with a blank icon (the reported bug: sim rows carry bare
-- "1001" links that can never yield a name or texture on their own).
-- Missing client cache (GetItemInfo -> nil) keeps the fallbacks.
function M.ResolveItemInfo(itemID, link, quality, texture, name)
  local rName, rLink, rQ, rTex = name, link, quality, texture
  if GetItemInfo then
    -- 1.12 takes the item LINK (the sheet's per-id call only works for
    -- cache-warm keys). Try the row link first, then the numeric id.
    if link and link ~= "" then
      local ok, n, l, q, _, _, _, _, _, t = pcall(GetItemInfo, link)
      if ok then
        if n and n ~= "" then rName = n end
        if l and l ~= "" then rLink = l end
        if q ~= nil then rQ = q end
        if t and t ~= "" then rTex = t end
      end
    end
    local id = tonumber(itemID)
    if id and (rName == nil or rName == "" or rTex == nil or rTex == "") then
      local ok, n, l, q, _, _, _, _, _, t = pcall(GetItemInfo, id)
      if ok then
        if n and n ~= "" and (rName == nil or rName == "") then rName = n end
        if l and l ~= "" and (rLink == nil or rLink == "" or not string.find(tostring(rLink), "|Hitem:", 1, true)) then rLink = l end
        if q ~= nil and (rQ == nil or rQ == 0) then rQ = q end
        if t and t ~= "" and (rTex == nil or rTex == "") then rTex = t end
      end
    end
  end
  if (rName == nil or rName == "") and rLink then
    local nm = string.match(tostring(rLink), "%[(.-)%]")
    if nm and nm ~= "" then rName = nm end
  end
  -- No full link from the cache but name known: synthesize a REAL link
  -- (BuildLink) so shift-click/tooltip always have a clickable link.
  if (rLink == nil or rLink == "" or not string.find(tostring(rLink), "|Hitem:", 1, true))
      and rName and rName ~= "" then
    local built = M.BuildLink(itemID or Z.Util.ItemID(rLink), rName, rQ)
    if built then rLink = built end
  end
  return rName, rLink, rQ, rTex
end

-- Fill a row in place (name/link/quality/texture); marks it resolved so
-- later Refresh calls skip the lookup. Safe headless (no GetItemInfo).
function M.EnsureResolved(it)
  if not it or it._resolved then return it end
  local name, link, q, tex = M.ResolveItemInfo(it.itemID, it.link,
    it.quality, it.texture, it.name)
  it.name = name
  if link and link ~= "" then it.link = link end
  if q ~= nil then it.quality = q end
  if tex and tex ~= "" then it.texture = tex end
  it._resolved = true
  return it
end

-- Shared tooltip show/hide: every item hover in the addon runs the ONE
-- shared ItemIcon module (ItemIcon.lua). Kept as thin wrappers so the
-- existing call sites (row, icon, detail title) keep working.
function M.ShowTip(owner, tipLink)
  if not tipLink then return end
  local ZL = ZugLoot.ItemIcon
  if ZL and ZL.Hover then
    local id = Z.Util and Z.Util.ItemID(tipLink)
    ZL.Hover(owner, id, tipLink)
    return
  end
  if GameTooltip and GameTooltip.SetOwner and GameTooltip.SetHyperlink then
    local ok = pcall(GameTooltip.SetOwner, GameTooltip, owner, "ANCHOR_RIGHT")
    if ok then
      pcall(GameTooltip.SetHyperlink, GameTooltip, tipLink)
      if GameTooltip.Show then GameTooltip:Show() end
    end
  end
end

function M.HideTip()
  local ZL = ZugLoot.ItemIcon
  if ZL and ZL.Hide then ZL.Hide() return end
  if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
end

-- Button width estimator (mock-safe: GetStringWidth when available).
function M.ButtonWidth(btn, text)
  local fs = btn.GetFontString and btn:GetFontString()
  local w = 0
  if fs and fs.GetStringWidth then w = fs:GetStringWidth() or 0 end
  if w == 0 then w = string.len(tostring(text)) * 7 end
  w = w + 24
  if w < 80 then w = 80 end
  return w
end

-- Flow layout (pure, headless-testable): pack visible buttons into rows
-- inside `barW`, then justify each row (even side margins, even gaps).
-- Input: { {btn=ref, w=width}... } in bar order. Returns rows of
-- { {btn, x, w}... } with x relative to the bar's left edge, plus the
-- row count. Rows stack upward from the bar bottom (row 1 = bottom).
function M.LayoutBarRows(slots, barW)
  local rows, cur, used = {}, {}, 0
  local gap = M.BTN_GAP
  for i = 1, Z.Util.ArrayCount(slots or {}) do
    local s = slots[i]
    local need = s.w + (Z.Util.ArrayCount(cur) > 0 and gap or 0)
    if Z.Util.ArrayCount(cur) > 0 and used + need > barW then
      table.insert(rows, cur)
      cur, used = {}, 0
      need = s.w
    end
    table.insert(cur, s)
    used = used + need
  end
  if Z.Util.ArrayCount(cur) > 0 then table.insert(rows, cur) end
  -- Justify: even margins + even gaps per row.
  local out = {}
  for r = 1, Z.Util.ArrayCount(rows) do
    local row = rows[r]
    local total = 0
    for i = 1, Z.Util.ArrayCount(row) do total = total + row[i].w end
    local gaps = Z.Util.ArrayCount(row) + 1
    local space = (barW - total) / gaps
    if space < 0 then space = 0 end
    local placed, x = {}, space
    for i = 1, Z.Util.ArrayCount(row) do
      table.insert(placed, { btn = row[i].btn, x = x, w = row[i].w })
      x = x + row[i].w + space
    end
    table.insert(out, placed)
  end
  return out
end

-- Apply a LayoutBarRows result to live buttons: row 1 sits on the bar
-- bottom (BOTTOM + margin), higher rows stack above it.
function M.PlaceBarRows(f, rows, _barW)
  if not (f and rows) then return 0 end
  local bh = M.BTN_HEIGHT
  for r = 1, Z.Util.ArrayCount(rows) do
    local y = M.BTN_MARGIN + (r - 1) * (bh + M.BTN_GAP)
    for i = 1, Z.Util.ArrayCount(rows[r]) do
      local cell = rows[r][i]
      local btn = cell.btn
      if btn then
        if btn.SetWidth then btn:SetWidth(cell.w) end
        if btn.ClearAllPoints then btn:ClearAllPoints() end
        if btn.SetPoint then
          btn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", M.BTN_MARGIN + cell.x, y)
        end
        if btn.Show then btn:Show() end
      end
    end
  end
  return Z.Util.ArrayCount(rows)
end

-- Quality color helper: client GetItemQualityColor when present, else the
-- classic quality hexes (keeps headless RowText AND built links correct).
-- Unknown quality reads white, never grey (grey = poor = free loot).
function M.QualityHex(q)
  if GetItemQualityColor then
    local r, g, b = GetItemQualityColor(q or 0)
    if r then
      return string.format("|cFF%02X%02X%02X",
        math.floor((r or 1) * 255), math.floor((g or 1) * 255), math.floor((b or 1) * 255))
    end
  end
  local hexes = { "|cff9d9d9d", "|cffffffff", "|cff1eff00",
    "|cff0070dd", "|cffa335ee", "|cffff8000" }
  local i = tonumber(q)
  if i ~= nil and hexes[i + 1] ~= nil then return hexes[i + 1] end
  return "|cFFFFFFFF"
end

-- Build a REAL clickable item link from parts (RollFor parity):
-- "|c<qualityhex>|Hitem:<id>:<suffix>|h[<name>]|h|r". Used whenever the
-- client cache has no full link (uncached items, bare ids) but we know
-- the name + quality from the sheet/scan — shift-click inserts this, and
-- it renders + tooltips like any real link. Pure (headless-testable).
function M.BuildLink(itemID, name, quality, suffix)
  local id = tonumber(itemID)
  if not id or not name or name == "" then return nil end
  local hex = M.QualityHex(quality)
  local code = string.match(hex or "", "^|c(%x%x%x%x%x%x%x%x)$") or "FFFFFFFF"
  return "|c" .. code .. "|Hitem:" .. id .. ":" .. tostring(suffix or "0:0:0")
    .. "|h[" .. tostring(name) .. "]|h|r"
end

function M.Refresh()
  if not M.frame then return end
  -- No header: nothing to retitle (title widget removed in BuildFrame).
  -- Rebuild rows (cheap for a handful of drops).
  for i = 1, Z.Util.ArrayCount(M.rows) do
    if M.rows[i].Hide then M.rows[i]:Hide() end
  end
  M.rows = {}
  if type(CreateFrame) ~= "function" then return end
  local y = -10
  for i = 1, Z.Util.ArrayCount(M.items) do
    local it = M.EnsureResolved(M.items[i])
    local id = it.itemID -- lua 5.0: fresh local per iteration for the closure
    local row = CreateFrame("Button", nil, M.frame)
    if type(row) ~= "table" or type(row.SetWidth) ~= "function"
        or type(row.CreateFontString) ~= "function" then
      M.rows = {} -- minimal-frame stubs: data layer already updated above
      return
    end
    -- Raider-window style rows: icon left, quality-colored name, badge.
    -- (No row number — the roll list reads like the raider frame.)
    row:SetWidth(200) row:SetHeight(M.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", M.frame, "TOPLEFT", 10, y)
    -- 1) item icon.
    local icon
    if row.CreateTexture then
      icon = row:CreateTexture(nil, "ARTWORK")
      icon:SetWidth(M.ICON_SIZE) icon:SetHeight(M.ICON_SIZE)
      icon:SetPoint("LEFT", row, "LEFT", 2, 0)
      if icon.SetTexture then
        icon:SetTexture(it.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
      end
    end
    -- 2) item name (readable name, quality-colored — never the raw link).
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if icon then name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    else name:SetPoint("LEFT", row, "LEFT", 4, 0) end
    name:SetWidth(150) name:SetJustifyH("LEFT")
    local label = M.DisplayName(it)
    if it.quantity and it.quantity > 1 then label = label .. " x" .. it.quantity end
    if it.status == "rolling" then label = label .. " [rolling]"
    elseif it.status == "done" then label = label .. " [done]" end
    if it.ignored then label = label .. " [ignored]" end
    if name.SetText then
      name:SetText(M.QualityHex(it.quality) .. label .. "|r")
    end
    it._tipLink = M.TooltipLink(it) -- stash for the hover closures below
    -- 3) SR/HR badge on the right.
    if it.badge and it.badge ~= "" then
      local badge = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      badge:SetPoint("RIGHT", row, "RIGHT", -6, 0)
      if badge.SetText then badge:SetText(it.badge) end
      if badge.SetTextColor then
        if it.badge == "HR" then badge:SetTextColor(1, 0.2, 0.2)
        else badge:SetTextColor(1, 0.65, 0.1) end -- SR orange, like RollFor
      end
      -- Make room for the badge: shrink the name field (SetPoint RIGHT
      -- needs anchor plumbing the mock stubs lack; width is enough).
      if name.SetWidth then name:SetWidth(108) end
    end
    -- Row click: coin/free rows loot their slot at once (no detail, no
    -- rolling); roll rows open the detail (RollFor: row click selects).
    -- Slot-explicit closure: the click carries THIS row's slot, never a
    -- Find(itemID) lookup (duplicates would loot the wrong row's slot).
    if row.SetScript then
      local clickSlot = it.slot
      row:SetScript("OnClick", function() M.OnRowClick(id, clickSlot) end)
      -- Hover: item tooltip via the stashed link (never the raw scan link).
      row:SetScript("OnEnter", function()
        M.ShowTip(row, it._tipLink)
      end)
      row:SetScript("OnLeave", function()
        M.HideTip()
      end)
    end
    -- Icon hover + modifiers: the SAME shared handlers as every other
    -- icon (ItemIcon.lua: hover details, ctrl dress-up, click/shift link).
    -- Live row state at event time (slots shift after each loot, rows
    -- re-resolve under the texture). A plain click stays the row action
    -- (open detail / loot slot); only modifiers divert to icon behavior.
    if icon and icon.SetScript then
      local ZL = Z.ItemIcon
      if ZL and ZL.Hover then
        local thisRow = it
        local iconBtn = nil
        icon:SetScript("OnEnter", function()
          ZL.Hover(icon, thisRow.itemID, thisRow.link, M.DisplayName(thisRow),
            function(full) thisRow.link = full end)
        end)
        icon:SetScript("OnLeave", function() ZL.Hide() end)
        -- Textures take no clicks, so an invisible Button overlay sits
        -- exactly over the icon and carries the FULL shared handling
        -- (hover + ctrl/shift via Wire — the overlay is on top, so the
        -- texture's own hover never fires client-side; it stays as the
        -- no-overlay fallback). Plain clicks fall through to the row.
        -- In mock frames CreateFrame may exist while the overlay
        -- fails; then clicks just hit the row (nil-safe).
        if CreateFrame and row then
          local okBtn, btn = pcall(CreateFrame, "Button", nil, row)
          if okBtn and btn and btn.SetWidth then
            btn:SetWidth(M.ICON_SIZE)
            if btn.SetHeight then btn:SetHeight(M.ICON_SIZE) end
            if btn.SetPoint then btn:SetPoint("LEFT", row, "LEFT", 2, 0) end
            if btn.SetScript and ZL.Wire then
              ZL.Wire(btn, function()
                return { itemID = thisRow.itemID, link = thisRow.link,
                  name = M.DisplayName(thisRow),
                  onLink = function(full) thisRow.link = full end }
              end)
              -- Same as the row body: plain click is the row action,
              -- modifiers never roll/loot (OnRowClick diverts them to
              -- dress-up / link first). Overwrites Wire's click so a
              -- plain icon click opens the detail instead of printing.
              local iconSlot = it.slot -- same slot the row body captured
              btn:SetScript("OnClick", function()
                M.OnRowClick(id, iconSlot)
              end)
            end
            iconBtn = btn
          end
        end
        it._iconBtn = iconBtn
      else
        icon:SetScript("OnEnter", function()
          M.ShowTip(icon, it._tipLink)
        end)
        icon:SetScript("OnLeave", function()
          M.HideTip()
        end)
      end
    end
    table.insert(M.rows, row)
    y = y - (M.ROW_HEIGHT + 2)
  end
  if M.frame.SetHeight then
    M.frame:SetHeight(math.max(70, 44 - y))
  end
end

-- -- Row detail (RollFor preview equivalent) --
--
-- Clicking a row opens a small window for that item:
--   Award        — direct award, only when exactly one SR/HR holder exists
--                  (labels them, like RollFor's single-winner shortcut).
--   Roll         — its own button: start the SR roll for this item.
--   Raid roll    — its own button: number the raid, ML's number wins
--                  and the item goes straight out (no award window).
--   Sand         — its own button, Hourglass Sand rows only: hand the
--                  stack to the lowest-ledger raider (evens out).
--   ... (More)   — award anyone directly (class-grouped roster).
--   Close        — dismiss, keep working the overview.
-- Headless it prints the same rows; the ML answers via doAction(...).

-- Build the detail data for an item (pure, headless-testable).
function M.BuildDetail(itemID)
  local it = M.EnsureResolved(M.Find(itemID))
  if not it then return nil end
  local sheet = Z.DB and Z.DB.sheet
  local rollers = {}
  if sheet and Z.SRData and Z.SRData.SRNames then
    rollers = Z.SRData.SRNames(sheet, itemID)
  end
  return {
    itemID = itemID,
    link = it.link,
    name = M.DisplayName(it),
    tipLink = M.TooltipLink(it),
    badge = it.badge or "",
    status = it.status,
    source = it.source,
    ignored = it.ignored == true,
    rollers = rollers,
    single = Z.Util.ArrayCount(rollers) == 1,
    phase = "pick", -- pick -> rolling -> award
    rolls = {},
    menu = nil,
    countdown = nil,
    countdownDur = nil,
  }
end

-- Mirror the open roll onto the OPEN detail. Only the rolling window
-- for THIS item takes rolls; anything else is a dead window and the
-- roll is dropped. Rebuilds the list from the roll table every time
-- (like the raider client rebuilds from M.rolls): a missed or doubled
-- feed can never desync the window, because no feed carries state.
-- Returns true when the window shows the roll.
function M.DetailOnRoll(itemID, _player, _roll, _rollType, _effective, _minR, _maxR)
  local MLUI = Z.MasterLootUI
  local live = MLUI and MLUI.roll
  if live and live.itemID == itemID then
    M.SyncRoll(live, "DetailOnRoll")
    local d = M.detail
    return d ~= nil and d.itemID == itemID
      and (d.phase or "pick") == "rolling"
  end
  return false
end

-- Rebuild the open detail's roll list from the roll table (single
-- source of truth). No-op unless the window is open and rolling.
function M.SyncRoll(roll, why)
  local d = M.detail
  if M.rollDebug then
    Z.Print("rolldebug: sync item=" .. tostring(roll and roll.itemID)
      .. " detail=" .. tostring(d and d.itemID)
      .. " phase=" .. tostring(d and d.phase)
      .. " rolls=" .. tostring(roll and roll.rolls and Z.Util.ArrayCount(roll.rolls))
      .. (why and (" (" .. tostring(why) .. ")") or ""))
  end
  if not d or not roll or d.itemID ~= roll.itemID then return end
  if (d.phase or "pick") ~= "rolling" then return end
  local rows = {}
  for i = 1, Z.Util.ArrayCount(roll.rolls) do
    local r = roll.rolls[i]
    if r and r.name then
      table.insert(rows, { name = r.name, roll = r.roll,
        rollType = r.type, effective = r.effective or r.roll,
        min = r.min, max = r.max })
    end
  end
  d.rolls = rows
  d.countdown = roll.rollLeft or d.countdown
  d.countdownDur = roll.rollDur or d.countdownDur
  M.RefreshDetail()
end

-- The roll finished: the OPEN detail becomes the award window (winner
-- rows + ... for anyone else). A closed window means no award view --
-- closing the window ended the roll, full stop.
function M.DetailOnFinish(itemID, menu)
  local d = M.detail
  if not d or d.itemID ~= itemID then return false end
  d.menu = menu
  d.phase = "award"
  d.countdown = nil
  d.countdownDur = nil
  M.RefreshDetail()
  return true
end

-- Roll range text + sorted roll rows: both come from the shared
-- RollList view (the same view the raider frame paints through), so a
-- roll reads identically in either window. Thin wrappers kept so old
-- callers/tests keep working.
function M.RollRangeText(r)
  if Z.RollList and Z.RollList.RangeText then
    return Z.RollList.RangeText(r)
  end
  return tostring((r or {}).roll)
end

function M.SortedDetailRolls(d)
  d = d or M.detail
  if Z.RollList and Z.RollList.SortedRolls then
    return Z.RollList.SortedRolls(d and d.rolls)
  end
  return {}
end


-- Row click entry: coin/free rows loot immediately through Blizzard's
-- frame (the only path that moves the item) and leave the list. Solo,
-- EVERY corpse row loots on click (Blizzard solo behavior: click takes
-- it) — out of group there is nobody to roll against, so even
-- threshold+ rows skip the detail. Sim rows carry no corpse slot and
-- always open the detail. Returns what happened (headless-testable).
-- Click-to-loot: coin/free rows ALWAYS loot on click; solo, EVERY corpse
-- row loots on click (nobody to roll against). Loot first, drop the row
-- only once the corpse CONFIRMS it (LOOT_SLOT_CLEARED, same slot) — never
-- optimistically, so a failed LootSlot (locked, full bags, range) leaves
-- the row up for retry. Sim rows carry no corpse slot: detail as usual.
-- Returns "looting" (call issued), "loot failed" (no call), or
-- "detail" (headless-testable).
-- Group-roll rows (Blizzard's Need/Greed owns them) are display-only:
-- clicking never loots (that would steal the item out from under the
-- group roll); the row drops when Blizzard's roll resolves and the winner
-- loots it (LOOT_SLOT_CLEARED rescan).
-- clickSlot: the CLICKED row's slot from the button closure (never a
-- Find(itemID) lookup — duplicates share itemIDs). Falls back to the
-- row's tracked slot when the closure predates it (headless/tests call
-- with itemID only).
-- Passthrough: when Blizzard's frame is restored (takeover off — e.g.
-- the click-to-loot kill-switch after silent loot calls), our rows are
-- display-only: report it and touch nothing, Blizzard's own frame loots.
function M.OnRowClick(itemID, clickSlot)
  local it = M.Find(itemID)
  -- Modifiers never roll/loot: ctrl previews (dress-up), shift links
  -- the item into chat (or prints it). Applies to the whole row — body
  -- and icon alike — so click-to-open-roll can't swallow them.
  if Z.ItemIcon and Z.ItemIcon.RowClick then
    local mod = Z.ItemIcon.RowClick(it and it.itemID or itemID,
      it and it.link, it and M.DisplayName(it),
      function(full) if it then it.link = full end end)
    if mod then return mod end
  end
  if it and it.group then return "group roll" end
  local solo = Z.SRSecurity and Z.SRSecurity.IsSolo
    and Z.SRSecurity.IsSolo()
  if M.blizzardTakeover == false then return "passthrough" end
  local slot = clickSlot or (it and it.slot)
  -- Rehearsal: solo non-coin rows open the roll detail instead of
  -- insta-looting (every corpse item gets its roll window + award flow).
  local rehearsing = solo and Z.DB and Z.DB.rehearse
    and not (it and it.coin)
  if rehearsing then
    return M.OpenDetail(itemID) and "detail" or nil
  end
  if it and slot and (it.coin or it.free or solo) then
    local issued = nil
    if Z.MasterLootUI and Z.MasterLootUI.LootCorpseSlot then
      local me = nil
      if UnitName then local ok, nm = pcall(UnitName, "player") if ok then me = nm end end
      issued = Z.MasterLootUI.LootCorpseSlot(it.link, itemID, me, slot)
    end
    -- STRICT true: "noslot" (corpse unreadable), "gone" (item already
    -- off the corpse — rescan to reconcile) and false (refused) must
    -- NEVER dim the row — a dimmed-but-unlooted row is exactly the
    -- reported "gray and says done, still not looted" ghost.
    -- "passthrough" (Blizzard frame restored, hands off): nothing to dim.
    if issued == "gone" then
      -- RescanLeftovers closes itself when it actually dropped rows.
      if Z.MasterLootUI and Z.MasterLootUI.RescanLeftovers then
        Z.MasterLootUI.RescanLeftovers()
      end
      return "gone"
    end
    -- Moved away: block early, list untouched, log it. Re-loot the same
    -- creature to resume — the window (rolls included) is still open.
    if issued == "norange" then
      Z.Print("Not looting " .. tostring(M.DisplayName(it))
        .. ": you moved away from the corpse. "
        .. "Loot it again to resume — the window is still open.")
      return "not looting"
    end
    -- No open corpse (walked away / closed): same block, same intact
    -- list. Re-looting resumes the window whole.
    if issued == "nolooot" then
      Z.Print("Not looting " .. tostring(M.DisplayName(it))
        .. ": no loot open. "
        .. "Loot the corpse again to resume — the window is still open.")
      return "not looting"
    end
    if issued == "passthrough" then return "passthrough" end
    if issued == true then
      M.MarkDone(itemID)
      -- Watchdog: if no confirm/error lands within 4s, re-read the slot
      -- and un-dim a still-present row (silent server ignore must never
      -- strand grey rows). Disarmed by confirm/error firing first.
      if M.WatchClick then M.WatchClick(slot, itemID, M.DisplayName(it)) end
      -- Kill-switch watch: clicks only (awards don't feed it — an ML
      -- re-awarding the same item must never restore Blizzard's frame).
      -- TWO consecutive silent clicks (issued clean, never confirmed) on
      -- the same slot+item = dead LootSlot path: restore Blizzard's frame.
      if M.NoteSilentLoot then M.NoteSilentLoot(slot, itemID) end
      if M.lootDebug then
        local link = nil
        if GetLootSlotLink then
          local ok, l = pcall(GetLootSlotLink, slot)
          if ok then link = l end
        end
        local method = nil
        if GetLootMethod then
          local ok, m = pcall(GetLootMethod)
          if ok then method = m end
        end
        -- FULL link (never truncated: names with spaces must be verifiable)
        -- plus loot method, so a wrong-slot vs dead-call cause is conclusive.
        Z.Print("lootdebug: row=" .. tostring(M.DisplayName(it))
          .. " LootSlot(" .. tostring(slot) .. ") of "
          .. tostring(GetNumLootItems and GetNumLootItems())
          .. " method=" .. tostring(method)
          .. " link=" .. tostring(link))
      end
      return "looting"
    end
    return "loot failed"
  end
  return M.OpenDetail(itemID) and "detail" or nil
end

-- /zl lootdebug: verbose click-to-loot logging (slot, corpse size, link).
-- Sticky: stays on until toggled off (survives reloads) so a silent
-- call can be caught across sessions without re-arming mid-corpse.
M.lootDebug = false

-- /zl rolldebug: one chat line per roll feed naming exactly where it
-- landed (or which guard dropped it: no window / wrong item / not
-- rolling). Off by default; turn it on when the ML window ever shows
-- rolls going missing again — the log names the guard instead of
-- guessing. Headless-safe: plain Z.Print.
M.rollDebug = false

-- Silent-call kill-switch: tracks consecutive click-to-loot calls that
-- issued clean but never confirmed (no LOOT_SLOT_CLEARED, no error).
-- LOOT_SLOT_CLEARED disarms via RescanLeftovers (arms clear there); any
-- second silent call while one is still armed = the LootSlot path is dead
-- on this client: restore Blizzard's frame (takeover off) so loot keeps
-- working through the stock UI instead of stranding dimmed rows.
-- Solo-only guard lives at the call site (grouped rolls need our flow).
-- Headless-safe: pure table + client-global touch isolated in Detach.
M.silentLootArms = nil
function M.NoteSilentLoot(slot, itemID)
  local solo = Z.SRSecurity and Z.SRSecurity.IsSolo
    and Z.SRSecurity.IsSolo()
  if not solo then return end
  -- Corpse-scoped: arms belong to the pinned corpse key. A new corpse
  -- (walk-away-and-back on something else) starts with a clean watch —
  -- an old corpse's silence must never trip the switch on a new one.
  local key = Z.MasterLootUI and Z.MasterLootUI.lootKey or nil
  if M.silentLootArms and Z.Util.ArrayCount(M.silentLootArms) > 0
      and M.silentLootArms[1] and M.silentLootArms[1].corpse ~= key then
    M.silentLootArms = nil
  end
  M.silentLootArms = M.silentLootArms or {}
  for i = 1, Z.Util.ArrayCount(M.silentLootArms) do
    local a = M.silentLootArms[i]
    if a and a.slot == slot and a.itemID == itemID then
      -- Second silent call on the same slot+item: path is dead. Persist
      -- the stand-down (survives corpses AND reloads) so the next corpse
      -- doesn't re-detach into the same broken loop — Blizzard's frame
      -- handles loot until the user re-arms (/zl lootframe, Setup tab).
      M.silentLootArms = nil
      if Z.LootWindow and Z.LootWindow.Clear then Z.LootWindow.Clear() end
      M.SetTakeoverWanted(false)
      -- The current corpse was scanned under a detached frame, so
      -- Blizzard's window can't show it (forced Show would crash
      -- FrameXML on nil page state). Re-loot the corpse for the stock UI.
      Z.Print("ZugLoot loot clicks aren't reaching the server — "
        .. "Blizzard loot frame restored (stays off until /zl lootframe). "
        .. "Close this corpse and loot it again; /zl sheet etc. still work.")
      return
    end
  end
  table.insert(M.silentLootArms,
    { slot = slot, itemID = itemID,
      corpse = Z.MasterLootUI and Z.MasterLootUI.lootKey or nil })
end

-- Open the row detail. Switching rows CLOSES the current window: if
-- it was rolling, the roll ends early right there (EndRoll) — a closed
-- window never keeps rolling behind anything. The new row opens fresh
-- in pick phase.
function M.OpenDetail(itemID)
  -- Already on this item: the window stays exactly as it is (a rolling
  -- window keeps its rolls; nothing rebuilds under it).
  if M.detail and M.detail.itemID == itemID then
    M.RefreshDetail()
    return M.detail
  end
  if M.detail then
    M.doAction(M.detail.itemID, "close")
  end
  local d = M.BuildDetail(itemID)
  if not d then return nil end
  M.detail = d
  M.RefreshDetail()
  return d
end

-- Detail-frame X button entry: the shared Close ACTION path. Headless-
-- testable (frame clicks need a client); asserts the wiring, not just
-- the action the wiring calls.
function M.OnCloseButton()
  if M.detail then return M.doAction(M.detail.itemID, "close") end
end

-- Close the detail window. Closing a ROLLING window ends the roll early
-- (EndRoll first): nothing keeps rolling behind a closed window, and a
-- closed roll never auto-finishes late. Closing the AWARD window drops
-- the finish stamp too: there is nothing left to continue once the
-- window is gone. Anything else just goes away.
function M.CloseDetail()
  local d = M.detail
  M.CloseMoreDropdown()
  M.detail = nil
  if d and (d.phase or "pick") == "rolling"
      and Z.MasterLootUI and Z.MasterLootUI.EndRoll then
    Z.MasterLootUI.EndRoll(d.itemID)
  end
  if d and (d.phase or "pick") == "award"
      and Z.MasterLootUI then
    Z.MasterLootUI.lastRound = nil
  end
  if M.detailFrame and M.detailFrame.Hide then M.detailFrame:Hide() end
  M.detailFrame = nil
end

-- Detail display lines (headless/text): title, phase body, actions.
function M.DetailLines(d)
  d = d or M.detail
  local lines = {}
  if not d then return lines end
  local head = tostring(d.name or d.link or ("item:" .. d.itemID))
  if d.badge and d.badge ~= "" then head = head .. " [" .. d.badge .. "]" end
  if d.ignored then head = head .. " [ignored]" end
  if d.phase == "rolling" then
    head = head .. " [rolling"
    -- Headless mirror of the client countdown bar (bar + seconds): the
    -- ML reads the clock off the same text the client paints.
    if d.countdown then head = head .. " (" .. tostring(d.countdown) .. "s)" end
    head = head .. "]"
  end
  table.insert(lines, head)
  if d.phase == "rolling" then
    -- Live roll list: every valid roll with its kind and the max of the
    -- /roll command used (56/98 for a TMOG roll). RollFor roll view.
    local rows = M.SortedDetailRolls(d)
    if Z.Util.ArrayCount(rows) == 0 then
      table.insert(lines, "  waiting for rolls...")
    else
      for i = 1, Z.Util.ArrayCount(rows) do
        local r = rows[i]
        table.insert(lines, "  " .. tostring(r.rollType) .. ": "
          .. PName(r.name) .. " " .. M.RollRangeText(r))
      end
    end
  elseif d.phase == "award" and d.menu then
    -- Award window: winner rows first, then the ... choices.
    local winners = d.menu.winners or {}
    for i = 1, Z.Util.ArrayCount(winners) do
      local w = winners[i]
      table.insert(lines, "  winner: " .. PName(w.name)
        .. " (" .. tostring(w.rollType) .. " " .. tostring(w.effective) .. ")")
    end
    if Z.Util.ArrayCount(winners) == 0 then
      table.insert(lines, "  (no eligible rolls — pick anyone or cancel)")
    end
  else
    if Z.Util.ArrayCount(d.rollers) > 0 then
      local rn = {}
      for i = 1, Z.Util.ArrayCount(d.rollers) do
        table.insert(rn, PName(d.rollers[i]))
      end
      table.insert(lines, "  reserved by: " .. table.concat(rn, ", "))
    else
      table.insert(lines, "  no reserves — open roll")
    end
  end
  local actions = M.DetailActions(d)
  local names = {}
  for i = 1, Z.Util.ArrayCount(actions) do table.insert(names, actions[i].label) end
  table.insert(lines, "  actions: " .. table.concat(names, " | "))
  return lines
end

-- Detail actions (data) per phase.
-- pick:    Award (single holder only), Roll, Raid roll, Ignore,
--          ... (More), Close.
-- rolling: Finish (resolve now, award on this window), Cancel (end the
--          roll, window back to pick), Raid roll (end the open roll and
--          raid-roll the item instead), Ignore (mark ignored, no award),
--          Close (ends roll AND closes).
-- award:   Award <winner> per winner row, Continue rolling (reopen
--          intake, landed rolls kept), Roll again (fresh), Raid roll,
--          Ignore, ... (anyone else), Close.
function M.DetailActions(d)
  d = d or M.detail
  local actions = {}
  if not d then return actions end
  local MLUI = Z.MasterLootUI
  if (d.phase or "pick") == "rolling" then
    table.insert(actions, { id = "finish", label = "Finish" })
    table.insert(actions, { id = "cancel", label = "Cancel" })
    table.insert(actions, { id = "raidroll", label = "Raid roll" })
    table.insert(actions, { id = "ignore", label = "Ignore" })
    table.insert(actions, { id = "close", label = "Close" })
    return actions
  end
  if (d.phase or "pick") == "award" and d.menu then
    -- Every kind winner gets its own row: overall winner(s) first, then
    -- each contested kind not already listed. Continue rolling reopens
    -- intake with the landed rolls kept (Roll again starts fresh);
    -- Raid roll sits on the bar next to the winners; ... covers anyone
    -- else.
    local listed = {}
    for i = 1, Z.Util.ArrayCount(d.menu.winners or {}) do
      local w = d.menu.winners[i]
      table.insert(actions, { id = "award-name", label = "Award " .. PName(w.name)
        .. " (" .. tostring(w.rollType) .. ")", name = w.name, via = "winner" })
      listed[w.name] = true
    end
    for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
      local trow = (d.menu.perType or {})[gt]
      if trow and trow.entry and not listed[trow.entry.name] then
        listed[trow.entry.name] = true
        local via = (gt == "TMOG") and "tmog" or "winner"
        table.insert(actions, { id = "award-name",
          label = "Award " .. PName(trow.entry.name) .. " (" .. gt .. ")",
          name = trow.entry.name, via = via })
      end
    end
    table.insert(actions, { id = "continue", label = "Continue rolling" })
    table.insert(actions, { id = "roll", label = "Roll again" })
    table.insert(actions, { id = "raidroll", label = "Raid roll" })
    table.insert(actions, { id = "ignore", label = "Ignore" })
    table.insert(actions, { id = "more", label = "..." })
    table.insert(actions, { id = "close", label = "Close" })
    return actions
  end
  if d.single then
    table.insert(actions, { id = "award", label = "Award " .. PName(d.rollers[1]) })
  end
  table.insert(actions, { id = "roll", label = "Roll" })
  table.insert(actions, { id = "raidroll", label = "Raid roll" })
  if MLUI and MLUI.IsSandItem and MLUI.IsSandItem(d.itemID) then
    table.insert(actions, { id = "sand", label = "Sand" })
  end
  table.insert(actions, { id = "ignore", label = "Ignore" })
  table.insert(actions, { id = "more", label = "..." })
  table.insert(actions, { id = "close", label = "Close" })
  return actions
end

-- Headless/text action entry: AwardChosen for award, MoreLines for ...,
-- CloseDetail for close. Returns a string (what happened) for tests.
function M.doAction(itemID, actionID, extra)
  local d = M.detail
  if not d or d.itemID ~= itemID then
    d = M.OpenDetail(itemID)
  end
  if not d then return "unknown item" end
  local MLUI = Z.MasterLootUI
  if actionID == "close" then
    M.CloseDetail()
    return "closed"
  end
  if actionID == "award" then
    if not d.single then return "needs choice (...)" end
    if MLUI and MLUI.AwardDirect then
      MLUI.AwardDirect(d.itemID, d.rollers[1], d.source)
    end
    M.CloseDetail()
    return "awarded " .. d.rollers[1]
  end
  if actionID == "more" then
    return M.MoreLines(d)
  end
  if actionID == "ignore" then
    -- Ignore: mark the row ignored (it stays listed) with no award, no
    -- won mark, no history. Ends any open roll for the item first (same
    -- as awarding). The item stays on the corpse for manual handling;
    -- the audit trail records it as ignored.
    if MLUI and MLUI.Ignore then
      MLUI.Ignore(d.itemID, d.source)
      return "ignored " .. tostring(d.itemID)
    end
    return "ignore failed"
  end
  if actionID == "sand" then
    -- Sand: distribute one Hourglass Sand row to the lowest-ledger
    -- raider (ledger evens out over the raid). Not a roll: no SR,
    -- no award window, no sheet writes — just the handoff + ledger.
    if MLUI and MLUI.IsSandItem and MLUI.IsSandItem(d.itemID)
        and MLUI.SandDistribute then
      if MLUI.SandDistribute(d.itemID, d.source) then
        return "sand " .. tostring(d.itemID)
      end
      return "sand failed"
    end
    return "sand failed"
  end
  if actionID == "roll" then
    -- Refused while ANY roll is open (finish, award, or close it first).
    if MLUI and MLUI.roll then return "roll failed" end
    -- Starters report by return (roll table / true = rolling). The
    -- window flips only on a real start — never on a refusal.
    local started
    -- Rehearsal rows roll invented raiders through the same live path.
    if d.source ~= "sim" and Z.Sim and Z.Sim.RequestRoll
        and Z.Sim.Rehearsing and Z.Sim.Rehearsing() then
      started = Z.Sim.RequestRoll(d.itemID)
    elseif d.source == "sim" then
      started = Z.Sim and Z.Sim.RequestRoll and Z.Sim.RequestRoll(d.itemID)
    else
      started = MLUI and MLUI.StartItemRoll and MLUI.StartItemRoll(d.itemID)
    end
    if started then
      d.phase = "rolling"
      d.rolls = {}
      d.menu = nil
      d.status = "rolling"
      M.seedCountdown(d)
      -- Starters that land rolls instantly (sim/rehearsal fakes feed
      -- AddRoll -> SyncRoll mid-start) already filled the mirror — the
      -- wipe above just cleared it, so rebuild off the live roll.
      -- Live starts hold no rolls yet: the rebuild is an empty no-op
      -- and the window correctly shows "waiting for rolls...".
      if MLUI and MLUI.roll then M.SyncRoll(MLUI.roll, "roll-start") end
      M.RefreshDetail()
      return "rolling"
    end
    return "roll failed"
  end
  if actionID == "raidroll" then
    -- Raid roll button: the open roll (if any) for this item ends
    -- early FIRST (explicit user end), then the raid-roll starts on the
    -- same window. On success the old view wipes and flips to rolling;
    -- on refusal the window drops back to pick with the old rolls kept
    -- for the record (nothing live behind them).
    if MLUI and MLUI.roll and MLUI.roll.itemID ~= d.itemID then
      return "roll failed"
    end
    if MLUI and MLUI.EndRoll then MLUI.EndRoll(d.itemID) end
    local started = MLUI and MLUI.StartRaidRoll
      and MLUI.StartRaidRoll(d.itemID)
    if started then
      d.rolls = {}
      d.menu = nil
      d.phase = "rolling"
      d.status = "rolling"
      M.seedCountdown(d)
      M.RefreshDetail()
      return "rolling"
    end
    d.phase = "pick"
    d.status = "open"
    d.countdown = nil
    d.countdownDur = nil
    M.RefreshDetail()
    return "roll failed"
  end
  if actionID == "award-name" then
    -- Award a named raider from ANY phase: the roll (if any) ends early
    -- inside the award. Stays open on failure, closes on success.
    local nm = extra
    if type(extra) == "table" then nm = extra.name end
    if MLUI and MLUI.AwardChosen then
      MLUI.AwardChosen({ name = nm }, d.itemID, d.source)
      return "awarded " .. tostring(nm)
    end
    return "award failed"
  end
  if actionID == "finish" then
    if MLUI and MLUI.FinishRoll then
      return MLUI.FinishRoll(itemID)
    end
    return "finish failed"
  end
  if actionID == "continue" then
    -- Continue rolling: reopen intake on the finished window, landed
    -- rolls kept (unlike "roll", which starts fresh). Refuses without
    -- the finish stamp (same item, award phase) or with a live roll.
    if MLUI and MLUI.roll then return "roll failed" end
    if (d.phase or "pick") ~= "award" then return "roll failed" end
    local resumed = MLUI and MLUI.ContinueRoll
      and MLUI.ContinueRoll(d.itemID)
    if resumed then
      -- Keep the landed rolls on the window: the truth already holds
      -- them (carried over inside ContinueRoll), so mirror it whole.
      -- A missed or doubled feed can never desync the mirror.
      d.menu = nil
      d.phase = "rolling"
      d.status = "rolling"
      M.seedCountdown(d)
      M.SyncRoll(resumed, "continue")
      M.RefreshDetail()
      return "rolling"
    end
    return "roll failed"
  end
  if actionID == "cancel" then
    if MLUI and MLUI.Cancel then MLUI.Cancel(itemID) end
    if M.detail and M.detail.itemID == itemID then
      local dd = M.detail
      dd.phase = "pick"
      dd.rolls = {}
      dd.menu = nil
      dd.countdown = nil
      dd.countdownDur = nil
      dd.status = "open"
      M.RefreshDetail()
    end
    return "cancelled"
  end
  return "unknown action"
end

-- Seed the rolling countdown at once (full window, not one tick late).
function M.seedCountdown(d)
  local MLUI = Z.MasterLootUI
  local roll = MLUI and MLUI.roll
  local dur = (roll and roll.rollDur)
    or (MLUI and MLUI.RollDuration and MLUI.RollDuration()) or nil
  d.countdown = (roll and roll.rollLeft) or dur
  d.countdownDur = dur or d.countdown
end

-- The "..." (More) list: every awardable name. Roll initiation lives on
-- the bar buttons (Roll / Raid roll), never in the menu.
-- Returns lines (headless) and stores them for the client frame.
-- Pre-roll the roster groups by class (same groups the client shows as
-- side submenus); every listed name awards directly, no roll needed.
function M.MoreLines(d)
  d = d or M.detail
  local lines = {}
  if not d then return lines end
  table.insert(lines, "Award " .. tostring(d.name or d.link or ("item:" .. d.itemID)) .. " to?")
  if Z.Util.ArrayCount(d.rollers) > 0 then
    for i = 1, Z.Util.ArrayCount(d.rollers) do
      table.insert(lines, "  SR: " .. PName(d.rollers[i]))
    end
  end
  if (d.phase or "pick") == "pick" then
    -- Roll initiation lives on the bar buttons, not in this list.
    local seen = {}
    for i = 1, Z.Util.ArrayCount(d.rollers or {}) do
      if d.rollers[i] then seen[d.rollers[i]] = true end
    end
    for i = 1, Z.Util.ArrayCount(d.rolls or {}) do
      if d.rolls[i] and d.rolls[i].name then seen[d.rolls[i].name] = true end
    end
    if (d.phase or "pick") ~= "award" or not d.menu then
      -- Pick/rolling phase: class groups of everyone reachable (landed
      -- rollers + live raid roster) — so pre-roll the ... menu still
      -- reaches every raider for a direct award. Empty classes omitted;
      -- members never duplicate the labeled top-level rows.
      -- (Award phase: the bar buttons own re-rolls; list stays awardable
      -- names only, i.e. nothing more to add here.)
      for _, g in ipairs(M.MoreClassGroups(d, seen)) do
        local names = {}
        for m = 1, Z.Util.ArrayCount(g.members) do
          if g.members[m] then table.insert(names, PName(g.members[m].name)) end
        end
        if Z.Util.ArrayCount(names) > 0 then
          table.insert(lines, "  " .. tostring(g.class) .. ": " .. table.concat(names, ", "))
        end
      end
    end
  end
  table.insert(lines, "  Anyone: /zl award <name> after the roll, or award now")
  return lines
end

function M.RefreshDetail()
  local d = M.detail
  if not d then
    if M.detailFrame and M.detailFrame.Hide then M.detailFrame:Hide() end
    return
  end
  if not CreateFrame then return end -- headless: data only
  if not M.detailFrame then M.BuildDetailFrame() end
  if not M.detailFrame then return end
  M.PaintDetailFrame()
  M.detailFrame:Show()
end

function M.BuildDetailFrame()
  if M.detailFrame then return M.detailFrame end
  if not CreateFrame then return nil end
  local parent = M.frame or UIParent
  local f = CreateFrame("Frame", "ZugLootLootDetailFrame", parent)
  if type(f) ~= "table" or type(f.SetWidth) ~= "function"
      or type(f.CreateFontString) ~= "function" then
    return nil
  end
  -- Raider-window style: 220px dark frame, 40px item icon + name header.
  f:SetWidth(220) f:SetHeight(250)
  f:SetPoint("CENTER", parent, "CENTER", 350, 40)
  f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0, 0, 0, 0.85)
  f:SetBackdropBorderColor(0.2, 0.2, 0.2)
  f:SetMovable(true) f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  f:SetClampedToScreen(true)
  -- Icon top-center (mirrors the raider frame header). Its own Button
  -- overlay carries the SAME shared handlers as every other icon
  -- (ItemIcon.lua: hover details, ctrl dress-up, click/shift link).
  -- Live detail state at event time (the detail flips items under it).
  local dicon = f:CreateTexture(nil, "ARTWORK")
  dicon:SetWidth(40) dicon:SetHeight(40)
  dicon:SetPoint("TOP", f, "TOP", 0, -10)
  f.dicon = dicon
  if Z.ItemIcon and Z.ItemIcon.Wire and CreateFrame then
    local okBtn, dib = pcall(CreateFrame, "Button", nil, f)
    if okBtn and dib and dib.SetWidth then
      dib:SetWidth(40)
      if dib.SetHeight then dib:SetHeight(40) end
      if dib.SetPoint then dib:SetPoint("TOP", f, "TOP", 0, -10) end
      if dib.SetScript then
        Z.ItemIcon.Wire(dib, function()
          local d = M.detail
          if not d then return nil end
          local it = M.Find(d.itemID)
          return { itemID = d.itemID,
            link = (it and it.link) or d.link or d.tipLink,
            name = (it and M.DisplayName(it)) or d.name,
            onLink = function(full)
              if it then it.link = full end
              if M.detail and M.detail.itemID == d.itemID then
                if M.detail.link then M.detail.link = full end
                M.detail.tipLink = full
              end
            end }
        end)
        f.diconBtn = dib
      end
    end
  end
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", dicon, "BOTTOM", 0, -6)
  title:SetWidth(200) title:SetJustifyH("CENTER")
  f.title = title
  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
  sub:SetWidth(200) sub:SetJustifyH("CENTER")
  f.sub = sub
  -- Countdown bar floating above the frame (raider-window parity:
  -- green->orange->red, seconds text, pulses under 5s). Shown only
  -- while rolling; d.countdown/d.countdownDur own the values.
  local timerBar = CreateFrame("StatusBar", nil, f)
  timerBar:SetWidth(200) timerBar:SetHeight(14)
  timerBar:SetPoint("TOP", f, "TOP", 0, 18)
  timerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  timerBar:SetStatusBarColor(0.2, 0.7, 0.2, 1)
  timerBar:Hide()
  local timerBarText = timerBar:CreateFontString(nil, "OVERLAY",
    "GameFontHighlightSmall")
  timerBarText:SetPoint("CENTER", timerBar, "CENTER", 0, 0)
  f.timerBar = timerBar
  f.timerBarText = timerBarText
  -- Live roll list: two columns like the raider frame (names left,
  -- "roll (min-max)" right, grouped SR > MS > OS > TMOG). Hidden in
  -- pick phase, shown while rolling / awarding.
  local rollsL = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rollsL:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -120)
  rollsL:SetJustifyH("LEFT")
  rollsL:SetWidth(110)
  rollsL:SetHeight(70)
  f.rollsL = rollsL
  local rollsR = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rollsR:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -120)
  rollsR:SetJustifyH("RIGHT")
  rollsR:SetWidth(100)
  rollsR:SetHeight(70)
  f.rollsR = rollsR
  -- Legacy single-text widget (kept so old paint/tests referencing
  -- f.rolls keep working; hidden, mirrors rollsL content).
  local rolls = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  rolls:SetPoint("TOP", sub, "BOTTOM", 0, -6)
  rolls:SetWidth(200) rolls:SetJustifyH("LEFT")
  if rolls.Hide then rolls:Hide() end
  f.rolls = rolls
  -- Button bar pinned to the BOTTOM (never overlapping the roll list):
  -- primary left, Roll, Raid roll, Ignore, ... right. Roll + Raid roll
  -- are their own buttons (never inside ...): rolling starts one click,
  -- on every phase that can start one (pick, mid-roll switch, award
  -- re-rolls). Continue rolling reopens a finished round with the
  -- landed rolls kept. Ignore marks the row ignored on every phase.
  -- pick:    "Award <name>" on a single holder, else hidden; Roll +
  --          Raid roll always; ... = award anyone.
  -- rolling: "Finish" (resolve now, award on this window) + Raid roll
  --          (end the open roll, raid-roll instead); Roll hides.
  -- award:   "Award <top winner>" (further winners via their own rows),
  --          Continue rolling + Roll again + Raid roll next to them.
  -- Width fits the label: measured text + padding, capped to the bar.
  -- NOTE: no SetPoint here — LayoutBar places all buttons (flow layout).
  local awardB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  awardB:SetHeight(M.BTN_HEIGHT)
  awardB:SetText("Award")
  awardB:SetScript("OnClick", function()
    if not M.detail then return end
    local ph = M.detail.phase or "pick"
    if ph == "rolling" then M.doAction(M.detail.itemID, "finish")
    elseif ph == "award" then
      -- First award action row (top winner, incl. TMOG via choice).
      local acts = M.DetailActions(M.detail)
      local first = acts and acts[1]
      if first and first.id == "award-name" then
        M.doAction(M.detail.itemID, "award-name",
          { name = first.name, via = first.via })
      end
    else M.doAction(M.detail.itemID, "award") end
  end)
  f.awardB = awardB
  -- Second award button: "Award TMOG" (TMOG kind winner). Visible in the
  -- award phase whenever the TMOG kind was contested. Sits right of the
  -- primary so both awards are one click, no ... menu needed.
  local tmogB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  tmogB:SetHeight(M.BTN_HEIGHT)
  tmogB:SetText("Award TMOG")
  tmogB:SetScript("OnClick", function()
    if not M.detail then return end
    local acts = M.DetailActions(M.detail)
    for i = 1, Z.Util.ArrayCount(acts or {}) do
      local a = acts[i]
      if a.id == "award-name" and a.via == "tmog" then
        M.doAction(M.detail.itemID, "award-name",
          { name = a.name, via = a.via })
        return
      end
    end
  end)
  f.tmogB = tmogB
  -- Roll: its own button (never inside ...) — starts the SR roll for
  -- this item. Visible on pick + award (re-roll); hidden mid-roll.
  local rollB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  rollB:SetHeight(M.BTN_HEIGHT)
  rollB:SetText("Roll")
  rollB:SetScript("OnClick", function()
    if M.detail then M.doAction(M.detail.itemID, "roll") end
  end)
  f.rollB = rollB
  -- Raid roll: its own button (never inside ...) — numbers the raid,
  -- the ML's number wins and the item goes straight out. Visible on
  -- pick + award (re-roll) and mid-roll (ends the open roll first).
  local raidB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  raidB:SetHeight(M.BTN_HEIGHT)
  raidB:SetText("Raid roll")
  raidB:SetScript("OnClick", function()
    if M.detail then M.doAction(M.detail.itemID, "raidroll") end
  end)
  f.raidB = raidB
  -- Continue rolling: reopens intake on a FINISHED round with the
  -- landed rolls kept (unlike Roll again, which starts fresh). Visible
  -- on the award window only.
  local contB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  contB:SetHeight(M.BTN_HEIGHT)
  contB:SetText("Continue rolling")
  contB:SetScript("OnClick", function()
    if M.detail then M.doAction(M.detail.itemID, "continue") end
  end)
  f.contB = contB
  -- Ignore: marks the row ignored (stays listed) — no award, no won
  -- mark, no corpse take. Visible on every phase (pick, rolling, award).
  local ignoreB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  ignoreB:SetHeight(M.BTN_HEIGHT)
  ignoreB:SetText("Ignore")
  ignoreB:SetScript("OnClick", function()
    if M.detail then M.doAction(M.detail.itemID, "ignore") end
  end)
  f.ignoreB = ignoreB
  -- Sand: distributes one Hourglass Sand row to the lowest-ledger
  -- raider. Built always (paint decides visibility); only ever shown
  -- on sand rows (pick phase — sand is never rolled).
  local sandB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  sandB:SetHeight(M.BTN_HEIGHT)
  sandB:SetText("Sand")
  sandB:SetScript("OnClick", function()
    if M.detail then M.doAction(M.detail.itemID, "sand") end
  end)
  f.sandB = sandB
  -- "..." More: a real dropdown (RollFor GuiElements.dropdown parity) —
  -- award anyone on the list. Anchored above the
  -- button (drops UP like RollFor's candidate frame) so it never covers
  -- the bar.
  local moreB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  moreB:SetWidth(M.BTN_MORE_W) moreB:SetHeight(M.BTN_HEIGHT)
  moreB:SetText("...")
  moreB:SetScript("OnClick", function()
    if M.detail then M.ToggleMoreDropdown(moreB) end
  end)
  f.moreB = moreB
  -- X in the top-right corner: close the window (ends any open roll).
  local closeB = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  closeB:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
  f.closeB = closeB
  -- Routed via OnCloseButton (named for tests) rather than inline.

  closeB:SetScript("OnClick", function() M.OnCloseButton() end)
  M.detailFrame = f
  return f
end

function M.PaintDetailFrame()
  local f, d = M.detailFrame, M.detail
  if not f or not d then return end
  local phase = d.phase or "pick"
  if f.title and f.title.SetText then
    local head = tostring(d.name or d.link or ("item:" .. d.itemID))
    if d.badge and d.badge ~= "" then head = head .. " [" .. d.badge .. "]" end
    if d.ignored then head = head .. " [ignored]" end
    if phase == "rolling" then head = head .. " [rolling]" end
    f.title:SetText(head)
  end
  if f.title and f.title.SetScript then
    f.title:SetScript("OnEnter", function() M.ShowTip(f.title, d.tipLink) end)
    f.title:SetScript("OnLeave", function() M.HideTip() end)
  end
  if f.sub and f.sub.SetText then
    if phase == "rolling" then
      local n = Z.Util.ArrayCount(d.rolls or {})
      local cd = d.countdown and (" (" .. tostring(d.countdown) .. "s)") or ""
      f.sub:SetText("Rolling..." .. cd .. " (" .. n .. " roll" .. (n == 1 and "" or "s") .. ")")
    elseif phase == "award" and d.menu then
      local winners = d.menu.winners or {}
      if Z.Util.ArrayCount(winners) > 0 then
        local w = {}
        for i = 1, Z.Util.ArrayCount(winners) do
          table.insert(w, PName(winners[i].name) .. " (" .. tostring(winners[i].rollType)
            .. " " .. tostring(winners[i].effective) .. ")")
        end
        f.sub:SetText("Winner: " .. table.concat(w, ", "))
      else
        f.sub:SetText("No eligible rolls — pick anyone (...)")
      end
    elseif Z.Util.ArrayCount(d.rollers) > 0 then
      local rn = {}
      for i = 1, Z.Util.ArrayCount(d.rollers) do
        table.insert(rn, PName(d.rollers[i]))
      end
      f.sub:SetText("Reserved by: " .. table.concat(rn, ", "))
    else
      f.sub:SetText("No reserves — open roll")
    end
  end
  -- Countdown bar: raider-window parity (green->orange->red, seconds
  -- text, pulse under 5s). Rolling only; every other phase hides it.
  if f.timerBar then
    if phase == "rolling" and d.countdown then
      local left = tonumber(d.countdown) or 0
      if left < 0 then left = 0 end
      local dur = tonumber(d.countdownDur) or left
      if dur <= 0 then dur = left end
      if f.timerBar.SetMinMaxValues then f.timerBar:SetMinMaxValues(0, dur) end
      if f.timerBar.SetValue then f.timerBar:SetValue(left) end
      if f.timerBarText and f.timerBarText.SetText then
        f.timerBarText:SetText(string.format("%.0fs", left))
      end
      local pct = (dur > 0) and (left / dur) or 0
      if f.timerBar.SetStatusBarColor then
        if pct < 0.25 then f.timerBar:SetStatusBarColor(1, 0.1, 0.1)
        elseif pct < 0.5 then f.timerBar:SetStatusBarColor(1, 0.6, 0)
        else f.timerBar:SetStatusBarColor(0.2, 0.7, 0.2, 1) end
      end
      if f.timerBar.SetAlpha then
        if left <= 5 and left > 0 and GetTime then
          f.timerBar:SetAlpha(0.5 + 0.5 * math.sin(GetTime() * 15))
        else
          f.timerBar:SetAlpha(1)
        end
      end
      if f.timerBar.Show then f.timerBar:Show() end
    else
      if f.timerBar.Hide then f.timerBar:Hide() end
      if f.timerBar.SetAlpha then f.timerBar:SetAlpha(1) end
    end
  end
  -- The legacy f.rolls mirror stays hidden always: showing it paints
  -- a second bare-name block stacked above the two columns (every
  -- roller twice).
  if f.rolls and f.rolls.Hide then f.rolls:Hide() end
  -- Live roll list: painted through the shared RollList view (same
  -- grouping/colors/ranges as the raider frame). Empty + ROLLING shows
  -- the waiting text; pick phase stays blank; the award phase shows
  -- the landed rolls (possibly none — the sub header already says
  -- "No eligible rolls", never "waiting" once the roll is over).
  if Z.RollList and Z.RollList.Paint then
    if phase == "pick" then
      Z.RollList.Paint(f.rollsL, f.rollsR, d.rolls, nil)
    elseif phase == "rolling" then
      Z.RollList.Paint(f.rollsL, f.rollsR, d.rolls,
        { waiting = "waiting for rolls..." })
    else
      Z.RollList.Paint(f.rollsL, f.rollsR, d.rolls, nil)
    end
  end
  -- Button bar: collect the visible buttons, then flow-layout them
  -- (justify each row, wrap when narrow). Bar order: primary, TMOG,
  -- Continue rolling, Roll, Raid roll, Sand, Ignore, .... Sand shows
  -- only on sand rows in pick phase (sand is never rolled). A lone
  -- row spreads edge to edge; overflow wraps above.
  -- (Close lives top-right as X, not in the bar.)
  local barW = M.DETAIL_WIDTH - M.BTN_MARGIN * 2
  local slots = {}
  local function showBtn(btn, text)
    if btn.SetText then btn:SetText(text) end
    if btn.Enable then btn:Enable() end
    table.insert(slots, { btn = btn, w = M.ButtonWidth(btn, text) })
  end
  -- Award rows: primary = top winner, TMOG button = TMOG kind
  -- winner, Continue rolling + Roll/Raid roll = re-roll buttons,
  -- Ignore = mark ignored, ... = everyone else.
  local function awardButtons()
    if not (d.menu and phase == "award") then
      return
    end
    local acts = M.DetailActions(d)
    local first = acts and acts[1]
    if first and first.id == "award-name" then
      showBtn(f.awardB, first.label)
    elseif f.awardB.Hide then
      f.awardB:Hide() -- no eligible winners: primary hides, ... picks anyone
    end
    if f.tmogB then
      local trow = (d.menu.perType or {}).TMOG
      if trow and trow.entry then
        showBtn(f.tmogB, "Award TMOG (" .. PName(trow.entry.name) .. ")")
      elseif f.tmogB.Hide then
        f.tmogB:Hide()
      end
    end
    -- Re-roll buttons live on the bar next to the winners: Continue
    -- rolling first (keeps landed rolls), then fresh Roll again.
    if f.contB then showBtn(f.contB, "Continue rolling") end
    if f.rollB then showBtn(f.rollB, "Roll again") end
    if f.raidB then showBtn(f.raidB, "Raid roll") end
    if f.ignoreB then showBtn(f.ignoreB, "Ignore") end
  end
  if f.awardB then
    local show, label = false, "Award"
    if phase == "rolling" then
      show, label = true, "Finish"
    elseif d.single and phase == "pick" then
      show, label = true, "Award " .. PName(d.rollers[1])
    end
    if phase == "award" and d.menu then
      -- Award window: winner rows own the primary slot (+ re-rolls).
      awardButtons()
    else
      if show then
        showBtn(f.awardB, label)
      elseif f.awardB.Hide then
        f.awardB:Hide()
      end
      if f.tmogB and f.tmogB.Hide then f.tmogB:Hide() end
      -- Continue rolling only lives on the award window: hidden on
      -- pick/rolling.
      if f.contB and f.contB.Hide then f.contB:Hide() end
      -- Roll + Raid roll: their own buttons on pick (start) and
      -- mid-roll (raid-roll instead ends the open roll first).
      -- Rolling hides the Roll start (Finish/Cancel own that phase)
      -- but keeps the Raid roll button.
      local wantRoll = phase == "pick" or phase == "rolling"
      if f.rollB then
        if phase == "pick" then showBtn(f.rollB, "Roll")
        elseif f.rollB.Hide then f.rollB:Hide() end
      end
      if f.raidB then
        if wantRoll then showBtn(f.raidB, "Raid roll")
        elseif f.raidB.Hide then f.raidB:Hide() end
      end
      -- Ignore lives on the bar on every non-award phase too.
      if f.ignoreB then showBtn(f.ignoreB, "Ignore") end
      -- Sand: only on sand rows in pick phase (sand is never rolled,
      -- so rolling/award never show it).
      local MLUI2 = Z.MasterLootUI
      if f.sandB then
        if phase == "pick" and MLUI2 and MLUI2.IsSandItem
            and MLUI2.IsSandItem(d.itemID) then
          showBtn(f.sandB, "Sand")
        elseif f.sandB.Hide then
          f.sandB:Hide()
        end
      end
    end
  end
  if f.moreB then showBtn(f.moreB, "...") end
  -- Close lives in the top-right corner now (f.closeB), not the bar.
  local barRows = M.PlaceBarRows(f, M.LayoutBarRows(slots, barW), barW)
  if barRows == 0 then barRows = 1 end -- ... always slots in
  -- Auto-height: the frame grows one line per roll (DetailHeight) so
  -- every roller fits without scrolling; capped for huge raids.
  -- Award rows render below the roll list, so count them too.
  local nShown = Z.Util.ArrayCount(M.SortedDetailRolls(d))
  if phase == "award" and d.menu then
    nShown = nShown + Z.Util.ArrayCount((d.menu or {}).winners or {})
  end
  if f.SetHeight then f:SetHeight(M.DetailHeight(nShown, barRows)) end
  -- The roll columns stretch with the frame (fixed 70px clipped long
  -- lists before); anchored top + button bar, never overlapping it.
  local listH = M.DetailHeight(nShown, 1) - M.DETAIL_HEADER_H - 40
  if listH < 24 then listH = 24 end
  if f.rollsL and f.rollsL.SetHeight then f.rollsL:SetHeight(listH) end
  if f.rollsR and f.rollsR.SetHeight then f.rollsR:SetHeight(listH) end
  -- Item icon follows the detail's item (mirrors the raider header).
  if f.dicon and f.dicon.SetTexture and d then
    local tex = nil
    if Z.LootWindow and Z.LootWindow.ResolveItemInfo then
      local _, _, _, rtex = Z.LootWindow.ResolveItemInfo(d.itemID, d.link, nil, nil, nil)
      tex = rtex
    end
    f.dicon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
  end
end

-- "..." from the client frame: a dropdown menu (RollFor dropdown parity)
-- with one row per choice: award anyone on the list. Roll initiation
-- lives on its own bar buttons (Roll / Raid roll), never in the menu.
-- Rows highlight blue on hover; picking one runs it and closes the detail.
-- Headless (tests, /zl text UIs) it falls back to printing MoreLines.
M.moreDropdown = nil

-- Dropdown choice rows for the detail (data, headless-testable):
-- award rows + class groups only. Roll initiation lives on the bar
-- buttons (Roll / Raid roll via doAction), never in the menu
-- (MoreRollControls stays as the headless/text mirror of those buttons).
-- Priority rows (labeled rollers, kind winners) stay top-level for one
-- click; the REST of the awardable roster groups by class (MoreClassGroups), each group
-- opening a side submenu with its players — a flat 40-name list becomes
-- ~9 class rows. Every group member awards directly, even pre-roll
-- (AwardDirect, no roll needed).
-- Roll-control rows (headless/text mirror of the bar buttons): pick
-- offers nothing (bar buttons own it), mid-roll the menu offers
-- Raid-roll instead (ends the open roll, raid-rolls the item); the award
-- window keeps Continue rolling (reopen, rolls kept), Roll again
-- (fresh) and Raid-roll instead next to the awards. Client menus never
-- show these (bar buttons own them). Returns {} in pick phase.
function M.MoreRollControls(d)
  d = d or M.detail
  local out = {}
  if not d then return out end
  local ph = d.phase or "pick"
  if ph == "rolling" then
    table.insert(out, { id = "raidroll", label = "Raid-roll instead" })
    return out
  end
  if ph ~= "award" or not d.menu then return out end
  table.insert(out, { id = "continue", label = "Continue rolling" })
  table.insert(out, { id = "roll", label = "Roll again" })
  table.insert(out, { id = "raidroll", label = "Raid-roll instead" })
  return out
end

function M.MoreChoices(d)
  d = d or M.detail
  local out = {}
  if not d then return out end
  -- Roll initiation lives on the bar buttons (Roll / Raid roll), never
  -- in the menu: ... lists awardable names only.
  -- Landed rolls by name (their row carries roll + range for labels).
  local rolled = {}
  for i = 1, Z.Util.ArrayCount(d.rolls or {}) do
    local r = d.rolls[i]
    if r and r.name and not rolled[r.name] then rolled[r.name] = r end
  end
  local seen = {}
  local function addAward(nm)
    if nm and nm ~= "" and not seen[nm] then
      seen[nm] = true
      -- A roller shows once — WITH their roll ("Award Bbb (MS 80/100)"),
      -- never again bare; non-rollers stay bare names.
      local label = "Award " .. PName(nm)
      local r = rolled[nm]
      if r then
        label = label .. " (" .. tostring(r.rollType or "?") .. " "
          .. M.RollRangeText(r) .. ")"
      end
      table.insert(out, { id = "award-name", label = label, name = nm })
    end
  end
  local inAward = (d.phase or "pick") == "award" and d.menu
  if inAward then
    -- ... covers everyone the primary buttons do not: landed rollers
    -- first (labeled with their roll), then kind winners. The
    -- non-roller candidates (any raider, for when something is wrong
    -- with the rolls) ride the class groups below — never a flat
    -- 40-name list.
    for i = 1, Z.Util.ArrayCount(M.SortedDetailRolls(d)) do
      local r = M.SortedDetailRolls(d)[i]
      if r then addAward(r.name) end
    end
    for i = 1, Z.Util.ArrayCount((d.menu or {}).winners or {}) do
      if d.menu.winners[i] then addAward(d.menu.winners[i].name) end
    end
    for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
      local row = (d.menu.perType or {})[gt]
      if row and row.entry then addAward(row.entry.name) end
      for t = 1, Z.Util.ArrayCount((row or {}).tied or {}) do
        if row.tied[t] then addAward(row.tied[t].name) end
      end
    end
  else
    -- Pre-roll (pick, or rolling): reserves + landed rollers — nobody
    -- rolled on an award list yet, so labeled rollers dedupe the bare
    -- reserve names instead of duplicating them.
    for i = 1, Z.Util.ArrayCount(d.rollers or {}) do addAward(d.rollers[i]) end
    for i = 1, Z.Util.ArrayCount(d.rolls or {}) do
      if d.rolls[i] then addAward(d.rolls[i].name) end
    end
  end
  -- Class-grouped roster: everyone awardable NOT already listed above
  -- (seen) — the full raid, not just reserves, so anyone can be
  -- rewarded directly before a roll. In-client each group opens a side
  -- submenu; headless each member is an award row like the rest.
  for _, g in ipairs(M.MoreClassGroups(d, seen)) do
    table.insert(out, g)
  end
  return out
end

-- Class groups for the ... menu (data, headless-testable): every
-- awardable raider outside `skip`, grouped by class in roster order
-- (class-sorted, unknown last):
-- { { class="Warrior", members={ { id="award-name", ... }, ... } }, ... }.
-- Source is the award menu's class-sorted candidates once finished,
-- else the same class-sorted roster BuildCandidates builds (sheet +
-- landed rollers + live raid roster) — so pre-roll the ... menu still
-- reaches every raider for a direct award. Empty classes omitted;
-- members never duplicate the labeled top-level rows.
function M.MoreClassGroups(d, skip)
  d = d or M.detail
  local groups = {}
  if not d then return groups end
  local sheet = Z.DB and Z.DB.sheet
  local inAward = (d.phase or "pick") == "award" and d.menu
  local roster
  if inAward then
    roster = (d.menu or {}).candidates
  elseif Z.MasterLootUI and Z.MasterLootUI.BuildCandidates then
    roster = Z.MasterLootUI.BuildCandidates(sheet, d.rolls)
  else
    roster = {}
    for i = 1, Z.Util.ArrayCount(d.rollers or {}) do
      if d.rollers[i] then table.insert(roster, { name = d.rollers[i] }) end
    end
    for i = 1, Z.Util.ArrayCount(d.rolls or {}) do
      if d.rolls[i] and d.rolls[i].name then
        table.insert(roster, { name = d.rolls[i].name })
      end
    end
  end
  -- One roster-map lookup for the whole menu (ClassOf would rebuild it
  -- per name); sheet fills names the live roster never saw.
  local rawMap = (Z.ClassColors and Z.ClassColors.RosterMap
    and Z.ClassColors.RosterMap()) or {}
  local function classOf(nm)
    local c = nil
    local raw = rawMap[nm]
    if raw and raw ~= "" and Z.ClassColors and Z.ClassColors.NormalizeClass then
      c = Z.ClassColors.NormalizeClass(raw)
    end
    if not c and sheet and Z.SRData and Z.SRData.PlayerClass then
      c = Z.SRData.PlayerClass(sheet, nm)
    end
    return c
  end
  skip = skip or {}
  local byClass = {}
  for i = 1, Z.Util.ArrayCount(roster) do
    local e = roster[i]
    local nm = (type(e) == "table" and e.name)
      or (type(e) == "string" and e) or nil
    if nm and nm ~= "" and not skip[nm] then
      skip[nm] = true
      local cls = nil
      if type(e) == "table" and e.class
          and Z.ClassColors and Z.ClassColors.NormalizeClass then
        cls = Z.ClassColors.NormalizeClass(e.class)
      end
      if not cls then cls = classOf(nm) end
      local key = cls or "Unknown"
      local g = byClass[key]
      if not g then
        g = { class = key, members = {} }
        byClass[key] = g
        table.insert(groups, g)
      end
      table.insert(g.members,
        { id = "award-name", label = "Award " .. PName(nm), name = nm })
    end
  end
  local out = {}
  for i = 1, Z.Util.ArrayCount(groups) do
    local g = groups[i]
    if Z.Util.ArrayCount(g.members) > 0 then
      table.insert(out, { id = "class", class = g.class,
        label = g.class .. " (" .. Z.Util.ArrayCount(g.members) .. ") >",
        members = g.members })
    end
  end
  return out
end

function M.ToggleMoreDropdown(anchor)
  local d = M.detail
  if not d then return end
  -- Headless: print the choice list (MoreLines parity).
  if not CreateFrame then
    for i = 1, Z.Util.ArrayCount(M.MoreLines(d)) do Z.Print(M.MoreLines(d)[i]) end
    return
  end
  if M.moreDropdown then
    M.CloseMoreDropdown()
    return -- was open: toggle shut
  end
  local choices = M.MoreChoices(d)
  if Z.Util.ArrayCount(choices) == 0 then return end
  local parent = M.detailFrame or M.frame or UIParent
  local dd = CreateFrame("Frame", "ZugLootLootMoreDropdown", parent)
  if type(dd) ~= "table" or type(dd.SetWidth) ~= "function" then return end
  if dd.SetFrameStrata then pcall(dd.SetFrameStrata, dd, "TOOLTIP") end
  if dd.SetBackdrop then
    dd:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8",
      edgeFile = "Interface/Buttons/WHITE8x8", edgeSize = 0.5 })
  end
  if dd.SetBackdropColor then dd:SetBackdropColor(0, 0, 0, 1) end
  if dd.SetBackdropBorderColor then dd:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) end
  if dd.EnableMouse then dd:EnableMouse(true) end
  -- Hide when the mouse leaves the menu AND its submenu (RollFor
  -- dropdown parity): hovering a side submenu must not shut the list.
  if dd.SetScript and MouseIsOver then
    dd:SetScript("OnLeave", function()
      local sub = dd.submenu
      if not MouseIsOver(dd) and not (sub and MouseIsOver(sub)) then
        M.CloseMoreDropdown()
      end
    end)
  end
  -- One button per choice; width fits the longest label. Class-group
  -- rows (id="class") hover-open a side submenu with that class's
  -- players (each awards directly); every other row runs on click.
  local width, y = 0, -4
  dd.rows = {}
  for i = 1, Z.Util.ArrayCount(choices) do
    local c = choices[i] -- fresh local per iteration for the closure
    local b = CreateFrame("Button", nil, dd)
    if type(b) ~= "table" or type(b.SetWidth) ~= "function" then break end
    b:SetHeight(16)
    b:SetPoint("TOPLEFT", dd, "TOPLEFT", 5, y)
    b:SetPoint("RIGHT", dd, "RIGHT", -5, 0)
    if b.SetBackdrop then b:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8" }) end
    local function hover(a)
      if b.SetBackdropColor then b:SetBackdropColor(0.125, 0.624, 0.976, a) end
    end
    hover(0)
    if b.SetScript then
      b:SetScript("OnEnter", function()
        hover(0.2)
        if c.id == "class" then M.OpenMoreSubmenu(dd, b, c) end
      end)
      b:SetScript("OnLeave", function() hover(0) end)
      b:SetScript("OnClick", function()
        if c.id == "class" then
          -- Click pins the submenu too (hover alone opens it).
          M.OpenMoreSubmenu(dd, b, c)
          return
        end
        M.CloseMoreDropdown()
        if M.detail then
          if c.id == "award-name" then M.doAction(M.detail.itemID, "award-name", c.name) end
        end
      end)
    end
    local fs
    if b.CreateFontString then
      fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      fs:SetPoint("LEFT", b, "LEFT", 5, 0)
      if fs.SetText then fs:SetText(c.label) end
      local w = 0
      if fs.GetStringWidth then w = fs:GetStringWidth() or 0 end
      if w == 0 then w = string.len(c.label) * 7 end
      if w > width then width = w end
    end
    b.choice = c
    table.insert(dd.rows, b)
    y = y - 18
  end
  dd:SetWidth(width + 20)
  dd:SetHeight(-y + 5)
  if dd.ClearAllPoints then dd:ClearAllPoints() end
  if anchor and dd.SetPoint then
    -- Above the ... button (bar is at the bottom; drops UP so it never
    -- covers the buttons).
    dd:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
  elseif dd.SetPoint and M.detailFrame then
    dd:SetPoint("BOTTOM", M.detailFrame, "BOTTOM", 0, 40)
  end
  if dd.Show then dd:Show() end
  M.moreDropdown = dd
end

-- Side submenu for one class group: pops to the RIGHT of the hovered
-- class row, one award button per player of the class. Rebuilt per
-- hover (one open at a time); closes with the main dropdown.
function M.OpenMoreSubmenu(dd, anchorRow, group)
  if not (CreateFrame and dd and anchorRow and group) then return end
  if dd.submenu and dd.submenuClass == group.class then return end -- already open
  M.CloseMoreSubmenu()
  local members = group.members or {}
  if Z.Util.ArrayCount(members) == 0 then return end
  local parent = M.detailFrame or M.frame or UIParent
  local sub = CreateFrame("Frame", "ZugLootLootMoreSubmenu", parent)
  if type(sub) ~= "table" or type(sub.SetWidth) ~= "function" then return end
  if sub.SetFrameStrata then pcall(sub.SetFrameStrata, sub, "TOOLTIP") end
  if sub.SetBackdrop then
    sub:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8",
      edgeFile = "Interface/Buttons/WHITE8x8", edgeSize = 0.5 })
  end
  if sub.SetBackdropColor then sub:SetBackdropColor(0, 0, 0, 1) end
  if sub.SetBackdropBorderColor then sub:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) end
  if sub.EnableMouse then sub:EnableMouse(true) end
  -- Leaving both frames shuts the menu (main list guards the same way).
  if sub.SetScript and MouseIsOver then
    sub:SetScript("OnLeave", function()
      if not MouseIsOver(sub) and not MouseIsOver(dd) then
        M.CloseMoreDropdown()
      end
    end)
  end
  local width, y = 0, -4
  sub.rows = {}
  for i = 1, Z.Util.ArrayCount(members) do
    local m = members[i] -- fresh local per iteration for the closure
    local b = CreateFrame("Button", nil, sub)
    if type(b) ~= "table" or type(b.SetWidth) ~= "function" then break end
    b:SetHeight(16)
    b:SetPoint("TOPLEFT", sub, "TOPLEFT", 5, y)
    b:SetPoint("RIGHT", sub, "RIGHT", -5, 0)
    if b.SetBackdrop then b:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8" }) end
    local function hover(a)
      if b.SetBackdropColor then b:SetBackdropColor(0.125, 0.624, 0.976, a) end
    end
    hover(0)
    if b.SetScript then
      b:SetScript("OnEnter", function() hover(0.2) end)
      b:SetScript("OnLeave", function() hover(0) end)
      b:SetScript("OnClick", function()
        M.CloseMoreDropdown()
        if M.detail and m.name then
          M.doAction(M.detail.itemID, "award-name", m.name)
        end
      end)
    end
    if b.CreateFontString then
      local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      fs:SetPoint("LEFT", b, "LEFT", 5, 0)
      if fs.SetText then fs:SetText(m.label) end
      local w = 0
      if fs.GetStringWidth then w = fs:GetStringWidth() or 0 end
      if w == 0 then w = string.len(m.label or "") * 7 end
      if w > width then width = w end
    end
    table.insert(sub.rows, b)
    y = y - 18
  end
  sub:SetWidth(width + 20)
  sub:SetHeight(-y + 5)
  if sub.ClearAllPoints then sub:ClearAllPoints() end
  if sub.SetPoint then
    -- To the side of the hovered class row (pops right, never over
    -- the main list); falls right of the dropdown when unanchorable.
    if anchorRow and anchorRow ~= sub then
      sub:SetPoint("TOPLEFT", anchorRow, "TOPRIGHT", 2, 0)
    else
      sub:SetPoint("TOPLEFT", dd, "TOPRIGHT", 2, 0)
    end
  end
  if sub.Show then sub:Show() end
  dd.submenu = sub
  dd.submenuClass = group.class
  if M.moreDropdown == dd then M.moreSubmenu = sub end
end

function M.CloseMoreSubmenu()
  local dd = M.moreDropdown
  local sub = (dd and dd.submenu) or M.moreSubmenu
  if sub then
    if sub.Hide then sub:Hide() end
    if dd then dd.submenu, dd.submenuClass = nil, nil end
    M.moreSubmenu = nil
  end
end

M.moreSubmenu = nil

function M.CloseMoreDropdown()
  M.CloseMoreSubmenu()
  if M.moreDropdown then
    if M.moreDropdown.Hide then M.moreDropdown:Hide() end
    M.moreDropdown = nil
  end
  M.moreSubmenu = nil
end

-- "..." headless/text entry (kept for /zl text UIs): prints the choice list.
function M.MoreAction()
  local d = M.detail
  if not d then return end
  local lines = M.MoreLines(d)
  for i = 1, Z.Util.ArrayCount(lines) do Z.Print(lines[i]) end
end
