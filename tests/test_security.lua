-- tests/test_security.lua
-- SRSecurity solo/group gating: solo may load locally but never broadcast;
-- in-group import stays ML/leader-only. Needs mocked WoW group APIs.
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
dofile("ClassColors.lua")

-- Mock group state: upvalues the security module reads via globals.
-- ML rig: GetLootMethod returns ("master", id) — RollFor parity.
-- id 0 = me; id N = raid/party slot N of the ML.
local raidMembers, partyMembers = 0, 0
local lootMethod, lootId = nil, nil
local raidRoster = {} -- { {name, rank} }
local partyNames = {} -- [slot] = name
IsRaidLeader = function() return false end
IsRaidOfficer = function() return false end

GetNumRaidMembers = function() return raidMembers end
GetNumPartyMembers = function() return partyMembers end
GetLootMethod = function() return lootMethod, lootId end
UnitName = function(unit)
  if unit == "player" or unit == nil then return "SoloPlayer" end
  if type(unit) == "string" then
    local slot = string.match(unit, "^party(%d+)$")
    if slot then return partyNames[tonumber(slot)] end
  end
  return nil
end
GetRaidRosterInfo = function(i)
  local r = raidRoster[i]
  if not r then return nil end
  return r[1], r[2]
end

dofile("SRSecurity.lua")
dofile("Comm.lua")
local Sec = ZugLoot.SRSecurity
local Comm = ZugLoot.Comm

-- 1. Solo: allowed to import (local preview), never broadcast, no channel.
raidMembers, partyMembers = 0, 0
ok(Sec.IsSolo(), "solo detected")
ok(Sec.CanImport(), "solo can import locally")
ok(not Sec.CanBroadcast(), "solo cannot broadcast")
eq(Comm.Channel(), nil, "solo has no channel")
eq(Sec.RoleLabel(), "Solo (preview)", "solo role label")

-- 2. In raid as plain raider (ML is someone else): anyone may import
-- (local view), but only the ML may broadcast; sync trust stays ML-only.
raidMembers = 40
raidRoster = {}
for i = 1, 40 do raidRoster[i] = { "Player" .. i, 0 } end
lootMethod, lootId = "master", 5 -- ML is raid slot 5 (Player5), not me
ok(not Sec.IsSolo(), "raider not solo")
ok(Sec.CanImport(), "anyone can import locally")
ok(not Sec.AmML(), "raider is not ML")
ok(not Sec.CanBroadcast(), "raider cannot broadcast")
eq(Comm.Channel(), "RAID", "raid channel")
ok(not Sec.CanAcceptFrom("Player3"), "plain raider sheet untrusted")
ok(Sec.CanAcceptFrom("Player5"), "ML sheet trusted")
-- Leader rank WITHOUT the ML index confers nothing: rank-1 Player1's
-- sheet is refused, and broadcast stays shut.
raidRoster[1] = { "Player1", 1 }
ok(not Sec.CanAcceptFrom("Player1"), "leader-without-ML sheet refused")
-- Warn rank is orthogonal to ML rights: plain members (even the ML)
-- fall back to RAID; leaders and assists may use RAID_WARNING.
-- Rigged globals below; restore to plain-member stubs afterwards.
local saveLeader, saveOfficer = IsRaidLeader, IsRaidOfficer
IsRaidLeader = function() return true end
IsRaidOfficer = function() return false end
ok(Sec.CanRaidWarn(), "raid leader may warn")
IsRaidLeader = function() return false end
IsRaidOfficer = function() return true end
ok(Sec.CanRaidWarn(), "assist may warn")
IsRaidLeader = function() return false end
IsRaidOfficer = function() return false end
ok(not Sec.CanRaidWarn(), "plain member falls back (no /rw)")
IsRaidLeader, IsRaidOfficer = saveLeader, saveOfficer
raidMembers = 0 -- solo never warns
ok(not Sec.CanRaidWarn(), "solo never warns")
raidMembers = 40
IsRaidLeader, IsRaidOfficer = nil, nil -- missing API: never warn
ok(not Sec.CanRaidWarn(), "missing rank API never warns")
IsRaidLeader, IsRaidOfficer = saveLeader, saveOfficer

-- 3. I am the ML (id 0): may import + broadcast.
lootMethod, lootId = "master", 0
ok(Sec.AmML(), "ML detected via index 0")
ok(Sec.CanImport(), "ML can import")
ok(Sec.CanBroadcast(), "ML can broadcast")
ok(Sec.CanAcceptFrom("SoloPlayer"), "own ML sheet trusted")

