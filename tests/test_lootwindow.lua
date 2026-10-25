-- tests/test_lootwindow.lua
-- Raider-style loot window: icon/name/SR-HR rows (no numbers), and the
-- row detail that STAYS OPEN as the roll window (pick -> rolling -> award):
-- live roll list with kinds, finish-early, award-in-window.
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
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
time = time or os.time
CreateFrame = nil -- headless: data layer only

ZugLoot.SRSecurity = { AmML = function() return true end,
  IsInRaid = function() return false end, IsInGroup = function() return false end,
  IsSolo = function() return true end }
ZugLoot.DropLog = { Add = function() end }
ZugLoot.Comm = { BroadcastAward = function() end,
  WarnGroup = function(m) table.insert(printed, m) end,
  SayGroup = function(m) table.insert(printed, m) end }

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
local LW = ZugLoot.LootWindow
local ML = ZugLoot.MasterLootUI
local SRData = ZugLoot.SRData
-- Headless corpse session: rows imply an open corpse (the detail Award
-- button only exists on scanned rows). Closed-loot blocking is covered
-- in test_mlflow; here the session stays open unless a test closes it.
ML.lootOpen = true

local function makeSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2, sr_plus = nil },
  } }
  s.items[1002] = { quality = 4, rollers = {
    { name = "Solo", rolls = 1, sr_plus = nil },
  } }
  s.hardres[1003] = { quality = 5 }
  return s
end

-- 0. Client-like GetItemInfo: sheet-style name/link/quality/texture.
-- Sim rows carry bare "1001" links — resolution must still yield the
-- sheet-style presentation (regression: rows showed "item:<id>", no icon).
GetItemInfo = function(id)
  local db = { [1001] = { "Dragonfang Blade", "|cffa335ee|Hitem:1001:0:0:0|h[Dragonfang Blade]|h|r", 4, "Interface\\Icons\\INV_Sword_01" },
    [1002] = { "Healing Potion", "|cff1eff00|Hitem:1002:0:0:0|h[Healing Potion]|h|r", 2, "Interface\\Icons\\INV_Potion_01" } }
  local e = db[tonumber(id)]
  if not e then return nil end
  return e[1], e[2], e[3], 1, 1, "", "", "", e[4]
end
-- Bare "1001" links resolve sheet-style; unknown ids fall back cleanly.
local rn, rl, rq, rt = LW.ResolveItemInfo(1001, "1001", 0, nil, nil)
eq(rn .. "|" .. rq .. "|" .. rt, "Dragonfang Blade|4|Interface\\Icons\\INV_Sword_01",
  "name/quality/texture resolved from itemID")
ok(string.find(rl, "Hitem:1001", 1, true) ~= nil, "full link resolved")
LW.SetItems({ { itemID = 1001, link = "1001" } }, "sim")
eq(LW.items[1].name .. "|" .. LW.items[1].texture,
  "Dragonfang Blade|Interface\\Icons\\INV_Sword_01", "sim row resolved")
local tRes = LW.RowText(LW.items[1])
ok(string.find(tRes, "Dragonfang", 1, true) ~= nil
  and string.find(tRes, "item:1001", 1, true) == nil, "row text named, no bare id")
LW.SetItems({ { itemID = 4242, link = "item:4242" } }, "sim")
eq(LW.RowText(LW.items[1]), "item:4242", "unknown falls back to item:id")

-- 1. ReserveBadge: HR wins, SR / SR:n, "" when unreserved.
local sheet = makeSheet()
for id, want in pairs({ [1003] = "HR", [1001] = "SR:2", [1002] = "SR", [9999] = "" }) do
  eq(SRData.ReserveBadge(sheet, id), want, "badge " .. id)
end
ok(SRData.IsHardres(sheet, 1003) and not SRData.IsHardres(sheet, 1001)
  and not SRData.IsHardres(nil, 1001), "IsHardres")
eq(table.concat(SRData.SRNames(sheet, 1001), ","), "Aaa,Bbb", "SR names sorted")

-- 1b. DisplayName / TooltipLink (RollFor ItemUtils parity): the row shows
-- the readable name, never the raw link; tooltips use the item: part.
eq(LW.DisplayName({ itemID = 17182, link = "|cffa335ee|Hitem:17182:0:0:0|h[Sulfuras]|h|r" }),
  "Sulfuras", "name parsed from link")
