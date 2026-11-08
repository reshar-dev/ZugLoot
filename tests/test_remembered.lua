-- tests/test_remembered.lua
-- Remembered item defaults: ML ticks the top-right box on the roll
-- window (raid-roll, or award to a specific player); the decision is
-- stored per itemID (Z.DB.remembered) and applied when the row opens.
-- Setup "Remembered" section lists entries, selects one to show its
-- state in the textbox, and Remove forgets it.
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
-- Neutralize corpse globals leaked by earlier suite files (sand/mlflow
-- stub a live corpse): this harness awards headless, where no corpse
-- session exists and every take applies without a slot read.
GetNumLootItems = nil
GetLootSlotLink = nil
GetLootSlotInfo = nil

ZugLoot.SRSecurity = {
  AmML = function() return true end,
  IsInRaid = function() return true end,
  IsInGroup = function() return true end,
  IsInParty = function() return false end,
  IsSolo = function() return false end,
}
ZugLoot.DropLog = { Add = function() end }
ZugLoot.Comm = {
  BroadcastAward = function() end,
  WarnGroup = function() end,
  SayGroup = function() end,
  Say = function() end,
}
-- Wire taps: the real Comm (dofile below) sends group chat here and
-- addon traffic here. Auto (quiet) actions must emit NOTHING on
-- either; manual paths still speak (pinned in test_chat_routing).
local sentChat, sentAddon = {}, {}
SendChatMessage = function(msg, chan)
  table.insert(sentChat, { msg = tostring(msg), chan = tostring(chan) })
end
SendAddonMessage = function(prefix, msg, channel)
  table.insert(sentAddon, tostring(msg))
end
GetNumRaidMembers = function() return 3 end
GetRaidRosterInfo = function(i) return ({"SoloPlayer", "Aaa", "Bbb"})[i] end
UnitName = function(u) return "SoloPlayer" end
RandomRoll = function() end

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
local LW = ZugLoot.LootWindow
local ML = ZugLoot.MasterLootUI

local function makeSheet(rolls)
  local s = ZugLoot.SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = rolls or {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2 },
  } }
  return s
end

local function reset()
  ZugLoot.DB = { sheet = makeSheet(), remembered = {} }
  ML.roll = nil
  ML.lastRound = nil
  ML.lastRaidRollCast = nil
  ML.lootOpen = true
  LW.Clear()
  printed = {}
  sentChat, sentAddon = {}, {}
end

-- 1. Store primitives: raidroll stores, award needs a name, junk refuses.
reset()
ML.RememberedSet(19019, true, "raidroll", nil, "link-19019")
eq(ML.RememberedGet(19019).mode, "raidroll", "raidroll stored")
ML.RememberedSet(17063, true, "award", "Carbon", nil)
eq(ML.RememberedGet(17063).name, "Carbon", "award stored with name")
eq(ML.RememberedGet(123), nil, "nameless award refuses")
ML.RememberedSet(124, true, "bogus")
eq(ML.RememberedGet(124), nil, "junk mode refuses")
local list = ML.RememberedList()
eq(#list, 2, "two entries listed")
eq(list[1].itemID, 17063, "list sorted by itemID")
eq(ML.RememberedLine({ mode = "raidroll" }), "Raid-roll on open", "raidroll line")
eq(ML.RememberedLine({ mode = "award", name = "Carbon" }),
  "Award to Carbon on open", "award line")
eq(ML.RememberedBoxState(19019, "raidroll"), "raidroll", "box state matches")
eq(ML.RememberedBoxState(19019, "award", "X"), nil, "box state mismatches")
eq(ML.RememberedBoxState(19019, "raidroll", "Nobody"), "raidroll",
  "raidroll ignores the name")
ML.RememberedSet(19019, false)
eq(ML.RememberedGet(19019), nil, "forget drops the entry")
eq(#ML.RememberedList(), 1, "one entry left")

-- 2. Full raid-roll loop via the CHECKBOX (the reported bug: ticking
-- a context-free row silently did nothing, Setup stayed empty).
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.ToggleRemember(), true, "box tick stores raid-roll on a bare row")
eq(ML.RememberedGet(1001).mode, "raidroll", "Setup list gains the entry")
eq(LW.doAction(1001, "raidroll"), "rolling", "raid-roll starts")
ML.IntakeChatRoll("SoloPlayer rolls 2 (1-3)")
eq(ML.RememberedGet(1001).mode, "raidroll", "raid-roll finish keeps it")
-- Next drop: ApplyRemembered raid-rolls straight away.
ZugLoot.DB.sheet = makeSheet()
ML.roll = nil
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
eq(ML.ApplyRemembered(), "raidroll", "remembered raid-roll auto-starts on open")
ok(ML.roll ~= nil and ML.roll.mode == "RAIDROLL", "raid-roll mode live")

-- 3. Unticked raid-roll persists nothing.
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "raidroll"), "rolling", "unticked raid-roll starts")
ML.IntakeChatRoll("SoloPlayer rolls 2 (1-3)")
eq(ML.RememberedGet(1001), nil, "unticked raid-roll stores nothing")

