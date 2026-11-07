-- ZugLoot/Comm.lua
-- Addon-message transport + receiver-side sheet guard.
-- Prefix ZugLoot. Types: SHEET / ROLL_REQ / VER_REQ / VER_ANS / AWARD / LOG.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Comm = M

-- Player name for CHAT: clickable class-colored link (|cHEX|Hplayer:N|h[N]|h|r),
-- plain name when ClassColors is absent (headless). Stored data stays raw;
-- links are built at the print/send boundary only. Never nil.
local function ChatPlayer(name)
  if Z.ClassColors and Z.ClassColors.PlayerLink then
    return Z.ClassColors.PlayerLink(name)
  end
  return tostring(name or "")
end

local function send(msg, channel)
  channel = channel or M.Channel() or "RAID"
  if ChatThrottleLib and ChatThrottleLib.SendAddonMessage then
    ChatThrottleLib:SendAddonMessage("NORMAL", Z.PREFIX, msg, channel)
  elseif SendAddonMessage then
    SendAddonMessage(Z.PREFIX, msg, channel)
  end
end

M.CHUNK_SIZE = 160 -- Safe headroom under the 254-byte MTU limit
M.DEBOUNCE_INTERVAL = 1.5
M.lastBroadcastTime = 0
M.lastSheetReqTime = 0
M.lastVerReqTime = 0
M.chunkBuffers = {}

function M.Channel()
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return nil end
  if Z.SRSecurity and Z.SRSecurity.IsInRaid() then return "RAID" end
  return "PARTY"
end

-- Sim speaker: true while a SIM round owns the roll window (the open
-- roll, or the finished round parked for award/continue). Live rolls
-- and idle windows read false. Lets the shared SayGroup/WarnGroup path
-- route sim traffic to the group without every caller threading a flag
-- (a sim is an explicit test action, never background echo).
-- Nil-safe headless (no roll module -> false).
function M.SimSpeaker()
  local MLUI = Z.MasterLootUI
  if not MLUI then return false end
  local roll = MLUI.roll
  if roll and roll.mode == "SIM" then return true end
  local stamp = MLUI.lastRound
  if stamp and stamp.mode == "SIM" then return true end
  return false
end

-- SHEET_REQ: ask the group for the current sheet. Only the ML answers
-- (with a sheet they actually hold).
-- SHEET:<ver>:<raidID>:<payload>. Payload encoding: base64-wrapped when
-- the encoder exists, else escape-quoted raw. NEVER raw: the line format
-- uses "|" as its row separator and ChatThrottleLib (bundled with other
-- addons on this client) rejects bare pipes in chat/addon traffic with
-- "Invalid escape code in chat message" (ChatThrottleLib.lua:261).
-- Escape scheme (both directions, see DeserializeSheet): "%" -> "%P",
-- "|" -> "%B"; base64 output needs no escaping (A-Za-z0-9+/= only).
-- Solo: no one to send to — skip silently (local preview only).
function M.EncodeSheetPayload(sheet)
  local raw = Z.SRImport.SerializeSheet(sheet)
  if Base64Encode then
    local ok, enc = pcall(Base64Encode, raw)
    if ok and enc and enc ~= "" then return "B64" .. enc end
  end
  -- NOTE: gsub REPLACEMENTS escape % too: "%P" must be written "%%P"
  -- or lua reads %P as a (nonexistent) capture ("invalid use of %").
  local esc = string.gsub(tostring(raw), "%%", "%%P")
  esc = string.gsub(esc, "|", "%%B")
  return "ESC" .. esc
end