eq(LW.DisplayName({ itemID = 5, name = "Slot Name", link = "item:5" }),
  "Slot Name", "slot name preferred")
eq(LW.DisplayName({ itemID = 7 }), "item:7", "itemID fallback")
eq(LW.TooltipLink({ itemID = 17182, link = "|cffa335ee|Hitem:17182:0:0:0|h[Sulfuras]|h|r" }),
  "item:17182:0:0:0", "tooltip link extracted")
eq(LW.TooltipLink({ itemID = 8 }), "item:8:0:0:0", "tooltip link synthesized")
-- BuildLink: real clickable link from parts (RollFor parity) — used when
-- the cache has no full link but the name is known (uncached sheet items).
local builtHex = string.match(LW.BuildLink(17063, "Thunderfury", 5) or "", "^(|c%x+)")
ok(builtHex ~= nil, "built link has color prefix")
eq(LW.BuildLink(17063, "Thunderfury", 5), builtHex .. "|Hitem:17063:0:0:0|h[Thunderfury]|h|r", "built link shape")
eq(LW.BuildLink(8, nil, 4), nil, "no name, no link")
-- QualityHex: single color source. nil/zero quality is "unknown" and
-- stays white (never grey); known qualities consult the client API.
-- (Client GetItemQualityColor(0) is grey — the list default and the
-- ChatQuality "unknown" contract must not render as poor-quality.)
eq(LW.QualityHex(nil), "|cFFFFFFFF", "nil quality is white")
eq(LW.QualityHex(0), "|cFFFFFFFF", "zero quality is white")
eq(LW.BuildLink(9999, "Mystery", nil),
  "|cFFFFFFFF|Hitem:9999:0:0:0|h[Mystery]|h|r", "built link defaults to white")
-- ResolveItemInfo upgrades bare ids to full links when the name is known.
-- (Cache cold: stub misses 17063, so no full link comes from GetItemInfo.)
local _bn, bl = LW.ResolveItemInfo(17063, "item:17063:0:0:0", 5, nil, "Thunderfury")
ok(bl and string.find(bl, "|Hitem:17063", 1, true) ~= nil, "bare id upgraded to full link, got: " .. tostring(bl))