-- 4. Award loop via the CHECKBOX: ticked single-holder award persists;
-- next drop direct-awards on open (no roll started); unticked awards
-- persist nothing. Multi-holder ... picks adopt the scope when ticked.
reset()
ZugLoot.DB.sheet = makeSheet({ { name = "Solo", rolls = 1 } })
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
local d4 = LW.OpenDetail(1001)
eq(d4.single, true, "lone holder seeds the row")
eq(d4.rememberMode, "award", "award context seeded")
eq(d4.rememberName, "Solo", "holder prefilled")
eq(LW.ToggleRemember(), true, "box tick stores award-to-holder")
eq(LW.doAction(1001, "award"), "awarded Solo", "ticked direct award lands")
eq(ML.RememberedGet(1001).name, "Solo", "award persists the tick")
-- Next drop auto-awards on open.
ZugLoot.DB.sheet = makeSheet()
ML.roll = nil
ML.lootOpen = true
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
eq(ML.ApplyRemembered(), "awarded Solo", "remembered award auto-applies on open")
eq(LW.Find(1001), nil, "auto-awarded row leaves the list")
-- Unticked award: no store.
reset()
ZugLoot.DB.sheet = makeSheet({ { name = "Solo", rolls = 1 } })
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "award"), "awarded Solo", "unticked award lands")
eq(ML.RememberedGet(1001), nil, "unticked award stores nothing")
-- Multi-holder: tick the bare box (stores raid-roll), then ... award
-- Bbb — the ticked handling converges the entry to award-to-Bbb.
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
local d5 = LW.OpenDetail(1001)
eq(d5.rememberMode, nil, "multi-holder seeds no context")
eq(LW.ToggleRemember(), true, "bare-box tick stores the fallback")
eq(ML.RememberedGet(1001).mode, "raidroll", "fallback is raid-roll")
eq(LW.doAction(1001, "award-name", "Bbb"), "awarded Bbb", "... award lands")
eq(ML.RememberedGet(1001).name, "Bbb", "ticked handling converges to Bbb")
-- Untick forgets; re-tick re-stores the current decision. Reopening
-- re-seeds from the stored entry (tick on, award-to-Bbb context).
-- Bbb won, so the sheet now lists one live holder: untick resets to
-- THAT live seed (award-to-Aaa), and re-tick stores it.
LW.CloseDetail()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
local d6 = LW.OpenDetail(1001)
eq(d6.rememberChecked, true, "reopen shows the tick")
eq(d6.rememberMode, "award", "reopen context is the stored award")
eq(d6.rememberName, "Bbb", "reopen names the stored assignee")
eq(LW.ToggleRemember(), false, "untick forgets")
eq(ML.RememberedGet(1001), nil, "entry gone after untick")
eq(d6.rememberMode, "award", "untick resets to the live seed")
eq(d6.rememberName, "Aaa", "one live holder left after Bbb won")
eq(LW.ToggleRemember(), true, "re-tick stores again")
eq(ML.RememberedGet(1001).name, "Aaa", "live holder stored")

-- 5. Guards: sim rows never apply; nothing remembered = false.
reset()
ML.RememberedSet(2001, true, "raidroll")
ML.roll = nil
LW.SetItems({ { itemID = 2001, link = "item:2001", quality = 4 } }, "sim")
eq(ML.ApplyRemembered(), false, "sim rows never apply")
LW.SetItems({}, "loot")
eq(ML.ApplyRemembered(), false, "empty list applies nothing")

-- 6. One roll at a time: a live roll blocks the auto path.
reset()
ML.RememberedSet(1001, true, "raidroll")
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
ML.roll = { itemID = 9999, mode = "SR", rolls = {} }
eq(ML.ApplyRemembered(), false, "live roll blocks auto raid-roll")
ML.roll = nil