-- 4. Party ML: id 0 means me on a party client too.
raidMembers = 0
raidRoster = {}
partyMembers = 4
partyNames = { "P1", "P2", "P3", "P4" }
lootMethod, lootId = "master", 0
ok(not Sec.IsSolo(), "party member not solo")
ok(Sec.AmML(), "party ML detected")
ok(Sec.CanBroadcast(), "party ML can broadcast")
eq(Comm.Channel(), "PARTY", "party channel")

-- 5. Party non-ML (ML is party slot 2): may import locally, never broadcast.
lootMethod, lootId = "master", 2 -- P2 is the ML
ok(Sec.CanImport(), "party non-ML can import locally")
ok(not Sec.AmML(), "party non-ML detected")
ok(not Sec.CanBroadcast(), "party non-ML cannot broadcast")
ok(Sec.CanAcceptFrom("P2"), "party ML sheet trusted")
ok(not Sec.CanAcceptFrom("P3"), "party non-ML sheet refused")
ok(not Sec.CanAcceptFrom("Stranger"), "off-roster name refused")
-- Non-master loot: nobody is ML.
lootMethod, lootId = "group", nil
ok(not Sec.AmML(), "group loot: nobody is ML")
ok(not Sec.CanBroadcast(), "group loot: no broadcast")
ok(not Sec.CanAcceptFrom("P2"), "group loot: sheet refused")

-- 6. SHEET_REQ answer policy: only the ML answers broadcast requests
-- (at once, when they hold a sheet); everyone else stays silent.
-- Needs sheet + timer + comm shims.
dofile("Timer.lua")
local sent = {}
SendAddonMessage = function(prefix, msg, channel)
  table.insert(sent, { prefix = prefix, msg = msg, channel = channel })
end
ZugLoot.PREFIX = "ZugLoot"
ZugLoot.Timer = ZugLoot.Timer
ZugLoot.Print = function() end
-- Comm/SRSecurity captured `local Z = ZugLoot` at load: Z.DB must live
-- on that same table. Establish it once here (later sections mutate
-- .sheet in place, never rebind).
ZugLoot.DB = { sheet = nil }
ZugLoot.SRImport = { SerializeSheet = function() return "A;1:1" end }
-- Raid of 3: ML is slot 1 (MasterLou), me plain raider, LeadGal rank 2.
raidMembers = 3
raidRoster = { { "MasterLou", 0 }, { "SoloPlayer", 0 }, { "LeadGal", 2 } }
partyMembers = 0
partyNames = {}
lootMethod, lootId = "master", 1
ZugLoot.DB.sheet = { items = { [1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } } }, meta = {} }
-- Plain raider WITH a sheet still never answers.
eq(Sec.SheetReqAnswer(), nil, "raider never answers sheetreq")
-- Trust: raider sheet is refused even if one arrived.
ok(not Sec.CanAcceptFrom("SoloPlayer"), "raider sheet untrusted")
ok(Sec.CanAcceptFrom("MasterLou"), "ML sheet trusted")
-- Rank-2 LeadGal WITHOUT the ML index: refused, never answers.
ok(not Sec.CanAcceptFrom("LeadGal"), "leader-without-ML sheet refused")
UnitName = function(unit)
  if unit == "player" or unit == nil then return "LeadGal" end
  return nil
end
eq(Sec.SheetReqAnswer(), nil, "leader-without-ML never answers")
UnitName = function(unit)
  if unit == "player" or unit == nil then return "SoloPlayer" end
  return nil