-- 2. Rows: icon/name/badge (no numbers), RowText mirrors the paint.
ZugLoot.DB = { sheet = sheet }
LW.SetItems({
  { itemID = 1001, link = "item:1001", quality = 4, badge = SRData.ReserveBadge(sheet, 1001) },
  { itemID = 1003, link = "item:1003", quality = 5, badge = SRData.ReserveBadge(sheet, 1003) },
  { itemID = 9999, link = "item:9999", quality = 3, badge = SRData.ReserveBadge(sheet, 9999) },
}, "loot")
eq(#LW.items, 3, "three rows")
eq(LW.items[1].index, 1, "row 1 numbered")
eq(LW.items[3].index, 3, "row 3 numbered")
for i, want in ipairs({ "SR:2", "HR", "" }) do
  eq(LW.items[i].badge, want, "row " .. i .. " badge")
end
local t1 = LW.RowText(LW.items[1])
ok(string.find(t1, "^1%.") == nil, "row text unnumbered (raider style)")
ok(string.find(t1, "SR:2", 1, true) ~= nil, "row text shows badge")
-- legacy sr= input still derives the badge.
for _, tc in ipairs({ { 2, "SR:2" }, { 1, "SR" } }) do
  LW.SetItems({ { itemID = 1001, link = "item:1001", sr = tc[1] } }, "loot")
  eq(LW.items[1].badge, tc[2], "legacy sr=" .. tc[1])
end
-- RowText shows the display name, not the raw link.
LW.SetItems({ { itemID = 17182,
  link = "|cffa335ee|Hitem:17182:0:0:0|h[Sulfuras]|h|r", badge = "SR" } }, "loot")
local tName = LW.RowText(LW.items[1])
ok(string.find(tName, "Sulfuras", 1, true) ~= nil, "row text shows item name")
ok(string.find(tName, "|Hitem:", 1, true) == nil, "row text hides the raw link")

-- 3. Row detail, single holder: Award direct, Roll + Raid roll buttons,
-- ... lists, Close dismisses.
LW.SetItems({
  { itemID = 1002, link = "item:1002", quality = 4, badge = "SR" },
  { itemID = 1001, link = "item:1001", quality = 4, badge = "SR:2" },
}, "loot")
local d = LW.OpenDetail(1002)
ok(d ~= nil, "detail opens")
eq(d.single, true, "single holder flagged")
eq(d.rollers[1], "Solo", "single holder named")
local acts = LW.DetailActions(d)
eq(acts[1].id, "award", "Award first on single")
eq(acts[2].id, "roll", "Roll second")
eq(acts[3].id, "raidroll", "Raid roll third")
eq(acts[4].id, "ignore", "Ignore fourth")
eq(acts[5].id, "more", "... fifth")
eq(acts[6].id, "close", "Close last")
-- direct award: won mark + row GONE + detail closed, no session.
eq(LW.doAction(1002, "award"), "awarded Solo", "direct award returns")
ok(SRData.HasWon(sheet, 1002, "Solo"), "direct award won-marks")
ok(LW.Find(1002) == nil, "awarded row left the list")
ok(LW.Find(1001) ~= nil, "unawarded row still listed")
ok(LW.detail == nil, "detail closed after award")
ok(ML.session == nil, "direct award starts no session")
-- multi holder: no direct Award; Roll + Raid roll buttons, then ... offers the choice list.
local d2 = LW.OpenDetail(1001)
eq(d2.single, false, "multi holder not single")
local acts2 = LW.DetailActions(d2)
eq(acts2[1].id, "roll", "multi starts at Roll")
eq(acts2[2].id, "raidroll", "Raid roll second")
eq(acts2[3].id, "ignore", "Ignore third")
eq(acts2[4].id, "more", "... fourth")
eq(LW.doAction(1001, "award"), "needs choice (...)", "multi award refused")
local more = LW.doAction(1001, "more")
ok(type(more) == "table" and #more >= 3, "... lists choices")
eq(LW.doAction(1001, "close"), "closed", "Close dismisses")
ok(LW.detail == nil, "detail closed, overview kept")
-- award-name from the More list awards a named raider directly.
LW.OpenDetail(1001)
eq(LW.doAction(1001, "award-name", "Aaa"), "awarded Aaa", "named award")
ok(SRData.HasWon(sheet, 1001, "Aaa"), "named award won-marks")
-- unknown item / action are safe.
ok(LW.OpenDetail(4242) == nil, "unknown item no detail")
eq(LW.doAction(4242, "award"), "unknown item", "unknown item safe")

-- 4. Roll initiation routes by source; the window flips only on a
-- real start. Starters report by return (truthy = rolling).
local rolled = {}
ZugLoot.Sim = { RequestRoll = function(id)
  table.insert(rolled, "sim:" .. id)
  ML.roll = { itemID = id, mode = "SIM", rolls = {}, silent = true }
  return true
end }
local started = {}
local realStartItemRoll = ML.StartItemRoll
ML.StartItemRoll = function(id)
  table.insert(started, "live:" .. tostring(id))
  ML.roll = { itemID = id, mode = "SR", rolls = {} }
  return true
end
LW.SetItems({ { itemID = 2001, link = "item:2001" } }, "sim")
eq(LW.doAction(2001, "roll"), "rolling", "sim roll from detail")
eq(rolled[1], "sim:2001", "sim RequestRoll called")
ok(LW.detail.phase == "rolling", "window flips on sim start")
ML.roll = nil
LW.CloseDetail()
LW.SetItems({ { itemID = 2002, link = "item:2002" } }, "loot")
eq(LW.doAction(2002, "roll"), "rolling", "live roll from detail")
eq(started[1], "live:2002", "live StartItemRoll called")
ML.roll = nil
LW.CloseDetail()
ML.StartItemRoll = realStartItemRoll
-- A refused start flips nothing.
ML.StartItemRoll = function(id) return nil end
LW.SetItems({ { itemID = 2003, link = "item:2003" } }, "loot")
LW.OpenDetail(2003)
eq(LW.doAction(2003, "roll"), "roll failed", "refused start fails")
eq(LW.detail.phase, "pick", "refused start keeps pick phase")
ML.StartItemRoll = realStartItemRoll
LW.CloseDetail()

-- 5. DetailLines render + ... choices (headless parity).
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local lines = LW.DetailLines()
ok(#lines == 3, "three detail lines")
ok(string.find(lines[1], "SR:2", 1, true) ~= nil, "title carries badge")
ok(string.find(lines[2], "Aaa", 1, true) ~= nil, "rollers listed")
local choices = LW.MoreChoices()
-- two reserve awards + the class-grouped REST of the
-- roster (Solo, reserved on 1002) for direct pre-roll awards.
-- (Roll initiation lives on the bar buttons, never in the menu.)
eq(#choices, 3, "two awards + class group")
eq(choices[1].name, "Aaa", "first award row named")
eq(choices[2].name, "Bbb", "award row carries the name")
eq(choices[3].id, "class", "rest of roster groups by class")
eq(choices[3].members[1].name, "Solo", "group member awards directly")
-- Class groups never duplicate the labeled top-level rows.
local topSeen = {}
for i = 1, #choices do
  local c = choices[i]
  if c.id == "award-name" then topSeen[c.name] = true end
end
local grpDup = nil
for i = 1, #choices do
  local c = choices[i]
  if c.id == "class" then
    for m = 1, #c.members do
      if topSeen[c.members[m].name] then grpDup = c.members[m].name end
    end
  end
end
eq(grpDup, nil, "class groups add nobody twice")
-- A grouped member awards directly (no roll): same path as a bare name.
ZugLoot.DB.sheet = makeSheet()
local soloWonBefore = SRData.HasWon(ZugLoot.DB.sheet, 1001, "Solo")
eq(LW.doAction(1001, "award-name", "Solo"), "awarded Solo", "grouped member direct award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Solo") and not soloWonBefore, "grouped award won-marks")
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)

-- 6. One window, one roll: pick -> rolling -> award, then done.
-- Rolls land with their kind; first-roll-only; nothing lands closed.
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "roll starts from detail")
ok(ML.roll ~= nil and ML.roll.itemID == 1001, "the one roll is live")
ok(LW.detail ~= nil, "detail STAYS OPEN on roll (not closed)")
eq(LW.detail.phase, "rolling", "detail phase rolling")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Stranger rolls 80 (1-100)")
ML.IntakeChatRoll("Oz rolls 97 (1-98)")
ML.IntakeChatRoll("Aaa rolls 50 (1-100)") -- first-roll-only
eq(#ML.roll.rolls, 3, "first rolls only")
eq(#LW.detail.rolls, 3, "window lists every roll")
-- Closed-window intake is dead: rolls for another item never land here.
LW.OpenDetail(1001)
ok(LW.DetailOnRoll(1002, "Eve", 50, "MS", 50, 1, 100) == false, "other-item roll refused")
LW.OpenDetail(1001)
local rl2 = LW.DetailLines()
local sawSR, sawMS, sawTM = false, false, false
for i = 1, #rl2 do
  if string.find(rl2[i], "SR: Aaa 90", 1, true) then sawSR = true end
  if string.find(rl2[i], "MS: Stranger 80", 1, true) then sawMS = true end
  if string.find(rl2[i], "TMOG: Oz 97", 1, true) then sawTM = true end
end
ok(sawSR and sawMS and sawTM, "roll list shows every roll with its kind")
-- Each roll shows the max of the /roll command used (56/98 TMOG style).
local rlRange = LW.DetailLines()
local sawR, sawT = false, false
for i = 1, #rlRange do
  if string.find(rlRange[i], "SR: Aaa 90/100", 1, true) then sawR = true end
  if string.find(rlRange[i], "TMOG: Oz 97", 1, true)
      and string.find(rlRange[i], "/98", 1, true) then sawT = true end
end
ok(sawR and sawT, "rolls show with max of command used")
eq(LW.RollRangeText({ roll = 56, rollType = "TMOG", max = 98 }), "56/98", "tmog range")
eq(LW.RollRangeText({ roll = 90, rollType = "SR", max = 100, effective = 100 }),
  "90/100 (=100)", "sr bonus past base kept")
eq(LW.RollRangeText({ roll = 90, rollType = "SR" }), "90/100", "kind cap fallback")
-- Sorted SR > MS > OS > TMOG regardless of feed order.
local sorted = LW.SortedDetailRolls()
eq(sorted[1].rollType, "SR", "SR first")
eq(sorted[#sorted].rollType, "TMOG", "TMOG last")
-- Detail actions: pick offers Award (single) + Roll + Raid roll +
-- Ignore buttons + ...; rolling offers Finish / Cancel / Raid roll /
-- Ignore / Close.
local racts = LW.DetailActions()
eq(racts[1].id, "finish", "rolling offers Finish")
eq(racts[2].id, "cancel", "rolling offers Cancel")
eq(racts[3].id, "raidroll", "rolling offers Raid roll instead")
eq(racts[4].id, "ignore", "rolling offers Ignore")
-- Rolling again on the open rolling window is refused (a live roll
-- blocks any fresh start until it finishes or closes).
eq(LW.doAction(1001, "roll"), "roll failed", "double roll refused")
ok(ML.roll ~= nil and #ML.roll.rolls == 3, "live roll untouched by refusal")
-- Finish: the same window becomes the award window.
eq(LW.doAction(1001, "finish"), "finished", "finish resolves")
ok(ML.roll == nil, "finished roll cleared")
eq(LW.detail.phase, "award", "detail phase award")
local al = LW.DetailLines()
local sawWinner = false
for i = 1, #al do
  if string.find(al[i], "winner: Aaa", 1, true) then sawWinner = true end
end
ok(sawWinner, "award window names the winner with kind")
local aacts = LW.DetailActions()
eq(aacts[1].id, "award-name", "award offers winner rows")
eq(aacts[1].name, "Aaa", "top winner first")
local hasCont = false
for i = 1, #aacts do if aacts[i].id == "continue" then hasCont = true break end end
ok(hasCont, "award offers Continue rolling")
-- Award ... lists each roller once (with their roll above): no bare
-- duplicate of a name already shown with a roll.
local seenNames, dupName = {}, nil
for i = 1, #LW.MoreChoices() do
  local c = LW.MoreChoices()[i]
  if c.name then
    if seenNames[c.name] then dupName = c.name end
    seenNames[c.name] = true
  end
end
eq(dupName, nil, "award ... shows nobody twice")
-- Award-phase ... lists rollers/winners only (re-rolls live on the
-- bar buttons); MoreRollControls stays the headless mirror of them
-- (Continue rolling first, then fresh Roll again, then Raid roll).
local arc = LW.MoreRollControls()
eq(#arc, 3, "award controls mirror the re-roll buttons")
eq(arc[1].id, "continue", "continue rolling first")
eq(arc[2].id, "roll", "roll again second")
eq(arc[3].id, "raidroll", "raid-roll third")
-- 6a. Continue rolling: reopens intake with the landed rolls kept
-- (unlike Roll again, which starts fresh).
eq(LW.doAction(1001, "continue"), "rolling", "continue reopens the roll")
ok(ML.roll ~= nil and ML.roll.itemID == 1001, "continued roll is live")
eq(#ML.roll.rolls, 3, "landed rolls carried over")
eq(#LW.detail.rolls, 3, "window keeps the landed rolls")
eq(LW.detail.phase, "rolling", "window back to rolling")
ML.IntakeChatRoll("Stranger rolls 80 (1-100)") -- already rolled: first-roll-only
eq(#ML.roll.rolls, 3, "re-roll from the same player ignored")
ML.IntakeChatRoll("NewGuy rolls 70 (1-100)") -- newcomer joins the round
eq(#ML.roll.rolls, 4, "newcomer roll lands")
eq(#LW.detail.rolls, 4, "window shows the newcomer")
eq(LW.doAction(1001, "finish"), "finished", "re-finish resolves")
eq(LW.detail.phase, "award", "award window again")
-- Re-finishing stamps again: continuing chains (all four rolls kept).
eq(LW.doAction(1001, "continue"), "rolling", "continue chains after re-finish")
eq(#ML.roll.rolls, 4, "chained continue keeps every roll")
ok(ML.lastRound == nil, "stamp consumed on use")
eq(LW.doAction(1001, "finish"), "finished", "third finish resolves")
-- Continue refused off the award window: back to a fresh pick, the
-- stamp is gone with the close.
ML.roll = nil
LW.CloseDetail()
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "fresh roll after close")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
eq(LW.doAction(1001, "finish"), "finished", "finish resolves")
-- Award from the window closes everything.
eq(LW.doAction(1001, "award-name", "Aaa"), "awarded Aaa", "award in window")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "window award won-marks")
ok(LW.Find(1001) == nil, "awarded row left the list")
ok(LW.detail == nil, "window closed after award")
ok(ML.roll == nil, "no roll survives the award")

-- 6a2. Ignore: marks the row ignored (it STAYS listed) with no award,
-- no won mark, no history — from pick, mid-roll (ends the roll), and
-- the award window. The detail stays open on rows that are still
-- actionable; looting finishes (detail closes) only when nothing
-- actionable remains (empty list, or only ignored rows).
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
  { itemID = 1002, link = "item:1002", badge = "SR" },
}, "loot")
ok(not LW.LootingFinished(), "open rows: looting not finished")
LW.OpenDetail(1001)
local lootCalls0 = 0
local lootOpenSaved = ML.lootOpen
CloseLoot = function() lootCalls0 = lootCalls0 + 1 end
eq(LW.doAction(1001, "ignore"), "ignored 1001", "ignore from pick")
ok(LW.Find(1001) ~= nil and LW.Find(1001).ignored, "ignored row stays listed")
ok(LW.detail ~= nil and LW.detail.itemID == 1001, "detail stays open (rows actionable)")
eq(lootCalls0, 0, "CloseLoot not fired while rows actionable")
CloseLoot = nil
ML.lootOpen = lootOpenSaved
ok(string.find(LW.RowText(LW.Find(1001)), "[ignored]", 1, true) ~= nil, "ignored row flagged")
ok(not LW.LootingFinished(), "actionable rows left: looting not finished")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "ignore won-marks nobody")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 0, "ignore records no history")
ok(LW.Find(1002) ~= nil, "other row untouched")
-- Mid-roll ignore ends the live roll; the marked row stays listed.
-- It is also the LAST actionable row here, so the whole loot window
-- closes (not just the detail) — Hide() hides the overview frame.
local hideCalls = 0
local realHide = LW.Hide
local closeCalls = 0
CloseLoot = function() closeCalls = closeCalls + 1 end
LW.Hide = function() hideCalls = hideCalls + 1 return realHide() end
LW.OpenDetail(1002)
LW.doAction(1002, "roll")
ML.IntakeChatRoll("Solo rolls 70 (1-100)")
eq(LW.doAction(1002, "ignore"), "ignored 1002", "ignore mid-roll")
ok(ML.roll == nil, "ignore ends the roll")
ok(LW.Find(1002) ~= nil and LW.Find(1002).ignored, "mid-roll ignore stays listed")
ok(LW.detail == nil, "detail closed: only ignored rows left")
ok(hideCalls >= 1, "loot window closed: only ignored rows left")
ok(closeCalls >= 1, "loot session closed: only ignored rows left")
CloseLoot = nil
LW.Hide = realHide
ok(LW.LootingFinished(), "only ignored rows: looting finished")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 0, "unfinished roll logs nothing")
-- Ignore-first, then process the rest: ignoring 1001 up front leaves
-- 1002 actionable; awarding 1002 after must close the whole window
-- even though the close-out runs through the award path, not ignore.
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
  { itemID = 1002, link = "item:1002", badge = "SR" },
}, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "ignore"), "ignored 1001", "ignore-first from pick")
ok(LW.Find(1001).ignored, "first row ignored, still listed")
ok(LW.detail ~= nil, "detail open: 1002 still actionable")
hideCalls = 0
closeCalls = 0
CloseLoot = function() closeCalls = closeCalls + 1 end
LW.Hide = function() hideCalls = hideCalls + 1 return realHide() end
LW.OpenDetail(1002)
LW.doAction(1002, "roll")
ML.IntakeChatRoll("Solo rolls 70 (1-100)")
LW.doAction(1002, "finish")
eq(LW.doAction(1002, "award-name", "Solo"), "awarded Solo", "award the rest")
ok(LW.Find(1002) == nil, "awarded row left the list")
ok(LW.Find(1001) ~= nil and LW.Find(1001).ignored, "ignored row still listed")
ok(LW.detail == nil, "detail closed: only ignored rows left")
ok(hideCalls >= 1, "loot window closed: only ignored rows left")
ok(closeCalls >= 1, "loot session closed after ignore-first + award-rest")
CloseLoot = nil
LW.Hide = realHide
ok(LW.LootingFinished(), "ignore-first + award-rest finishes looting")
-- Award-phase ignore: history from the finished round stays (rolls
-- really happened), but nobody wins.
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
LW.doAction(1001, "finish")
eq(LW.doAction(1001, "ignore"), "ignored 1001", "ignore from award")
ok(LW.Find(1001) ~= nil and LW.Find(1001).ignored, "ignored item stays listed")
ok(LW.detail == nil, "detail closed: only ignored rows left")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "award-phase ignore won-marks nobody")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "finished-round history kept")

-- 6b. TMOG kind winner directly awardable next to the outright winner.
ZugLoot.DB = { sheet = makeSheet() }
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 58 (1-100)")
ML.IntakeChatRoll("Tmog rolls 15 (1-98)")
LW.doAction(1001, "finish")
eq(LW.detail.menu.winners[1].name, "Aaa", "sr wins outright by priority")
eq(LW.detail.menu.perType.TMOG.entry.name, "Tmog", "tmog owns its kind")
local tmogRow = nil
for i = 1, #(LW.DetailActions()) do
  local a = LW.DetailActions()[i]
  if a.via == "tmog" then tmogRow = a break end
end
ok(tmogRow ~= nil and tmogRow.name == "Tmog", "TMOG kind row present")
eq(LW.doAction(1001, "award-name", "Tmog"), "awarded Tmog", "tmog kind award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Tmog"), "tmog winner marked")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "no spillover mark")

