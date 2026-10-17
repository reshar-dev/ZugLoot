local function newObj(kind)
  local o = { kind=kind, children={}, scripts={}, points={}, texts={} };
  function o:SetWidth(w) self.w=w end
  function o:SetHeight(h) self.h=h end
  function o:SetPoint(...) table.insert(self.points,{...}) end
  function o:SetAllPoints(...) end
  function o:ClearAllPoints() self.points={} end
  function o:SetMovable() end
  function o:EnableMouse() end
  function o:SetClampedToScreen() end
  function o:RegisterForDrag() end
  function o:SetScript(k,f) self.scripts[k]=f end
  function o:GetScript(k) return self.scripts[k] end
  function o:SetBackdrop() end
  function o:SetBackdropColor() end
  function o:SetBackdropBorderColor() end
  function o:Hide() self.hidden=true end
  function o:Show() self.hidden=false end
  function o:SetAlpha(a) self.alpha=a end
  function o:GetAlpha() return self.alpha or 1 end
  function o:IsVisible() return not self.hidden end
  function o:CreateTexture(...) local t={scripts={}, points={}, w=0, h=0}; function t:SetTexture(r,g,b,a) if type(r)=="number" and g~=nil then self.tex={r,g,b,a} else self.tex=r end end; function t:GetTexture() return self.tex end; function t:SetAllPoints() end; function t:SetPoint(...) table.insert(self.points,{...}) end; function t:SetHeight(h) self.h=h end; function t:SetWidth(w) self.w=w end; function t:SetVertexColor(r,g,b,a) self.vc={r,g,b,a} end; function t:SetTexCoord(l,r,tm,b) self.coord={l,r,tm,b} end; function t:GetTexCoord() return self.coord end; function t:Hide() end; function t:Show() end; function t:SetScript(k,f) self.scripts[k]=f end; function t:GetScript(k) return self.scripts[k] end; return t end
  function o:CreateFontString(...) local fs={txt="",points={}}; function fs:SetAllPoints() end; function fs:SetText(s) self.txt=s end; function fs:GetText() return self.txt end; function fs:SetPoint(...) table.insert(self.points,{...}) end; function fs:ClearAllPoints() self.points={} end; function fs:SetWidth() end; function fs:SetHeight() end; function fs:SetJustifyH() end; function fs:SetJustifyV() end; function fs:SetTextColor(r,g,b,a) self.tc={r,g,b,a} end; function fs.SetShadowOffset() end; function fs:GetStringWidth() return 40 end; function fs:GetFont() return "Fonts\\FRIZQT__.TTF" end; function fs:SetFont(f,size,flags) self.font={f,size,flags} end; return fs end
  function o:GetFontString() local f={}; function f:SetFont() end; function f:SetPoint() end; function f:SetTextColor() end; return f end
  function o:SetStatusBarTexture() end
  function o:SetStatusBarColor() end
  function o:SetValue(v) self.sbval=v end
  function o:SetText(s) self.label=s end
  function o:SetThumbTexture() end
  function o:GetThumbTexture() local t={}; function t:SetWidth() end; function t:SetHeight() end; function t:SetVertexColor() end; return t end
  function o:SetMinMaxValues(a,b) self.mn=a; self.mx=b end
  function o:GetMinMaxValues() return self.mn or 0, self.mx or 0 end
  function o:SetValueStep() end
  function o:SetValue(v) self.val=v end
  function o:GetValue() return self.val or 0 end
  function o:EnableMouseWheel() end
  function o:SetScrollChild() end
  function o:SetVerticalScroll() end
  function o:GetVerticalScroll() return 0 end
  function o:GetVerticalScrollRange() return 0 end
  function o:UpdateScrollChildRect() end
  function o:SetMultiLine() end
  function o:SetAutoFocus() end
  function o:SetFontObject() end
  function o:SetJustifyH() end
  function o:SetJustifyV() end
  function o:SetMaxLetters() end
  function o:GetText() return self.label or "" end
  function o:SetFocus() self.focused=true end
  function o:SetTextInsets(l,r,t,b) self.insets={l,r,t,b} end
  function o:SetToplevel(t) self.toplevel=t end
  function o:StartMoving() end
  function o:StopMovingOrSizing() end
  function o:SetResizable() end
  function o:SetMinResize() end
  function o:StartSizing() end
  function o:SetNormalTexture() end
  function o:GetWidth() return self.w or 0 end
  function o:GetHeight() return self.h or 10 end
  function o:Raise() end
  function o:SetFrameStrata(s) self.strata=s end
  function o:GetFrameStrata() return self.strata end
  function o:SetFrameLevel(l) self.flevel=l end
  function o:GetFrameLevel() return self.flevel or 5 end
  return o;
end
CreateFrame = function(kind, name, parent, tmpl) return newObj(kind) end
UIParent = newObj("Frame");
GameTooltip = newObj("Tooltip");
function GameTooltip:SetOwner() end; function GameTooltip:SetText() end; function GameTooltip:AddLine() end; function GameTooltip:Show() end; function GameTooltip:Hide() end; function GameTooltip:SetHyperlink() end
getglobal = function() return nil end
-- Emulates the client: stable name/link/texture whether called with the
-- full link or the bare id (the arg-echoing stub hid link-vs-id bugs).
GetItemInfo = function(id)
  local num = tonumber(string.match(tostring(id), "item:(%d+)") or id)
  return "Test Sword", "|cffa335ee|Hitem:"..tostring(num)..":0:0:0|h[Test Sword]|h|r", 4, 0,0,0,0,0, "Interface\\Icons\\INV_Sword_01"