end
-- I am the ML (index 0): answer at once.
lootMethod, lootId = "master", 0
eq(Sec.SheetReqAnswer(), "ml", "ML answers sheetreq")
sent = {}
Comm.OnMessage("SHEET_REQ", "SoloPlayer")
eq(#sent, 1, "ML broadcast request answered at once")
ok(string.find(sent[1].msg, "SHEET:", 1, true) ~= nil, "answer is a sheet")
-- Non-master loot: nobody answers, not even a holder.
lootMethod, lootId = "group", nil
eq(Sec.SheetReqAnswer(), nil, "group loot: broadcast request unanswered")
-- No sheet held: nobody answers, not even the ML.
lootMethod, lootId = "master", 0
ZugLoot.DB.sheet = nil
eq(Sec.SheetReqAnswer(), nil, "no sheet: ML stays silent")

-- 7. Raid identity survives the broadcast: META envelope carries the
-- raid name + import stamp, the receiver's header shows them (not "—").
-- Needs the real SRImport/SRData (shimmed above) + archive shims.
dofile("SRData.lua")
dofile("SRImport.lua")
local SRData = ZugLoot.SRData
local RI = ZugLoot.SRImport
ZugLoot.RaidArchive = { ArchiveActive = function() end, SyncActive = function() end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
local raidSheet = SRData.NewSheet()
raidSheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
raidSheet.meta.raidID = "LeadGal-1234"
raidSheet.meta.raidName = "Molten Core"
raidSheet.meta.importedBy = "LeadGal"
raidSheet.meta.importedAt = 1234
raidSheet.meta.source = "paste"
local wirePayload = RI.SerializeSheet(raidSheet)
ok(string.find(wirePayload, "META;", 1, true) ~= nil, "META envelope serialized")
-- Full receive path through Comm (ML sender, raid channel).
raidMembers = 3
raidRoster = { { "SoloPlayer", 0 }, { "MasterLou", 0 }, { "Other", 0 } }
partyMembers = 0
lootMethod, lootId = "master", 2 -- MasterLou (slot 2) is the ML
ZugLoot.DB.sheet = nil
Comm.OnMessage("SHEET:1:MasterLou-1234:" .. wirePayload, "MasterLou")
ok(ZugLoot.DB.sheet ~= nil, "sheet received")
eq(ZugLoot.DB.sheet.meta.raidName, "Molten Core", "raid name survives sync")
eq(ZugLoot.DB.sheet.meta.raidID, "LeadGal-1234", "raid id survives sync")
eq(ZugLoot.DB.sheet.meta.importedAt, 1234, "import stamp survives sync")
eq(ZugLoot.DB.sheet.meta.importedBy, "MasterLou", "sender stamped")
ok(ZugLoot.DB.sheet.items[1001] ~= nil, "items survive sync")
-- META escaping: commas in names survive the envelope.
local commaSheet = SRData.NewSheet()
commaSheet.items[7] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
commaSheet.meta.raidName = "Ahn'Qiraj, Temple"
local wireC = RI.SerializeSheet(commaSheet)
local backC = RI.DeserializeSheet(wireC)
eq(backC.meta.raidName, "Ahn'Qiraj, Temple", "comma in raid name survives")
-- Legacy sender (no META line): receiver still stamps id + sender.
ZugLoot.DB.sheet = nil
Comm.OnMessage("SHEET:1:legacy-9:A;1:1", "MasterLou")
ok(ZugLoot.DB.sheet ~= nil, "legacy sheet received")
eq(ZugLoot.DB.sheet.meta.raidID, "legacy-9", "legacy raid id stamped")
eq(ZugLoot.DB.sheet.meta.importedBy, "MasterLou", "legacy sender stamped")

-- 8. Sync updates: same raidID + newer META stamp applies; same raidID +
-- older stamp is refused (never rolls the raid back).
ZugLoot.DB.sheet = nil
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. wirePayload, "MasterLou")
ok(ZugLoot.DB.sheet ~= nil, "base sync lands")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 1, "base content")
-- Build an update: same raid, newer stamp, extra roller.
local updSheet = SRData.NewSheet()
updSheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 }, { name = "Bbb", rolls = 1 } } }
updSheet.meta.raidID = "LeadGal-1234"
updSheet.meta.raidName = "Molten Core"
updSheet.meta.importedBy = "LeadGal"
updSheet.meta.importedAt = 9999
updSheet.meta.source = "paste"
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. RI.SerializeSheet(updSheet), "MasterLou")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 2, "sync update applies (keeps id)")
eq(ZugLoot.DB.sheet.meta.raidID, "LeadGal-1234", "sync update keeps raid id")
eq(ZugLoot.DB.sheet.meta.raidName, "Molten Core", "sync update keeps raid name")
-- Stale re-send (older stamp): refused, live update kept.
local staleSheet = SRData.NewSheet()
staleSheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
staleSheet.meta.raidID = "LeadGal-1234"
staleSheet.meta.raidName = "Molten Core"
staleSheet.meta.importedBy = "LeadGal"
staleSheet.meta.importedAt = 1234
staleSheet.meta.source = "paste"
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. RI.SerializeSheet(staleSheet), "MasterLou")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 2, "stale sync refused, update kept")

-- 9. Targeted sync (/zl sync <name>): only the named player answers,
-- directly (anyone holding a sheet may answer); trust stays on RECEIVE.
-- (Restore the SRImport shim: section 7 loaded the real module above.)
ZugLoot.SRImport = { SerializeSheet = function() return "A;1:1" end }
UnitName = function(unit)
  if unit == "player" or unit == nil then return "SoloPlayer" end
  return nil