function M.BroadcastSheet(sheet, raidID, targetChannel)
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return end
  -- Never broadcast an empty sheet: a bare-META wire would blank every
  -- receiver's sheet tab ("(sheet is empty)") for no gain.
  if Z.SRData and Z.SRData.SheetIsEmpty and Z.SRData.SheetIsEmpty(sheet) then
    Z.Print("Sheet NOT broadcast — it has no reservations (0 items, no hard reserves). "
      .. "Fix the import first so the raid never sees an empty sheet.")
    return
  end
  local channel = targetChannel or M.Channel()
  if not channel then return end
  local now = (GetTime and GetTime()) or (time and time()) or 0
  if (now - (M.lastBroadcastTime or 0)) < M.DEBOUNCE_INTERVAL then return end
  M.lastBroadcastTime = now
  local ver = 1
  local payload = M.EncodeSheetPayload(sheet)
  local plen = string.len(payload)
  if plen <= M.CHUNK_SIZE then
    send("SHEET:" .. ver .. ":" .. tostring(raidID) .. ":" .. payload, channel)
  else
    local total = math.floor((plen + M.CHUNK_SIZE - 1) / M.CHUNK_SIZE)
    for seq = 1, total do
      local startIdx = (seq - 1) * M.CHUNK_SIZE + 1
      local endIdx = seq * M.CHUNK_SIZE
      local chunk = string.sub(payload, startIdx, endIdx)
      send("SHEET_C:" .. ver .. ":" .. tostring(raidID) .. ":" .. seq .. ":" .. total .. ":" .. chunk, channel)
    end
  end
end

function M.SendRollReq(itemID, itemLink, mode)
  send("ROLL_REQ:" .. tostring(itemID) .. ":" .. tostring(itemLink) .. ":" .. tostring(mode), M.Channel())
end

function M.RequestVersions()
  local c = M.Channel()
  if not c then return end
  local now = (GetTime and GetTime()) or (time and time()) or 0
  if (now - (M.lastVerReqTime or 0)) < M.DEBOUNCE_INTERVAL then return end
  M.lastVerReqTime = now
  send("VER_REQ", c)
end

-- Strip a player link to its bare name: "|cFF...Name|r" (class-colored
-- chat link, possibly with an |Hplayer:...|h wrapper) -> "Name".
-- Anything without color markup passes through trimmed. Pure helper.
function M.StripPlayerLink(s)
  s = tostring(s or "")
  -- |Hplayer:Name|h[Name]|h form (possibly itself color-wrapped):
  -- prefer the bracket display.
  local disp = string.match(s, "|Hplayer:[^|]*|h%[(.-)%]|h")
  if disp and disp ~= "" then
    -- Recurse: the display itself may carry color markup.
    local inner = string.match(disp, "^|c%x%x%x%x%x%x%x%x(.-)|r$")
    if inner then disp = inner end
    return Z.Util.Trim(disp)
  end
  -- Bare color wrap |cXXXXXXXXName|r.
  local inner = string.match(s, "^|c%x%x%x%x%x%x%x%x(.-)|r$")
  if inner then return Z.Util.Trim(inner) end
  return Z.Util.Trim(s)
end

-- Ask the group for the SR sheet (Members tab button, /zl sheetreq).
-- Solo: nobody to ask. Everyone hears it; only the ML answers.
-- when no ML sheet exists) answers — see OnMessage/SHEET_REQ.
function M.RequestSheet()
  local c = M.Channel()
  if not c then
    Z.Print("No group to ask — solo has no sheet source.")
    return
  end
  local now = (GetTime and GetTime()) or (time and time()) or 0
  if (now - (M.lastSheetReqTime or 0)) < M.DEBOUNCE_INTERVAL then return end
  M.lastSheetReqTime = now
  local me = (UnitName and UnitName("player")) or "?"
  send("SHEET_REQ", c)
  Z.Print("Sheet requested from the master looter (" .. ChatPlayer(me) .. " asked).")
end

-- Ask ONE player for their sheet (/zl sync <name>): targeted request.
-- Anyone may hold a sheet worth syncing (imports are open to all), but
-- the RECEIVE side still only trusts ML sheets (CanAcceptFrom) —
-- a raider's answer arrives and is refused with the usual message.
-- Name accepts player links (color-coded [Name]) as well as bare names.
function M.RequestSheetFrom(rawName)
  local c = M.Channel()
  if not c then
    Z.Print("No group to ask — solo has no sheet source.")
    return
  end
  local name = M.StripPlayerLink(rawName)
  if not name or name == "" then
    Z.Print("Usage: /zl sync <name>")
    return
  end
  send("SHEET_REQ:" .. name, c)
  Z.Print("Sheet requested from " .. ChatPlayer(name) .. ".")
end
function M.AnnounceVersion()
  local c = M.Channel()
  if not c then return end
  send("VER_ANS:" .. tostring(Z.VERSION), c)
end
function M.BroadcastAward(itemID, winner)
  local c = M.Channel()
  if not c then return end
  send("AWARD:" .. tostring(itemID) .. ":" .. tostring(winner), c)
