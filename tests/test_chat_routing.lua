-- tests/test_chat_routing.lua
-- Single chat router verification: sim and live rolls share Comm.Say —
-- only the CHANNEL differs by grouping. Solo -> ZugLoot log (Z.Print),
-- party -> PARTY, raid -> RAID (RAID_WARNING for warnings). Identical
-- text in every grouping, so solo sim output reads exactly like the
-- raid-night lines (verifiable without a raid).
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
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("ItemCards.lua")
dofile("Timer.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
local printed = {} -- ZugLoot log (solo destination)
local sent = {} -- SendChatMessage calls: { msg, chan }
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
SendChatMessage = function(msg, chan) table.insert(sent, { msg = tostring(msg), chan = tostring(chan) }) end
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
time = time or os.time

local grouping = "solo"
-- Raid-rank rig: nil = headless (no rank proof), true = raid leader,
-- "officer" = assist, false = plain raider (ML without assist).
local raidRank = nil
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
  AmML = function() return true end,
  CanRaidWarn = function()
    if raidRank == nil then return false end -- headless: no rank proof
    return raidRank == true or raidRank == "officer"
  end,
}
ZugLoot.RaiderLootUI = { ShowItem = function() end, OnRoll = function() end, Hide = function() end }
ZugLoot.DropLog = { Add = function() end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
dofile("Sim.lua")
local Sim = ZugLoot.Sim
local SRData = ZugLoot.SRData
local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow
ML.lootOpen = true

local function makeSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2, sr_plus = nil },
  } }
  -- Sheet classes so chat pins cover the class color, not just the link.
  SRData.SetPlayerClass(s, "Aaa", "Paladin")
  SRData.SetPlayerClass(s, "Bbb", "Mage")
  return s
end

-- Player-link pins: clickable class color per name.
local LINK_AAA = "|cFFF58CBA|Hplayer:Aaa|h[Aaa]|h|r"
local LINK_BBB = "|cFF69CCF0|Hplayer:Bbb|h[Bbb]|h|r"

local function setRank(r) raidRank = r end

local function reset()
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.running = false
  Sim.raid = nil
  Sim.FakeCount = 2
  ML.roll = nil
  ML.lastRound = nil
  LW.Clear()
  printed, sent = {}, {}
  ZugLoot.DB = { sheet = makeSheet(), rollTime = 30 }
  -- Named sim row so DisplayItemLink resolves like a live corpse row
  -- (sim queue entries carry links; the window row carries the name).
  LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "sim")
end