-- 6c. TMOG award via the kind row names the normal winner in chat.
ZugLoot.DB = { sheet = makeSheet() }
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 58 (1-100)")
ML.IntakeChatRoll("Tmog rolls 15 (1-98)")
LW.doAction(1001, "finish")
printed = {}
eq(LW.doAction(1001, "award-name", { name = "Tmog", via = "tmog" }), "awarded Tmog", "tmog row award")
local tradeSaid = false
for i = 1, #printed do
  if string.find(printed[i], "|Hplayer:Tmog|h[Tmog]|h", 1, true)
      and string.find(printed[i], "|Hplayer:Aaa|h[Aaa]|h", 1, true)
      and string.find(printed[i], "after equipping.", 1, true) then
    tradeSaid = true break
  end
end
ok(tradeSaid, "tmog award tells chat to trade to the normal winner")
-- TMOG-only rolls: one trade only, so the note names the runner-up.
ZugLoot.DB = { sheet = makeSheet() }
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Tmog rolls 15 (1-98)")
ML.IntakeChatRoll("Oz rolls 10 (1-98)")
LW.doAction(1001, "finish")
printed = {}
eq(LW.doAction(1001, "award-name", { name = "Tmog", via = "tmog" }), "awarded Tmog", "tmog-only award")
local tradeSecond = false
for i = 1, #printed do
  if string.find(printed[i], "|Hplayer:Tmog|h[Tmog]|h", 1, true)
      and string.find(printed[i], "|Hplayer:Oz|h[Oz]|h", 1, true)
      and string.find(printed[i], "after equipping.", 1, true) then
    tradeSecond = true break
  end
