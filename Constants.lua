-- ZugLoot/Constants.lua
-- Shared constants: version, comm prefix, roll caps, colors.
ZugLoot = ZugLoot or {}
ZugLoot.VERSION = "0.2.4"
ZugLoot.PREFIX = "ZugLoot"

ZugLoot.Caps = {
  SR = 100,
  MS = 100,
  OS = 99,
  TMOG = 98,
}

ZugLoot.RollType = {
  SR = "SR",
  MS = "MS",
  OS = "OS",
  TMOG = "TMOG",
}

-- LootBlare-parity roll list colors (hex w/o alpha edge cases handled by callers).
ZugLoot.Colors = {
  SR = "ffe5302d",
  MS = "FFFFFF00",
  OS = "FF00FF00",
  TM = "FF00FFFF",
  GOLD = "FFFFD700",
  GREY = "FF888888",
  GREEN = "FF00FF00",
  YELLOW = "FFFFFF00",
  RED = "FFFF0000",
}

ZugLoot.Limits = {
  DROP_LOG_MAX = 500,
  ROLL_TIMEOUT_DEFAULT = 15,
  -- Quality numbers only exist for items; coin is handled separately.
  -- GetLootThreshold() returns the PARTY's roll threshold (2 green .. 4
  -- epic); items BELOW it never enter a group roll — plain LootSlot takes
  -- them. Default mirrors the client default threshold (uncommon).
  LOOT_THRESHOLD_DEFAULT = 2,
}

-- Bundled display faces (Media/, OFL). Client loads them by addon path;
-- pcall all SetFont call sites (a missing file must fall back clean).
ZugLoot.Fonts = {
  -- Griffy: fantasy display face — minimap ZL badge + main-window brand.
  DISPLAY = "Interface\\AddOns\\ZugLoot\\Media\\Griffy-Regular.ttf",
}
