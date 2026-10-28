-- ZugLoot/RollList.lua
-- ONE roll-list view used by both frames: the raider roll window
-- (RaiderLootUI) and the master-looter detail (LootWindow). Same
-- grouping, same colors, same range text — a roll looks identical
-- whichever window shows it.
--
-- Data in (either shape — normalized here):
--   raider: { player, roll, rtype, min, max, excluded, class }
--   ML:     { name, roll, rollType, effective, min, max }
-- Pure + nil-safe: no WoW API at load; frames only touch SetText.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.RollList = M

M.GROUP_ORDER = { "SR", "MS", "OS", "TMOG" }

-- Fallback class colors when ClassColors is absent (tests load standalone).
local FALLBACK_COLORS = {
  ["Warrior"] = "FFC79C6E",
  ["Mage"]    = "FF69CCF0",
  ["Rogue"]   = "FFFFF569",
  ["Druid"]   = "FFFF7D0A",
  ["Hunter"]  = "FFABD473",
  ["Shaman"]  = "FF0070DE",
  ["Priest"]  = "FFFFFFFF",
  ["Warlock"] = "FF9482C9",
  ["Paladin"] = "FFF58CBA",
}

-- Kind colors (the dice colors): SR red, MS yellow, OS green, TMOG cyan.
local TYPE_COLORS = {
  ["SR"]   = "ffe5302d",
  ["MS"]   = "FFFFFF00",
  ["OS"]   = "FF00FF00",
  ["TMOG"] = "FF00FFFF",
}

function M.ClassHex(name, class)
  if Z.ClassColors and Z.ClassColors.ClassColorHex then
    if class then
      return Z.ClassColors.ClassColorHex(class)
    end
    local c = Z.ClassColors.ClassOf and Z.ClassColors.ClassOf(name) or nil
    return Z.ClassColors.ClassColorHex(c)
  end
  return FALLBACK_COLORS[class] or "FFFFFFFF"
end

function M.TypeHex(rtype)
  return TYPE_COLORS[rtype] or "FFFFFFFF"
end

-- Normalize one row to { name, roll, rtype, effective, sr_plus, min, max,
-- excluded, class }. Missing max falls back to the kind cap.
function M.Normalize(r)
  r = r or {}
  local rtype = r.rtype or r.rollType or "MS"
  local max = r.max
  if max == nil then
    if Z.MasterLootUI and Z.MasterLootUI.RollCap then
      max = Z.MasterLootUI.RollCap(rtype)
    elseif rtype == "OS" then max = 99
    elseif rtype == "TMOG" then max = 98
    else max = 100 end
  end
  return {
    name = r.name or r.player,
    roll = r.roll,
    rtype = rtype,
    rollType = rtype, -- alias: ML rows carry rollType, raider rows rtype
    effective = r.effective,
    sr_plus = r.sr_plus,
    min = r.min or r.minR or 1,
    max = max,
    excluded = r.excluded,
    class = r.class,
  }
end

-- "56/98" for a roll, with " (+10=100)" when an SR bonus applies
-- (bonus first, then the total). Min is always 1 by construction (all
-- ranges are 1-X), so max alone carries the range.
function M.RangeText(r)
  local n = M.Normalize(r)
  local s = tostring(n.roll)
  if n.max ~= nil then s = s .. "/" .. tostring(n.max) end
  local bonus = tonumber(n.sr_plus) or 0
  if bonus > 0 then
    s = s .. " (+" .. bonus .. "=" .. tostring(n.effective or n.roll) .. ")"
  elseif n.effective ~= nil and n.effective ~= n.roll then
    s = s .. " (=" .. tostring(n.effective) .. ")"
  end
  return s
end

-- Sort rows for display: SR > MS > OS > TMOG, best roll first within a
-- group, name tiebreak. Pure: returns a new array, input untouched.
function M.SortedRolls(rolls)
  -- Kind order lives on M.GROUP_ORDER (single source of truth).
  local normed = {}
  for i = 1, Z.Util.ArrayCount(rolls or {}) do
    if rolls[i] then table.insert(normed, M.Normalize(rolls[i])) end
  end
  -- Group first (stable kind blocks), then best-first within each.
  local groups = { SR = {}, MS = {}, OS = {}, TMOG = {} }
  local other = {}
  for i = 1, Z.Util.ArrayCount(normed) do
    local r = normed[i]
    if groups[r.rtype] then table.insert(groups[r.rtype], r)
    else table.insert(other, r) end
  end
  local out = {}
  for _, key in ipairs(M.GROUP_ORDER) do
    local g = groups[key]
    table.sort(g, function(a, b)
      if (a.effective or a.roll or 0) ~= (b.effective or b.roll or 0) then
        return (a.effective or a.roll or 0) > (b.effective or b.roll or 0)
      end
      return (a.name or "") < (b.name or "")
    end)
    for i = 1, Z.Util.ArrayCount(g) do table.insert(out, g[i]) end
  end
  for i = 1, Z.Util.ArrayCount(other) do table.insert(out, other[i]) end
  return out
end

-- Paint the two-column list: class-colored names left, kind-colored
-- "roll/max" right. Excluded (already-won) rows grey out with a "won"
-- tag. opts: { maxRows } (nil = all), { waiting } (empty-list text, or
-- nil for blank). Nil-safe: missing widgets are skipped.
function M.Paint(leftFS, rightFS, rolls, opts)
  opts = opts or {}
  if not leftFS and not rightFS then return end
  local rows = M.SortedRolls(rolls)
  local left, right = {}, {}
  local maxRows = opts.maxRows
  for i = 1, Z.Util.ArrayCount(rows) do
    if maxRows and i > maxRows then break end
    local r = rows[i]
    local nm = string.sub(tostring(r.name or "?"), 1, 15)
    if r.excluded then
      table.insert(left, "|cff888888" .. nm .. "|r")
      table.insert(right, "|cff888888" .. tostring(r.roll)
        .. "/" .. tostring(r.max) .. " won|r")
    else
      table.insert(left, "|c" .. M.ClassHex(r.name, r.class) .. nm .. "|r")
      table.insert(right, "|c" .. M.TypeHex(r.rtype)
        .. M.RangeText(r) .. "|r")
    end
  end
  if Z.Util.ArrayCount(rows) == 0 and opts.waiting then
    if leftFS and leftFS.SetText then leftFS:SetText(opts.waiting) end
    if rightFS and rightFS.SetText then rightFS:SetText("") end
    return
  end
  if leftFS and leftFS.SetText then leftFS:SetText(table.concat(left, "\n")) end
  if rightFS and rightFS.SetText then rightFS:SetText(table.concat(right, "\n")) end
end

if ZugLoot then ZugLoot.RollList = M end
return M