end
ok(tradeSecond, "tmog-only award names the runner-up")
-- Lone TMOG roller: nobody to trade to, no note.
ZugLoot.DB = { sheet = makeSheet() }
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Tmog rolls 15 (1-98)")
LW.doAction(1001, "finish")
printed = {}
eq(LW.doAction(1001, "award-name", { name = "Tmog", via = "tmog" }), "awarded Tmog", "lone tmog award")
local tradeOmitted = true
for i = 1, #printed do
  if string.find(printed[i], "Trade to ", 1, true) then tradeOmitted = false break end
end
ok(tradeOmitted, "lone tmog award omits the trade note")
-- Plain line builder: note only with a trade recipient.
local tradeBuilt = ML.AwardLine(1001, "item:1001", "Tmog", "Aaa")
ok(string.find(tradeBuilt, "|Hplayer:Tmog|h[Tmog]|h", 1, true) ~= nil, "AwardLine links the winner")
ok(string.find(tradeBuilt, "|Hplayer:Aaa|h[Aaa]|h", 1, true) ~= nil
  and string.find(tradeBuilt, "after equipping.", 1, true) ~= nil, "AwardLine appends the trade note")
ok(string.find(ML.AwardLine(1001, "item:1001", "Aaa"), "Trade to ", 1, true) == nil, "AwardLine plain without trade recipient")