-- 7. Setup list painter (headless pool): sorted entries paint into
-- the recycled rows at the offset; selection highlights; past-count
-- rows hide; empty list hides everything and drops a stale selection.
-- Drives the real MainWindow painter with a stubbed row pool (the
-- module loads headless; only setupBtns/rememberSel are swapped).
dofile("MainWindow.lua")
reset()
local function fakeRow()
  local rb = { shown = true, label = nil, state = nil, scripts = {} }
  function rb:Show() self.shown = true end
  function rb:Hide() self.shown = false end
  rb.zlLabel = { SetText = function(_, s) rb.label = s end }
  rb.zlState = { SetText = function(_, s) rb.state = s end }
  function rb:SetBackdropColor(r, g, b, a) rb.bg = a end
  function rb:SetScript(ev, fn) rb.scripts[ev] = fn end
  function rb:GetScript(ev) return rb.scripts[ev] end
  return rb
end
local sbKeep, selKeep = ZugLoot.MainWindow.setupBtns, ZugLoot.MainWindow.rememberSel
ZugLoot.MainWindow.setupBtns = { rememberedRows = { fakeRow(), fakeRow(), fakeRow() } }
ZugLoot.MainWindow.rememberSel = 3002
ML.RememberedSet(3001, true, "raidroll", nil, "|cffffffff|Hitem:3001|h[Alpha]|h|r")
ML.RememberedSet(3002, true, "award", "Carbon", nil)
ML.RememberedSet(3003, true, "award", "Bbb", nil)
ok(type(ZugLoot.MainWindow.RefreshRememberedList) == "function", "list painter exists")
ZugLoot.MainWindow.RefreshRememberedList(0)
local rows = ZugLoot.MainWindow.setupBtns.rememberedRows
eq(rows[1].itemID, 3001, "row 1 sorted first")
eq(rows[2].itemID, 3002, "row 2 sorted second")
eq(rows[3].itemID, 3003, "row 3 sorted third")
ok(string.find(rows[1].label or "", "Alpha", 1, true) ~= nil, "row 1 names the item")
ok(string.find(rows[2].state or "", "Carbon", 1, true) ~= nil, "row 2 states the assignee")
eq(rows[2].bg, 0.45, "selected row highlighted")
eq(rows[1].bg, 0, "unselected row clear")
-- click toggles selection (the click repaints via RefreshRememberedState).
rows[1].scripts.OnClick()
eq(ZugLoot.MainWindow.rememberSel, 3001, "row click selects")
rows[1].scripts.OnClick()
eq(ZugLoot.MainWindow.rememberSel, nil, "row click again deselects")
-- offset window: only the tail paints.
ZugLoot.MainWindow.RefreshRememberedList(2)
eq(rows[1].itemID, 3003, "offset skips to the tail")
eq(rows[2].shown, false, "past-count rows hide")
eq(rows[3].shown, false, "past-count rows hide (3)")
-- stale selection drops.
ZugLoot.MainWindow.rememberSel = 9999
ZugLoot.MainWindow.RefreshRememberedList(0)
eq(ZugLoot.MainWindow.rememberSel, nil, "stale selection dropped")
-- empty list hides everything.
ZugLoot.DB.remembered = {}
ZugLoot.MainWindow.RefreshRememberedList(0)
eq(rows[1].shown, false, "empty list hides row 1")
ZugLoot.MainWindow.setupBtns = sbKeep
ZugLoot.MainWindow.rememberSel = selKeep

