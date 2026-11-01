-- tests/test_global_guard.lua
-- Global namespace trap and Lua 5.0 engine compatibility audit.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else
    T.pass = T.pass + 1
  end
end

-- 1. Whitelist of allowed globals for WoW 1.12.1 + ZugLoot test environment
local allowedGlobals = {
  -- Lua core
  ["_G"] = true, ["_VERSION"] = true, ["assert"] = true, ["collectgarbage"] = true,
  ["dofile"] = true, ["error"] = true, ["getfenv"] = true, ["getmetatable"] = true,
  ["ipairs"] = true, ["load"] = true, ["loadfile"] = true, ["loadstring"] = true,
  ["next"] = true, ["pairs"] = true, ["pcall"] = true, ["print"] = true,
  ["rawequal"] = true, ["rawget"] = true, ["rawset"] = true, ["select"] = true,
  ["setfenv"] = true, ["setmetatable"] = true, ["tonumber"] = true, ["tostring"] = true,
  ["type"] = true, ["unpack"] = true, ["xpcall"] = true,
  ["coroutine"] = true, ["debug"] = true, ["io"] = true, ["math"] = true,
  ["os"] = true, ["package"] = true, ["string"] = true, ["table"] = true,
  -- Addon namespace
  ["ZugLoot"] = true, ["SlashCmdList"] = true, ["SLASH_ZUGLOOT1"] = true,
  ["SLASH_ZUGLOOT2"] = true, ["SLASH_ZUGLOOT3"] = true,
  -- ClassicAPI DLL table (probed, never required). ZugLoot touches
  -- C_Loot only; Nampower/Turtle provide the cast/speed/position APIs.
  ["C_Loot"] = true,
  -- Blizzard frames and globals
  ["UIParent"] = true, ["GameTooltip"] = true, ["DEFAULT_CHAT_FRAME"] = true,
  ["ChatFrameEditBox"] = true, ["StaticPopupDialogs"] = true, ["StaticPopup_Show"] = true,
  ["StaticPopup_Hide"] = true, ["UIErrorsFrame"] = true, ["ChatThrottleLib"] = true,
  ["CreateFrame"] = true, ["GetTime"] = true, ["time"] = true, ["date"] = true,
  ["UnitName"] = true, ["UnitClass"] = true, ["UnitExists"] = true,
  ["GetNumRaidMembers"] = true, ["GetNumPartyMembers"] = true, ["GetRaidRosterInfo"] = true,
  ["IsRaidLeader"] = true, ["IsRaidOfficer"] = true, ["GetLootMethod"] = true,
  ["GetLootMaster"] = true, ["GetLootThreshold"] = true, ["GetNumLootItems"] = true,
  ["GetLootSlotInfo"] = true, ["GetLootSlotLink"] = true, ["LootSlot"] = true,
  ["ConfirmLootSlot"] = true, ["GiveMasterLoot"] = true, ["GiveMasterLootCandidate"] = true,
  ["GetMasterLootCandidate"] = true, ["SendAddonMessage"] = true, ["SendChatMessage"] = true,
  ["CheckInteractDistance"] = true, ["GetItemInfo"] = true, ["PlaySound"] = true,
  ["GuildRoster"] = true, ["GetNumGuildMembers"] = true, ["GetGuildRosterInfo"] = true,
  ["IsInGuild"] = true, ["SetItemRef"] = true, ["DressUpItemLink"] = true,
  ["Base64Encode"] = true, ["Base64Decode"] = true, ["ReadCustomFile"] = true,
  ["WriteCustomFile"] = true, ["CursorHasItem"] = true, ["ClearCursor"] = true,
  ["arg1"] = true, ["arg2"] = true, ["arg3"] = true, ["arg4"] = true,
  ["this"] = true, ["event"] = true,
  -- Test harness symbols
  ["T"] = true, ["eq"] = true, ["ok"] = true,
}

-- Seed existing globals into whitelist
for k in pairs(_G) do
  allowedGlobals[k] = true
end

-- 2. Install _G metatable trap
local trappedViolations = {}
local trapActive = true