local function rigged(values)
  local i = 0
  return function(lo, hi)
    i = i + 1
    local v = values[((i - 1) % #values) + 1]
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
  end
end
local realRandom = math.random

-- Chat snapshot helpers: what the user would SEE per grouping.
local function logText() return table.concat(printed, "\n") end
local function chatText()
  local out = {}
  for i = 1, #sent do table.insert(out, sent[i].msg) end
  return table.concat(out, "\n")
end
local function chatChans()
  local out = {}
  for i = 1, #sent do table.insert(out, sent[i].chan) end
  return table.concat(out, ",")
end

-- 1. Solo: everything lands in the ZugLoot log, nothing on the wire.
reset()
grouping = "solo"
math.random = rigged({ 90, 80 })
Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
math.random = realRandom
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
eq(#sent, 0, "solo sends nothing (log only)")
local soloLog = logText()
ok(string.find(soloLog, "Roll ", 1, true) ~= nil, "solo log has roll-start")
ok(string.find(soloLog, LINK_AAA .. " rolls 90 (1-100)", 1, true) ~= nil, "solo log has fake roll line (linked)")
ok(string.find(soloLog, "won by " .. LINK_AAA .. " (100)", 1, true) ~= nil, "solo log has verdict (linked)")
ok(string.find(soloLog, LINK_AAA .. " wins ", 1, true) ~= nil, "solo log has award line (linked)")

-- 2. Same sim IN RAID with assist: identical text on RAID / RAID_WARNING.
-- NOTE: rigged() cycles {90, 80} across FakeCount draws + kind draws,
-- so the exact fake roster varies with draw order — pins assert the
-- shared builders + channels, not a byte-fixed roll list.
reset()
grouping = "raid"
setRank("officer")
math.random = rigged({ 90, 80 })
Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
math.random = realRandom
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(#sent > 0, "raid sim reaches group chat")
-- Line builders produce the same text solo printed locally...
local raidChat = chatText()
ok(string.find(raidChat, "|Hplayer:Aaa", 1, true) ~= nil, "raid sim roll lines name rollers")
ok(string.find(raidChat, "won by ", 1, true) ~= nil, "raid sim verdict matches solo shape")
ok(string.find(raidChat, " wins ", 1, true) ~= nil, "raid sim award matches solo shape")
-- ...on the group channels only (start is a warning).
ok(string.find(chatChans(), "RAID_WARNING", 1, true) ~= nil, "roll-start warns the raid (assist)")
ok(string.find(chatChans(), "RAID", 1, true) ~= nil, "roll traffic on RAID")
for i = 1, #sent do
  ok(sent[i].chan == "RAID" or sent[i].chan == "RAID_WARNING", "raid sends RAID/RAID_WARNING only")
end
eq(#printed, 3, "raid sim keeps only harness lines local (queue/drain notes)")

-- 2b. Same sim IN RAID as ML WITHOUT assist: warn traffic falls back
-- to plain RAID (an ML without leader/assist rank cannot send /rw).
reset()
grouping = "raid"
setRank(false)
math.random = rigged({ 90, 80 })
Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
math.random = realRandom
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(#sent > 0, "assist-less sim still reaches group chat")
for i = 1, #sent do
  eq(sent[i].chan, "RAID", "assist-less sim sends RAID only (no /rw)")
end
ok(string.find(chatText(), "Roll ", 1, true) ~= nil, "assist-less start text unchanged")
setRank(nil)

-- 3. Same sim IN PARTY: identical text on PARTY (warnings degrade: no
-- party warning channel exists).
reset()
grouping = "party"
math.random = rigged({ 90, 80 })
Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
math.random = realRandom
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(#sent > 0, "party sim reaches party chat")
for i = 1, #sent do
  eq(sent[i].chan, "PARTY", "party sends PARTY only (no warnings)")
end

-- 4. LIVE roll shares the path: same builders, same channels.
-- Rank pinned per side: the assisting ML warns, the plain-ML
-- fallback stays on RAID (2b covers the warn side of sim; 4b the
-- live side).
reset()
grouping = "raid"
setRank("officer")
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
local liveChat = chatText()
-- Chat lines carry REAL clickable links, never bare white text.
ok(string.find(liveChat, "|Hitem:1001", 1, true) ~= nil, "live roll-start links the item")
ok(string.find(liveChat, "Roll |c", 1, true) ~= nil, "live roll-start is quality-colored")
-- Live intake does NOT re-announce (the player's own /roll system
-- message is already in chat): only start + verdict + award go out.
ok(string.find(liveChat, "Aaa rolls 90", 1, true) == nil, "live intake stays quiet (no double line)")
ok(string.find(liveChat, "won by " .. LINK_AAA .. " (100)", 1, true) ~= nil, "live verdict shares the builder")
ok(string.find(liveChat, LINK_AAA .. " wins |c", 1, true) ~= nil, "live award shares the builder (linked)")
for i = 1, #sent do
  ok(sent[i].chan == "RAID" or sent[i].chan == "RAID_WARNING", "live raid sends RAID/RAID_WARNING only (assist)")
end
-- 4b. LIVE roll as ML WITHOUT assist: identical text, RAID only.
reset()
grouping = "raid"
setRank(false)
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(#sent > 0, "assist-less live roll still reaches group chat")
for i = 1, #sent do
  eq(sent[i].chan, "RAID", "assist-less live sends RAID only (no /rw)")
end
setRank(nil)
-- The sim fake line and the shared builder agree word-for-word.
eq(ML.RollLine({ name = "Aaa", roll = 90, min = 1, max = 100 }), LINK_AAA .. " rolls 90 (1-100)", "RollLine format pinned")
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
local awardBuilt = ML.AwardLine(1001, "item:1001", "Aaa")
ok(string.find(awardBuilt, LINK_AAA .. " wins ", 1, true) ~= nil, "AwardLine names the winner (linked)")
ok(string.find(awardBuilt, "|Hitem:1001", 1, true) ~= nil, "AwardLine links the item")
ok(string.find(awardBuilt, "[Dragonfang Blade]", 1, true) ~= nil, "AwardLine names the item")

-- 5. Non-ML simmer in raid/party: the sim speaks to the group — a sim
-- is an explicit test action, never background echo, so the speaker
-- gate doesn't apply. Same text the ML's sim produces, on the same
-- channels (start warns). (AmML is flipped per-grouping inside: the
-- shared-router block above ends ML, and reset() doesn't touch it.)
ZugLoot.SRSecurity.AmML = function() return true end
setRank("officer") -- non-ML simmers still warn when they hold assist
for _, g in ipairs({ "raid", "party" }) do
  reset()
  grouping = g
  ZugLoot.SRSecurity.AmML = function() return false end
  math.random = rigged({ 90, 80 })
  Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
  math.random = realRandom
  LW.doAction(1001, "finish")
  ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
  ok(#sent > 0, g .. " simmer reaches group chat")
  -- Same SHAPE as the ML's sim (start + roll lines + verdict + award
  -- through the shared builders); exact fakes vary with RNG draw order
  -- (ties re-roll the shape: verdict/award shift but stay linked).
  local simChat = chatText()
  ok(string.find(simChat, "^Roll ", 1) ~= nil or string.find(simChat, "\nRoll ", 1, true) ~= nil, g .. " simmer start matches")
  ok(string.find(simChat, " rolls %d+ %(%d+%-%d+%)") ~= nil, g .. " simmer roll lines match")
  ok(string.find(simChat, "|Hplayer:", 1, true) ~= nil, g .. " simmer names link")
  ok(string.find(simChat, "|Hitem:", 1, true) ~= nil, g .. " simmer items link")
  for i = 1, #sent do
    if g == "raid" then
      ok(sent[i].chan == "RAID" or sent[i].chan == "RAID_WARNING", "raid simmer sends RAID/RAID_WARNING only")
    else
      eq(sent[i].chan, "PARTY", "party simmer sends PARTY only")
    end
  end
end

-- 5b. Shared-router sim sniffing: SayGroup/WarnGroup route by the ROLL,
-- not a caller flag — a SIM round speaks even through the plain path.
reset()
grouping = "raid"
ZugLoot.SRSecurity.AmML = function() return false end
ZugLoot.DB = { sheet = makeSheet(), rollTime = 30 }
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "sim")
local simRoll = ML.BeginRoll(1001, "item:1001", "SIM", true)
ok(simRoll ~= nil and simRoll.mode == "SIM", "sim round opens")
sent = {}
ZugLoot.Comm.SayGroup("plain-path sim line")
eq(#sent, 1, "SayGroup speaks during a SIM round")
eq(sent[1].chan, "RAID", "sim line on RAID even from non-ML")
ML.EndRoll(1001)
sent = {}
ZugLoot.Comm.SayGroup("plain-path live line")
eq(#sent, 0, "SayGroup stays local with no SIM round (non-ML)")
-- Parked SIM round (finished, award pending) still counts as sim.
ML.lastRound = { itemID = 1001, itemLink = "item:1001", mode = "SIM", silent = true }
sent = {}
ZugLoot.Comm.SayGroup("parked sim line")
eq(#sent, 1, "SayGroup speaks for a parked SIM round")
-- ...but awarding consumes the stamp, so the NEXT live line is local.
ML.lastRound = nil
sent = {}
ZugLoot.Comm.SayGroup("after award, no SIM round")
eq(#sent, 0, "SayGroup local again once the SIM stamp is consumed")
ZugLoot.SRSecurity.AmML = function() return true end

-- 5c. Non-ML LIVE flow stays local: only the master looter speaks live
-- lines to the group (no background echo from raiders' clients).
-- Rank pinned: warnings route through the same fallback (assist ->
-- /rw, plain -> RAID), but these lines never reach the wire at all.
setRank("officer")
for _, g in ipairs({ "raid", "party" }) do
  reset()
  grouping = g
  ZugLoot.SRSecurity.AmML = function() return false end
  LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
  LW.OpenDetail(1001)
  LW.doAction(1001, "roll")
  ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
  ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
  LW.doAction(1001, "finish")
  ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
  eq(#sent, 0, g .. " raider sends no live lines (ML-only chat)")
  local raiderLog = logText()
  ok(string.find(raiderLog, "won by " .. LINK_AAA .. " (100)", 1, true) ~= nil, g .. " raider still sees the verdict locally")
  ok(string.find(raiderLog, LINK_AAA .. " wins ", 1, true) ~= nil, g .. " raider still sees the award locally")
end
ZugLoot.SRSecurity.AmML = function() return true end
setRank(nil)

-- 5d. Unit pins for the rank gate (Comm.Say WarnGroup side):
-- raid leader may warn, assist may warn, a plain raider (ML without
-- rank) may not. Party has no warn channel: always party text.
reset()
grouping = "raid"
ZugLoot.SRSecurity.AmML = function() return true end
local function chanOf(rank)
  setRank(rank)
  sent = {}
  ZugLoot.Comm.WarnGroup("rank probe")
  setRank(nil)
  eq(#sent, 1, "warn probe sends (rank " .. tostring(rank) .. ")")
  return sent[1].chan
end
eq(chanOf(true), "RAID_WARNING", "raid leader warns")
eq(chanOf("officer"), "RAID_WARNING", "assist warns")
eq(chanOf(false), "RAID", "plain ML falls back to RAID")
-- Party: warn degrades to PARTY regardless of rank.
reset()
grouping = "party"
setRank(true)
sent = {}
ZugLoot.Comm.WarnGroup("party probe")
eq(#sent, 1, "party warn probe sends")
eq(sent[1].chan, "PARTY", "party warn degrades to PARTY")
setRank(nil)

-- 5c. Player names in chat are clickable class-colored links
-- (|cHEX|Hplayer:Name|h[Name]|h|r): click -> whisper menu, color ->
-- class. Unknown classes still link (white). Roll/verdict/award/sand
-- all share the builder, so one pin covers every chat line.
reset()
local linkBuilt = ML.AwardLine(1001, "item:1001", "Aaa")
ok(string.find(linkBuilt, "|Hplayer:Aaa|h[Aaa]|h", 1, true) ~= nil, "award names the winner as a player link")
local linkRoll = ML.RollLine({ name = "Aaa", roll = 90, min = 1, max = 100 })
ok(string.find(linkRoll, "|Hplayer:Aaa|h[Aaa]|h", 1, true) ~= nil, "roll line links the roller")
eq(ML.RollLine({ name = "Aaa", roll = 90, min = 1, max = 100 }),
  ZugLoot.ClassColors.PlayerLink("Aaa") .. " rolls 90 (1-100)", "RollLine links, format pinned")
local linkTied = ML.ResultLine({ itemID = 1001, itemLink = "item:1001" },
  { winners = {}, tied = { { name = "Bbb" } } })
ok(string.find(linkTied, "|Hplayer:Bbb|h[Bbb]|h", 1, true) ~= nil, "tie verdict links the tied")
local linkSand = ML.SandLine(19183, "item:19183", "Bbb", 1, 6)
ok(string.find(linkSand, "|Hplayer:Bbb|h[Bbb]|h", 1, true) ~= nil, "sand line links the winner")
ok(string.find(ML.AwardLine(1001, "item:1001", "Tmog", "Aaa"),
  "|Hplayer:Aaa|h[Aaa]|h", 1, true) ~= nil, "trade-to recipient links too")

-- 6. Pure builders: tie / no-winner verdicts + sand line + start line.
reset()
LW.SetItems({
  { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" },
  { itemID = 19183, link = "item:19183", name = "Hourglass Sand" },
}, "loot")
local tieRes = { winners = {}, tied = { { name = "Aaa" }, { name = "Bbb" } } }
ok(string.find(ML.ResultLine({ itemID = 1001, itemLink = "item:1001" }, tieRes), "tie between " .. LINK_AAA .. ", " .. LINK_BBB, 1, true) ~= nil, "tie verdict pinned")
local noRes = { winners = {}, tied = {} }
ok(string.find(ML.ResultLine({ itemID = 1001, itemLink = "item:1001" }, noRes), "no eligible rolls", 1, true) ~= nil, "no-winner verdict pinned")
local sandBuilt = ML.SandLine(19183, "item:19183", "Bbb", 1, 6)
ok(string.find(sandBuilt, "Sand x1 -> " .. LINK_BBB .. " (6 total)", 1, true) ~= nil, "sand line pinned")
ok(string.find(sandBuilt, "|Hitem:19183", 1, true) ~= nil, "sand line links the item")
local startBuilt = ML.StartLine(1001, "item:1001", "SR")
ok(string.find(startBuilt, "Roll ", 1, true) ~= nil, "start line pinned")
ok(string.find(startBuilt, "|Hitem:1001", 1, true) ~= nil, "start line links the item")
local rrBuilt = ML.StartLine(1001, "item:1001", "RAIDROLL")
ok(string.find(rrBuilt, "Raid rolling ", 1, true) ~= nil, "raid-roll start pinned")
ok(string.find(rrBuilt, "|Hitem:1001", 1, true) ~= nil, "raid-roll start links the item")

-- 6. Sand shares the router too (was SayGroup-gated on source before).
reset()
grouping = "party"
LW.SetItems({ { itemID = 19183, link = "item:19183", name = "Hourglass Sand" } }, "loot")
ok(ML.SandDistribute(19183, "loot"), "sand distributes")
eq(#sent, 1, "party sand reaches party chat")
eq(sent[1].chan, "PARTY", "party sand on PARTY")
ok(string.find(sent[1].msg, "Sand x1 -> ", 1, true) ~= nil, "sand text shared")

-- 7. Grouped quiet traffic is hushed: the ML's own client never logs
-- what the group already sees on its channel (drop announces).
reset()
grouping = "raid"
printed = {}
ZugLoot.DB = { sheet = makeSheet(), rollTime = 30 }
-- Drive the announce through the real OnLootOpened path: stub the
-- corpse slots the scanner reads (GetNumLootItems/GetLootSlotLink).
local saveNum, saveLink, saveInfo = GetNumLootItems, GetLootSlotLink, GetLootSlotInfo
GetNumLootItems = function() return 1 end
GetLootSlotLink = function(s) if s == 1 then return "item:1001:0:0:0" end end
GetLootSlotInfo = function(s)
  if s == 1 then return "tex", "Dragonfang Blade", 1, 4 end
end
ML.lootOpen = true
ML.OnLootOpened()
GetNumLootItems, GetLootSlotLink, GetLootSlotInfo = saveNum, saveLink, saveInfo
local noisy = false
for i = 1, #printed do
  if string.find(printed[i], "dropped", 1, true) then noisy = true break end
end
ok(not noisy, "raid drop announce stays off the ML log")
ok(LW.Find(1001) ~= nil, "quiet announce still lists the row")
-- ...but the headless mirror keeps verify/paste working when the
-- wire is absent.
SendChatMessage = nil
printed = {}
reset()
grouping = "raid"
GetNumLootItems = function() return 1 end
GetLootSlotLink = function(s) if s == 1 then return "item:1001:0:0:0" end end
GetLootSlotInfo = function(s)
  if s == 1 then return "tex", "Dragonfang Blade", 1, 4 end
end
ML.lootOpen = true
ML.OnLootOpened()
GetNumLootItems, GetLootSlotLink, GetLootSlotInfo = saveNum, saveLink, saveInfo
SendChatMessage = function(msg, chan) table.insert(sent, { msg = tostring(msg), chan = tostring(chan) }) end
local mirrored = false
for i = 1, #printed do
  if string.find(printed[i], "(raid)", 1, true)
      and string.find(printed[i], "dropped 1 item", 1, true) then mirrored = true break end
end
ok(mirrored, "headless mirror tags the raid line for verify/paste")

if T.fail == 0 then
  print("chat routing discipline passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
