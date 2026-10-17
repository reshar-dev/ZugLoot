-- tests/test_colors_in_chat.lua
-- Group-chat lines use FULL clickable item links + class-colored player
-- names. The raider roll window pops ONLY on the roll-call shape
-- ("Roll for <link>..."); links buried in drop lists, winner lines, or
-- sand lines never trigger it (MatchRollCall requires the shape).
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
local SRData = ZugLoot.SRData

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
local printed = {}
local said = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
time = time or os.time
CreateFrame = nil -- headless: data layer only
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end

ZugLoot.SRSecurity = {
  AmML = function() return true end,
  IsML = function() return true end,
  IsLeader = function() return false end,
  IsInRaid = function() return false end,
  IsInGroup = function() return false end,
  IsSolo = function() return true end,
}
ZugLoot.DropLog = { Add = function() end }
ZugLoot.SRSecurity.LootMethod = function() return "master" end
-- Solo routes chat to the local log (localLoot): Say/Warn land in `said`
-- through Z.Print — link markup is asserted verbatim.
ZugLoot.Comm = nil

dofile("RollList.lua")
dofile("Comm.lua")
-- Route solo "chat" into said so link markup is asserted verbatim.
local RealSay = ZugLoot.Comm.Say
ZugLoot.Comm.Say = function(msg) table.insert(said, tostring(msg)) return RealSay(msg) end
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
-- No dofile("RaiderLootUI.lua") here: its Build() needs CreateFrame
-- (mocked only in mockrun.lua). MatchRollCall coverage lives in the
-- mock UI run; section 4 below asserts the shape rule via inline stub.
local LW = ZugLoot.LootWindow
local ML = ZugLoot.MasterLootUI
ML.lootOpen = true

-- Sheet classes for name coloring: SheetPal is pink.
local sheet = SRData.NewSheet()
SRData.SetPlayerClass(sheet, "SheetPal", "PaladinHoly")
ZugLoot.DB = { sheet = sheet, rollTime = 30 }
ZugLoot.DB.lootTakeover = true

local FULL = "|cffa335ee|Hitem:1001:0:0:0|h[Dragonfang Blade]|h|r"

-- 1. ChatItem: the full link when known (row scan link wins).
LW.SetItems({ { itemID = 1001, link = FULL, name = "Dragonfang Blade", quality = 4 } }, "loot")
local ci = ML.ChatItem(1001, FULL)
eq(ci, FULL, "chat item is the full link, got: " .. tostring(ci))
-- Row link wins over a bare passed link (scan-time links are full).
local ciRow = ML.ChatItem(1001, "item:1001")
eq(ciRow, FULL, "row link wins over bare id, got: " .. tostring(ciRow))
-- Uncached + bare id: synthesized clickable link (never a bare item:id).
-- (GetItemInfo stubbed to the id itself: the cache "knows" nothing
-- beyond it, so BuildLink synthesizes from name + explicit quality.)
GetItemInfo = function(id) return nil end
LW.SetItems({ { itemID = 4242, link = "item:4242", name = "Mystery Blade", quality = 2 } }, "loot")
local ciBuilt = ML.ChatItem(4242, "item:4242")
ok(string.find(ciBuilt, "|Hitem:4242", 1, true) ~= nil, "uncached item builds a link, got: " .. tostring(ciBuilt))
ok(string.find(ciBuilt, "|cff1eff00", 1, true) ~= nil, "built link carries quality color, got: " .. tostring(ciBuilt))
GetItemInfo = nil
-- Quality colors follow the client cache when rows carry none.
GetItemQualityColor = function(q) if q == 4 then return 0.64, 0.21, 0.93 end end
local qc = ML.QualityColor(4)
eq(qc, "|cFFA335ED", "epic hex from client colors")
GetItemQualityColor = nil
-- No client + unknown quality = white fallback (never grey: grey = poor).
eq(ML.QualityColor(nil), "|cffffffff", "unknown quality reads white")

-- 2. Drop call: header + per-item LINK lines.
LW.SetItems({ { itemID = 1001, link = FULL, name = "Dragonfang Blade", quality = 4 } }, "loot")
said = {}
GetNumLootItems = function() return 1 end
GetLootSlotLink = function(slot) return FULL end
GetLootSlotInfo = function(slot) return "tex", "Dragonfang Blade", 1, 4 end
GetItemInfo = function(id) return "Dragonfang Blade", FULL, 4 end
LW.Clear()
ZugLoot.LootWindow.TakeoverWanted = function() return true end
ZugLoot.LootWindow.DetachBlizzardLoot = function() end
ML.lootOpen = false
ML.lootKey, ML.lootGUID, ML.lootTarget = nil, nil, nil
ML.OnLootOpened()
local head, item1 = nil, nil
for i = 1, #said do
  if string.find(said[i], "dropped 1 item", 1, true) then head = said[i] end
  if string.find(said[i], "Dragonfang Blade", 1, true) then item1 = said[i] end
end
ok(head ~= nil, "drop header announced")
ok(item1 ~= nil, "drop item line announced")
ok(string.find(item1, "|Hitem:1001", 1, true) ~= nil, "drop line is a link, got: " .. tostring(item1))
GetNumLootItems = nil GetLootSlotLink = nil GetLootSlotInfo = nil GetItemInfo = nil

-- 3. Finish + award lines: link for the item, class color for the winner.
LW.SetItems({ { itemID = 1001, link = FULL, name = "Dragonfang Blade", quality = 4 } }, "loot")
said = {}
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("SheetPal rolls 90 (1-100)")
LW.doAction(1001, "finish")
local verdict = nil
for i = 1, #said do
  if string.find(said[i], "won by", 1, true) then verdict = said[i] end
end
ok(verdict ~= nil, "verdict announced")
ok(string.find(verdict, "|cFFF58CBASheetPal|r", 1, true) ~= nil, "winner class-colored, got: " .. tostring(verdict))
ok(string.find(verdict, "|Hitem:1001", 1, true) ~= nil, "verdict links the item, got: " .. tostring(verdict))

-- 4. Trigger shape rule (mirrors MatchRollCall): ONLY "Roll for ..."
-- lines match — links buried in drop/winner/numbering lines never do.
local function matchLikeRollCall(t)
  local plain = string.gsub(tostring(t or ""), "|c%x%x%x%x%x%x%x%x(.-)|r", "%1")
  local item = string.match(plain, "^[Rr]oll for (.+)$")
  if item then
    item = string.gsub(item, "%s*:%s*/roll.*$", "")
    item = ZugLoot.Util.Trim(item)
    if item ~= "" then
      local link = string.match(tostring(t or ""), "(|c%x+|Hitem.-|h%[.-%]|h|r)")
      if link then return link end
      return item
    end
  end
  return ""
end
local call = "Roll for " .. FULL
eq(matchLikeRollCall(call), FULL, "roll call returns the link")
eq(matchLikeRollCall("Roll for Nemesis Gloves: /roll (MS)"), "Nemesis Gloves", "plain dice line still matches")
eq(matchLikeRollCall("Jin'do the Hexxer dropped 2 items:"), "", "drop head never matches")
eq(matchLikeRollCall("1. " .. FULL), "", "linked drop line never matches")
eq(matchLikeRollCall(verdict or "x won by y"), "", "winner line never matches")
eq(matchLikeRollCall("[1]:Evilson, [2]:Broman"), "", "raid-roll numbering never matches")

return T
