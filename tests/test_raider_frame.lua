-- tests/test_raider_frame.lua
-- Raider-frame policy: master-loot rolls ONLY by default. The window
-- pops off the master looter's roll call (ROLL_REQ addon message or
-- their RW line) and stays shut in every other mode — group loot,
-- solo, or anyone else's chat. Opt-out: Z.DB.raiderFrame = "all"
-- restores the legacy group-loot mirror + local preview.
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
ZugLoot.Print = function() end
time = time or os.time

-- Group + loot-method rig (RollFor parity: GetLootMethod's second
-- return is the ML slot index; 0 = self). ML is raid slot 1 here
-- (MasterLou), never the test player.
local grouping = "solo" -- solo | party | raid
local lootMethod = nil -- nil | "master" | "group"
local lootId = nil -- ML slot index under master loot
GetLootMethod = function() return lootMethod, lootId end
UnitName = function(u)
  if u == "player" or u == nil then return "SoloPlayer" end
  return nil
end
GetNumRaidMembers = function() return grouping == "raid" and 3 or 0 end
GetRaidRosterInfo = function(i)
  if grouping ~= "raid" then return nil end
  local roster = { "MasterLou", "SoloPlayer", "Raider" }
  return roster[i]
end
GetNumPartyMembers = function() return grouping == "party" and 2 or 0 end

ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
  LootMethod = function() return lootMethod end,
}
dofile("SRSecurity.lua")
-- Real SRSecurity on the rigged globals (IsML/AmML verified there).
local Sec = ZugLoot.SRSecurity
ZugLoot.SRSecurity.IsML = Sec.IsML
ZugLoot.SRSecurity.AmML = Sec.AmML

-- Headless frame stub: records visibility so the POLICY result
-- (shown vs refused) is pinnable without a client. Methods are no-ops;
-- text setters record so itemNameText-style assertions keep working.
local shownFlag = false
local function newObj()
  local o = {}
  setmetatable(o, { __index = function(t, k)
    if k == "Show" then return function() shownFlag = true end end
    if k == "Hide" then return function() shownFlag = false end end
    if k == "IsVisible" then return function() return shownFlag end end
    if k == "SetText" then return function(self, s) self.text = s end end
    if k == "GetText" then return function(self) return self.text end end
    if k == "CreateFontString" then return function() return newObj() end end
    if k == "CreateTexture" then return function() return newObj() end end
    if k == "GetFontString" then return function() return nil end end
    if k == "GetScript" then return function() return nil end end
    return function() end
  end })
  return o
end
CreateFrame = function() return newObj() end
UIParent = {}
-- Visibility probe: the stub Show/Hide write this (same upvalue).
ZugLoot._TestShown = function() return shownFlag end
ZugLoot.DB = { rollTime = 15 }
ZugLoot.RollList = { Paint = function() end }
dofile("RaiderLootUI.lua")
local RL = ZugLoot.RaiderLootUI

local LINK = "|cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r"

local function reset()
  grouping = "solo"
  lootMethod = nil
  lootId = nil
  ZugLoot.DB.raiderFrame = nil
  RL.groupRollID = nil
end

-- 1. Default mode is "ml" (nothing set, garbage set).
reset()
eq(RL.FrameMode(), "ml", "default frame mode is ml")
ZugLoot.DB.raiderFrame = "bogus"
eq(RL.FrameMode(), "ml", "garbage mode falls back to ml")
ZugLoot.DB.raiderFrame = "all"
eq(RL.FrameMode(), "all", "explicit all opts in")

-- 2. AllowMasterFrame: open only for grouped master loot (default).
reset()
eq(RL.AllowMasterFrame(), false, "solo shut by default")
grouping = "raid" lootMethod = "group"
eq(RL.AllowMasterFrame(), false, "raid group-loot shut by default")
grouping = "raid" lootMethod, lootId = "master", 1
eq(RL.AllowMasterFrame(), true, "raid master-loot opens")
grouping = "party" lootMethod, lootId = "master", 1
eq(RL.AllowMasterFrame(), true, "party master-loot opens")
grouping = "party" lootMethod = "group"
eq(RL.AllowMasterFrame(), false, "party group-loot shut by default")
grouping = "raid" lootMethod = nil
eq(RL.AllowMasterFrame(), false, "unknown method shut (fail closed)")
-- "all" mode opens everywhere (local preview restored).
ZugLoot.DB.raiderFrame = "all"
grouping = "solo"
eq(RL.AllowMasterFrame(), true, "all mode previews solo")
grouping = "raid" lootMethod = "group"
eq(RL.AllowMasterFrame(), true, "all mode mirrors group loot")

-- 3. ShowItem obeys the gate (stub frame records visibility).
reset()
shownFlag = false
eq(RL.ShowItem(LINK, 15), false, "solo ShowItem refused")
eq(shownFlag, false, "solo frame stays hidden")
grouping = "raid" lootMethod = "group"
eq(RL.ShowItem(LINK, 15), false, "group-loot ShowItem refused")
eq(shownFlag, false, "group-loot frame stays hidden")
grouping = "raid" lootMethod, lootId = "master", 1
eq(RL.ShowItem(LINK, 15), true, "raid master-loot shows")
eq(shownFlag, true, "raid master-loot frame visible")
reset()
grouping = "raid" lootMethod = "group"
ok(not RL.MayShow(false), "raid group-loot blocked at the gate")
ZugLoot.DB.raiderFrame = "all"
ok(RL.MayShow(false), "all mode passes the gate anywhere")