end
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
GetNumPartyMembers = function() return 0 end
ChatFrameEditBox = { IsVisible=function() return false end };
UIFrameFadeIn = function(f) if f then f:SetAlpha(1) end end
GetItemQualityColor = function(q) return 0.64, 0.21, 0.93, "|cffa335ee" end
GetTime = function() return 100 end
UnitClass = function() return "Warrior", "WARRIOR" end
IsControlKeyDown = function() return false end
IsShiftKeyDown = function() return false end
math.mod = math.mod or function(a,b) return a % b end;
ZugLoot = {}; dofile("Util.lua"); dofile("Constants.lua"); dofile("ClassColors.lua");
ZugLoot.Print = function() end
ZugLoot.DB = { sheet=nil, drops={}, rollTime=15 };
ZugLoot.CharDB = { autoRoll=false };
dofile("SRData.lua"); dofile("Resolver.lua"); dofile("ItemCards.lua");
dofile("ItemIcon.lua");
dofile("RaidArchive.lua");
dofile("SRSecurity.lua");
dofile("RollList.lua")
dofile("Comm.lua");
dofile("Pysanka.lua");
dofile("SRImport.lua");
ZugLoot.AutoRoll = { Set=function() end };
ZugLoot.VersionGrid = { seen={}, RosterNames=function() return {"A","B"} end, GridNames=function() return {{name="A",inGroup=true},{name="B",inGroup=true}} end, StatusFor=function() return "GREEN" end, ColorFor=function() return "GREEN" end, Request=function() end };
dofile("MainWindow.lua");
dofile("LootWindow.lua");
dofile("MasterLootUI.lua");
dofile("RaiderLootUI.lua");
dofile("Minimap.lua");
local Z = ZugLoot;
Z.MainWindow.Build();
Z.MainWindow.Show("sheet");
print("empty sheet render OK");
local s,_ = Z.SRData.ParseLineFormat("Blackfang; 17063:2+20, 19137:1\nCarbon; 18646:1+60, 17063:1+130\nHARDRES; 17782, 18564\n");
s.meta.raidID = "MOCK-RAID-1";
s.meta.raidName = "Molten Core";
s.meta.importedAt = 1720000000;
Z.SRData.RecordRolls(s, 17063, { t=1, mode="SR", winners={"Carbon"}, entries={{name="Carbon",base=95,sr_plus=130,effective=225},{name="Blackfang",base=40,sr_plus=20,effective=60}} });
Z.SRData.EnsureUnreserved(s, 9999, 4);
Z.SRData.RecordRolls(s, 9999, { t=2, mode="OPEN", winners={"SoloPlayer"}, entries={{name="SoloPlayer",base=70,sr_plus=0,effective=70}} });
Z.SRData.MarkWon(s, 17063, "Carbon");
Z.DB.sheet = s;
Z.DB.drops = { { t=1, itemID=17063, link="[Test Sword]", source="raid", outcome="award", winner="Carbon" } };
Z.DB.sheet = s;
-- Sheet tab renders cards in 3 even columns, one tracked row per visual
-- row (single scroll body => columns scroll together).
Z.MainWindow.SelectTab("sheet");
local sheetRows = Z.MainWindow.DebugBodyRows("sheet");
assert(sheetRows and #sheetRows == 2, "4 cards in 3 cols = 2 tracked rows, got " .. tostring(sheetRows and #sheetRows));
local r1 = sheetRows[1];
assert(r1.cells and #r1.cells == 3, "first visual row holds 3 cards");
assert(r1.cells[1].x == 0 and r1.cells[2].x > r1.cells[1].x and r1.cells[3].x > r1.cells[2].x, "columns spaced left to right");
assert(r1.cells[2].x - r1.cells[1].x == r1.cells[3].x - r1.cells[2].x, "columns evenly spaced");
local r2 = sheetRows[2];
assert(r2.cells and #r2.cells == 1, "last visual row holds the leftover card");
print("sheet 3-column layout OK");
-- Card rollers split into two columns (17063 has Blackfang + Carbon).
local twoCol = Z.MainWindow.DebugCardColumns(17063);
assert(twoCol and twoCol.left == 1 and twoCol.right == 1, "rollers split 1+1 across two columns, got " .. tostring(twoCol and (twoCol.left .. "+" .. twoCol.right)));
print("sheet roller 2-column split OK");
-- My-SR badge: mock player is SoloPlayer — add them to 17063's rollers
-- (Blackfang + Carbon otherwise), re-render, then check.
table.insert(s.items[17063].rollers, { name = "SoloPlayer", rolls = 1 });
Z.MainWindow.SelectTab("sheet");
assert(Z.MainWindow.DebugCardMine(17063) == true, "my-SR card flagged");
assert(Z.MainWindow.DebugCardMine(18646) ~= true, "other card not flagged");
print("sheet my-SR badge OK");
-- Drop-count corner: 17063 rolled once (RecordRolls above) -> #1;
-- 18646 never rolled -> #0. No "not rolled yet" text anywhere.
assert(Z.MainWindow.DebugCardDrops(17063) == 1, "rolled card shows #1, got: " .. tostring(Z.MainWindow.DebugCardDrops(17063)));
assert(Z.MainWindow.DebugCardDrops(18646) == 0, "unrolled card shows #0, got: " .. tostring(Z.MainWindow.DebugCardDrops(18646)));
print("sheet drop-count corner OK");
-- Shift-click link: full color link, never a bare item id.
local cardLink = Z.MainWindow.DebugCardLink(17063);
assert(cardLink and string.find(cardLink, "|Hitem:", 1, true), "card link is a full link, got: " .. tostring(cardLink));
print("sheet card link OK");
-- Ctrl-click try-on: DressUpItemLink fires for the card's item.
local tried = {};
DressUpItemLink = function(link) table.insert(tried, link) end;
IsControlKeyDown = function() return true end;
local sheetIcons = Z.MainWindow.DebugCardIcons and Z.MainWindow.DebugCardIcons();
assert(sheetIcons and sheetIcons[17063] and sheetIcons[17063].GetScript, "sheet icon tracked");
local sheetClick = sheetIcons[17063]:GetScript("OnClick");
assert(sheetClick, "sheet icon click wired");
sheetClick();
IsControlKeyDown = function() return false end;
DressUpItemLink = nil;
assert(#tried == 1 and string.find(tried[1], "17063", 1, true), "ctrl-click tries on 17063, got: " .. tostring(tried[1]));
print("sheet card try-on OK");
-- Drop-count badge + roll-log window data for the rolled item.
local log = Z.MainWindow.ItemLogLines(17063);
assert(log and log.header and log.header.itemID == 17063, "log header targets the item");
assert(string.find(log.header.name, "Test Sword", 1, true), "log header names the item, got: " .. tostring(log.header.name));
assert(#log.lines >= 3, "log holds session + player lines, got " .. tostring(#log.lines));
assert(string.find(table.concat(log.lines, "\n"), "Carbon", 1, true), "log names the winner");
-- Card click opens the log window (mock frame: builds + shows).
Z.MainWindow.ShowItemLog(17063);
assert(Z.MainWindow.itemLogFrame ~= nil, "log window built on card click");
assert(Z.MainWindow.itemLogItem == 17063, "log window targets the clicked item");
print("item roll-log window OK");
-- ML loot window + award menu render under the mock frame API.
Z.LootWindow.SetItems({ { itemID=19137, link="[Test Dagger]", quality=4, sr=1 } }, "loot");
Z.LootWindow.Show("Boss loot");
assert(Z.LootWindow.Find(19137) ~= nil, "loot window lists the drop");
local fakeRolls = { { name="Blackfang", roll=95, type="SR" } };
local res = Z.Resolver.ResolveItem(s, 19137, fakeRolls, { cap=100 });
assert(type(Z.MasterLootUI.AwardMenu) == "function", "menu builder loaded");
local menu = Z.MasterLootUI.AwardMenu(19137, "[Test Dagger]", res);
assert(type(menu) == "table" and type(menu.winners) == "table", "menu shape");
assert(menu.winners[1].name == "Blackfang", "menu top winner");
assert(#menu.candidates >= 2, "candidate roster built");
print("loot window + award menu OK");
-- client frames: overview rows + row detail under the mock frame API.
Z.LootWindow.Show("Boss loot");
assert(Z.LootWindow.frame ~= nil, "overview frame built");
assert(#Z.LootWindow.rows == 1, "one overview row painted");
Z.LootWindow.OpenDetail(19137);
assert(Z.LootWindow.detail ~= nil, "detail data opened");
assert(Z.LootWindow.detailFrame ~= nil, "detail frame built");
assert(Z.LootWindow.detailFrame.ignoreB ~= nil, "Ignore button built");
assert(Z.LootWindow.detailFrame.ignoreB.label == "Ignore", "Ignore labeled");
assert(Z.LootWindow.detailFrame.ignoreB:GetScript("OnClick"), "Ignore click wired");
assert(Z.LootWindow.detailFrame.sandB ~= nil, "Sand button built");
assert(Z.LootWindow.detailFrame.sandB.label == "Sand", "Sand labeled");
assert(Z.LootWindow.detailFrame.sandB:GetScript("OnClick"), "Sand click wired");
assert(Z.LootWindow.detailFrame.rolls ~= nil, "roll list widget built");
-- rolling + award phases repaint under the mock API (persistent window).
Z.LootWindow.detail.phase = "rolling";
Z.LootWindow.DetailOnRoll(19137, "Blackfang", 95, "SR", 115);
Z.LootWindow.detail.countdown = 12;
Z.LootWindow.detail.countdownDur = 15;
Z.LootWindow.RefreshDetail();
-- Master countdown bar (raider parity): built once, visible while
-- rolling with the painted value, hidden once the roll finishes.
local dfBar = Z.LootWindow.detailFrame;
assert(dfBar.timerBar ~= nil, "countdown bar built");
assert(dfBar.timerBarText ~= nil, "countdown seconds built");
assert(dfBar.timerBar.hidden ~= true, "bar visible while rolling");
assert(dfBar.timerBar.sbval == 12 or dfBar.timerBar.val == 12,
  "bar paints 12s, got: " .. tostring(dfBar.timerBar.sbval or dfBar.timerBar.val));
assert(string.find(dfBar.timerBarText.txt or "", "12s", 1, true) ~= nil,
  "bar seconds text paints, got: " .. tostring(dfBar.timerBarText.txt));
Z.LootWindow.DetailOnFinish(19137, menu);
assert(Z.LootWindow.detail.phase == "award", "detail flips to award");
Z.LootWindow.RefreshDetail();
assert(Z.LootWindow.detailFrame.timerBar.hidden == true,
  "bar hides once the roll finishes");
-- bar buttons: primary (SR winner) + Award TMOG (kind winner) +
-- Continue rolling + Roll again + Raid roll + ... — roll initiation
-- lives on the bar, never in the ... menu.
Z.LootWindow.detail.menu.perType = Z.LootWindow.detail.menu.perType or {};
Z.LootWindow.detail.menu.perType.TMOG = { entry = { name = "SoloPlayer",
  rollType = "TMOG", effective = 15 }, tied = {} };
Z.LootWindow.RefreshDetail();
local df2 = Z.LootWindow.detailFrame;
assert(df2.tmogB ~= nil, "Award TMOG button built");
assert(df2.tmogB.hidden ~= true, "Award TMOG visible with a TMOG roll");
assert(string.find(df2.tmogB.label or "", "SoloPlayer", 1, true) ~= nil,
  "Award TMOG names the kind winner, got: " .. tostring(df2.tmogB.label));
-- no TMOG roll -> button hides (SR-only award window).
Z.LootWindow.detail.menu.perType.TMOG = {};
Z.LootWindow.RefreshDetail();
assert(df2.tmogB.hidden == true, "Award TMOG hidden without a TMOG roll");
assert(df2.rollB ~= nil, "Roll button built");
assert(df2.raidB ~= nil, "Raid roll button built");
assert(df2.contB ~= nil, "Continue rolling button built");
assert(df2.rollB.hidden ~= true, "Roll visible on the award window");
assert(df2.raidB.hidden ~= true, "Raid roll visible on the award window");
assert(df2.contB.hidden ~= true, "Continue rolling visible on the award window");
assert(string.find(df2.contB.label or "", "Continue rolling", 1, true) ~= nil,
  "continue labeled, got: " .. tostring(df2.contB.label));
assert(string.find(df2.rollB.label or "", "Roll again", 1, true) ~= nil,
  "award Roll re-labels, got: " .. tostring(df2.rollB.label));
assert(string.find(df2.raidB.label or "", "Raid roll", 1, true) ~= nil,
  "raid button labeled, got: " .. tostring(df2.raidB.label));
-- pick phase: Roll + Raid roll start buttons (Continue hidden);
-- rolling: Roll + Continue hide, Raid roll stays (switch mid-roll).
Z.LootWindow.detail.phase = "pick";
Z.LootWindow.detail.menu = nil;
Z.LootWindow.RefreshDetail();
assert(df2.rollB.hidden ~= true, "Roll visible pre-roll");
assert(df2.raidB.hidden ~= true, "Raid roll visible pre-roll");
assert(df2.contB.hidden == true, "Continue hidden pre-roll");
assert(string.find(df2.rollB.label or "", "^Roll", 1, false) ~= nil
  or string.find(df2.rollB.label or "", "Roll", 1, true) ~= nil,
  "pick Roll labeled, got: " .. tostring(df2.rollB.label));
Z.LootWindow.detail.phase = "rolling";
Z.LootWindow.RefreshDetail();
assert(df2.rollB.hidden == true, "Roll hidden mid-roll");
assert(df2.contB.hidden == true, "Continue hidden mid-roll");
assert(df2.raidB.hidden ~= true, "Raid roll stays mid-roll");
-- award phase: same winner rows power the primary button.
Z.LootWindow.detail.phase = "award";
Z.LootWindow.detail.menu = menu;
Z.LootWindow.RefreshDetail();
local preActs = Z.LootWindow.DetailActions();
assert(preActs[1].id == "award-name", "award primary is the top winner");
assert(preActs[1].name == "Blackfang", "award winner named");
assert(df2.awardB.hidden ~= true, "award primary button visible");
assert(string.find(df2.awardB.label or "", "Blackfang", 1, true) ~= nil,
  "award primary names the winner, got: " .. tostring(df2.awardB.label));
-- button bar geometry: flow-layout invariants — every VISIBLE button
-- inside the frame, no two buttons on the same row overlap, rows stack
-- on the 10 + k*30 grid (wraps when narrow, shares one row when wide).
local df = Z.LootWindow.detailFrame;
local function barBox(b)
  local pts = b.points or {}
  local last = pts[#pts]
  if not last or last[1] ~= "BOTTOMLEFT" then return nil end
  return { x = last[4] or 0, y = last[5] or 0, w = b.w or 0 }
end
local vis = {}
for _, n in ipairs({ "awardB", "tmogB", "contB", "rollB", "raidB", "sandB", "ignoreB", "moreB" }) do
  local btn = df[n]
  if btn and btn.hidden ~= true then
    local box = barBox(btn)
    assert(box ~= nil, n .. " placed");
    assert(box.x >= 0 and box.x + box.w <= Z.LootWindow.DETAIL_WIDTH,
      n .. " inside frame");
    assert((box.y - 10) % 30 == 0, n .. " on row grid");
    table.insert(vis, { name = n, box = box })
  end
end
for i = 1, #vis do
  for j = i + 1, #vis do
    local a, b = vis[i], vis[j]
    if a.box.y == b.box.y then
      local overlap = not (a.box.x + a.box.w <= b.box.x or b.box.x + b.box.w <= a.box.x)
      assert(not overlap, a.name .. " overlaps " .. b.name);
    end
  end
end
local function hasAnchor(pts, want)
  for _, p in ipairs(pts or {}) do
    for _, v in ipairs(p) do if v == want then return true end end
  end
  return false
end
-- Raider-style columns: header icon + two roll columns (names left,
-- rolls right), fixed 220-wide frame.
assert(df.dicon ~= nil, "detail header icon built");
assert(df.rollsL ~= nil and df.rollsR ~= nil, "two roll columns built");
assert(hasAnchor(df.rollsL.points, "TOPLEFT"), "left column anchored");
assert(hasAnchor(df.rollsR.points, "TOPRIGHT"), "right column anchored");
-- X buttons (standard close): loot overview + detail both carry one
-- top-right, wired to the same actions as the old bottom Close buttons.
local lwX = Z.LootWindow.frame and Z.LootWindow.frame.closeB;
assert(lwX ~= nil, "loot overview has top-right X");
local dfX = Z.LootWindow.detailFrame and Z.LootWindow.detailFrame.closeB;
assert(dfX ~= nil, "detail has top-right X");
local function hasTopRight(pts)
  for _, p in ipairs(pts or {}) do
    if p[1] == "TOPRIGHT" then return true end
  end
  return false
end
assert(hasTopRight(lwX.points), "overview X anchored top-right");
assert(hasTopRight(dfX.points), "detail X anchored top-right");
print("top-right X buttons OK");
-- ... dropdown builds under the mock API, rows clickable, closes cleanly.
-- (Roll initiation lives on the bar buttons, never in the menu.)
Z.LootWindow.ToggleMoreDropdown(Z.LootWindow.detailFrame.moreB);
assert(Z.LootWindow.moreDropdown ~= nil, "more dropdown opened");
assert(#Z.LootWindow.moreDropdown.rows >= 1, "dropdown rows painted");
for _, r in ipairs(Z.LootWindow.moreDropdown.rows) do
  assert(r.choice and r.choice.id ~= "roll" and r.choice.id ~= "raidroll",
    "menu carries awards only, got: " .. tostring(r.choice and r.choice.id));
end
-- Class-group side submenu: find a class row, hover it, the submenu
-- pops to the side with that class's players (no flat 40-name list).
local classRow = nil;
for _, r in ipairs(Z.LootWindow.moreDropdown.rows) do
  if r.choice and r.choice.id == "class" then classRow = r break end
end
if classRow then
  local enter = classRow:GetScript("OnEnter");
  assert(enter, "class row hover wired");
  enter();
  local sub = Z.LootWindow.moreDropdown.submenu;
  assert(sub ~= nil, "submenu opened on class hover");
  assert(sub.rows and #sub.rows >= 1, "submenu holds the class players");
  local anchored = false;
  for _, p in ipairs((sub.points or {})) do
    if p[1] == "TOPLEFT" then anchored = true end
  end
  assert(anchored, "submenu anchored to the side");
  -- Submenu award click runs the direct award path and closes the menu.
  local first = sub.rows[1];
  local click = first:GetScript("OnClick");
  assert(click, "submenu award click wired");
  -- Awarding needs an open corpse: the mock keeps lootOpen from setup.
  Z.MasterLootUI.lootOpen = true;
  local targetItem = Z.LootWindow.detail and Z.LootWindow.detail.itemID;
  click();
  assert(Z.LootWindow.moreDropdown == nil, "submenu award closes the menu");
  assert(Z.LootWindow.Find(targetItem) == nil, "submenu award hands out the row");
  Z.LootWindow.SetItems({ { itemID=19137, link="[Test Dagger]", quality=4, sr=1 } }, "loot");
  Z.LootWindow.OpenDetail(19137);
  Z.LootWindow.ToggleMoreDropdown(Z.LootWindow.detailFrame.moreB);
  assert(Z.LootWindow.moreDropdown ~= nil, "dropdown reopens after submenu award");
else
  print("note: no class row in ... menu (solo sheet), submenu skipped");
end
Z.LootWindow.CloseDetail();
assert(Z.LootWindow.detail == nil, "detail closed");
assert(Z.LootWindow.moreDropdown == nil, "dropdown closed with detail");
assert(Z.LootWindow.moreSubmenu == nil, "submenu closed with detail");
print("loot frames OK");
Z.RaidArchive.ArchiveActive(Z.DB, 2000);
-- Member-tab role icons: hunter (ranged/bow), warrior (melee/sword),
-- priest (healer/book) via the sheet classes; unknown gets no icon.
ZugLoot.ClassColors = ZugLoot.ClassColors or {};
local roleSheet = ZugLoot.SRData.NewSheet();
ZugLoot.SRData.SetPlayerClass(roleSheet, "RangedR", "HunterBeastMastery");
ZugLoot.SRData.SetPlayerClass(roleSheet, "MeleeM", "WarriorProtection");
ZugLoot.SRData.SetPlayerClass(roleSheet, "HealH", "PriestHoly");
-- Save the raid sheet: the role-icon render overwrites it, the header
-- asserts below need the raid back.
local savedSheet = ZugLoot.DB.sheet;
ZugLoot.DB.sheet = roleSheet;
ZugLoot.VersionGrid.GridNames = function()
  return { { name = "RangedR", inGroup = true }, { name = "MeleeM", inGroup = true },
    { name = "HealH", inGroup = true }, { name = "Nobody", inGroup = true } }
end;
Z.MainWindow.SelectTab("versions");
local gridCells = Z.MainWindow.DebugGridCells and Z.MainWindow.DebugGridCells() or nil;
assert(gridCells and #gridCells == 4, "four member cells, got: " .. tostring(gridCells and #gridCells));
assert(gridCells[1].roleIcon and string.find(gridCells[1].roleIcon, "Bow", 1, true), "hunter gets bow");
assert(gridCells[2].roleIcon and string.find(gridCells[2].roleIcon, "Shield", 1, true), "prot warrior gets shield");
assert(gridCells[3].roleIcon and string.find(gridCells[3].roleIcon, "Book", 1, true), "priest gets book");
assert(gridCells[4].roleIcon == nil, "unknown class gets no icon");
assert(gridCells[1].spec == "Beast Mastery", "hunter spec shows, got: " .. tostring(gridCells[1].spec));
assert(gridCells[2].spec == "Protection", "prot spec shows, got: " .. tostring(gridCells[2].spec));
assert(gridCells[3].spec == "Holy", "holy spec shows, got: " .. tostring(gridCells[3].spec));
assert(gridCells[4].spec == nil, "unknown class shows no spec");
print("member role icons OK");
ZugLoot.DB.sheet = savedSheet;
Z.MainWindow.Refresh();
-- Pysanka tab: renders, invitation word defaults to invite, player
-- fields + edits are present, writes land in the model, and the picker
-- opens merged sheet + roster choices on click.
Z.MainWindow.SelectTab("pysanka");
local pyVals = Z.MainWindow.DebugPysankaValues();
assert(pyVals and pyVals["invite"] == "invite", "invite defaults to invite, got: " .. tostring(pyVals and pyVals["invite"]));
assert(Z.MainWindow.SetPysankaField("invite", "inv"), "invite field writable");
assert(pyVals == nil or Z.MainWindow.DebugPysankaValues()["invite"] == "inv", "invite edit persists");
Z.MainWindow.SetPysankaField("invite", "   ");
assert(Z.MainWindow.DebugPysankaValues()["invite"] == "invite", "blank invite falls back");
assert(Z.MainWindow.SetPysankaField("tank:1:tank", "Pysanka"), "tank field writable");
assert(Z.MainWindow.DebugPysankaValues()["tank:1:tank"] == "Pysanka", "tank assignment persists");
assert(Z.MainWindow.SetPysankaField("buff:1-2/MoTW", "Janetta"), "buff field writable");
assert(Z.MainWindow.DebugPysankaValues()["buff:1-2/MoTW"] == "Janetta", "buff assignment persists");
assert(Z.MainWindow.SetPysankaField("debuff:CoR", "Ahjinn"), "debuff field writable");
assert(Z.MainWindow.SetPysankaField("puller", "Remorph"), "puller writable");
assert(Z.MainWindow.SetPysankaField("coordinator", "Pysanka"), "coordinator writable");
local pyWidgets = Z.MainWindow.DebugPysankaWidgets();
local nEdit, nPlayer = 0, 0;
for i = 1, Z.Util.ArrayCount(pyWidgets) do
  if pyWidgets[i].kind == "edit" then nEdit = nEdit + 1 else nPlayer = nPlayer + 1 end
end
assert(nEdit == 1, "exactly one invite edit box, got " .. tostring(nEdit));
-- 20 buffs + pally/coordinator + 24 tank rows + 2 raid-all + puller + 11 debuffs
assert(nPlayer == 20 + 2 + 24 + 2 + 1 + 11, "all player fields clickable, got " .. tostring(nPlayer));
-- Clicking a player field opens the picker with sheet+roster choices.
-- reach into the tracked widgets via a second select (widgets rebuild)
Z.MainWindow.SelectTab("sheet");
Z.MainWindow.SelectTab("pysanka");
assert(Z.MainWindow.DebugPysankaPicker() == nil, "no picker before click");
-- find a tank button: re-render then click through its OnClick script
local tankBtn = nil
for _, w in ipairs(Z.MainWindow.zlPysPlayers or {}) do
  if w.zlDesc == "tank:1:tank" then tankBtn = w break end
end
assert(tankBtn ~= nil and tankBtn.GetScript, "tank button tracked");
local tankClick = tankBtn:GetScript("OnClick");
assert(tankClick, "tank button click wired");
tankClick();
local pick = Z.MainWindow.DebugPysankaPicker();
assert(pick ~= nil, "picker opened on tank click");
assert(pick.open == true, "picker records open state");
assert(Z.Util.ArrayCount(pick.names) >= 2, "picker merges sheet players, got " .. tostring(pick.names and Z.Util.ArrayCount(pick.names)));
-- Picker paints ABOVE the main window (TOOLTIP strata + higher level),
-- or it slides under the window and cannot be clicked.
local drop = Z.MainWindow.DebugPysankaDrop();
assert(drop ~= nil, "picker frame built");
assert(drop.strata == "TOOLTIP", "picker strata above window, got: " .. tostring(drop.strata));
assert((drop.flevel or 0) > 5, "picker level above window, got: " .. tostring(drop.flevel));
-- Clicking the same field again toggles the picker shut.
tankClick();
assert(Z.MainWindow.DebugPysankaPicker().open == false, "second click closes picker");
assert(Z.MainWindow.DebugPysankaDrop() == nil, "picker frame torn down");
-- Import sheet paints ABOVE the main window (DIALOG strata + higher
-- level), or it slides under the window and cannot be clicked.
Z.SRImport.ShowPaste();
local impF = Z.SRImport.DebugImportFrame();
assert(impF ~= nil, "import frame built");
assert(impF.strata == "DIALOG", "import strata above window, got: " .. tostring(impF.strata));
assert((impF.flevel or 0) > (Z.MainWindow.frame and Z.MainWindow.frame:GetFrameLevel() or 5),
  "import level above main window, got: " .. tostring(impF.flevel));
-- Re-show after a main-window rebuild (size change path) re-pins above.
-- Force the rebuild: move the stored size off the live size first.
Z.MainWindow.winW, Z.MainWindow.winH = -1, -1;
assert(Z.MainWindow.EnsureSize() == true, "main window rebuilt");
Z.SRImport.ShowPaste();
local impF2 = Z.SRImport.DebugImportFrame();
assert((impF2.flevel or 0) > (Z.MainWindow.frame and Z.MainWindow.frame:GetFrameLevel() or 5),
  "import re-pinned after main rebuild, got: " .. tostring(impF2 and impF2.flevel));
print("import sheet above main window OK");
-- Static sheet box: fixed width + height, bordered like a standard
-- Blizzard input. Neither the box nor the dialog resizes; long pastes
-- scroll inside. Clicking the box focuses it for Ctrl+V; opening the
-- dialog focuses it.
local impBox = Z.SRImport.DebugImportBox();
assert(impBox ~= nil and impBox.GetText, "import box tracked");
assert(impBox.w == Z.SRImport.IMPORT_BOX_W - 24, "box width static, got: " .. tostring(impBox.w));
assert(impBox.h == Z.SRImport.IMPORT_BOX_H - 20, "box height static, got: " .. tostring(impBox.h));
local impBorder = Z.SRImport.DebugImportBorder();
assert(impBorder ~= nil, "import border tracked");
assert(impBorder.w == Z.SRImport.IMPORT_BOX_W, "border width static, got: " .. tostring(impBorder.w));
assert(impBorder.h == Z.SRImport.IMPORT_BOX_H, "border height static, got: " .. tostring(impBorder.h));
local impScroll = Z.SRImport.DebugImportScroll();
assert(impScroll ~= nil, "import scroll tracked");
assert(impScroll.w == Z.SRImport.IMPORT_BOX_W - 20, "scroll width static, got: " .. tostring(impScroll.w));
assert(impScroll.h == Z.SRImport.IMPORT_BOX_H - 20, "scroll height static, got: " .. tostring(impScroll.h));
-- No expand path: the box/scroll carry no BOTTOMRIGHT anchor and no
-- resize grip may stretch them.
for _, p in ipairs(impScroll.points or {}) do
  assert(p[1] ~= "BOTTOMRIGHT", "scroll must not stretch-anchor");
end
-- Text stays clear of the border: 10px moat (scroll inset inside the
-- border frame) plus text insets inside the box. Either alone can be
-- defeated (insets by an unbreakable base64 line, the moat by nothing).
assert(impBox.insets ~= nil, "box carries text insets");
assert((impBox.insets[1] or 0) >= 6 and (impBox.insets[3] or 0) >= 6,
  "insets pad the box, got: " .. tostring(impBox.insets and table.concat(impBox.insets, ",")));
local moatTL = false;
for _, p in ipairs(impScroll.points or {}) do
  if p[1] == "TOPLEFT" and p[4] == 10 and p[5] == -10 then moatTL = true end
end
assert(moatTL, "scroll sits 10px inside the border");
assert(impBorder:GetScript("OnMouseDown"), "moat click-to-focus wired");
impBorder:GetScript("OnMouseDown")();
assert(impBox.focused == true, "moat click focuses the box");
assert(impScroll:GetScript("OnMouseDown"), "box click-to-focus wired");
impScroll:GetScript("OnMouseDown")();
assert(impBox.focused == true, "click focuses the box");
impBox.focused = nil;
Z.SRImport.ShowPaste();
assert(Z.SRImport.DebugImportBox().focused == true, "dialog open focuses the box");
print("import compact input box OK");
-- Kill order renders the 8 real raid-target icons in order.
Z.MainWindow.SelectTab("sheet");
Z.MainWindow.SelectTab("pysanka");
local ko = Z.MainWindow.DebugPysankaKillOrder();
assert(ko and Z.Util.ArrayCount(ko) == 8, "kill order holds 8 icons, got " .. tostring(ko and Z.Util.ArrayCount(ko)));
assert(ko[1].mark == "Skull" and ko[1].icon == Z.Pysanka.MarkIcon("Skull"), "kill order starts at skull");
for i = 1, 8 do
  assert(ko[i].icon == "Interface\\TargetingFrame\\UI-RaidTargetingIcons",
    "kill icon " .. i .. " uses the raid sheet, got: " .. tostring(ko[i].icon));
  assert(ko[i].mark == Z.Pysanka.MARKS[i], "kill icon " .. i .. " order");
end
-- Without the client API the path is used; with it (stock 1.12
-- SetRaidTargetIconTexture) the API paints the texture directly.
SetRaidTargetIconTexture = function(tex, idx)
  tex:SetTexture("API-ICON-" .. tostring(idx))
end;
Z.MainWindow.SelectTab("sheet");
Z.MainWindow.SelectTab("pysanka");
local koApi = Z.MainWindow.DebugPysankaKillOrder();
assert(koApi and koApi[1].via == "api", "client raid-icon API used when present");
SetRaidTargetIconTexture = nil;
print("pysanka tab OK");
-- Pysanka layout invariant: no widget row may start inside the one
-- above — every header->field step must clear the widget heights
-- (GameFontNormal ~14px, small ~12px, fields 20px). Catches the
-- header/field overlap family (buff columns over row 1-2, tank heads
-- over Skull, kill-order icons over their header).
Z.MainWindow.SelectTab("sheet");
Z.MainWindow.SelectTab("pysanka");
local pyRows = Z.MainWindow.DebugPysankaRowYs and Z.MainWindow.DebugPysankaRowYs();
if pyRows then
  local function clear(aTop, aH, bTop, what)
    assert(bTop <= aTop - (aH - 2), what .. ": gap violated (" .. tostring(aTop) .. "->" .. tostring(bTop) .. ")");
  end
  clear(pyRows.buffHead, 14, pyRows.buffRow1, "buff header clears row 1-2");
  clear(pyRows.tankHead, 14, pyRows.tankRow1, "tank header clears skull");
  clear(pyRows.dbHead1, 14, pyRows.dbRow1, "debuff header clears row 1");
  clear(pyRows.dbHead2, 14, pyRows.dbRow2, "debuff header clears row 2");
  clear(pyRows.koHead, 14, pyRows.koIcons, "kill-order header clears icons");
  print("pysanka layout invariant OK");
end
for _,tab in ipairs({"sheet","raids","pysanka","versions","setup"}) do
  Z.MainWindow.SelectTab(tab);
  print("rendered tab:", tab);
end
-- setup tab: auto loot-method toggles exist, flip the DB flags, relabel.
Z.DB.mlOnBoss = false;
Z.DB.backToGroup = false;
Z.MainWindow.SelectTab("setup");
local st = Z.MainWindow.DebugSetupToggles();
assert(st.mlOnBoss ~= nil, "ML on boss toggle built");
assert(st.backToGroup ~= nil, "Back to group toggle built");
assert(string.find(st.mlOnBoss.label or "", "OFF", 1, true) ~= nil, "ML toggle starts OFF");
st.mlOnBoss:GetScript("OnClick")();
assert(Z.DB.mlOnBoss == true, "ML toggle flips the flag");
assert(string.find(st.mlOnBoss.label or "", "ON", 1, true) ~= nil, "ML toggle relabels");
st.backToGroup:GetScript("OnClick")();
assert(Z.DB.backToGroup == true, "group toggle flips the flag");
-- boss threshold dropdown: button shows the pick, 4 rows, click stores.
Z.DB.bossThreshold = 4;
Z.MainWindow.SelectTab("setup");
local st2 = Z.MainWindow.DebugSetupToggles();
assert(st2.bossThreshold ~= nil, "threshold button built");
assert(string.find(st2.bossThreshold.label or "", "Epic", 1, true) ~= nil,
  "threshold button shows the pick, got: " .. tostring(st2.bossThreshold.label));
Z.MainWindow.ToggleThresholdDropdown(st2.bossThreshold);
assert(Z.MainWindow.threshDropdown ~= nil, "threshold dropdown opened");
assert(#Z.MainWindow.threshDropdown.rows == 4, "four threshold rows");
assert(Z.MainWindow.threshDropdown.rows[1].choice.value == 1, "common first");
assert(Z.MainWindow.threshDropdown.rows[3].choice.label == "Rare (3)", "rare labeled");
Z.MainWindow.threshDropdown.rows[3]:GetScript("OnClick")();
assert(Z.DB.bossThreshold == 3, "dropdown click stores rare");
assert(Z.MainWindow.threshDropdown == nil, "dropdown closes on pick");
Z.DB.bossThreshold = 4;
Z.DB.mlOnBoss = false;
Z.DB.backToGroup = false;
print("setup loot toggles OK");
-- scrollbar invariant, checked on every tab: a visible slider may only belong
-- to the active tab. Hidden tabs must never paint a thumb (the old bug left
-- stale sliders from hidden tabs over the live list).
for _,tab in ipairs({"sheet","raids","pysanka","versions","setup"}) do
  Z.MainWindow.SelectTab(tab);
  local sliderState = Z.MainWindow.DebugSliderState();
  for other, _vis in pairs(sliderState) do
    assert(not _vis or other == tab, "slider of hidden tab " .. other .. " visible while on " .. tab);
  end
end
print("slider invariant OK");
-- layout invariant: rows must span the live window (bodyWidth == winW - 64).
-- Catches Lua-scoping regressions where size assignments miss the locals.
local layout = Z.MainWindow.DebugLayout();
assert(layout.winW == 900, "expected 900-wide window in mock, got " .. tostring(layout.winW));
assert(layout.bodyWidth == layout.winW - 64, "body width " .. tostring(layout.bodyWidth) .. " detached from window " .. tostring(layout.winW));
print("layout invariant OK");
-- header shows ID, raid name and raid start
Z.MainWindow.SelectTab("sheet");
local hdr = Z.MainWindow.DebugHeader();
assert(hdr and string.find(hdr, "ID MOCK-RAID-1", 1, true), "header shows raid ID, got: " .. tostring(hdr));
assert(string.find(hdr, "Molten Core", 1, true), "header shows raid name, got: " .. tostring(hdr));
assert(string.find(hdr, "started 2024", 1, true), "header shows raid start, got: " .. tostring(hdr));
assert(string.find(hdr, "items", 1, true), "header shows item count, got: " .. tostring(hdr));
-- prominent active raid line on the brand row: name + start (ID lives on sub-line)
local act = Z.MainWindow.DebugActiveRaid();
assert(act and string.find(act, "ACTIVE RAID", 1, true), "active raid label, got: " .. tostring(act));
assert(string.find(act, "Molten Core", 1, true), "active raid name, got: " .. tostring(act));
assert(string.find(act, "started 2024", 1, true), "active raid start, got: " .. tostring(act));
assert(not string.find(act, "MOCK-RAID-1", 1, true), "ID stays on sub-line, got: " .. tostring(act));
print("header invariant OK");
-- brand uses the bundled fantasy face (falls back clean without it).
assert(Z.MainWindow.brandFS ~= nil and Z.MainWindow.brandFS.txt == "ZUGLOOT",
  "brand text");
assert(Z.MainWindow.brandFS.font ~= nil
  and Z.MainWindow.brandFS.font[1] == ZugLoot.Fonts.DISPLAY,
  "brand uses the bundled display face, got: "
  .. tostring(Z.MainWindow.brandFS.font and Z.MainWindow.brandFS.font[1]));
-- header buttons: Reset rolls + Get sheet + Import + File exist exactly
-- once each (Setup holds no duplicates). Get sheet hides solo/with sheet.
local hb = Z.MainWindow.DebugHeaderButtons();
assert(hb and hb.reset, "header Reset rolls button built");
assert(hb.getsheet, "header Get sheet button built");
assert(hb.import, "header Import button built");
assert(hb.file, "header File button built");
assert(hb.getsheetVisible == true, "Get sheet always visible");
-- LootBlare-style roll window: build, show item, feed grouped rolls.
Z.RaiderLootUI.ShowItem("|cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r", 15);
-- icon + name resolve link-first (regression: bare-ID call showed no
-- icon and fell back to the raw link text).
assert(Z.RaiderLootUI.iconPath == "Interface\\Icons\\INV_Sword_01",
  "roll window icon resolved, got: " .. tostring(Z.RaiderLootUI.iconPath));
assert(Z.RaiderLootUI.itemNameText ~= nil
  and not string.find(Z.RaiderLootUI.itemNameText, "|Hitem:", 1, true),
  "roll window name resolved, got: " .. tostring(Z.RaiderLootUI.itemNameText));
Z.RaiderLootUI.OnRoll("Thrall", 40, "SR");
Z.RaiderLootUI.OnRoll("Jaina", 50, "MS");
Z.RaiderLootUI.OnRoll("Varian", 45, "OS");
Z.RaiderLootUI.OnRoll("Anduin", 98, "TMOG");
Z.RaiderLootUI.OnRoll("Guldan", 35, "SR");
assert(#Z.RaiderLootUI.rolls == 5, "roll window collected 5 rolls");
-- sheet fallback colors the roll list: Thrall is a Paladin on the sheet.
s.players = s.players or {};
s.players["Thrall"] = { class = "PaladinHoly" };
assert(Z.ClassColors.ClassOf("Thrall") == "Paladin", "roll window sheet class");
assert(Z.ClassColors.ColoredName("Thrall") == "|cFFF58CBAThrall|r", "roll window pink");
Z.RaiderLootUI.ShowResult("The winner is Jaina (50) !");
-- Pysanka-style roll calls pop the raider window ONLY on the actual
-- roll call ("Roll for <link>: ..." dice line, plain name, bare link).
-- Everything else Pysanka says — drop lists, winners, countdowns,
-- stop-rolls, raid-roll numbering, bare item names, other senders —
-- never pops it, even when those lines carry links.
GetLootMethod = function() return "master" end;
GetLootMaster = function() return "Pysanka" end;
GetNumRaidMembers = function() return 3 end;
Z.RaiderLootUI.Hide();
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "Roll for Nemesis Gloves: /roll (MS) or /roll 99 (OS) or /roll 98 (TMOG)", "Pysanka");
assert(Z.RaiderLootUI.itemNameText == "Nemesis Gloves", "dice line pops window with item, got: " .. tostring(Z.RaiderLootUI.itemNameText));
-- Linked roll call (what the ML actually sends now) pops with the link.
Z.RaiderLootUI.Hide();
Z.RaiderLootUI.itemNameText = nil;
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "Roll for |cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r: /roll (MS)", "Pysanka");
assert(Z.RaiderLootUI.itemNameText == "Thunderfury", "linked dice line pops window, got: " .. tostring(Z.RaiderLootUI.itemNameText));
assert(Z.RaiderLootUI.itemLink ~= nil
  and string.find(Z.RaiderLootUI.itemLink, "|Hitem:17063", 1, true) ~= nil,
  "linked dice line keeps the clickable link, got: " .. tostring(Z.RaiderLootUI.itemLink));
Z.RaiderLootUI.Hide();
Z.RaiderLootUI.itemNameText = nil;
-- Linked non-roll lines never pop: drop line + winner line.
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "1. |cff0070dd|Hitem:19137:0:0:0|h[Primal Hakkari Idol]|h|r", "Pysanka");
assert(Z.RaiderLootUI.itemNameText == nil, "linked drop line does not pop window, got: " .. tostring(Z.RaiderLootUI.itemNameText));
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "|cFFF58CBAJaina|r wins |cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r.", "Pysanka");
assert(Z.RaiderLootUI.itemNameText == nil, "linked winner line does not pop window, got: " .. tostring(Z.RaiderLootUI.itemNameText));
Z.RaiderLootUI.Hide();
Z.RaiderLootUI.itemNameText = nil;
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "Nemesis Gloves", "Pysanka");
assert(Z.RaiderLootUI.itemNameText == nil, "bare item name does not pop window, got: " .. tostring(Z.RaiderLootUI.itemNameText));
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "Firemaw dropped 2 items:", "Pysanka");
assert(Z.RaiderLootUI.itemNameText ~= "Firemaw dropped 2 items:", "drop head does not pop window");
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "1. Legguards of the Fallen Crusader (SR by Shawty)", "Pysanka");
assert(Z.RaiderLootUI.itemNameText ~= "1. Legguards of the Fallen Crusader (SR by Shawty)", "drop line does not pop window");
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "Stopping rolls in 3", "Pysanka");
assert(Z.RaiderLootUI.itemNameText ~= "Stopping rolls in 3", "stop-rolls does not pop window");
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "2", "Pysanka");
assert(Z.RaiderLootUI.itemNameText ~= "2", "countdown does not pop window");
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "Ahjinn rolled the highest (10) for Nemesis Gloves.", "Pysanka");
assert(Z.RaiderLootUI.itemNameText ~= "Ahjinn rolled the highest (10) for Nemesis Gloves.", "winner line does not pop window");
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "[1]:Evilson, [2]:Broman", "Pysanka");
assert(Z.RaiderLootUI.itemNameText ~= "[1]:Evilson, [2]:Broman", "raid-roll numbering does not pop window");
Z.RaiderLootUI.OnEvent("CHAT_MSG_RAID_WARNING", "Roll for Nemesis Gloves: /roll (MS)", "RandomRaider");
assert(Z.RaiderLootUI.itemNameText ~= "Nemesis Gloves", "non-ML sender does not pop window");
GetLootMethod = nil;
GetLootMaster = nil;
GetNumRaidMembers = function() return 0 end;
print("roll-call trigger OK");
-- Roll-window icon hover: full link -> SetHyperlink tooltip; bare name
-- (Pysanka-style call, unseen item) -> name + hint, never a dead tip.
local tipCalls = {};
GameTooltip.SetHyperlink = function(self, link) table.insert(tipCalls, { "hyper", link }) end;
GameTooltip.SetText = function(self, txt) table.insert(tipCalls, { "text", txt }) end;
local function hoverIcon()
  local scripts = Z.RaiderLootUI.DebugIconScripts and Z.RaiderLootUI.DebugIconScripts();
  assert(scripts and scripts.OnEnter, "icon hover wired");
  scripts.OnEnter();
end
Z.RaiderLootUI.ShowItem("|cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r", 15);
tipCalls = {};
hoverIcon();
assert(#tipCalls == 1 and tipCalls[1][1] == "hyper", "link hover shows item tooltip");
assert(tipCalls[1][2] == "item:17063:0:0:0", "hover passes the bare item string, got: " .. tostring(tipCalls[1][2]));
Z.RaiderLootUI.ShowItem("Nemesis Gloves", 15);
tipCalls = {};
hoverIcon();
assert(#tipCalls >= 1 and tipCalls[1][1] == "text" and tipCalls[1][2] == "Nemesis Gloves", "bare-name hover shows name, got: " .. tostring(tipCalls[1] and tipCalls[1][2]));
-- Bare id ("item:NNNN"): resolves through the cache to a full tooltip.
Z.RaiderLootUI.ShowItem("item:17063:0:0:0", 15);
tipCalls = {};
hoverIcon();
assert(#tipCalls == 1 and tipCalls[1][1] == "hyper", "bare-id hover resolves to item tooltip");
assert(tipCalls[1][2] == "item:17063:0:0:0", "bare-id hover passes the item string, got: " .. tostring(tipCalls[1][2]));
print("roll icon tooltip OK");
-- Shift-click inserts a FULL link even when the window opened on a bare
-- id (click-time cache resolve + upgrade).
local inserted = {};
ChatFrameEditBox = { IsVisible = function() return true end, Insert = function(_self, s) table.insert(inserted, s) end };
IsShiftKeyDown = function() return true end;
IsControlKeyDown = function() return false end;
Z.RaiderLootUI.ShowItem("item:17063:0:0:0", 15);
local clickScripts = Z.RaiderLootUI.DebugIconScripts and Z.RaiderLootUI.DebugIconScripts();
assert(clickScripts and clickScripts.OnClick, "icon click wired");
clickScripts.OnClick();
assert(#inserted == 1 and string.find(inserted[1], "|Hitem:", 1, true), "shift-click inserts full link, got: " .. tostring(inserted[1]));
IsShiftKeyDown = function() return false end;
ChatFrameEditBox = { IsVisible = function() return false end };
print("roll icon shift-click OK");
-- Shared icon parity: EVERY icon runs the same handlers (ItemIcon.lua),
-- so hover/ctrl/shift behave identically on all five. The loot row icon
-- (overlay button) and the detail header icon had no assertions before.
local sheetEnter = Z.MainWindow.DebugCardIcons()[17063]:GetScript("OnEnter");
assert(sheetEnter, "sheet icon hover wired");
local raiderScripts = Z.RaiderLootUI.DebugIconScripts();
assert(raiderScripts and raiderScripts.OnEnter and raiderScripts.OnClick, "raider icon wired");
-- Loot row icon overlay: same hover (full tooltip) as the sheet card.
local lootRowBtn = Z.LootWindow.Find(19137) and Z.LootWindow.Find(19137)._iconBtn;
assert(lootRowBtn and lootRowBtn:GetScript("OnEnter"), "loot row icon hover wired");
assert(lootRowBtn:GetScript("OnClick"), "loot row icon click wired");
tipCalls = {};
lootRowBtn:GetScript("OnEnter")();
assert(#tipCalls == 1 and tipCalls[1][1] == "hyper", "loot row hover shows item tooltip");
-- Plain click (no modifier, no chat box): falls through to the row action.
-- Plain click (no modifier, no chat box): falls through to the row action
-- (whatever the row itself would do — detail, loot call, or passthrough).
Z.LootWindow.CloseDetail();
local wantRow = Z.LootWindow.OnRowClick(19137, nil);
Z.LootWindow.CloseDetail();
lootRowBtn:GetScript("OnClick")();
local gotRow = (Z.LootWindow.detail ~= nil and Z.LootWindow.detail.itemID == 19137)
  and "detail" or wantRow;
assert(gotRow == wantRow, "loot row plain click matches the row action, want " .. tostring(wantRow));
-- Loot detail header icon: hover shows the same item tooltip, ctrl-click
-- tries it on — like every other icon. (Opened directly: row clicks are
-- passthrough while the takeover is off in this harness.)
Z.LootWindow.OpenDetail(19137);
assert(Z.LootWindow.detailFrame ~= nil, "detail frame built");
local diconBtn = Z.LootWindow.detailFrame and Z.LootWindow.detailFrame.diconBtn;
assert(diconBtn and diconBtn:GetScript("OnEnter"), "detail icon hover wired");
assert(diconBtn:GetScript("OnClick"), "detail icon click wired");
tipCalls = {};
diconBtn:GetScript("OnEnter")();
assert(#tipCalls == 1 and tipCalls[1][1] == "hyper", "detail hover shows item tooltip");
local triedDetail = {};
DressUpItemLink = function(link) table.insert(triedDetail, link) end;
IsControlKeyDown = function() return true end;
diconBtn:GetScript("OnClick")();
IsControlKeyDown = function() return false end;
DressUpItemLink = nil;
assert(#triedDetail == 1 and string.find(triedDetail[1], "19137", 1, true),
  "detail ctrl-click tries on, got: " .. tostring(triedDetail[1]));
print("shared icon parity OK");
-- START_LOOT_ROLL mirrors a group roll in OUR dice frame; the dice vote
-- through RollOnLoot (Need 1 / Greed 2 / Pass 0), never RandomRoll chat
-- spam (which would forfeit the roll). CANCEL hides the frame.
local votes = {};
RollOnLoot = function(id, vote) table.insert(votes, { id, vote }) end;
GetLootRollItemLink = function(id) return "item:2001:0:0:0" end;
Z.RaiderLootUI.OnEvent("START_LOOT_ROLL", 7);
assert(Z.RaiderLootUI.groupRollID == 7, "group roll tracked");
Z.RaiderLootUI.DoRoll("SR", 100);
assert(votes[1][1] == 7 and votes[1][2] == 1, "SR votes Need on the roll");
Z.RaiderLootUI.DoRoll("OS", 99);
assert(votes[2][2] == 2, "OS votes Greed");
Z.RaiderLootUI.DoRoll("TMOG", 98);
assert(votes[3][2] == 2, "TMOG votes Greed");
Z.RaiderLootUI.DoRoll("MS", 100);
assert(votes[4][2] == 1, "MS votes Need");
Z.RaiderLootUI.OnEvent("CANCEL_LOOT_ROLL", 7);
assert(Z.RaiderLootUI.groupRollID == nil, "cancel clears the roll");
RollOnLoot = nil; GetLootRollItemLink = nil;
print("roll window OK");
-- Minimap ZL badge: ONE prerendered image texture (feathered disc +
-- Griffy gold ZL + halo, centered by measured bbox in Media/) — no
-- FontStrings, so nothing can drift. Plus the gold tracking ring.
Minimap = newObj("Frame");
local mmBtn = Z.Minimap.Build();
assert(mmBtn ~= nil, "minimap button built");
assert(mmBtn.badge ~= nil, "badge texture built");
assert(mmBtn.badge.tex == Z.Minimap.BADGE_IMAGE, "badge uses the media art");
assert(mmBtn.badge.w == Z.Minimap.BADGE_SIZE
  and mmBtn.badge.h == Z.Minimap.BADGE_SIZE, "badge sized");
assert(mmBtn.badgeLabel == nil and mmBtn.badgeGlows == nil,
  "no FontStrings: image-only badge");
local function ptCenter(tex)
  for _, p in ipairs(tex.points or {}) do
    if p[1] == "CENTER" then return p[4], p[5] end -- point, rel, x, y
  end
  return nil, nil
end
local bbx, bby = ptCenter(mmBtn.badge);
assert(bbx == 0 and bby == 0, "badge dead-centered on the button");
assert(mmBtn:GetScript("OnClick"), "badge click wired");
assert(mmBtn:GetScript("OnEnter"), "badge hover wired");
print("minimap ZL badge OK");
print("MOCK UI RUN OK");
