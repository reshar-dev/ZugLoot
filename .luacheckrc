-- ZugLoot/.luacheckrc — WoW 1.12 (Lua 5.0) lint baseline.
-- The stock lua51 std knows nothing about the WoW client API, so every
-- client-provided global used by the addon is declared below. Keep the
-- 11x (undefined-global) warnings STRICT: a typo in a global name is a
-- silent nil on the client (e.g. the LootWindow clickSlot closure bug).
-- Intentional exceptions live here, not scattered:
--   * `_`-prefixed args/locals: callback signatures we must match
--     (OnEvent, pcall result lists) or API parity (HandleClick._name).
--   * compat shims: Util.lua polyfills string.match/string.gmatch for
--     strict 5.0 clients; Resolver/MainWindow probe math.mod with a
--     5.1+ fallback; SRData/SRImport read string.gfind directly.
--     These trip W122/W143 by design.
--   * line length is NOT gated: the codebase wraps at prose width, not
--     120 cols (UI copy + long links); gating it would be ~80 lines of
--     churn for no signal.
std = "lua51"
max_line_length = false
allow_defined = true
-- Local git worktrees (git-ignored checkouts); each lints itself in CI.
exclude_files = { "worktrees/**" }
ignore = { "211/_.*", "212/_.*" }
-- Shared by read_globals (addon: client provides) and tests/mockrun
-- globals (harness: tests rebind). Single list so the two can't drift.
local wow = {
  -- WoW 1.12 client API (provided in-game; stubbed by tests/).
  "CreateFrame", "UIParent", "DEFAULT_CHAT_FRAME", "GameTooltip",
  "GameFontHighlightSmall", "ChatFrameEditBox", "Minimap", "LootSlot",
  "LootFrame", "UIFrameFadeIn", "MouseIsOver",
  -- 1.12 FauxScrollFrame template API (remembered list).
  "FauxScrollFrame_Update", "FauxScrollFrame_OnVerticalScroll",
  "FauxScrollFrame_GetOffset",
  "IsShiftKeyDown", "IsControlKeyDown",
  "SendChatMessage", "SendAddonMessage", "RandomRoll",
  "UnitName", "UnitClass", "UnitExists", "UnitIsPartyLeader",
  "UnitClassification", "UnitHealthMax",
  "GetNumRaidMembers", "GetNumPartyMembers", "GetRaidRosterInfo",
  "GetLootMethod", "GetLootMaster", "GetLootThreshold",
  "GetLootSlotInfo", "GetLootSlotLink", "GetLootSlotType",
  "GetNumLootItems", "GetItemInfo", "GetItemQualityColor",
  "GetLootRollItemLink", "GetLootRollTimeLeft", "GetUnitSpeed",
  "UnitPosition", "UnitDistanceSquared", "FocusUnit", "TargetUnit",
  "ClearTarget", "UnitIsDead", "UnitIsUnit", "UnitCanAttack",
  "UnitChannelInfo", "UnitCastingInfo", "UnitIsDeadOrGhost",
  "UnitAffectingCombat", "GetNetStats",
  "GetMasterLootCandidate", "GiveMasterLoot",
  "SetLootMethod", "SetLootThreshold", "SetRaidTargetIconTexture",
  "ConfirmLootSlot", "CloseLoot", "RollOnLoot",
  "LootSlotIsCoin", "LootSlotIsItem", "LOOT_SLOT_MONEY",
  "GetTime", "GetCursorPosition", "GetScreenWidth", "GetScreenHeight",
  "DressUpItemLink", "CheckInteractDistance",
  "IsRaidLeader", "IsRaidOfficer", "IsPartyLeader",
  "getglobal", "event", "arg1", "arg2", "arg3", "arg4",
  -- Nampower custom-file lib + its `date` global (Turtle WoW).
  "ReadCustomFile", "WriteCustomFile", "CustomFileExists", "date",
  "Base64Encode", "Base64Decode",
  -- Optional dependency (Atlas-CFM loot tables), probed, never required.
  "AtlasCFM",
  -- ClassicAPI DLL tables (probed, never required): loot engine +
  -- cast mirrors + timer + event-validity. Absent without the DLL.
  "C_Loot", "C_Spell", "C_Timer", "C_EventUtils",
  -- 5.0-compat probes: absent on 5.1+, present on the 1.12 client.
  -- (Util.lua polyfills string.match/string.gmatch when missing.)
  "math.mod", "string.gfind", "table.unpack",
}
-- Test-rigged stdlib fields (deterministic seeds, 5.0 shims).
local rigged = {
  "math.mod", "math.random", "string.match", "string.gmatch",
  "string.gfind",
}
read_globals = wow
globals = {
  -- Addon-owned namespaces and slash-command registration.
  "ZugLoot", "ZugLootDB", "ZugLootCharDB",
  "SLASH_ZUGLOOT1", "SLASH_ZUGLOOT2", "SlashCmdList",
  -- WoW-owned table the addon legitimately extends (award dialog).
  "StaticPopupDialogs", "StaticPopup_Show",
}
files["tests/*.lua"] = {
  -- Test stubs rebind client globals (GetItemInfo = function...) and
  -- rig math.random / string.gfind for determinism; mockrun probes
  -- math.mod. Callback-signature stubs keep unused args (212).
  ignore = { "211/_.*", "212", "212/_.*" },
  globals = (function()
    local g = {
      "ZugLoot", "ZugLootDB", "ZugLootCharDB",
      "SLASH_ZUGLOOT1", "SLASH_ZUGLOOT2", "SlashCmdList",
      "StaticPopupDialogs", "StaticPopup_Show",
    }
    for _, v in ipairs(wow) do g[#g + 1] = v end
    for _, v in ipairs(rigged) do g[#g + 1] = v end
    return g
  end)(),
}
files["tests/wow_mock.lua"] = {
  -- Legacy shim, currently unloaded (SPEC: "if needed"). The client
  -- would read these globals, so unused-global warnings don't apply.
  ignore = { "131" },
}
files["tests/mockrun.lua"] = {
  -- Headless client harness: hundreds of one-line frame stubs whose
  -- colon-methods bind an unused `self`, plus intentional field
  -- shadowing in the fake widget tree. Undefined-global checks stay on.
  -- (Same writable globals as tests/*.lua above; luacheck applies the
  -- most-specific files[] block, it does not merge them.)
  ignore = { "211/_.*", "212", "212/_.*", "421", "431", "432" },
  globals = files["tests/*.lua"].globals,
}
