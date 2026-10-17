# ZugLoot — Specification (v0.1 skeleton)

Loot addon for Turtle WoW (1.12, Interface 11200) for **both master looters and raiders**.
Inspiration: **RollFor** (master-looter automation, SR integration, version broadcast,
tie handling, raid-roll) and **LootBlare** (big obvious raider frame, SR/MS/OS/TMOG
buttons with roll caps, raid-warning triggered rolls).

## 1. Goals / non-goals

Goals:

- One addon, two faces: a **master-looter console** (RollFor-like) and a **raider
  loot window** (LootBlare-like, incl. group-loot display).
- **SR sheets**: import, secure distribution, SR+ math, fancy in-game sheet view,
  one-win-per-item enforcement, drop log.
- **Auto-roll + auto-resolve**: raiders can auto-roll SR items; if the whole raid
  runs ZugLoot the ML can auto-resolve SR drops without waiting on chat rolls.
- **Visibility**: raid-wide version grid (squares), drop log, simulation mode.
- **Testability**: pure loot logic (parse / resolve) runs both in-game and under
  stock `lua` outside the client (`tests/`).

Non-goals (skeleton): DKP/EPGP, full boss loot database for every raid, LibStub
dependencies, minimap button art. These are extension points, not blockers.

## 2. Roles & security

| Role | How detected (1.12 APIs) | Powers |
|------|--------------------------|--------|
| Loot runner (anyone) | whoever opens the corpse — solo, any loot method, ML or not | Collect loot, start/finish/cancel rolls, award loot |
| Master Looter (ML) | `GetLootMethod()` returns `"master"` + `GetLootMaster()` == player | As loot runner, plus group-chat announces + `ROLL_REQ` to rollers |
| Raid leader / assistant | `IsRaidLeader()` / `IsRaidOfficer()` (fallback: party leader) | Import + broadcast sheet (same as ML) |
| Raider | everyone else | View sheet, roll, auto-roll, sim |

Rules:

1. **Only ML or raid leader/assistant may broadcast a sheet.** This is enforced
   *twice*:
   - sender side: `SRSecurity.CanBroadcast()` gates sending; `ApplySheet` only
     broadcasts when it is true;
   - receiver side: `Comm.OnSheetReceived` verifies the sender `IsML(sender) or
     IsRaidLeaderOrAssistant(sender)` against the *current* roster and drops +
     warns on violation.
1b. **Anyone may load a sheet locally** (paste or `Load from File`, solo or
grouped) for their own view/sim — importing never pushes anything.
Broadcasting stays ML/leader-only (`CanBroadcast()`); synced sheets are
trusted from ML/leader only (`CanAcceptFrom()`). No broadcast happens solo
(`Comm.Channel()` is nil there; `VER_REQ`/`AWARD` also skip).
2. Sheet broadcasts carry `raidID` (= leader name + import timestamp), `version`,
   and a META envelope (raid name + revision stamp). Same-raid updates keep
   the raidID and apply by revision (`importedAt`: raidres export time, else
   import time) — older-or-equal revisions are stale and refused on ALL paths
   (paste, file, sync), BEFORE archiving, so an old export can never roll a
   newer update back. Different raidIDs always apply.
3. Raiders get a **read-only** copy. There is no addon-message path for a raider to
   push sheet edits.
4. Comm prefix: `ZugLoot` (chat addon channel `CHAT_MSG_ADDON`). Message types:
   `SHEET:<ver>:<raidID>:<payload>`, `ROLL_REQ:<sessionID>:<itemLink>:<mode>`,
   `ROLL_ANS:<sessionID>:<name>:<rollType>`, `VER_REQ`, `VER_ANS:<version>`,
   `AWARD:<itemID>:<winner>`, `LOG:<entry>`.

## 3. SR sheet model

```lua
Sheet = {
  meta    = { raidID = "Leader-epoch", raidName = "Molten Core"|nil, importedAt = 0, importedBy = "Name", source = "paste|file" },
  items   = { [itemID] = { quality = 4, rollers = { { name="X", rolls=2, sr_plus=30 }, ... } } },
  hardres = { [itemID] = { quality = 5 } },
  won     = { [itemID] = { ["PlayerName"] = true } },  -- one copy per player per raid
}
```

- `rolls` = how many times the player SR'd that item (duplicate reservations count,
  e.g. `x2`). Displayed as `Name x2`.
- `sr_plus` = highest SR+ bonus across that player's duplicate reservations for the
  item (RollFor parity: keep `max`, never sum). `nil/0` = no bonus.
- `won` is runtime-only (per raid, cleared on new sheet / `/zl reset`). It is what
  powers "won items are visible but marked; that raider can't win another copy".
- `raidName` = instance name from the raidres export (`metadata.instances[1]`,
  else `metadata.instance`); nil for hand-written line sheets. Shown in the
  window header next to the ID.
- `importedAt` = import timestamp = the raid's start time for display and
  raid-list ordering (see Raids tab).

### 3.1 Supported import formats

1. **raidres.top / raidres.fly.dev / softres.it export** (paste path): base64-encoded
   JSON with any of `reservations[]` (new: `character.name`, `raidItemId`,
   `srPlus` as number|string|`{value,isValid}`), `softreserves[]`
   (`name/role/items[{id,quality,sr_plus}]`), `hardreserves[]`. `sr_plus` also
   accepts `rollBonus`/`roll_bonus` (softres.it). Numeric strings coerced.
   `isValid=false` still counts (raidres defaults it to false when validation is
   off) — value is what matters.
2. **Static file** (`CustomData/ZugLoot_SR.txt`, via Load from File): accepts
   *either* a raw raidres export blob pasted into the file (base64, exactly
   what raidres.top gives you), the CSV export below, *or* the static line
   format. Paste-import accepts all three as well; format is auto-detected
   (export first, CSV second, lines third). Lines above the payload
   (tool headers, "copy below this line" notes) are dropped for the
   export and CSV formats.