-- 8. Auto actions are fully silent in chat: no start/verdict/award
-- lines, no ROLL_REQ, no roster broadcast — but the item still rolls
-- and assigns. Manual raid-rolls still announce (control).
reset()
ZugLoot.DB.sheet = makeSheet()
ML.RememberedSet(1001, true, "raidroll", nil, "item:1001")
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
eq(ML.ApplyRemembered(), "raidroll", "remembered raid-roll auto-starts")
local auto = ML.roll
ok(auto ~= nil and auto.mode == "RAIDROLL", "auto roll live")
ok(auto.quiet, "auto roll flagged quiet")
eq(#sentChat, 0, "auto raid-roll start: no chat")
eq(#sentAddon, 0, "auto raid-roll start: no ROLL_REQ")
eq(ML.lastRaidRollCast, nil, "quiet roll leaves the roster cache alone")
-- The ML's own dice still feed intake; the finish awards at once with
-- no verdict/award chat — but the addon AWARD still syncs (data).
-- (RAIDROLL intake finishes inline: the roll resolves on the dice.)
ML.IntakeChatRoll("SoloPlayer rolls 2 (1-3)")
eq(ML.roll, nil, "quiet raid-roll resolves on intake")
eq(ML.lastRound, nil, "quiet award consumes the stamp")
eq(#sentChat, 0, "quiet finish: no verdict/award chat")
eq(#sentAddon, 1, "quiet finish: addon AWARD still syncs")
ok(string.find(sentAddon[1], "AWARD:1001:Aaa", 1, true) ~= nil, "sync names the award")
eq(LW.Find(1001), nil, "auto-awarded row leaves the list")
ok(ZugLoot.SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "quiet award won-marks")
-- Manual raid-roll control: same flow announces (start + numbering).
reset()
ZugLoot.DB.sheet = makeSheet()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
ok(ML.StartRaidRoll(1001) ~= nil, "manual raid-roll starts")
ok(not ML.roll.quiet, "manual roll not quiet")
ok(#sentChat >= 2, "manual raid-roll announces (start + roster)")
local sawStart = false
for i = 1, #sentChat do
  if string.find(sentChat[i].msg, "Raid rolling", 1, true) then sawStart = true end
end
ok(sawStart, "manual raid-roll names the item")
ok(#sentAddon >= 1, "manual raid-roll sends ROLL_REQ")
ok(ML.lastRaidRollCast ~= nil, "manual roll caches the roster")
ML.roll = nil

-- 9. Remembered awards chain silently: every stored award applies
-- with zero chat; unremembered rows stay for the ML.
reset()
ZugLoot.DB.sheet = makeSheet()
ML.RememberedSet(1001, true, "award", "Aaa", "item:1001")
ML.RememberedSet(1002, true, "award", "Bbb", "item:1002")
LW.SetItems({
  { itemID = 1001, link = "item:1001", quality = 4, slot = 1 },
  { itemID = 1002, link = "item:1002", quality = 4, slot = 2 },
  { itemID = 1003, link = "item:1003", quality = 4, slot = 3 },
}, "loot")
eq(ML.ApplyRemembered(), "awarded Bbb", "chained remembered awards apply")
eq(#sentChat, 0, "chained auto-awards: no chat")
eq(LW.Find(1001), nil, "first auto-award leaves")
eq(LW.Find(1002), nil, "second auto-award leaves")
ok(LW.Find(1003) ~= nil, "unremembered row stays for the ML")
ok(ZugLoot.SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "chained award won-marks (1)")
ok(ZugLoot.SRData.HasWon(ZugLoot.DB.sheet, 1002, "Bbb"), "chained award won-marks (2)")
-- Awards-before-raid-roll: a stored award applies even when a
-- remembered raid-roll is also pending (instant first), and the
-- raid-roll then starts quietly.
reset()
ZugLoot.DB.sheet = makeSheet()
ML.RememberedSet(1001, true, "award", "Aaa", "item:1001")
ML.RememberedSet(1002, true, "raidroll", nil, "item:1002")
LW.SetItems({
  { itemID = 1002, link = "item:1002", quality = 4, slot = 2 },
  { itemID = 1001, link = "item:1001", quality = 4, slot = 1 },
}, "loot")
eq(ML.ApplyRemembered(), "raidroll", "award applies, then raid-roll starts")
eq(#sentChat, 0, "mixed auto actions: no chat")
eq(LW.Find(1001), nil, "stored award applied")
ok(ML.roll ~= nil and ML.roll.quiet, "remembered raid-roll quiet")
ML.roll = nil
-- AutoSilentOnOpen pins: remembered entries and enabled categories
-- read silent; plain rows, open rolls, and non-ML clients do not.
reset()
ML.RememberedSet(1001, true, "raidroll", nil, "item:1001")
ok(ML.AutoSilentOnOpen(1001), "remembered row reads auto-silent")
ok(not ML.AutoSilentOnOpen(1003), "plain row not auto-silent")
ML.roll = { itemID = 9999, mode = "SR", rolls = {} }
ok(not ML.AutoSilentOnOpen(1001), "open roll blocks auto-silence")
ML.roll = nil
ZugLoot.SRSecurity.AmML = function() return false end
ok(not ML.AutoSilentOnOpen(1001), "non-ML never auto-silent")
ZugLoot.SRSecurity.AmML = function() return true end

-- 7. Mid normal-roll tick arms (nothing storable yet); the award
-- converges it to the winner. Tied award windows offer nothing.
reset()
LW.SetItems({ { itemID = 1001, link = "item:1001", quality = 4, slot = 1 } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "normal roll starts")
eq(LW.ToggleRemember(), true, "mid-roll tick arms")
eq(ML.RememberedGet(1001), nil, "armed tick stores nothing yet")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
eq(LW.doAction(1001, "finish"), "finished", "finish resolves")
eq(LW.doAction(1001, "award-name", "Aaa"), "awarded Aaa", "award lands")
eq(ML.RememberedGet(1001).name, "Aaa", "armed tick converges to the winner")

return T
