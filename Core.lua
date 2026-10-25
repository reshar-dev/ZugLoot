-- ZugLoot/Core.lua
-- Namespace bootstrap, SavedVariables defaults, event frame, slash commands.
-- (In-game only; tests load pure files directly.)
ZugLoot = ZugLoot or {}
local Z = ZugLoot

Z.DB = nil
Z.CharDB = nil

function Z.Print(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700ZugLoot:|r " .. tostring(msg or ""))
  end
end

-- Hush: true while quiet traffic is being composed (chat mirror
-- suppression). The router (Comm.Say) consults it before mirroring
-- grouped traffic into the local log: quiet senders (drop announces,
-- version checks, sheet sync chatter) set it around their sends so a
-- double never lands in the log. Plain Z.Print callers are unaffected -
-- only the (raid)/(party) mirror reads the flag. Nil-safe headless.
Z._hush = 0
function Z.Hush()
  return (Z._hush or 0) > 0
end
function Z.HushAround(fn)
  Z._hush = (Z._hush or 0) + 1
  local ok, err = pcall(fn)
  Z._hush = (Z._hush or 0) - 1
  if not ok then error(err) end
end

-- Multi-line /zl help: grouped sections, one line per command with a
-- real description. Headless-testable (returns the lines too).
-- Slim command set: windows do the rest via buttons/menus. Kept:
-- sheet, import, loadfile, sheetreq, sync, simboss, simraid, simstop.
function Z.HelpLines()
  return {
    "|cFFFFD700ZugLoot v" .. tostring(Z.VERSION or "?") .. " — commands:|r",
    "    sheet ............ open the SR sheet",
    "    raids ............ open raid history (activate / delete past raids)",
    "    raid <id> ........ activate an archived raid (continue it)",
    "    raidforget <id> .. permanently delete an archived raid",
    "    import ........... paste a raidres export or line-format sheet",
    "    loadfile ......... import from CustomData/ZugLoot_SR.txt",
    "    sheetreq ......... ask the group for the current sheet (ML answers)",
    "    sync <name> ...... ask ONE player for their sheet (player link works)",
    "    simboss <boss> ... queue a boss's drops, you roll each",
    "    simraid <raid> ... condensed full raid: one boss at a time (+ trash), you roll each",
    "    simstop .......... stop the sim, reset everything",
    "    sand [reset] ..... Hourglass Sand ledger (reset clears it)",
    "    rolldebug ........ trace roll feeds (ML window diagnosis)",
    "    lootdebug ........ verbose click-to-loot logging (slot, corpse, link)",
    "    help ............. this list",
  }
end

function Z.PrintHelp()
  local lines = Z.HelpLines()
  -- 5.0-safe: no # operator (parse-time error on the 1.12 client).
  for i = 1, Z.Util.ArrayCount(lines) do Z.Print(lines[i]) end
  return lines
end

function Z.InitDB()
  ZugLootDB = ZugLootDB or {}
  ZugLootCharDB = ZugLootCharDB or {}
  ZugLootDB.sheet = ZugLootDB.sheet or nil
  if ZugLootDB.sheet and type(ZugLootDB.sheet) == "table" then
    ZugLootDB.sheet.items = ZugLootDB.sheet.items or {}
    ZugLootDB.sheet.hardres = ZugLootDB.sheet.hardres or {}
    ZugLootDB.sheet.won = ZugLootDB.sheet.won or {}
    ZugLootDB.sheet.rolls = ZugLootDB.sheet.rolls or {}
    ZugLootDB.sheet.players = ZugLootDB.sheet.players or {}
    ZugLootDB.sheet.meta = ZugLootDB.sheet.meta or {}
  end
  ZugLootDB.raidArchive = ZugLootDB.raidArchive or {}
  ZugLootDB.drops = ZugLootDB.drops or {}
  ZugLootDB.rollTime = ZugLootDB.rollTime or Z.Limits.ROLL_TIMEOUT_DEFAULT
  -- Loot-takeover kill-switch state (see LootWindow.NoteSilentLoot):
  -- once our LootSlot path proves dead, the takeover stays OFF across
  -- corpses and sessions until the user opts back in. Survives reloads
  -- (a broken loot path won't fix itself on relog); re-arm via Setup tab
  -- or /zl lootframe. Never nil-guarded away: false is a valid state.
  if ZugLootDB.lootTakeover == nil then ZugLootDB.lootTakeover = true end
  -- Auto loot-method switching (ML boss flow, Setup tab):
  -- flip to master loot when the ML selects a boss, flip back to
  -- group loot once the boss is fully looted. Absent = off.
  if ZugLootDB.mlOnBoss == nil then ZugLootDB.mlOnBoss = false end
  if ZugLootDB.backToGroup == nil then ZugLootDB.backToGroup = false end
  -- Boss threshold for the auto-switch (Setup dropdown, 1 common ..
  -- 4 epic). Default epic: bosses drop epics. Absent = default.
  if ZugLootDB.bossThreshold == nil then ZugLootDB.bossThreshold = 4 end
  -- Raider roll window policy (Setup toggle): "ml" (default) = the
  -- window pops for master-loot rolls only; "all" = legacy (also
  -- mirror group-loot rolls + local preview). Absent = default.
  if ZugLootDB.raiderFrame ~= "all" then ZugLootDB.raiderFrame = "ml" end
  -- Pysanka raid-setup sheet (invitation word, buff/tank/debuff tables).
  if Z.Pysanka and Z.Pysanka.Ensure then Z.Pysanka.Ensure(ZugLootDB) end
  ZugLootDB.autoClose = (ZugLootDB.autoClose == nil) and true or ZugLootDB.autoClose
  ZugLootCharDB.autoRoll = ZugLootCharDB.autoRoll or false
  ZugLootCharDB.verSeen = ZugLootCharDB.verSeen or {}
  -- Minimap button angle (degrees, 0 = top, clockwise). Persisted per
  -- character; nil = default position (Minimap.GetAngle handles it).
  if ZugLootCharDB.minimapAngle ~= nil then
    ZugLootCharDB.minimapAngle = tonumber(ZugLootCharDB.minimapAngle)
  end
  Z.DB = ZugLootDB
  Z.CharDB = ZugLootCharDB
end

-- Factory reset: wipe all SavedVariables (account + character) and reapply
-- defaults via InitDB. Clears session data too (active sheet, raid archive,
-- drop log). AGGRESSIVE: also drops every runtime session artifact that
-- survives a SavedVariables wipe and would otherwise make the NEXT import
-- fail byte-identically (stale import-box text, open rolls + their timers,
-- sim staging, pending sheet/roll chunks, corpse cache, hush counter) —
-- the "reset did nothing" report. Deliberately NOT permission-gated:
-- everything touched is local client state (a raider must be able to
-- recover a broken local setup, and the raid can always rebroadcast the
-- sheet). Testable core.
function Z.DoResetAllSettings()
  if ZugLootDB then for k in pairs(ZugLootDB) do ZugLootDB[k] = nil end end
  if ZugLootCharDB then for k in pairs(ZugLootCharDB) do ZugLootCharDB[k] = nil end end
  Z.InitDB()
  if Z.VersionGrid and Z.VersionGrid.seen then Z.VersionGrid.seen = {} end
  if Z.VersionGrid and Z.VersionGrid.warned then Z.VersionGrid.warned = {} end
  -- Session state beyond SavedVariables (same client session, no reload):
  -- every module is probed, never required (nil-safe headless).
  -- Pending timers first: nothing scheduled may fire after the wipe.
  if Z.Timer and Z.Timer.CancelAll then Z.Timer.CancelAll() end
  -- Stale import text: the paste box keeps its (broken) content across
  -- resets per character — re-clicking Import without re-pasting fails
  -- byte-identically and looks like the reset did nothing.
  if Z.SRImport and Z.SRImport.ClearImportBox then Z.SRImport.ClearImportBox() end
  -- Open rolls + sim staging: a dead roll must never collect rolls or
  -- auto-finish late; staged sim queues must not outlive the wipe.
  if Z.MasterLootUI then
    if Z.MasterLootUI.roll and Z.MasterLootUI.CancelRollTimer then
      Z.MasterLootUI.CancelRollTimer(Z.MasterLootUI.roll)
    end
    Z.MasterLootUI.roll = nil
    Z.MasterLootUI.lastRound = nil
    Z.MasterLootUI.pendingLoot = nil
    Z.MasterLootUI.lootKey = nil
    Z.MasterLootUI.corpseCache = {}
    Z.MasterLootUI.corpseOrder = {}
    Z.MasterLootUI.autoML = false
  end
  if Z.Sim then
    Z.Sim.pending = {}
    Z.Sim.running = false
    Z.Sim.raid = nil
  end
  -- Partial network reassemblies: stale chunks must never complete a
  -- post-reset sheet/roll session.
  if Z.Comm then
    Z.Comm.chunkBuffers = {}
    Z.Comm.rollChunkBuffers = {}
  end
  Z._hush = 0
  -- Windows back to hidden; raider intake cleared.
  if Z.LootWindow then
    if Z.LootWindow.CloseDetail then Z.LootWindow.CloseDetail() end
    if Z.LootWindow.CloseMoreDropdown then Z.LootWindow.CloseMoreDropdown() end
    Z.LootWindow.items = {}
    Z.LootWindow.watchdogs = nil
    Z.LootWindow.silentLootArms = nil
    if Z.LootWindow.Hide then Z.LootWindow.Hide() end
  end
  if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
end

-- Button/slash entry point with confirmation window. Outside the client
-- (no StaticPopup API) the confirm is skipped so tests can use it directly.
function Z.RequestResetAllSettings()
  if not (StaticPopupDialogs and StaticPopup_Show) then
    Z.DoResetAllSettings()
    Z.Print("All ZugLoot settings reset to defaults (sheet, history, log and options cleared).")
    return
  end
  StaticPopupDialogs["ZUGLOOT_RESET_ALL"] = StaticPopupDialogs["ZUGLOOT_RESET_ALL"] or {
    text = "Reset ALL ZugLoot settings?\nActive sheet, raid history, drop log and all options return to defaults. This cannot be undone.",
    button1 = "Reset all", button2 = "Cancel",
    OnAccept = function()
      Z.DoResetAllSettings()
      Z.Print("All ZugLoot settings reset to defaults (sheet, history, log and options cleared).")
    end,
    timeout = 0, whileDead = 1,
  }
  StaticPopup_Show("ZUGLOOT_RESET_ALL")
end

local frame = nil
function Z.OnEvent(event, arg1, arg2, arg3, arg4)
  if event == "ADDON_LOADED" and arg1 == "ZugLoot" then
    Z.InitDB()
    Z.Print("loaded v" .. tostring(Z.VERSION) .. ". /zl help")
    -- RollFor parity: detach Blizzard's loot frame for the whole session,
    -- so OUR loot window is the loot window in every looting situation.
    if Z.LootWindow and Z.LootWindow.DetachBlizzardLoot then
      pcall(Z.LootWindow.DetachBlizzardLoot)
    end
    if Z.VersionGrid then Z.VersionGrid.Announce() end
    -- Minimap die button (nil-safe: Build no-ops without frame APIs).
    if Z.Minimap then pcall(Z.Minimap.Build) end
  elseif Z.Comm then
    Z.Comm.OnEvent(event, arg1, arg2, arg3, arg4)
  end
  if Z.MasterLootUI and Z.MasterLootUI.OnEvent then Z.MasterLootUI.OnEvent(event, arg1, arg2, arg3, arg4) end
  if Z.RaiderLootUI and Z.RaiderLootUI.OnEvent then Z.RaiderLootUI.OnEvent(event, arg1, arg2, arg3, arg4) end
  if Z.LootWindow and Z.LootWindow.OnEvent then Z.LootWindow.OnEvent(event, arg1) end
end

function Z.Init()
  if not CreateFrame then return end
  frame = CreateFrame("Frame", "ZugLootFrame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("CHAT_MSG_ADDON")
  frame:RegisterEvent("CHAT_MSG_SYSTEM")
  frame:RegisterEvent("CHAT_MSG_RAID_WARNING")
  frame:RegisterEvent("LOOT_OPENED")
  frame:RegisterEvent("LOOT_CLOSED")
  frame:RegisterEvent("LOOT_SLOT_CLEARED")
  frame:RegisterEvent("START_LOOT_ROLL")
  frame:RegisterEvent("CANCEL_LOOT_ROLL")
  frame:RegisterEvent("LOOT_BIND_CONFIRM")
  frame:RegisterEvent("UI_ERROR_MESSAGE")
  frame:RegisterEvent("RAID_ROSTER_UPDATE")
  frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
  frame:RegisterEvent("PLAYER_TARGET_CHANGED")
  frame:SetScript("OnEvent", function() Z.OnEvent(event, arg1, arg2, arg3, arg4) end)
  -- luacheck: push ignore 131 (WoW client reads SLASH_* + SlashCmdList).
  SLASH_ZUGLOOT1 = "/zl"
  SLASH_ZUGLOOT2 = "/zugloot"
  SlashCmdList["ZUGLOOT"] = function(msg) Z.Slash(msg) end
  -- luacheck: pop
  -- Timer driver: advances ZugLoot.Timer on every frame (vanilla 1.12 has
  -- no C_Timer). Guarded so Core loads even if Timer.lua is absent.
  if Z.Timer then
    local tf = CreateFrame("Frame", "ZugLootTimerFrame")
    tf:SetScript("OnUpdate", function() Z.Timer.Update(arg1) end)
  end
end

function Z.Slash(msg)
  msg = (Z.Util and Z.Util.Trim(msg or "")) or tostring(msg or "")
  local cmd, rest = string.match(msg, "^(%S+)%s*(.*)$")
  cmd = string.lower(cmd or "")
  rest = rest or ""
  -- Slim command set (windows do the rest via buttons/menus):
  -- sheet, import, loadfile, sheetreq, sync, simboss, simraid, simstop.
  if cmd == "" or cmd == "help" then
    Z.PrintHelp()
  elseif cmd == "sheet" then Z.MainWindow.Toggle("sheet")
  elseif cmd == "raids" then Z.MainWindow.Toggle("raids")
  elseif cmd == "raid" then Z.SRImport.ActivateArchivedRaid(Z.Util.Trim(rest))
  elseif cmd == "raidforget" then Z.SRImport.RequestDeleteArchivedRaid(Z.Util.Trim(rest))
  elseif cmd == "import" then Z.SRImport.ShowPaste()
  elseif cmd == "loadfile" then Z.SRImport.LoadFromFile()
  elseif cmd == "sheetreq" then Z.Comm.RequestSheet()
  elseif cmd == "sync" then Z.Comm.RequestSheetFrom(rest)
  elseif cmd == "simboss" then Z.Sim.SimBoss(rest)
  elseif cmd == "simraid" then Z.Sim.SimRaid(rest)
  elseif cmd == "simstop" then Z.Sim.Stop()
  elseif cmd == "sand" then
    if Z.MasterLootUI and Z.MasterLootUI.SandCommand then Z.MasterLootUI.SandCommand(rest) end
  elseif cmd == "rolldebug" then
    if Z.LootWindow then
      Z.LootWindow.rollDebug = not Z.LootWindow.rollDebug
      Z.Print("rolldebug " .. (Z.LootWindow.rollDebug and "ON" or "OFF"))
    end
  elseif cmd == "lootdebug" then
    if Z.LootWindow then
      Z.LootWindow.lootDebug = not Z.LootWindow.lootDebug
      Z.Print("lootdebug " .. (Z.LootWindow.lootDebug and "ON" or "OFF"))
    end
  else Z.Print("unknown command. /zl help")
  end
end

Z.Init()
