-- tests/run_tests.lua — stock-lua runner. Usage: lua tests/run_tests.lua (cwd = ZugLoot/)
local totalPass, totalFail = 0, 0
local function run(file)
  local chunk, err = loadfile("tests/" .. file)
  if not chunk then
    print("LOAD FAIL " .. file .. ": " .. tostring(err))
    totalFail = totalFail + 1
    return
  end
  -- Each test file expects cwd files Util.lua etc.; set package path + cwd.
  local ok, T = pcall(chunk)
  if not ok then
    print("RUN FAIL " .. file .. ": " .. tostring(T))
    totalFail = totalFail + 1
    return
  end
  totalPass = totalPass + (T.pass or 0)
  totalFail = totalFail + (T.fail or 0)
  for _, e in ipairs(T.errors or {}) do print(e) end
  print(string.format("%s: %d passed, %d failed", file, T.pass or 0, T.fail or 0))
end

-- Tests dofile() sibling pure modules, so run them with cwd = addon root.
run("test_util.lua")
run("test_pysanka.lua")
run("test_srdata.lua")
run("test_resolver.lua")
run("test_security.lua")
run("test_itemcards.lua")
run("test_itemicon.lua")
run("test_sim.lua")
run("test_reset.lua")
run("test_raids.lua")
run("test_window_size.lua")
run("test_timer.lua")
run("test_classcolors.lua")
run("test_colors_in_chat.lua")
run("test_versiongrid.lua")
run("test_help.lua")
run("test_minimap.lua")
run("test_settings_reset.lua")
run("test_mlflow.lua")
run("test_sand.lua")
run("test_lootwindow.lua")
run("test_threshold.lua")
run("test_atlasloot.lua")
run("test_network_mtu_throttle.lua")
run("test_corpse_slot_shift.lua")
run("test_fuzz_deserialization.lua")
run("test_memory_churn_bounds.lua")
run("test_global_guard.lua")

-- Mock-client UI run: executes MainWindow Build + all tab renders under a
-- fake 1.12 frame API to catch typos/nil-globals outside the client.
print("--- mock UI run --")
local mchunk, merr = loadfile("tests/mockrun.lua")
if not mchunk then
  print("LOAD FAIL mockrun.lua: " .. tostring(merr))
  totalFail = totalFail + 1
else
  local mok, merr2 = pcall(mchunk)
  if not mok then
    print("RUN FAIL mockrun.lua: " .. tostring(merr2))
    totalFail = totalFail + 1
  end
end

-- 5.0-syntax sanity: all shipped lua files must parse (loadfile without running).
local files = { "Constants.lua", "Util.lua", "Timer.lua", "ClassColors.lua", "SRData.lua", "Resolver.lua", "ItemCards.lua", "ItemIcon.lua", "SRView.lua",
  "SRSecurity.lua", "SRImport.lua", "Pysanka.lua", "MainWindow.lua", "Sim.lua", "MasterLootUI.lua",
  "RaidArchive.lua", "Comm.lua", "Core.lua", "LootWindow.lua", "AtlasLoot.lua", "RaiderLootUI.lua", "DropLog.lua", "VersionGrid.lua", "Minimap.lua" }
for _, f in ipairs(files) do
  local c, e = loadfile(f)
  if not c then print("PARSE FAIL " .. f .. ": " .. tostring(e)) totalFail = totalFail + 1
  else print("parse ok: " .. f) end
end

-- Lua 5.0 gate (the 1.12 client runs 5.0; this suite runs 5.5, which
-- accepts everything 5.0 rejects). Static scan of shipped files with
-- comments and string literals stripped: flags # (length op), % (modulo
-- op), // (int division), goto / ::labels::, bitwise ops, table.unpack,
-- and bare string.gmatch (5.0 only has string.gfind). A single hit is a
-- whole-file parse/runtime failure on the client — e.g. `#` in Core.lua
-- once killed /zl while the addon still showed in the addon list.
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
local fifty = {
  { pat = "#[%a_({\"']", msg = "# length operator" },
  { pat = "[^%s~=<>]%s+%%%s+[^%s=]", msg = "% modulo operator (use math.mod)" },
  { pat = "//", msg = "// integer division" },
  { pat = "%f[%a]goto%f[%A]", msg = "goto" },
  { pat = "::", msg = "::label::" },
  { pat = "table%.unpack%f[^%s]", msg = "table.unpack (5.0: global unpack)" },
  -- NOTE: `string.gmatch or string.gfind` fallback idiom is SAFE and
  -- allowed; only a bare call is flagged. The pattern below requires
  -- the match NOT to be followed by ` or `.
  { pat = "string%.gmatch%f[^%s]", msg = "bare string.gmatch (5.0: string.gfind)" },
  { pat = "%f[%A]~%f[%A]", msg = "~ bitwise op" },
  { pat = "<<", msg = "<< bitwise op" },
  { pat = ">>", msg = ">> bitwise op" },
}
local gateFail = 0
for _, f in ipairs(files) do
  local fh = io.open(f, "r")
  if not fh then print("GATE FAIL " .. f .. ": unreadable") gateFail = gateFail + 1
  else
    local code = stripLua(fh:read("*a"))
    fh:close()
    for _, g in ipairs(fifty) do
      local at = string.find(code, g.pat)
      if at then
        local line = 1
        for _ in string.gmatch(string.sub(code, 1, at), "\n") do line = line + 1 end
        print("GATE FAIL " .. f .. ":" .. line .. ": " .. g.msg)
        gateFail = gateFail + 1
      end
    end
  end
end
if gateFail == 0 then print("lua50 gate: clean") end
totalFail = totalFail + gateFail

print(string.format("TOTAL: %d passed, %d failed", totalPass, totalFail))
if totalFail > 0 then os.exit(1) end
print("All tests passed.")