-- 6d. Raid roll button, mid-roll: old roll ends, the
-- raid-roll starts clean on the same window. doAction("raidroll") stays
-- (bar-button entry); the ... menu no longer carries roll rows.
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
-- ... carries awardable names only now (buttons own roll initiation).
local midCh = LW.MoreChoices()
local midRaid = false
for i = 1, #midCh do if midCh[i].id == "raidroll" then midRaid = true break end end
ok(not midRaid, "... no longer offers raid-roll")
local arc2 = LW.MoreRollControls()
eq(#arc2, 1, "mid-roll controls mirror the raid button")
eq(arc2[1].id, "raidroll", "raid-roll control")
local realRaidRoll = ML.StartRaidRoll
ML.StartRaidRoll = function(id)
  ML.roll = { itemID = id, mode = "RAIDROLL", rolls = {},
    roster = { "Aaa", "Bbb" }, n = 2 }
  return ML.roll
end
eq(LW.doAction(1001, "raidroll"), "rolling", "raid-roll replaces the roll")
eq(ML.roll.mode, "RAIDROLL", "raid-roll live")
eq(#ML.roll.rolls, 0, "old rolls wiped, not merged")
eq(LW.detail.phase, "rolling", "window stays rolling")
ML.StartRaidRoll = realRaidRoll
-- Refused raid-roll (starter says no): the old roll already ended by the
-- explicit raid-roll press; the window drops to pick with old rolls kept.
ML.StartRaidRoll = function(id) return nil end
eq(LW.doAction(1001, "raidroll"), "roll failed", "refused raid-roll fails")
ok(ML.roll == nil, "refused raid-roll keeps nothing live")
eq(LW.detail.phase, "pick", "refused raid-roll parks the window")
eq(#LW.detail.rolls, 0, "successful raid-roll wiped old rolls; refusal keeps the window")
ML.StartRaidRoll = realRaidRoll
ML.roll = nil
LW.CloseDetail()

-- 7. Cancel drops a rolling window back to pick (re-roll / close).
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
eq(LW.doAction(1001, "cancel"), "cancelled", "cancel from window")
ok(ML.roll == nil, "cancel ends the roll")
eq(LW.detail.phase, "pick", "detail back to pick after cancel")
eq(#LW.detail.rolls, 0, "rolls cleared after cancel")
ok(LW.detail ~= nil, "window stays for re-roll choice")

-- 7b. X button closes the rolling window and ends the roll: the next
-- item rolls clean on a fresh roll.
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
  { itemID = 1002, link = "item:1002", badge = "SR" },
}, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
LW.OnCloseButton()
ok(ML.roll == nil, "X close ends the roll")
ok(LW.detail == nil, "X close shuts the window")
LW.OpenDetail(1002)
eq(LW.doAction(1002, "roll"), "rolling", "next item rolls clean")
ML.IntakeChatRoll("Solo rolls 70 (1-100)")
eq(#ML.roll.rolls, 1, "roll lands on the new item")
ML.roll = nil
LW.CloseDetail()

-- 8. Award-then-gone: awarded rows never come back; empty list hides.
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
LW.doAction(1001, "finish")
LW.doAction(1001, "award-name", "Aaa")
ok(LW.Find(1001) == nil and LW.detail == nil, "awarded item fully gone")

-- 9. Starter that lands rolls mid-start (sim fakes feed
-- AddRoll -> SyncRoll BEFORE doAction's post-start wipe): the window
-- must mirror the live rolls, never strand on "waiting for rolls..."
-- while the winner resolves fine (the reported visual-only bug).
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local realStart = ML.StartItemRoll
ML.StartItemRoll = function(id)
  local r = realStart(id)
  ML.AddRoll("Aaa", 90, 1, 100) -- instant feed, mid-start
  ML.AddRoll("Bbb", 80, 1, 100)
  return r
end
eq(LW.doAction(1001, "roll"), "rolling", "instant-feed roll starts")
ML.StartItemRoll = realStart
eq(#ML.roll.rolls, 2, "truth holds both rolls")
eq(#LW.detail.rolls, 2, "mirror survives the post-start wipe")
eq(LW.doAction(1001, "finish"), "finished", "finish resolves")
eq(LW.detail.phase, "award", "award view on the same window")
eq(LW.detail.menu.winners[1].name, "Aaa", "winner resolves off the truth")
eq(#LW.detail.rolls, 2, "award view keeps the landed rolls")
local wlines = LW.DetailLines()
local stuck = false
for i = 1, #wlines do
  if string.find(wlines[i], "waiting for rolls", 1, true) then stuck = true break end
end
ok(not stuck, "award view never shows waiting-for-rolls")
ML.roll = nil
LW.CloseDetail()

return T