-- 4. ROLL_REQ from the ML opens only under master loot (default).
reset()
grouping = "raid" lootMethod, lootId = "master", 1
local opened = 0
local realShow = RL.ShowItem
RL.ShowItem = function(...) opened = opened + 1 return true end
RL.OnRollReq("ROLL_REQ:17063:" .. LINK .. ":SR", "MasterLou")
eq(opened, 1, "ML ROLL_REQ opens under master loot")
RL.ShowItem = realShow
-- Same message under group loot: sender verified but gate shut.
reset()
grouping = "raid" lootMethod = "group"
opened = 0
RL.ShowItem = function(...) opened = opened + 1 return true end
RL.OnRollReq("ROLL_REQ:17063:" .. LINK .. ":SR", "MasterLou")
-- OnRollReq calls ShowItem unconditionally; ShowItem itself refuses.
-- Restore the real ShowItem (headless: returns false) and assert that.
RL.ShowItem = realShow
eq(RL.ShowItem(LINK, 15), false, "group-loot ROLL_REQ refused at ShowItem")
-- Non-ML sender never opens (LootBlare rule, unchanged).
reset()
grouping = "raid" lootMethod, lootId = "master", 1
opened = 0
RL.ShowItem = function(...) opened = opened + 1 return true end
RL.OnRollReq("ROLL_REQ:17063:" .. LINK .. ":SR", "RandomRaider")
eq(opened, 0, "non-ML ROLL_REQ ignored")
RL.ShowItem = realShow

-- 5. RW roll call from the ML opens only under master loot (default).
reset()
grouping = "raid" lootMethod, lootId = "master", 1
opened = 0
RL.ShowItem = function(...) opened = opened + 1 return true end
RL.OnEvent("CHAT_MSG_RAID_WARNING", "Roll for Thunderfury: /roll (MS)", "MasterLou")
eq(opened, 1, "ML RW call opens under master loot")
RL.ShowItem = realShow
reset()
grouping = "raid" lootMethod = "group"
eq(RL.ShowItem(LINK, 15), false, "group-loot RW call refused at ShowItem")
-- Non-ML chatter never matches (matcher rule, unchanged).
eq(RL.MatchRollCall("Roll for Thunderfury: /roll (MS)", "RandomRaider"), "", "non-ML RW never matches")

-- 6. START_LOOT_ROLL mirror: shut by default, "all" mirrors.
reset()
grouping = "raid" lootMethod = "group"
RL.OnEvent("START_LOOT_ROLL", 7)
eq(RL.groupRollID, nil, "group roll mirror shut by default")
ZugLoot.DB.raiderFrame = "all"
RL.OnEvent("START_LOOT_ROLL", 7)
eq(RL.groupRollID, 7, "all mode tracks the group roll")
RL.OnEvent("CANCEL_LOOT_ROLL", 7)
eq(RL.groupRollID, nil, "cancel clears the roll")

-- 7. Dice in default mode roll /roll (no mirror id can exist).
reset()
local rolled = {}
RandomRoll = function(lo, hi) table.insert(rolled, { lo, hi }) end
RL.groupRollID = nil
RL.DoRoll("SR", 100)
eq(#rolled, 1, "default dice roll /roll")
eq(rolled[1][1], 1, "/roll from 1")
eq(rolled[1][2], 100, "/roll SR cap")
RandomRoll = nil

-- 8. Shared color source: raider frame colors through LootWindow.QualityHex.
-- Needs the shared helper loaded (it owns the nil/zero-is-white rule).
if not ZugLoot.LootWindow then
  dofile("LootWindow.lua")
end
local LW = ZugLoot.LootWindow
-- The test stub's meta __index swallows raw GetItemQualityColor, so pin
-- the client API with the same stub the addon-wide mock run uses
-- (epic purple), letting the shared path compute a real hex. Floor
-- math: 0.64*255=163 (A3), 0.21*255=53 (35), 0.93*255=237 (ED).
GetItemQualityColor = function(q) return 0.64, 0.21, 0.93, "|cffa335ee" end
-- Quality resolves through the shared chain, so the cache must answer:
-- the raider file defines no GetItemInfo, pin a minimal epic entry.
GetItemInfo = function(id)
  local s = tostring(id or "")
  if s == "17063" or string.find(s, "17063", 1, true) then
    return "Thunderfury", "|cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r",
      4, 1, 1, "", "", "", "Interface\\Icons\\INV_Sword_01"
  end
  return nil
end
local sharedEpic = LW.QualityHex(4)
eq(sharedEpic, "|cFFA335ED", "shared helper colors epic quality")
local sharedWhite = LW.QualityHex(nil)
eq(sharedWhite, "|cFFFFFFFF", "shared helper keeps unknown white")
eq(LW.QualityHex(0), "|cFFFFFFFF", "shared helper keeps zero white")
-- Raider frame reuses the same source: build an epic frame and assert
-- its computed name/border colors derive from the shared helper.
reset()
grouping = "raid" lootMethod, lootId = "master", 1
ZugLoot.DB.raiderFrame = "all"
eq(RL.ShowItem("|cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r", 15), true, "epic roll shows frame")
-- Quality resolves through the shared chain; the probe records what
-- SetItemInfo actually computed for text + border.
local colors = RL._TestColors
ok(colors ~= nil, "color probe recorded")
ok(colors.textHex == LW.QualityHex(4), "name text uses the shared helper")
ok(colors.border ~= nil and colors.border[1] ~= 0.2,
  "border tinted by quality, not neutral grey")
-- Unknown quality degrades to white text + neutral border, never grey.
eq(LW.QualityHex(nil), "|cFFFFFFFF", "unknown quality stays white")
GetItemQualityColor = nil
GetItemInfo = nil

if T.fail == 0 then
  print("raider frame policy passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