3. **Static line format** (hand-written sheets, either path):
   `#` comments, blank lines ignored.
   ```
   # Player; itemID[:count][: +srplus], ...
   Blackfang; 17063:2+20, 19137:1
   Carbon; 18646:1+60
   HARDRES; 17782, 18564
   ```
   Grammar per entry: `itemID` (required number), `:count` (default 1),
   `+srplus` (default 0). `HARDRES;` line lists hard-reserved item IDs.
4. **CSV export** (either path): header-matched, so column order and extra
   columns (`Item`, `Boss`, `Comment`, `Date`) don't matter. Minimum
   columns: `ID` (+`Attendee`); minimum per row: numeric ID + non-empty
   attendee (other rows skipped). `Class` feeds the sheet class store
   (unknown still imports, just uncolored); `Specialization` is optional
   (missing = class-default role); `SR+` defaults to 0. Header aliases:
   `ID`/`ItemID`, `Attendee`/`Player`/`Name`/`Character`/`Raider`,
   `Specialization`/`Spec`, `SR+`/`SRPlus`. Lines above the header
   (preamble) are dropped.
   ```
   ID,Item,Boss,Attendee,Class,Specialization,SR+
   18814,"Choker of the Fire Lord",Ragnaros,Pysanka,Paladin,Protection,70
   ```
   STRICT, all-or-nothing: every data row must carry a numeric item ID +
   non-empty attendee. ONE bad row blocks the WHOLE import with its line
   number (e.g. `CSV line 4: missing numeric item ID (got 'Choker ...'
   for attendee 'Pysanka')`) — never half-imports, never a silent
   0-item sheet. Header with zero data rows below it is likewise a loud
   error. Blank lines / `#` comments are ignored, not rows.
5. Anything else → import error naming the first bad line (never half-imports).
6. **Empty-content sheets never move.** A sheet with 0 items and no hard
   reserves is refused at every boundary, live data kept: `ApplySheet`
   (import) refuses before stamping/archiving, `BroadcastSheet` refuses
   before sending, `ApplyReceivedSheet` ignores an empty wire, and
   `AnySheet` treats an empty holder as sheetless (no sync answer).

### 3.2 Roll types (normative): each kind judged by itself

- Ranges (LootBlare parity): SR 1–100, MS 1–100, OS 1–99, TMOG 1–98.
  A roll only counts inside its own range — anything above the TYPE cap is
  an over-roll (flagged, never wins). `effective = base + sr_plus`, where
  the SR bonus applies to SR rolls by sheet rollers ONLY (MS/OS/TMOG never
  take sr_plus).
- Each kind crowns its own winner (`perType`: best SR, best MS, best OS,
  best TMOG) from the RANGE the player chose — 1-100 is SR only with the
  reserve on the item, otherwise MS; 1-99 OS; 1-98 TMOG. Ties re-roll
  WITHIN the kind.
- Overall winner by priority SR > MS > OS: the best SR beats any MS/OS
  roll (TMOG 15 vs SR 58 → SR wins outright). TMOG never takes an overall
  winner slot — it crowns its own kind winner, directly awardable.
- Miss-rolls = SR-range rolls from players WITHOUT the reserve (fake SR
  claims): recorded but ignored. MS/OS rolls are valid kind contests from
  anyone (the sheet only holds SR rollers); TMOG never misses.
- Eligible = not already in `won[itemID]` — for the SR contest ONLY
  (one-win-per-item; excluded SR rolls stay visible with `[already won]`,
  never silently dropped). MS/OS/TMOG stay contestable after a win (e.g.
  rolling transmog after winning mainspec).
- Multi-SR allowance: a player who SR'd the item N times (`rolls`, e.g.
  `x2`) may roll up to N times in one session; their best roll stands.
  Extra rolls are extra chances, never extra winners: a player's own
  rolls never tie against each other, and anything past the allowance is
  ignored. Non-holders roll once.
- Off-sheet rolls (no holders on the item): same single path - kind
  priority SR > MS > OS, with an empty SR contest. An MS 33 beats an
  OS 76 even with nobody holding SR; OS wins only with no MS contest.
- Two-copies drops (`2x<link>`): winner + runner-up (same kind first, then
  other kinds in priority order).
- TMOG is directly awardable: the award window offers `Award <name> (TMOG)`
  for the kind winner next to the outright winner rows. The ML awards the
  SR, MS, OS or TMOG winner; anything after the award (e.g. a trade) is
  outside the addon. Chat follows the raid-roll style (Pysanka parity):
  one `Name: roll (TYPE)` line per roller (already-won tagged inline),
  then `Name wins Item.` on award.