setmetatable(_G, {
  __newindex = function(t, key, val)
    if trapActive and not allowedGlobals[key] then
      table.insert(trappedViolations, tostring(key))
    end
    rawset(t, key, val)
  end,
  __index = function(t, key)
    return rawget(t, key)
  end,
})

-- Positive control: verify that undeclared global triggers the trap
_G["__test_unauthorized_leak__"] = 123
_G["__test_unauthorized_leak__"] = nil
eq(#trappedViolations, 1, "trap catches unauthorized global write")
eq(trappedViolations[1], "__test_unauthorized_leak__", "trapped variable name matches")
trappedViolations = {} -- reset after positive control

-- Load all shipped modules in fresh sandbox check
local shippedFiles = {
  "Constants.lua", "Util.lua", "Timer.lua", "ClassColors.lua", "SRData.lua",
  "Resolver.lua", "ItemCards.lua", "ItemIcon.lua", "SRView.lua", "SRSecurity.lua",
  "SRImport.lua", "Pysanka.lua", "MainWindow.lua", "Sim.lua", "MasterLootUI.lua",
  "RaidArchive.lua", "Comm.lua", "Core.lua", "LootWindow.lua", "AtlasLoot.lua",
  "RaiderLootUI.lua", "DropLog.lua", "VersionGrid.lua", "Minimap.lua", "AreaLoot.lua"
}

for _, f in ipairs(shippedFiles) do
  local chunk, err = loadfile(f)
  if not chunk then
    T.fail = T.fail + 1
    table.insert(T.errors, "LOAD FAIL " .. f .. ": " .. tostring(err))
  else
    local okCall, resErr = pcall(chunk)
    if not okCall then
      T.fail = T.fail + 1
      table.insert(T.errors, "EXEC FAIL " .. f .. ": " .. tostring(resErr))
    end
  end
end

eq(#trappedViolations, 0, "zero undeclared globals leaked across shipped modules")
if #trappedViolations > 0 then
  for _, v in ipairs(trappedViolations) do
    table.insert(T.errors, "LEAKED GLOBAL: " .. v)
  end
end

-- 3. Strict Lua 5.0 compatibility scan
local function stripLua(src)
  local out, i, n = {}, 1, string.len(src)
  while i <= n do
    local c = string.sub(src, i, i)
    local two = string.sub(src, i, i + 1)
    if two == "--" then
      if string.sub(src, i, i + 3) == "--[[" then
        local e = string.find(src, "]]", i + 4, true)
        i = (e and (e + 2)) or (n + 1)
      else
        local e = string.find(src, "\n", i, true)
        i = (e and (e + 1)) or (n + 1)
      end
      table.insert(out, "\n")
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = string.sub(src, j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      i = j + 1
      table.insert(out, '""')
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return table.concat(out)
end

local lua50Banned = {
  { pat = "#[%a_({\"']", msg = "# length operator (unsupported in 5.0)" },
  { pat = "[^%s~=<>]%s+%%%s+[^%s=]", msg = "% modulo operator (use math.mod / Util.Mod)" },
  { pat = "//", msg = "// integer division" },
  { pat = "%f[%a]goto%f[%A]", msg = "goto statement" },
  { pat = "::", msg = "::label:: syntax" },
  { pat = "table%.unpack%f[^%s]", msg = "table.unpack (5.0 uses unpack)" },
  { pat = "string%.gmatch%f[^%s]", msg = "bare string.gmatch (use Gfind or fallback idiom)" },
  { pat = "math%.huge", msg = "math.huge (unsupported in 5.0)" },
  { pat = "%f[%a]metaLine:gsub", msg = "string method call without metatable" },
}

local violations50 = 0
for _, f in ipairs(shippedFiles) do
  local fh = io.open(f, "r")
  if not fh then
    T.fail = T.fail + 1
    table.insert(T.errors, "UNREADABLE: " .. f)
  else
    local code = stripLua(fh:read("*a"))
    fh:close()
    for _, rule in ipairs(lua50Banned) do
      if string.find(code, rule.pat) then
        violations50 = violations50 + 1
        table.insert(T.errors, "LUA 5.0 VIOLATION in " .. f .. ": " .. rule.msg)
      end
    end
  end
end

eq(violations50, 0, "zero Lua 5.0 engine violations")

if T.fail == 0 then
  print("global pollution trap passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