end

-- Roll-session progress: one recorded session (what was rolled) to the
-- raid, right when the ML's client records it at finish time.
-- ROLLLOG:<ver>:<raidID>:<itemID>:<tail> (tail shares the ROLLH session
-- encoding), chunked as ROLLLOG_C:<ver>:<raidID>:<itemID>:<seq>:<total>:
-- <chunk> past CHUNK_SIZE. Won marks ride the existing AWARD message;
-- full history rides the SHEET payload — this covers the live record.
-- Send-side gate mirrors the sheet broadcast path (ML only,
-- never solo); receivers trust ML only (CanAcceptFrom) and only
-- apply to the live sheet of the SAME raid.
M.rollChunkBuffers = {}
function M.BroadcastRollSession(sheet, itemID, sess)
  if not sheet or not sess or not itemID then return end
  if Z.SRSecurity and Z.SRSecurity.CanBroadcast
      and not Z.SRSecurity.CanBroadcast() then return end
  local channel = M.Channel()
  if not channel then return end
  local raidID = sheet.meta and sheet.meta.raidID
  if not raidID or raidID == "" then return end
  local tail = Z.SRImport and Z.SRImport.EncodeSession(itemID, sess)
  if not tail or tail == "" then return end
  local ver = 1
  if string.len(tail) <= M.CHUNK_SIZE then
    send("ROLLLOG:" .. ver .. ":" .. tostring(raidID) .. ":"
      .. tostring(itemID) .. ":" .. tail, channel)
  else
    local total = math.floor((string.len(tail) + M.CHUNK_SIZE - 1) / M.CHUNK_SIZE)
    for seq = 1, total do
      local startIdx = (seq - 1) * M.CHUNK_SIZE + 1
      local chunk = string.sub(tail, startIdx, startIdx + M.CHUNK_SIZE - 1)
      send("ROLLLOG_C:" .. ver .. ":" .. tostring(raidID) .. ":"
        .. tostring(itemID) .. ":" .. seq .. ":" .. total .. ":" .. chunk, channel)
    end
  end
end

-- One session landed: append it to the live sheet of the same raid.
-- Anything else (wrong raid, no sheet, untrusted sender, bad tail) is
-- ignored — the next full SHEET sync recovers. Redelivery drops via
-- the session signature (same bytes = same session). Unknown items
-- stub first (EnsureUnreserved) so non-SR sessions have a card.
-- Silent: the finish and award lines already printed; views refresh
-- underneath.
function M.ApplyRollSession(raidID, itemID, tail, sender)
  if not Z.SRSecurity.CanAcceptFrom(sender) then
    Z.Print("Ignored roll session from " .. ChatPlayer(sender) .. " (not ML).")
    return
  end
  local sheet = Z.DB and Z.DB.sheet
  if not sheet or not sheet.meta
      or tostring(sheet.meta.raidID or "") ~= tostring(raidID or "") then
    return
  end
  if not Z.SRImport or not Z.SRImport.DecodeSession then return end
  local id, sess = Z.SRImport.DecodeSession(tail)
  if not id or not sess or id ~= tonumber(itemID) then return end
  if not Z.SRData then return end
  -- Redelivered session (double event frame, retried send): the same
  -- bytes carry the same signature — drop it instead of stacking a
  -- duplicate next to the recorded one.
  if Z.SRData.SessionKnown and Z.SRData.SessionKnown(sheet, id, sess) then return end
  -- Non-SR item (unreserved stub on the sender): no item row exists
  -- here yet, so the session would land invisibly. Stub it first —
  -- same artifact the recorder created — so raiders see the card.
  -- Quality refines on the next full SHEET (UNSR line carries it).
  if not (sheet.items or {})[id] and Z.SRData.EnsureUnreserved then
    Z.SRData.EnsureUnreserved(sheet, id, nil)
  end
  if Z.SRData.RecordRolls then
    Z.SRData.RecordRolls(sheet, id, sess)
  end
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
end