end
raidMembers = 3
raidRoster = { { "MasterLou", 0 }, { "SoloPlayer", 0 }, { "LeadGal", 2 } }
partyMembers = 0
lootMethod, lootId = "master", 1 -- MasterLou is the ML
ZugLoot.DB.sheet = { items = { [1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } } }, meta = {} }
-- Link-strip: color-coded [Name] links reduce to bare names.
eq(Comm.StripPlayerLink("|cFFF58CBASoloPlayer|r"), "SoloPlayer", "color link stripped")
eq(Comm.StripPlayerLink("|cFFF58CBA|Hplayer:SoloPlayer|h[SoloPlayer]|h|r"), "SoloPlayer", "player link stripped")
eq(Comm.StripPlayerLink("SoloPlayer"), "SoloPlayer", "bare name passes through")
-- Requester side: targeted request goes out addressed.
sent = {}
Comm.RequestSheetFrom("|cFFF58CBA|Hplayer:LeadGal|h[LeadGal]|h|r")
eq(#sent, 1, "targeted request sent")
ok(string.find(sent[1].msg, "SHEET_REQ:LeadGal", 1, true) ~= nil, "request addressed to LeadGal")
Comm.RequestSheetFrom("")
eq(#sent, 1, "empty name sends nothing (usage)")
-- Answer side (as SoloPlayer, holding a sheet): targeted request
-- answered directly — anyone holding a sheet may answer a /zl sync,
-- ML or not. (ML-only applies to broadcast SHEET_REQ, section 6.)
sent = {}
UnitName = function(unit)
  if unit == "player" or unit == nil then return "SoloPlayer" end
  return nil
end
time = function() return 6000 end -- past the broadcast debounce
Comm.OnMessage("SHEET_REQ:SoloPlayer", "LeadGal")
eq(#sent, 1, "named holder answers directly")
ok(string.find(sent[1].msg, "SHEET:", 1, true) ~= nil, "answer is a sheet")
-- Wrong name: silence (not us, don't answer).
sent = {}
Comm.OnMessage("SHEET_REQ:SomebodyElse", "SoloPlayer")
eq(#sent, 0, "wrong name stays silent")
-- No sheet held: silence even when named.
ZugLoot.DB.sheet = nil
sent = {}
Comm.OnMessage("SHEET_REQ:SoloPlayer", "LeadGal")
eq(#sent, 0, "sheetless named player stays silent")

-- 10. Empty-content sync guards (regression: a sender whose import was
-- a thin CSV broadcast a bare-META wire; receivers printed "Sheet
-- received" and landed on "(sheet is empty)").
-- Restore the real modules (section 9 shimmed SRImport) + print tap.
dofile("SRData.lua")
dofile("SRImport.lua")
local RI2 = ZugLoot.SRImport
local seen = {}
ZugLoot.Print = function(m) table.insert(seen, tostring(m)) end
ZugLoot.DB.sheet = nil
ZugLoot.RaidArchive = { ArchiveActive = function() end, SyncActive = function() end }
-- Live content sheet lands normally first (ML sender).
raidMembers = 3
raidRoster = { { "MasterLou", 0 }, { "SoloPlayer", 0 }, { "Other", 0 } }
partyMembers = 0
lootMethod, lootId = "master", 1 -- MasterLou is the ML
UnitName = function(unit)
  if unit == "player" or unit == nil then return "SoloPlayer" end
  return nil
end
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. wirePayload, "MasterLou")
ok(ZugLoot.DB.sheet ~= nil, "live content sync lands")
-- An EMPTY wire (bare META, thin-CSV sender) is refused: live kept.
local emptySheet = ZugLoot.SRData.NewSheet()
emptySheet.meta = { raidID = "Rempty", importedBy = "LeadGal", importedAt = 99999, source = "paste" }
Comm.OnMessage("SHEET:1:Rempty:" .. RI2.SerializeSheet(emptySheet), "MasterLou")
eq(ZugLoot.DB.sheet.meta.raidID, "LeadGal-1234", "empty sync keeps live raid")
ok(string.find(seen[#seen] or "", "empty sheet", 1, true) ~= nil, "empty sync explains itself")
-- And we never ANSWER a request with an empty sheet either.
ZugLoot.DB.sheet = ZugLoot.SRData.NewSheet()
sent = {}
UnitName = function(unit)
  if unit == "player" or unit == nil then return "SoloPlayer" end
  return nil
end
Comm.OnMessage("SHEET_REQ:SoloPlayer", "MasterLou")
eq(#sent, 0, "empty holder stays silent on targeted sync")

return T