- Raid-roll (loot `Raid roll` button — RollFor +
  Pysanka parity): the raid is announced numbered (`[1]:Name, ...`,
  chunked), the ML rolls 1-N with `/roll`, the number IS the winner
  (frozen roster, so leavers/joiners mid-roll change nothing; only the
  ML's 1-N roll counts, first number only). The item goes straight out
  on the number — no award window. Finish/award reuse the
  normal path, including the award line.
- Sand (loot `Sand` button, Hourglass Sand item 19183 only): the
  lowest-ledger raider takes the row via the master-loot handoff, no
  roll, no award window. Ledger `Z.DB.sand` (`{ [name] = count }`)
  tracks running totals per raider so sand evens out over the raid;
  one corpse slot = one handoff of the whole stack. Never touches the
  SR sheet (no SR, no won mark, no roll history) — DropLog records it
  as `sand`. `/zl sand` prints the ledger, `/zl sand reset` clears it
  (solo always; in group ML/leader only).
- One-win-per-item: after award, `won[itemID][winner]=true`. Sheet view renders
  `WON: Name`; the resolver excludes them from later SR contests for that itemID.
  Excluded rollers stay visible everywhere: their rolls are kept in a separate
  `excluded` list (never silently dropped), shown with an `[already won]` tag in
  the raid result line, the live raider roll list (greyed), sim output, and the
  Sheet tab history lines (`Resolver.ToHistoryEntry` carries them into
  `sheet.rolls`).

### 3.3 Unreserved drops (not on the sheet)

— When a finished roll (live or sim) had rolls for an itemID absent
  from `sheet.items`, a stub `{ quality, rollers = {}, unsr = true }` is added
  via `SRData.EnsureUnreserved` — never touching existing entries, so real SR
  data can't be clobbered. Empty sessions (no rolls) add nothing.
- **Sheet log floor (rare 3+ only)**: roll history, unreserved stubs,
  and won marks only ever cover rare (blue) and above — anything below
  never enters the sheet (`SRData.SHEET_QUALITY_MIN = 3`, enforced via
  `SRData.LoggableQuality` at every roll-session write: `AnnounceResult`
  history + stubs, `Award` won marks, `AWARD` receive won marks).
  Unknown quality (cold item cache, no row) proceeds — it can't be
  classified, so nothing is lost. Quality 0 counts as unknown: poor
  items are always free rows and can never roll. Imports are user data
  and are never filtered.
- Cards: unreserved items render at the **bottom** of the Sheet tab
  (`SRData.SortedCardIDs`: SR'd numeric first, stubs last), with a grey
  `[not SR'd]` title badge and a `(not on SR sheet — open roll)` body line.
  `CardSummary` / `SRView.RenderText` tag them `[not SR'd]` too.
- Stubs are local roll artifacts: `SerializeSheet` emits no lines for
  them (empty rollers), so they never pollute broadcasts; roll-log reset
  prunes them (`PruneUnreserved`) and the sheet returns to imported state.

## 4. UI

### 4.1 Main window (`MainWindow.lua`) — both roles, Aegis-SBR-skinned

- `/zl sheet` opens the big tabbed window (900×640 target, clamped to screen
  minus margins, min 480×360, re-clamped + rebuilt on resolution/UI-scale
  change, clamped-to-screen dragging; movable, flat dark palette,
  gold accent strip, tab rail with gold underline on the active tab, per-tab
  scroll bodies with scrollbar + mouse wheel). Tabs: **Sheet** (default) |
  **Raids** | **Members** | **Setup**. `/zl log` prints the drop log to
  chat, `/zl ver` opens Members, `/zl raids` opens Raids. Header row:
  Reset rolls | Get sheet (always visible; solo prints “nobody to ask”) | Import | File —
  Setup holds options only (no duplicate import/clear buttons). (`SRView`/
  `VersionGrid` standalone frames retired into tabs; their modules keep
  pure logic + slash commands. DropLog has no tab: `Show()` prints.)
- Minimap ZL badge (`Minimap.lua`, `Media/ZL-Badge.tga` — one
  prerendered image: feathered black disc + Griffy gold `ZL` + halo,
  ink centered by measured bbox at bake time; no FontStrings, so client
  font/anchor drift can't move the letters): click toggles the main
  window, hover shows version/raid/role, drag repositions (angle
  persisted per character). Classic tracking ring tinted gold on top.
- **Brand**: the `ZUGLOOT` header uses the same bundled Griffy face
  (`Z.Fonts.DISPLAY`, pcall-guarded with template-font fallback), gold
  on the dark header — badge and window read as one identity.
- **Sheet tab**, one card per item in **3 even columns** (row-major flow,
  single shared scroll body — columns scroll together; card styling
  unchanged): SR rollers in **two columns** inside each card, drop count as
  a green `[xN]` badge, **left-click opens the item roll-log window** (loot
  icon + name header, every roll newest-first): SR'd items alphabetical
  by name (client cache, else sheet name, else item:id fallback; numeric
  ids break ties),
  unreserved items (rolled but never SR'd — auto-added at the bottom, see §3.3):
  - icon button (texture via `GetItemInfo(tonumber(id))` numeric-ID trick, cf.
    LootBlare fix #8; quality-color bottom border). **Hover = full GameTooltip
    item details** (`SetHyperlink` when the client knows the item, fallback
    text otherwise). Click inserts the link into an open chat box,
    ctrl-click tries it on (DressUp). All five item icons in the addon
    (sheet cards, log header, raider window, loot rows, loot detail) run
    the ONE shared implementation (`ItemIcon.lua`), so hover/ctrl/shift
    behave identically everywhere.
  - title: quality-colored name + `[HR]` tag + green `[rolled xN]` badge +
    grey `[not SR'd]` badge for unreserved items.
  - SR list: `Name xN (+SR+)` (SR+ in gold), `[WON]` marks for already-won.
  - roll history: every finished roll this raid as its own block
    (`— rolls #k (mode) => winners`), **one line per player**:
    `Carbon 95(+130=225)` with `WINNER:` prefix, `[miss — no SR]` /
    `[already won]` flags where applicable.
  - zebra rows; row hover tooltip summarizes SR/HR + roll state.
- Card data comes from pure `ItemCards.BuildCards(sheet)` (tested); roll
  rolls persist in `sheet.rolls[itemID]` (capped at 25/item), recorded by
  `MasterLootUI.AnnounceResult` for every finished roll.
- Header: brand row carries a prominent green `ACTIVE RAID: <name> | started
  <date>` (grey `no active raid` when no sheet; name "—" for line sheets
  without instance info); sub-line `ID <raidID> | <raid name> | started <date>
  | N items | M rolled`. Setup tab: Import (paste),
  Load from File, auto-roll toggle, clear won marks, **Reset all settings**
  (factory reset with confirmation: sheet, raid history, drop log and all
  options back to defaults; local data only, no permission gate),
  auto loot-method switching (**ML on boss**: as raid leader, flip
  to master loot when selecting a raid boss — worldboss flag or 100k+ HP
  (indoor bosses report elite; raid trash never reaches 100k), raid only; **Boss
  threshold** dropdown (Common 1 .. Epic 4, default Epic) rides along
  with the switch, previous threshold remembered and restored on
  switch-back;
  **Back to group**: flip back to group loot once the boss is fully
  looted — only after OUR auto-switch, never yanks a manual change;
  both off by default), roll-time/log stats.
- **Raids tab**: imported raids with the **latest raid at the top**, ordered
  by raid datetime = the sheet's `meta.importedAt` import timestamp (the
  closest thing to a raid start time the sheet carries; `archivedAt` is only
  a fallback for legacy snapshots). Archive position never affects order, so
  re-archiving an old raid can't shuffle it above newer ones. The live sheet
  is always listed too (synced on load and on every render, so a just-loaded
  raid shows up even though it was never unloaded). Each row is titled with
  the raid name (+ green `[ACTIVE]` on the live one; "—" when unknown) and
  lists `ID <raidID>`, `started <date>`, importer, source, and counts
  (items / players / rolls / won). **Activate** makes a raid the live
  sheet and continues it — won marks + roll history come along, and the
  outgoing sheet is archived first so no progress is lost (`/zl raid <raidID>`
  does the same from chat). History lives in `ZugLootDB.raidArchive` (capped
  at 20, deduped by raidID); every import, incoming broadcast, and activation
  archives the outgoing sheet first (pure `RaidArchive` module, tested).

### 4.2 Loot console (`MasterLootUI.lua`) — RollFor-like, universal

- `/zl` shows console: loot list (current loot window items w/ SR badges + counts).
Rolls start from the loot-window Roll / Raid roll buttons only. Announce via
RAID_WARNING (LootBlare trigger compatibility) + `ROLL_REQ` addon message.
Accept chat `CHAT_MSG_SYSTEM` rolls (`X rolls Y (1-Z)`) while the roll
window is open, up to the player's SR allowance (one roll, or N rolls
for N reservations of the item); over-rolls flagged, ties
re-roll fresh. Exactly one roll at a time — closing its window ends it.
Raider clients pop their roll window off the ML/RL's RAID_WARNING roll
call ONLY (`MatchRollCall`: `Roll for <link>: /roll ...` dice line,
plain Pysanka name, or bare full link — Pysanka/LootBlare parity).
Drop lists, winners, countdowns, stop
lines, raid-roll numbering, bare names and non-ML senders never trigger
— links buried in those lines are ignored: only the roll-call shape pops.
- **Loot window** (`LootWindow.lua`, raider-window style (220px dark
  frame, icon + quality-colored name rows, roll detail with header icon
  + two-column roll list) — always ours, never Blizzard's): on
  `LOOT_OPENED`, whoever opened the corpse (solo, any loot method, ML or
  not), EVERY corpse slot gets a row (RollFor parity): coin first, then
  roll-worthy items (quality ≥ the party's `GetLootThreshold`, 1 common
  .. 4 epic), then below-threshold leftovers (grey quality 0 always) as
  one-click free rows that loot straight to the player in any loot method. Blizzard's `LootFrame`
  is DETACHED session-wide (RollFor `main.lua:on_player_login` parity:
  `UnregisterAllEvents` + `OnHide` stripped at `ADDON_LOADED`, re-armed
  per `LOOT_OPENED`) — one-shot hiding is NOT enough, FrameXML re-shows
  the frame on every loot — so our rows are the loot window in every
  looting situation. NOTHING falls back to Blizzard: coin/free rows loot
  their slot on click; grouped, roll rows open the detail, while SOLO every
  row loots on click (Blizzard solo behavior — nobody to roll against, so
  no detail opens). At/above the PARTY threshold (`GetLootThreshold`,
  1 common→4 epic): master-loot hands the item out via the roll window,
  group loot enters a real group roll — listed with a `ROLL` badge, click
  never loots (Blizzard's Need/Greed frames own them, mirrored in our dice
  frame which votes via `RollOnLoot`, never chat `/roll`); below it the
  item loots straight to the player (grey/white never roll). Slot quality comes from the slot's own
  `GetLootSlotInfo`, never the maybe-cold item cache. Click-to-loot is
  CONFIRM-driven, never optimistic: the click issues the corpse call and
  dims the row; the row drops only when `LOOT_SLOT_CLEARED` confirms the
  slot left the corpse — a failed call (locked slot, full bags, out of
  range) leaves the row up for retry, and a pcall-level blowup surfaces
  in chat instead of dimming the row into a "done but not looted" ghost.
  BoP takes confirm via `LOOT_BIND_CONFIRM` → `ConfirmLootSlot`.
  Kill-switch: two consecutive solo clicks that issue clean but never
  confirm (no `LOOT_SLOT_CLEARED`, no error) restore Blizzard's frame and
  stand our rows down to display-only (`passthrough`) — a dead `LootSlot`
  path must yield to the stock UI, never strand dimmed rows. Confirms,
  errors, and failed-but-present rescans all disarm the watch; awards
  never arm it; the watch is corpse-scoped (a new corpse starts clean).
  Corpse-open flag (`MasterLootUI.lootOpen`, true between `LOOT_OPENED`
  and `LOOT_CLOSED`): with no corpse open there is no call that can land.
  Clicks and live awards both check it FIRST — before range, before slot
  verify — and block with `"not looting"` / `"Not awarding <name>: no
  loot open"`, list + row untouched; re-looting resumes the window. This
  is what stops the walk-away wipe: the old code read an empty (closed)
  corpse as `"gone"` and rescanned every row away. Rescans with no open
  corpse likewise keep all rows (an unreadable corpse proves nothing
  left). Sim/non-row awards bypass the gate (no corpse).
  Range gate: "moved away" is read off `CheckInteractDistance("target",
  1)` against the corpse pinned at scan — by GUID when the client offers
  one, else by target name. Same corpse + out of range = moved: the click
  is blocked BEFORE the corpse call (`"not looting"` + chat log telling
  the player to loot the corpse again), the list is untouched — nothing
  dims, nothing clears. A different GUID is never a range block (identity
  belongs to the corpse key).
  Corpse identity: `UnitExists("target")` returns `(exists, guid)` on this
  client (Nampower/SuperWoW extension — DoiteAuras/Luna/Aegis_SBR rely on
  the same second return; GUIDs double as unit tokens). The corpse key is
  `guid:<guid>` when available, else `fp:<name>|<sorted ids>[|+coin]`.
  Walk-away-and-back reuses the window: `LOOT_CLOSED` with leftovers
  keeps the rows, and re-looting the SAME corpse (key match) reconciles
  instead of wiping — an open roll keeps collecting while its window is
  open. A different corpse rebuilds as before.
  Row corpse cache (`MasterLootUI.corpseCache`, never persisted — empty
  at load, no SavedVariables): each not-fully-looted corpse owns its rows
  (+ open detail, click arms) under its key. Restore takes (no stale
  copies); fully-looted corpses are forgotten; abandoned ones evict
  oldest-first past a cap of 5. Rolls are never parked: an open window
  kept collecting, a closed one ended its roll.
  Each roll-row item is
  announced + logged (`loot`/`seen`), awarding loots the corpse slot
  through Blizzard's APIs (master loot hands to another winner by
  CANDIDATE INDEX via `GetMasterLootCandidate` — RollFor parity, never by
  name; a non-candidate award is refused with the row kept — plain
  `LootSlot` otherwise), and the overview Close button reconciles with
  the corpse (empty list closes out). `LOOT_SLOT_CLEARED` while open
  re-scans by identity multiset (slot numbers shift after each loot, so
  duplicate itemIDs track correctly); the last award closes the corpse
  out via `CloseLoot`.
  The **loot window
  lists every drop as a numbered row: row number, item icon, quality-colored
  item name, and the SR/HR badge on the right** (resolution chain per row —
  same source the sheet list uses: `GetItemInfo(row link)`, then
  `GetItemInfo(itemID)`, then the slot texture/name captured at scan time,
  then `[Name]` parsed out of the link; rows never show bare `item:<id>` while
  the client cache knows the item; the row icon and the row-detail header
  icon run the same shared handlers as every other icon (hover details,
  ctrl dress-up, click/shift link — a plain row click still opens the
  detail / loots the slot). The raider roll window resolves its icon + name
  through the same link-first chain (`RaiderLootUI.SetItemInfo` →
  `LootWindow.ResolveItemInfo`), so it matches the loot list instead of
  degrading to a `?` icon and raw-link text when the bare-ID cache key
  misses.
- **Row detail = the roll window** (RollFor preview → rolling → winners in
  one window): clicking a row opens the detail with
  Award (direct award on a single holder) / Roll / Close. Choosing **Roll
  keeps the window open** — it flips to the rolling view listing every
  valid roll with its kind (`SR: Aaa 90 (=100)`), SR > MS > OS > TMOG
  best-first, with Finish / Cancel / Close, plus the **countdown bar +
  seconds** (raider-window parity: green→orange→red, pulsing under 5s) —
  seeded at the full window the moment the roll starts, ticking every
  second, clearing on finish/cancel/close. There is exactly ONE roll at a
  time (`MasterLootUI.roll`, set only while its window is open): any roll
  — real `/roll` or test fake — lands on it or nowhere. Closing the window
  ends the roll early (intake dead, clock disarmed); a closed roll never
  finishes late and never awards. **Finish resolves the roll and the same
  window becomes the award window**: TWO award buttons -- `Award <winner>`
  (kind winner by priority) and `Award TMOG (<name>)` whenever the TMOG
  kind was contested — `...` for anyone else (candidates: any raider, for
  when something is wrong with the rolls), Close. **Continue rolling**
  reopens intake on the finished round with the landed rolls kept
  (unlike **Roll again**, which starts fresh); newcomers roll in,
  re-rollers are allowance-capped. Awarding ends any open
  roll first, then hands out the item and closes the window; the row
  leaves the list (done = gone). Ties stay open for a fresh re-roll round.
  Cancel ends the roll and drops the window back to pick (re-roll /
  choose / close). (`HR` red for hard reserves, `SR` / `SR:n` orange for
  soft reserves). Nothing auto-starts — clicking a row opens the **row
  detail**: direct **Award** when exactly one SR/HR holder exists (no
  rolling needed), **Roll** + **Raid roll** as their own buttons (never
  inside `...`; raid roll numbers the raid and the ML's number wins the
  item straight out, no award window), **...** for a real dropdown
  (RollFor parity: blue-hover rows — Award per reserver, plus one row
  per raid class like `Warrior (4) >`): hovering (or clicking) a class row pops a side submenu
  with that class's players, so the whole raid is one hover away instead
  of a flat 40-name list. Every submenu name awards directly, even before
  a roll, and nobody already listed above repeats inside a group.
  The award window keeps **Continue rolling**, **Roll again**,
  **Raid roll** and **Ignore** as bar buttons
  next to the winners. **Ignore** (on every phase: pick, rolling,
  award) marks the row ignored — it STAYS listed (`[ignored]`) with no
  award, no won mark, no corpse take and no roll history; the item stays
  on the corpse for manual handling, the audit log records it as
  ignored. Sim rows advance the queue. When no rows remain, or only
  ignored rows do, looting is finished: the detail closes, the loot
  window can close, and a raid-boss auto-switch flips back to group
  loot when it should.
  **Close** to dismiss and keep working the overview. `/zl cr`
  returns the item to open.
- **Award menu** (RollFor finish-popup style): on SR-roll completion nothing is
  auto-awarded — the ML gets winners (ranked, roll-typed) + SR/MS/OS/TMOG
  loser groups + a **class-sorted candidate roster** (sheet + rollers + raid
  roster, winners starred like RollFor's candidate grid), and picks who gets
  the item: the SR winner, a main-spec / offspec / TMOG roller, or any raider
  from the roster. Every name renders in its **class color** (see §4.8).
  In-client this is the menu frame; headless it prints and
  the ML answers `/zl award <name>`. The pick fires the confirmation popup
  (`Award <link> to <name>?`) → `GiveMasterLoot` + `AWARD` broadcast + `won`
  marking + DropLog entry.
- **TMOG kind award**: whenever the TMOG kind was contested, the menu offers
  `Award TMOG (<name>)` next to the outright winner — the ML awards the SR,
  MS, OS or TMOG winner directly. No trade handling: the award is final.

### 4.3 Raider loot window (`RaiderLootUI.lua`) — LootBlare-like

- Appears when: (a) a roll starts on this client (the local loot window
  shows it, whoever runs the loot), or (b) `ROLL_REQ` received, or (c)
  **group-loot mode**: loot method is group and a roll-worthy item
  (quality ≥ threshold) is announced — same frame, so group loot looks
  identical to master loot from the raider's side (per requirement).
- Contents (LootBlare layout, 220×250): green countdown **status bar floating
  above the frame** with seconds text (green→orange→red, pulsing under 5s),
  big 40px item icon (shared handlers: hover = item tooltip, click =
  chat-link, ctrl-click = dress-up — identical on all five icons) +
  quality-colored truncated name, quality-colored frame border, big countdown
  digits, **two-column roll list** — class-colored names left, `roll (min-max)`
  in roll-type color right, grouped **SR > MS > OS > TMOG**, best-first, max 8
  rows — four **dice buttons** (SR/MS/OS/TM) with colored borders, hover glow
  and tooltips, plus a top-screen huge-text **winner banner** (5s fade, winner
  in class color). Roll-list class resolution is roster-first with the SR
  sheet as fallback (see §4.8).
- Rolls up to the SR allowance (one roll, or N for N reservations of
the item); extra rolls ignored with notice. Auto-close timer configurable
  (`/zl time N`, `/zl autoclose on|off`).
- Draggable; `/zl show|hide`.

### 4.8 Class-colored names (`ClassColors.lua`)

- Every character name the addon renders — Sheet tab rollers/history,
  loot-window roll lists/award rows/`...` choices, award
  menu + confirm, winner banner, version grid + `/zl verlist`, drop-log
  lines, AND group-chat lines (drop calls, roll calls, winners, sand) —
  shows in its Blizzard **class color** (Paladin pink etc.).
- Source order: the **live party/raid member list first** (raid roster,
  then party units + self), **fallback to the class stored on the SR sheet**
  at import (`sheet.players`, from raidres `character.class` / legacy `role`).
  Unknown names stay plain white; solo/offline clients still get sheet colors.
- Roles carry class+spec (`PaladinHoly`): the **class prefix colors the name**,
  the spec is ignored. Case/abbreviation/file-name tolerant
  (`paladin`, `PALADIN`, `War` all resolve).
- Display-only: stored data (sheet, history, `PLAYERS` broadcast line,
  archive snapshots) keeps raw class strings. Group-chat ITEM names are
  FULL clickable links (`|cHEX|Hitem:id:...|h[Name]|h|r`): shift-clickable,
  hover tooltip, quality-colored in every client. When no full link is
  known (uncached item, bare id) the addon synthesizes one from name +
  quality — never a bare `item:id`. The raider roll window pops ONLY on
  the roll-call shape (`Roll for <link>...`); links buried in drop lists,
  winner, or sand lines never trigger it. Pure + headless-safe
  (nil-guarded roster APIs) with `tests/test_classcolors.lua` and
  `tests/test_colors_in_chat.lua` coverage.

### 4.4 Members grid (`VersionGrid.lua`, Members tab)

- `/zl ver` requests versions (`VER_REQ` → all clients answer `VER_ANS`).
- Sheet fetch (Members tab “Request SR sheet” button, `/zl sheetreq`):
  `SHEET_REQ` → the **master looter answers at once** with their sheet;
  the **raid leader/assistant answers after a 5s delay, only when no ML
  sheet exists** (no master loot, ML absent/unknown, or ML sheetless) —
  an arriving SHEET cancels the pending leader reply, so the group never
  gets two competing sheets. Raiders never answer. Receivers trust ONLY
  ML/leader sheets (`CanAcceptFrom` — a raider's sheet is refused even if
  one arrives). Solo: nobody to ask.
- Targeted sync (`/zl sync <name>`, bare name or color-coded `[Name]`
  player link): `SHEET_REQ:<name>` → ONLY the named player answers,
  directly (anyone holding a sheet may answer — imports are open to
  all). Trust stays on RECEIVE: a non-ML/leader answer still lands and
  is refused by `CanAcceptFrom` with the usual message.
- Wire encoding (`Comm.EncodeSheetPayload` / `SRImport.DecodeSheetPayload`):
  base64-wrapped when an encoder exists, else `%`-escaped raw (`%` →
  `%P`, `|` → `%B`). NEVER a bare `|`: ChatThrottleLib (bundled with other
  addons on this client) rejects bare pipes in chat/addon traffic with
  “Invalid escape code in chat message”. Decode order: `%B` → `|` first,
  `%P` → `%` last.
- Raid identity envelope: `SerializeSheet` leads with a
  `META;raidID=…,name=…,by=…,at=…,src=…` line (commas escaped `%C`), so a
  synced sheet shows the raid name in the header/archive instead of “—”.
  `ParseLineFormat` skips META; `ExtractMeta` strips + parses it on
  receive; legacy senders without META still get message-raidID + trusted
  sender stamped. `DeserializeSheet` applies META only where non-empty.
- Grid of **rectangles**: group first, then SR-sheet players not in the
  group. Full name in class color (outlined). Colors (muted):
  green = in group + on the sheet, red = in group + no SR,
  amber = outdated addon (beats sheet green), grey = sheet, not in group.
  Tooltip: name, version, what the color means. Self seeds on request
  (solo sends nothing, so the grid must not claim we lack the addon).
- Text list fallback via `/zl verlist`. Grid doubles as auto-resolve readiness:
  all-green ⇒ ML's `Auto-resolve` button enabled.

### 4.5 Auto-roll (`AutoRoll.lua`)

- Per-character opt-in: `/zl auto on|off` (default off). Stored in `ZugLootCharDB`.
- When a `ROLL_REQ`/warning arrives for an item the player SR'd (and hasn't won),
  auto `/roll`s with SR cap after 1s jitter (avoids thundering herd).
- **Auto-resolve**: if every eligible SR roller is version-grid green with auto-roll
  on, the ML is told all rollers are auto (the rolls themselves still
  arrive as normal `/roll` chat).

### 4.6 Simulation (`Sim.lua`)

In-game, no raid needed. **Requires the loaded sheet** — without one the
commands refuse with a pointer to `/zl import`. Sim + rehearsal exist ONLY
to test master looting: they open the SAME roll window through the SAME
`MasterLootUI` roll, with fake rolls landing instantly (no timers, no
scheduling) alongside any real `/roll`s. One roll at a time; the open
window owns everything; closing it ends the roll — exactly like live.

- `/zl sim <itemLink> [N]` — one-shot: queues the item, opens its roll,
  lands the fakes at once. On-sheet item: its SR rollers roll (plus N
  optional `RollerN` fillers). Off-sheet item: every player on the sheet
  rolls (plus N fillers).
- `/zl simboss <boss> [raid]` — rolls the boss's OWN drops from the LIVE
  Atlas-CFM loot tables (`AtlasLoot.lua` reads `AtlasCFM.InstanceData` —
  the same tables + `dropRate` percents the Atlas browser shows — straight
  from the game; nothing is copied into this project, and Atlas-CFM is an
  OPTIONAL dependency: without it loaded the command refuses with a
  pointer). Each listed drop gets an INDEPENDENT chance roll per run
  (entry `dropRate` → boss `defaults` → 0.5% floor, clamped 0–100; a 13%
  tier piece drops ~1 run in 8, a 100% quest item always) — so consecutive
  runs vary by design. Server-filtered entries (Turtle vs Vanilla+ item
  variants) are skipped via `AtlasCFM.Server.IsVisible`; the pool is epic+
  (`GetItemInfo` quality ≥ 4, unknown/uncached quality kept, so Turtle
  customs survive a cold cache). Multi-word names work (`/zl simboss
  Ragnaros`); a trailing raid name disambiguates (`/zl simboss Ragnaros
  Molten Core`). An all-miss run rolls nothing and says so — try again.
  The drops land in the
  **same loot window** (title `Simulated loot: <boss>`, source `sim`) and
  stops: the ML — you — initiates every roll from the list (Roll button),
  in any order. After each finish the award window decides the winner;
  the awarded item leaves the list and stays gone, won marks apply
  immediately, so the one-win rule chains across drops exactly like a
  real raid night. `/zl simstop` is a full stop: ends any open roll,
  drops the queue, and closes the windows — a fresh `/zl sim` can start
  immediately.
- `/zl simraid <raid>` — a CONDENSED full raid: ONE boss at a time, each
  through the SAME simboss starter (`Sim.QueueBossRun` — no parallel
  implementation). A trash row rolls BEFORE each boss — the mobs cleared
  walking up to it — then the boss. When a boss's queue drains (every
  drop awarded), the next stage queues automatically off the normal
  queue-drain path (`Sim.NextRaidStage`, via `AfterAward`); after the
  last boss the run ends like any sim. Unknown raids get the raid list;
  a raid with no lootable bosses refuses; `/zl simstop` stops the whole
  raid anywhere.
- Nothing auto-awards, ever: the sim awards on the same window too.
  After the ML picks, the confirm popup fires and the queue continues.
- `/zl simtmog <itemLink>` — transmog demo: one roller rolls TMOG instead
  of SR; the award window offers the TMOG kind winner next to the outright
  winner and the ML awards either directly.
- Chat routing matches live rolls: raid → `RAID` + `RAID_WARNING`, party →
  `PARTY` (warnings have no party channel, so plain party text), solo → local
  chat frame. Sim sessions are silent on the addon channel (no
  `ROLL_REQ` broadcast), so other clients' windows and auto-rolls never fire.
- Every sim roll is **written back into the sheet**: roll history
  (`sheet.rolls`, mode `SIM`, same shape as live via
  `Resolver.ToHistoryEntry`), won marks, and drop-log entries
  (source `sim`). Visible in the Sheet tab right away. The sheet log
  floor applies (rare 3+ only — see §3.3).
- `/zl rehearse [on|off]` — solo master-loot practice, no sheet needed.
  While on, every solo corpse's non-coin rows queue with invented rollers
  (Aldric, Bryn, Cora, ...) and wait for the ML: each item's Roll button
  starts its roll through the same live path (roll window, instant fake
  rolls; the ML's own dice work too). Awarding is a REAL live award — the
  item leaves the solo corpse via the normal `LootSlot(slot, 1)` take —
  which is the point: the full distribute flow rehearsed end to end.
  Invented names are fenced off the sheet (won marks + history skip
  them). `/zl simstop` and flag-off both end the run, keeping
  already-looted items.
- `Timer.lua` stays for the roll clock and the click-to-loot watchdog
  (`LootWindow.WatchClick`).
- Uses the **same** `Resolver` pure module as real sessions and as `tests/`, so
  sim output matches tested logic. Randomness via `math.random`, seeded by time.

### 4.7 Drop log (`DropLog.lua`)

- Every observed drop (ML loot window / announced item) appended:
  `{ time, itemID, itemLink, source(boss/manual), strategy, winner, price:nil }`.
- `/zl log` prints the log to chat (newest first), `/zl logclear` (ML/RL only).
- Persisted in `ZugLootDB.drops` (cap 500, ring buffer).

## 5. File layout (skeleton)

```
ZugLoot/
  ZugLoot.toc        Interface 11200, SavedVariables(+PerCharacter), load order
  SPEC.md            this file
  README.md          install + commands
  Core.lua           namespace, version, print, event frame, slash cmds
  Constants.lua      caps, colors, prefix, addon version
  Util.lua           pure helpers (trim/split/itemID/base64) — testable
  FileIO.lua         CustomData wrapper (ReadCustomFile/WriteCustomFile, Nampower)
  SRData.lua         PURE: parse line/base64 formats, SR+ extract, won helpers
  Resolver.lua       PURE: effective-roll winner/tie/missroll/two-win logic
  Comm.lua           addon-message send/receive, sheet guard (security)
  SRSecurity.lua     IsML/IsLeader/CanImport/CanBroadcast
  SRImport.lua       paste frame + "Load from File" (CustomData/ZugLoot_SR.txt)
  SRView.lua         fancy sheet window (sorted by item, xN, +SR+, WON)
  MasterLootUI.lua   ML console + session control + award menu + confirm
  ItemIcon.lua       ONE shared item-icon implementation (hover/ctrl/shift
                     for all five icons: sheet, log header, raider, rows, detail)
  LootWindow.lua     ML loot list (numbered icon/name/SR-HR rows + row detail)
  RaiderLootUI.lua   LootBlare-like frame incl. group-loot display
  AutoRoll.lua       auto-roll + auto-resolve eligibility
  VersionGrid.lua    members grid + version request handling
  AtlasLoot.lua      live Atlas-CFM loot source (boss/raid/trash chance rolls)
  RaidArchive.lua    raid history snapshots: view / continue past raids
  Sim.lua            /zl sim, /zl simboss, /zl simtmog, /zl simroll (uses Resolver)
  DropLog.lua        drop log store + window
  tests/
    run_tests.lua    stock-lua runner (lua tests/run_tests.lua)
    wow_mock.lua     minimal WoW globals shim for in-client files if needed
    test_srdata.lua  SR parse / SR+ / won tests
    test_resolver.lua winner / tie / missroll / one-win / 2x tests
  CustomData_example/
    ZugLoot_SR.txt   static-file format example (copy to <WoW>/CustomData/)
    ZugLoot_SR.txt.csv  CSV export format example (same destination)
```

Load order respects deps (pure → security/comm → import → views). All files are
Lua 5.0-safe (no `goto`, no bitwise ops, no `//`; `table.getn` avoided — use
`table.getn` shim in `Util` if needed; actually skeleton uses `#`-free counting
via `Util.Count` so it parses on 5.0 and runs on 5.5 tests).

## 6. Slash commands

```
/zl sheet            open sheet view
/zl raids            open raid history
/zl raid <raidID>   activate an archived raid (continue it)
/zl import           open import frame (anyone; broadcast stays ML/RL)
/zl loadfile         import from CustomData/ZugLoot_SR.txt (anyone)
/zl rf <link>        start SR roll (ML)        /zl arf <link>  open roll
/zl rr <link>        raid-roll: numbered raid, ML rolls 1-N (RollFor parity)
/zl roll <item>      roll one loot-window item (ML, live corpse loot)
/zl award <name>     award the finished roll to <name> (ML, from the menu)
/zl fr [item]      finish a roll early (parks it for award; Continue reopens)
/zl cr [item]      cancel a roll (returns loot item to open)
/zl show|hide        raider frame toggle
/zl time N           roll window seconds       /zl autoclose on|off
/zl auto on|off      auto-roll SR items (per char)
/zl ver | /zl verlist version grid | text list
/zl sim <link> [N]   simulate one item (auto-plays: the ML chose it)
/zl simboss <boss>   queue boss drops in the loot window (ML rolls each)
/zl simraid <raid>   queue a whole raid's drops (+ trash) in one window
/zl simtmog <link>   transmog demo (TMOG kind winner awardable)
/zl simroll <item>   roll one queued sim item (ML)
/zl simstop          full stop: session, timers, queue, menus, windows reset
/zl log | /zl logclear drop log
/zl lootdebug       verbose click-to-loot logging (slot, corpse size, link)
/zl lootframe       toggle corpse-loot window: ZugLoot vs Blizzard's (persisted;
                    auto-stands-down if ZugLoot clicks stop reaching the server)
/zl rehearse [on|off] solo master-loot practice: corpse items roll with invented
                    raiders (3-5 rolls), awards loot the corpse for real.
                    No sheet needed; real sheet stays loaded, invented names
                    fenced off it.
/zl rollauto [on|off] auto-start rolls as corpses are looted (default OFF:
                    the ML picks each item's Roll button). General master-loot
                    behaviour; rehearsal inherits it.
/zl reset            clear roll log: sessions + won marks (ML/RL in group, anyone solo)
                    (Setup tab "Reset all settings" = full factory reset with confirm)
/zl help
```

## 7. Testing

- Outside client: `lua tests/run_tests.lua` (repo root = `ZugLoot/`). Covers:
  line-format parse, base64/raidres transform incl. all `srPlus` spellings,
  max-not-sum SR+, winner/tie/miss-roll/one-win-per-item/2x, file-example parse.
- In game: `/zl sim` + `/zl simboss` exercise the same `Resolver`; import a sheet
  via paste and via `Load from File`; check version grid with a second client.
- Lua 5.0 compliance (the 1.12 client runs 5.0; the suite runs 5.5, which
  accepts everything 5.0 rejects): no `#`, no `%` operator (use
  `Util.Mod` / the local `mod` in standalone files like Resolver),
  no `//`, no `goto`, no bitwise ops, no `table.unpack`, no bare
  `string.gmatch` (use the `string.gmatch or string.gfind` idiom).
  Enforced by the `lua50 gate` in `tests/run_tests.lua` — a static scan
  that fails the suite on any hit. Plus polyfill coverage: `Util.lua`
  (2nd in the toc) shims `string.match`/`string.gmatch` off
  `string.find`/`string.gfind` when the client lacks them, and
  `tests/test_util.lua` simulates a strict-5.0 client (natives hidden)
  to prove the shims hold. Background: a `#` in Core.lua once
  killed `/zl` entirely (whole-file parse failure) while the addon still
  showed in the addon list; later a missing `string.match` on a strict
  client broke every `/zl` command the same way.

## 8. Requirements traceability

- SR import + ML/RL-only security → §2, `SRSecurity` + `Comm` guards + `SRImport`.
- SR+ calc → §3.2, `SRData.ExtractSRPlus` + `Resolver.Effective`.
- Fancy sheet view, sorted by item, player ×N + SR+, won-but-blocked → §3, §4.1.
- ML interface (RollFor-like) → §4.2. Raider window (LootBlare-like) → §4.3.
- Auto-roll SR + full-raid auto-resolve + version squares grid → §4.4, §4.5.
- In-game sim (SR resolution, rolling, raid roll, miss-roll, results) + outside
  tests → §4.6, §7.
- Drop log → §4.7. Static file import w/ button → §3.1(2), `FileIO` + `SRImport`.
- Group-loot item display (LootBlare-style) → §4.3(c).