-- Single chat router for ALL roll traffic — sim AND live share it.
-- One policy, speaker + channel: solo -> the ZugLoot log (local chat
-- frame); grouped, only the master looter speaks — party -> PARTY,
-- raid -> RAID (RAID_WARNING when warn=true AND the speaker holds
-- raid-leader/assist rank, else plain RAID: a master looter without
-- assist cannot send /rw, so warn traffic falls back instead of
-- erroring), while raiders see the
-- same lines locally. EXCEPTION: sim lines (isSim) always speak to
-- the group — a sim is an explicit user action ("show the raid this
-- test roll"), never background echo, so the simulator reads exactly
-- like the real roll would even when the simmer isn't the ML. A solo
-- sim stays local. SayGroup/WarnGroup sniff the sim out via
-- SimSpeaker (open SIM roll / parked SIM round), so callers don't
-- thread the flag; SaySim/WarnSim force it. Callers never touch
-- SendChatMessage directly.
--
-- Verifiable by design: every roll line goes through here, so tests pin
-- the channel (`SendChatMessage` stub) + text (`Z.Print` stub) per
-- grouping (see tests/test_chat_routing.lua) — solo prints locally,
-- party sends PARTY, raid sends RAID/RAID_WARNING, all with identical
-- text for sim and live rolls.
function M.Say(msg, warn, isSim)
  msg = tostring(msg)
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then
    Z.Print(msg)
    return "local"
  end
  -- Only the master looter speaks LIVE lines to the group: a raider's
  -- client sees the exact same lines locally instead of echoing them
  -- into /raid (or /party). Real /rolls are client rolls, never this
  -- path. Sim lines bypass the gate (see above).
  if not isSim
      and not (Z.SRSecurity and Z.SRSecurity.AmML and Z.SRSecurity.AmML()) then
    Z.Print(msg)
    return "local"
  end
  if Z.SRSecurity and Z.SRSecurity.IsInRaid and Z.SRSecurity.IsInRaid() then
    -- /rw needs raid-leader/assist rank: ML without assist falls back
    -- to plain RAID (never error or drop). No CanRaidWarn shim (old
    -- harness) keeps the legacy warn behavior; a present one decides.
    local canWarn = warn
    if canWarn and Z.SRSecurity.CanRaidWarn then
      canWarn = Z.SRSecurity.CanRaidWarn()
    end
    local chan = (canWarn and "RAID_WARNING") or "RAID"
    if SendChatMessage then
      SendChatMessage(msg, chan)
      return chan
    end
    -- Grouped but headless (or client API missing): the raid WOULD
    -- see this line. Mirror it into the log tagged, never silently
    -- drop it — the ML must be able to verify (and paste) exactly
    -- what the group saw. Suppressed only for quiet traffic (Z.Hush).
    if not (Z.Hush and Z.Hush()) then
      Z.Print("(raid) " .. msg)
    end
    return "local"
  end
  if Z.SRSecurity and Z.SRSecurity.IsInGroup and Z.SRSecurity.IsInGroup() then
    -- No raid warnings in a party: plain party message instead.
    if SendChatMessage then
      SendChatMessage(msg, "PARTY")
      return "PARTY"
    end
    if not (Z.Hush and Z.Hush()) then
      Z.Print("(party) " .. msg)
    end
    return "local"
  end
  Z.Print(msg)
  return "local"
end

-- Roll-traffic chat: live ML-only (raid -> RAID, party -> PARTY,
-- solo/raiders -> ZugLoot log). SayGroup/WarnGroup route sim traffic
-- to the group too (SimSpeaker): a sim is an explicit test action,
-- never background echo. Sim and live share this path; only the
-- speaker + channel differ by role and grouping.
function M.SayGroup(msg)
  M.Say(msg, false, M.SimSpeaker())
end

function M.WarnGroup(msg)
  M.Say(msg, true, M.SimSpeaker())
end

-- Sim-traffic chat: explicit sim routing (same channels, speaker gate
-- bypassed — whoever runs the sim wants the group to see the test
-- lines). Mostly redundant with the SimSpeaker sniffing above; kept
-- for callers that already know the line is sim traffic. Solo sims
-- still stay local.
function M.SaySim(msg)
  M.Say(msg, false, true)
end

function M.WarnSim(msg)
  M.Say(msg, true, true)
end

function M.ApplyReceivedSheet(_ver, raidID, payload, sender)
  -- SECURITY: only the master looter may push sheets.
  if not Z.SRSecurity.CanAcceptFrom(sender) then
    Z.Print("Ignored sheet from " .. ChatPlayer(sender) .. " (not ML).")
    return
  end
  local sheet, err = Z.SRImport.DeserializeSheet(payload)
  if not sheet then Z.Print("Sheet import failed: " .. tostring(err)) return end
  -- Never let an empty sheet clobber the live one: when the sender's
  -- import held nothing (thin CSV, blank paste), the wire is a bare
  -- META line — keep our progress and say so.
  if Z.SRData and Z.SRData.SheetIsEmpty and Z.SRData.SheetIsEmpty(sheet) then
    Z.Print("Ignored empty sheet from " .. tostring(sender)
      .. " (no reservations — their import likely has no numeric item IDs). "
      .. "Live sheet kept.")
    return
  end
  -- Envelope (META line) carries the raid identity; the message raidID
  -- and the trusted sender fill gaps it leaves (legacy senders send no
  -- META at all). Sender always wins: we know who pushed it.
  sheet.meta = sheet.meta or {}
  if not sheet.meta.raidID or sheet.meta.raidID == "" then
    sheet.meta.raidID = raidID
  end
  sheet.meta.importedBy = sender
  -- Stale guard: same raid compares content revision (importedAt from
  -- the META envelope), not the raidID string — a re-sent update keeps
  -- its raidID but carries a NEWER stamp and must apply. Refuse BEFORE
  -- archiving (archiving first would snapshot progress, then drop it).
  if Z.SRImport and Z.SRImport.SheetIsStale
      and Z.SRImport.SheetIsStale(Z.DB and Z.DB.sheet, sheet) then
    Z.Print("Ignored stale sheet " .. tostring(sheet.meta.raidID)
      .. " (a newer update is already applied).")
    return
  end
  if Z.RaidArchive then
    Z.RaidArchive.ArchiveActive(Z.DB, (time and time()) or 0)
  end
  Z.DB.sheet = sheet
  if Z.RaidArchive then
    Z.RaidArchive.SyncActive(Z.DB, (time and time()) or 0)
  end
  Z.Print("Sheet received from " .. ChatPlayer(sender) .. " (" .. tostring(raidID) .. ")")
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
end

function M.OnEvent(event, a1, a2, a3, a4)
  if event == "CHAT_MSG_ADDON" then
    local prefix, msg, channel, sender = a1, a2, a3, a4
    if prefix ~= Z.PREFIX then return end
    M.OnMessage(tostring(msg or ""), sender, channel)
  end
end

function M.OnMessage(msg, sender, channel)
  local tag = string.match(msg, "^(%S+):")
  -- Sheet request: the ML answers at once when they hold a sheet.
  -- Nobody else answers broadcast requests — receivers only trust ML
  -- sheets (CanAcceptFrom).
  if msg == "SHEET_REQ" or tag == "SHEET_REQ" then
    -- Targeted form "SHEET_REQ:<name>": only answer when WE are the
    -- named player (exact name match after link-strip). Anyone may be
    -- asked (imports are open); trust is enforced on RECEIVE.
    local target = string.match(msg, "^SHEET_REQ:(.+)$")
    if target then
      local me = UnitName and UnitName("player") or nil
      if not me or Z.Comm.StripPlayerLink(target) ~= me then return end
    end
    if Z.SRSecurity and Z.SRSecurity.ShouldAnswerSheetReq then
      Z.SRSecurity.ShouldAnswerSheetReq(sender, target and true or false, channel)
    end
    return
  end
  -- Version traffic is open to all.
  if string.sub(msg, 1, 7) == "VER_REQ" then
    M.AnnounceVersion()
    return
  end
  if string.sub(msg, 1, 7) == "VER_ANS" then
    if Z.VersionGrid then Z.VersionGrid.OnVersion(sender, string.match(msg, "VER_ANS:(.*)$")) end
    return
  end
  if string.sub(msg, 1, 9) == "ROLL_REQ:" then
    if Z.RaiderLootUI then Z.RaiderLootUI.OnRollReq(msg, sender) end
    return
  end
  if string.sub(msg, 1, 8) == "ROLLLOG:" then
    local _ver, raidID, itemID, tail = string.match(msg, "^ROLLLOG:(%d+):([^:]+):(%d+):(.*)$")
    if not tail then Z.Print("Bad roll session from " .. ChatPlayer(sender)) return end
    M.ApplyRollSession(raidID, tonumber(itemID), tail, sender)
    return
  end
  if string.sub(msg, 1, 10) == "ROLLLOG_C:" then
    local _ver, raidID, itemID, seqStr, totStr, chunk =
      string.match(msg, "^ROLLLOG_C:(%d+):([^:]+):(%d+):(%d+):(%d+):(.*)$")
    local seq = tonumber(seqStr)
    local total = tonumber(totStr)
    if not (seq and total and chunk) then
      Z.Print("Bad roll session chunk from " .. ChatPlayer(sender))
      return
    end
    if not Z.SRSecurity.CanAcceptFrom(sender) then
      Z.Print("Ignored roll session chunk from " .. ChatPlayer(sender) .. " (not ML).")
      return
    end
    local now = (GetTime and GetTime()) or (time and time()) or 0
    M.rollChunkBuffers = M.rollChunkBuffers or {}
    local key = tostring(raidID) .. "#" .. tostring(itemID)
    local buf = M.rollChunkBuffers[key]
    if not buf or (now - (buf.t or 0) > 15) then
      buf = { total = total, chunks = {}, count = 0, t = now }
      M.rollChunkBuffers[key] = buf
    end
    if not buf.chunks[seq] then
      buf.chunks[seq] = chunk
      buf.count = buf.count + 1
    end
    if buf.count == total then
      local parts = {}
      for i = 1, total do table.insert(parts, buf.chunks[i] or "") end
      M.rollChunkBuffers[key] = nil
      M.ApplyRollSession(raidID, tonumber(itemID), table.concat(parts, ""), sender)
    end
    return
  end
  if string.sub(msg, 1, 6) == "AWARD:" then
    if not Z.SRSecurity.CanAcceptFrom(sender) then
      Z.Print("Ignored award from " .. ChatPlayer(sender) .. " (not ML).")
      return
    end
    local itemID, winner = string.match(msg, "AWARD:(%d+):(.+)$")
    if itemID and Z.DB and Z.DB.sheet and Z.SRData then
      -- Sheet log floor (sender-side parity): a known below-rare award
      -- leaves no won mark. Unknown quality proceeds (unclassifiable).
      local q = nil
      if GetItemInfo then
        local _, _, qq = GetItemInfo(tonumber(itemID))
        q = qq
      end
      Z.SRData.MarkWon(Z.DB.sheet, tonumber(itemID), winner, q)
      if Z.MainWindow then Z.MainWindow.Refresh() end
      if Z.SRView then Z.SRView.Refresh() end
    end
    return
  end
  if string.sub(msg, 1, 8) == "SHEET_C:" then
    local ver, raidID, seqStr, totStr, chunk = string.match(msg, "^SHEET_C:(%d+):([^:]+):(%d+):(%d+):(.*)$")
    local seq = tonumber(seqStr)
    local total = tonumber(totStr)
    if not (seq and total and chunk) then
      Z.Print("Bad sheet chunk from " .. ChatPlayer(sender))
      return
    end
    if not Z.SRSecurity.CanAcceptFrom(sender) then
      Z.Print("Ignored sheet chunk from " .. ChatPlayer(sender) .. " (not ML).")
      return
    end
    local now = (GetTime and GetTime()) or (time and time()) or 0
    M.chunkBuffers = M.chunkBuffers or {}
    local buf = M.chunkBuffers[raidID]
    if not buf or (now - (buf.t or 0) > 15) then
      buf = { total = total, chunks = {}, count = 0, t = now, sender = sender }
      M.chunkBuffers[raidID] = buf
    end
    if not buf.chunks[seq] then
      buf.chunks[seq] = chunk
      buf.count = buf.count + 1
    end
    if buf.count == total then
      local parts = {}
      for i = 1, total do table.insert(parts, buf.chunks[i] or "") end
      local fullPayload = table.concat(parts, "")
      M.chunkBuffers[raidID] = nil
      M.ApplyReceivedSheet(tonumber(ver) or 1, raidID, fullPayload, sender)
    end
    return
  end
  if string.sub(msg, 1, 6) == "SHEET:" then
    local ver, raidID, payload = string.match(msg, "SHEET:(%d+):([^:]+):(.+)$")
    if not payload then Z.Print("Bad sheet message from " .. ChatPlayer(sender)) return end
    M.ApplyReceivedSheet(tonumber(ver) or 1, raidID, payload, sender)
    return
  end
end
