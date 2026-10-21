# Flipside spec

Oct 13, 2026 · @Limpan

Flipside is a World of Warcraft economy addon rebuilt from the TSM analysis, with in-game scanning as its only price source. This tab records what we keep, change or add; for how TSM behaves today, see TradeSkillMaster: Analysis & Product Specification.

## Handover to Claude Code

Start with Spike 0 (§8), then follow the MVP build order. Everything below applies to every task.

1. **Clean room.** Build from this spec only. Never copy TSM code, assets, names or string formats. Points marked *(inferred)* in the TSM reference are guesses to verify, not facts.
2. **API source of truth.** Check every Blizzard API against the Forever client's interface code ([Ketho/wow-ui-source-forever](https://github.com/Ketho/wow-ui-source-forever)) and the API pages on [warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/World_of_Warcraft_API). Forever may differ from Retail; when they disagree, the Forever source wins.
3. **Project setup.**
   - Folder layout: `Shared/Core/` (framework), `Shared/Services/`, `Shared/Features/<Name>/`, `Shared/UI/`, `Shared/Libs/`, `Shared/Locales/`, `Tests/`.
   - TOC with the Forever interface number taken from the client source (the source has no interface number; 16001 comes from `GetBuildInfo` in the client), and the SavedVariables of Flipside (Main DB, Scan DB, §7.1). The ledger is a second addon, `Flipside_Ledger`, with its own TOC and SavedVariables (D25, §5.8).
   - Lint with luacheck; WoW globals declared in its config.
   - Unit tests with busted and a mocked WoW API, for the pure logic: formula compiler, market-value algorithm, selling decisions, keep-stock maths, deposit-aware maths.
   - Packaging for CurseForge and Wago via a release workflow. The release has two addon folders: `Flipside` and `Flipside_Ledger`. The TOC of `Flipside_Ledger` has `## LoadOnDemand: 1` and `## Dependencies: Flipside`.
4. **Libraries.** Decide in the first task whether to use common libraries (e.g. Ace3, LibSerialize, LibDeflate) or write our own; check each licence is compatible with MIT (D12) and list them in the README. The decision is made: see D18.
5. **Repo CLAUDE.md** containing: the link to this spec; the build order; "Decisions D1–D25 are binding — ask before changing one"; "When something gets scoped, update the Needs scoping table"; the definition of done below.
6. **Definition of done per feature.** Unit tests pass; luacheck is clean; the feature's in-game checklist passes on WoW: Forever; the spec section is updated if behaviour changed; the Phase dropdown and Needs scoping status reflect reality.
7. **Open questions** at the end of this tab are not decided. If a task depends on one, stop and ask.

## Goals, non-goals and decisions

**Goal:** a self-contained addon that does TSM's core money-making work — buy, sell, craft, move and track items by rules — with no server, no desktop app and no account.

**Goals**

- Everything runs inside the game client; price data comes from the player's own scans.
- Same core model as TSM: groups + operations + a price-formula language, so experienced users feel at home.
- Easier first hour: starter groups and operations, a simple mode, and explanations for every automated decision.
- Open, documented formats for import, export and ledger data.

**Non-goals (for now)**

- Cross-realm arbitrage data and region sale rates — they need a server.
- A website, alerts or web analytics.
- Bypassing Blizzard limits: one click per protected action and search throttling stay as they are.
- Compatibility with real TSM import strings (could come later; see Open questions).

**Decisions**

| # | Decision | Replaces in TSM | Date |
| --- | --- | --- | --- |
| D1 | Price data comes only from in-game scans (full scan + passive learning) | Desktop app, AppHelper, AuctionDB downloads | 2026-10-13 |
| D2 | Optional external data import slot exists but ships empty | AppHelper as a required addon | 2026-10-13 |
| D3 | Separate spec tab; TSM analysis kept as reference | — | 2026-10-13 |
| D4 | A price "day" follows server (realm) time | — | 2026-10-13 |
| D5 | A targeted search newer than the day's full scan overrides that day's value for the item | — | 2026-10-13 |
| D6 | Price history kept at least 60 days by default; retention is a setting | 14-day AuctionDB window | 2026-10-13 |
| D7 | Guild data sharing is opt-in, off by default, offered during onboarding | — | 2026-10-13 |
| D8 | Keep stock overrides selling and other outgoing rules unless the player presses Override stock | Separate keep fields per module | 2026-10-13 |
| D9 | Last full-scan time is stored account-wide in SavedVariables; every character shows the shared cooldown | — | 2026-10-13 |
| D10 | Add Great Deals, price history chart, deposit-aware posting, craft profit ranking, presets and undo | Premium Great Deals | 2026-10-13 |
| D11 | Launch on WoW: Forever. WoW: TBC Anniversary is ported now, with its own TOC (D23). Retail comes later | Retail-first | 2026-10-13 (changed 2026-10-14) |
| D12 | Licence: MIT | Proprietary | 2026-10-13 |
| D13 | No import of TSM group strings | — | 2026-10-13 |
| D14 | Guild sharing ships, behind an on/off toggle | — | 2026-10-13 |
| D15 | WoW: Forever has one region-wide market per ruleset (mega-server), with stackables traded as commodities; all price data is keyed by region and ruleset | Per-realm AuctionDB data | 2026-10-13 |
| D16 | The addon is called Flipside; slash commands /flipside and /flip | — | 2026-10-13 |
| D17 | Visual style: the pure WoW: Forever look. Only the client's own textures, atlases, fonts and frame templates, untinted and referenced by path or name; nothing is shipped. No own art and no bronze tint | TSM's flat dark theme | 2026-10-13 (changed 2026-10-14) |
| D18 | No Ace3. Flipside writes its own framework (settings DB, event bus, coroutine scheduler, slash commands) and its own UI kit. No third-party library ships in the MVP. The use of AceComm with ChatThrottleLib for guild sharing is decided again at Phase 3 | — | 2026-10-14 |
| D19 | The UI kit is reusable for other addons: style only (theme table, frames, buttons, tabs, lists), with no Flipside logic and no reference to Flipside code or names. It lives in `Shared/UI/Kit/` in this repository and can be extracted to a library later | — | 2026-10-14 |
| D20 | Item identity: the item key is built from item link fields: item id, suffix id and bonus ids. Enchants, gems, unique id, link level and specialization are not part of the key. Commodities (stackable items) use the item id only. Granularity (base item or exact variant) is chosen when a group or price source matches, not when data is stored. Keys never contain localised names. Flipside uses its own text form for keys, not TSM's | — | 2026-10-14 |
| D21 | Battle pets are out of the MVP | — | 2026-10-14 |
| D22 | Scan data is keyed by region and ruleset (refines D15). The region comes from the client. Each stored record also has a ruleset field that has one fixed value in the MVP; real rulesets (for example hardcore or self-found) can come later without a rewrite of stored data | — | 2026-10-14 |
| D23 | Flavour separation. Each flavour has its own TOC: `Flipside.toc` for Forever and `Flipside_TBC.toc` for TBC Anniversary. One release zip holds both TOCs. Shared code lives in `Shared/` (`Shared/Core`, `Shared/Services`, `Shared/Features`, `Shared/UI`, `Shared/UI/Kit`, `Shared/UI/Pages`). Flavour code lives in `Core_<Flavour>/` (flavour config `Flavour.lua`, tooltip hook) and `AH_<Flavour>/` (all auction API calls and the AH tab host). Only AuctionClient backends call the auction API. Shared code reads `ns.Flavour` and never checks the flavour name. The TOC selects the flavour folders | One TOC with flavour checks in shared code | 2026-10-14 |
| D24 | TBC scan data is keyed by region, realm and ruleset. The ruleset value is "tbc-anniversary" (refines D15 and D22). Forever stays region + "standard". The realm part can be removed later if a test shows that TBC auctions are shared across realms | Region and ruleset only | 2026-10-14 |
| D25 | TBC uses its own SavedVariables names: `FlipsideDB_TBC` and `FlipsideScanDB_TBC`. These are the names in `Flipside.toc` plus `_TBC`. The ledger is a separate load-on-demand addon, `Flipside_Ledger`, with the SavedVariables `FlipsideLedgerDB` (TBC: `FlipsideLedgerDB_TBC`). It is no longer a part of the Main DB. See §5.8 | Shared SavedVariables | 2026-10-14 (changed 2026-10-15) |
| D26 | Buying and Selling make one protected AH call for each click. Every buy asks for confirmation in v1 and shows the final server price. Flipside never buys without a click | Automatic buying of listed rows | 2026-10-14 |

### Improvements over TSM

Fifteen improvements, each specified in the section named.

| Improvement | Why it matters | Spec |
| --- | --- | --- |
| No account, server or desktop app | Install the addon and play; nothing to log into or keep running | §3 |
| Free Great Deals after every full scan | TSM charges for this; we compute it locally | §5.11 |
| In-game price history chart | See trends without leaving the game | §5.12 |
| Deposit-aware posting | Stops posting items that lose more in deposits than they earn | §5.13 |
| Craft profit ranking after every scan | "What should I craft right now?" answered automatically | §5.14 |
| Freshness on every price | Stale prices are visible and rules can refuse them | §3.4 |
| Dry run and decision log | Every post, skip and cancel explains itself | §5.4 |
| Keep stock as one rule with clear precedence | One place to say what to hold; selling can't eat your stock | §5.6 |
| Rule-based (smart) groups (later; not in build step 4) | Groups that fill themselves by item properties | §5.2 |
| Starter groups and presets (later; not in build step 4) | Useful on the first day, not after a week of setup | §5.2, §5.15 |
| Undo for configuration edits | Experiment without fear of breaking rules | §5.15 |
| Vendoring safety check | Never vendor something worth far more on the AH | §5.7 |
| Open import/export and ledger CSV | Your data is yours and portable | §7.4, §5.8 |
| Separate Scan DB | Reset or share price data without touching settings | §7.1 |
| Mailing operations exportable | Share mailing setups with the groups and operations (recipient as typed) | §5.5 |

## Feature list

Nine features come from your list, twelve are ones TSM users rely on that are easy to forget, and five are new improvements (D10). The MVP is the smallest set that lets a player scan, price, buy, sell and see profit. Change any phase with its dropdown.

| Feature | What it does | Change vs TSM | From | Phase |
| --- | --- | --- | --- | --- |
| Full scan | Captures every AH listing and builds local price history | Replaces AuctionDB downloads (D1) | You | MVP |
| Buying | Search the AH, buy below a max price, restock materials | Same as Shopping; adds "% of market" and data-age columns | You | MVP |
| Selling | Post and cancel by rules with min / max / normal prices | Same as Auctioning; adds dry run and decision log | You | MVP |
| Item groups | Organise items into a tree that rules apply to | Same model; adds starter groups and auto profession groups (later; not in build step 4) | You | MVP |
| Mailing | Send grouped items to a named character: the mailing operation of a group (replaces the mail list, decided 2026-10-16) | Same as Mailing operations; the mailing view runs the mail groups at the mailbox | You | MVP |
| Keep stock | Hold target quantities per character and location | Unifies TSM restock settings from Mailing, Banking and Shopping | You | Phase 2 |
| Vendoring | Sell junk and low-value items, buy vendor reagents | Same as Vendoring; adds "never vendor above X" safety | You | MVP |
| Ledger | Record sales, purchases, fees and failures; show profit | Same as Accounting; adds documented CSV export | You | MVP |
| Sniper | Repeat searches to catch underpriced new listings | Same as Sniper; uses local scan prices for thresholds | You | Phase 2 |
| Operations and price formulas | Reusable rules with a formula language | Same language; new local price sources; live formula preview | Added | MVP |
| Tooltips | Prices, counts and history on every item (the history chart is Phase 2) | Shows prices as a Min/Avg/Max/Market table by window (1d, 14d, 30d, 60d) with the data age in the header | Added | MVP |
| Inventory tracking | Counts per character, bank, mail, AH, guild (guild bank later; equipped items later) | Same | Added | MVP |
| Decision log and dry run | Shows why each item was posted, skipped or cancelled | New | Added | MVP |
| Crafting and queue | Profit per recipe, restock queue, craft next | Same | Added | Phase 2 |
| Banking | Move groups between bags, bank and warband bank | Folded into Keep stock rules | Added | Phase 2 |
| Profiles | Swap rule sets per character | Same | Added | Phase 2 |
| Import and export | Share groups and operations as text (MVP, mailing operations included); keep-stock rules later (Phase 2) | Open, documented format | Added | MVP |
| Dashboard | Gold over time and profit summary | Same, from local ledger only | Added | Phase 2 |
| Account sync | Share inventory, ledger and scan data across accounts | Also shares scan history (fills gaps) | Added | Phase 3 |
| Task List | Step-by-step guide through a crafting session | Same | Added | Phase 3 |
| Destroying | Disenchant, mill and prospect in bulk | Same | Added | Phase 3 |
| Great Deals | Lists underpriced items right after every full scan | New for free; premium-only in TSM | Improvement | MVP |
| Price history chart | 60+ days of an item's prices and volume in game | New | Improvement | Phase 2 |
| Deposit-aware posting | Skips posts whose expected deposit loss outweighs expected profit | New | Improvement | Phase 2 |
| Craft profit ranking | Ranks every known recipe by profit after each scan | New | Improvement | Phase 2 |
| Presets and undo | Ready-made operations and undo for config edits | New | Improvement | Phase 2 |

## Local scan data

All prices come from three kinds of in-game scans, folded into a compact daily history per item. Freshness and sample size travel with every price so rules can refuse to act on stale data.

### 3.1 Scan types

| Scan | Blizzard API (Retail) | Returns | Limit | Use |
| --- | --- | --- | --- | --- |
| Full scan | `C_AuctionHouse.ReplicateItems` | Every listing with price and quantity | 15 min account-wide cooldown (assumed; not yet measured on Forever) | Primary data source, one button |
| Summary scan | Browse query + "request more results" | Lowest price and total quantity per item | Search throttle, no cooldown | Fallback when full scan is on cooldown or fails |
| Passive capture | Any search done by Buying, Selling or Sniper | Full depth for searched items | None extra | Keeps watched items fresh between full scans; searches in Blizzard's own AH window are captured too |

Full-scan facts that shape the design ([Warcraft Wiki](https://warcraft.wiki.gg/wiki/API:C_AuctionHouse.ReplicateItems)):

- The cooldown is per account, not per character. Store the time of the last scan call account-wide in SavedVariables, and show the shared countdown on every character (D9).
- Results are read by index, and the client handles about 2,000 item-info events per frame. The reader must process in slices of roughly 1,000–2,000 rows per frame.
- Some rows arrive without item info. Request the item data of all such rows at once and read each row again when its data arrives. The wait has no fixed cap: it stops when no row was accepted for the no-progress time (see "Forever scan retry"). An item that still has an unloaded row then gets no new snapshot and keeps its old data. The other items are stored in full (see the scan engine design in §3.2).
- On very busy realms the call has disconnected clients before (a fix in 9.0.2 removed seller names). Seller names are therefore never available from a full scan; blacklist features must use targeted searches.
- WoW: Forever lists the same full-scan call in Blizzard's API (confirm behaviour in the beta); older Classic clients use the older "get all" query, also on a cooldown; the snapshot pipeline after it is the same.

### 3.2 Snapshot pipeline

1. **Collect** rows into a temporary per-item list of unit buyouts and quantities (bid-only listings skipped).
2. **Reduce** each item to snapshot stats: min buyout, market value (the outlier filter from the reference §4.3), listed quantity, auction count.
3. **Merge** into today's bucket for that item; keep up to 4 snapshots per day (a fifth drops the oldest); the day's record is their average. A targeted search newer than the day's full scan replaces that day's value for the searched item (D5).
4. **Roll up** at the first scan after the server day changes (D4) and also at login: today's bucket becomes one daily record.
5. **Discard** raw listings. Only daily records and today's bucket are saved.

Rows can arrive without full item info, so the pipeline loads item data before it uses names, links or stack sizes (see Spike 0 result in §8).

All steps run as coroutines that yield each frame, with a progress bar. The scan engine emits the event `Flipside.ScanProgress` with a table `{ mode, phase, done, total, rows }` (added 2026-10-16). The phases are `waiting` (for the server, no count), `reading` (rows read of `GetNumReplicateItems`), `loading` (item data), `saving`, and `pages` (page mode: `done` is the page, `total` the page count, `rows` the rows read). The engine emits at most every 0.2 s; a change of phase always emits. `Engine:GetScanProgress()` returns the same table while a scan runs. The ScanBar only listens: it shows the text ("Scanning 1234 / 5678 (22%)", "Waiting for server", "Loading items 5 / 10 (50%)", "Saving", "Page scan: page 3 of 40, 150 rows") and clears it on `Flipside.ScanFinished`, which the engine emits on a finish, a failure and a cancel. The Flipside tab fills a progress bar from `done / total`; the bar of the Forever layout shows only while a scan runs. The bar stays empty while the count is unknown.A scan is partial only if the read is incomplete (for example the AH closes during the read); a partial scan updates only the "latest" values (see the scan engine design below).

**Scan engine design (decided 2026-10-14)**

- A `/reload` or logout during a scan discards the run. Nothing of it is saved.
- After the rows are read, the scan waits for the item data (updated 2026-10-16). It stops when no row was accepted for the no-progress time (backend value `ScanRefreshSeconds`, 15 s on Forever; see "Forever scan retry"). It has no cap on the total time. An item that still has an unloaded row is pending. It gets no write and keeps its old data. It gets a new attempt at the next scan. The other items are stored as a complete scan, and the summary says "complete with N pending".
1. **Stored format.** One record per item per region and ruleset, stored as one delimited string per item (§3.3). Gear and other non-stackable items use the D20 exact key. Commodities use the base key. Money is whole copper. Days are integer day numbers.
2. **Market value.** The "lowest 30%" and "first 15%" rules count auctions, not units. Outliers are removed with the population standard deviation. The market value is the plain (unweighted) average of the remaining unit prices, rounded half up to whole copper.
3. **Price day (D4).** A day starts at 00:00 UTC by the server clock (`GetServerTime`). Day number = floor(server time / 86,400).
4. **Region and ruleset.** Region is the client's region text (`GetCurrentRegionName`, for example "EU"). Ruleset is the fixed value "standard" in the MVP. The client's standard-mode flag (`C_GameRules.IsStandard`) is stored next to it as information.
5. **Commodity detection.** After the item loads, ask the client (`C_AuctionHouse.GetItemKeyInfo`, field `isCommodity`). If the client gives no answer, use "maximum stack size above 1". Cases where both answers exist and disagree are counted and reported, so they can be checked in game.
6. **Cooldown.** The 15-minute timer starts when the scan is called, not when data arrives. Flipside refuses a new full scan before the timer ends and shows the time left. The 15 minutes stays an assumption until measured (open question).
7. **Start before the AH frame exists.** `/flip scan` (or `/flipside scan`) at the open Auction House shows a warning popup. Accept starts the scan.
8. **Snapshots and roll-up.** Keep up to 4 snapshots per day; a fifth drops the oldest. The day's record is the average of the day's snapshots. Roll-up into history happens at the first scan of a new day and also at login.
9. **Partial scans** (the read is incomplete: the AH closed during the read, or a page got no answer). The data updates the "latest" values of each item. It does not enter the day's snapshots or the history. Only a complete read does that. Completeness is decided for each item: a complete read writes a normal snapshot (today and latest) for every item that has a key, also if other items stay pending. A pending item (no key yet, for example no item data or no link) gets no write. If some rows of a keyed item have no key, that item gets latest values only. This rule is the same for the full, fast and page modes.
10. **Processing-time target.** "Under 5 s of scan processing" means Flipside's own processing time (CPU time of scan work). It excludes the server delay before the first event and the item-load wait. It is measured on the largest Forever run (about 73,000 rows).
- Key fallback: if the commodity status is still unknown after the item-load wait, the exact key from the listing link is used (equal to the base key for plain items).
- **Passive capture (decided 2026-10-14).**
  1. A complete item search result replaces the day's value (D5): `latest` becomes this snapshot, and today's snapshots of the item become this one snapshot. A later full scan adds snapshots as usual.
  2. If the client has not sent all result pages, only the lowest price is saved, marked partial (latest only). `market`, `qty` and `auctions` stay from the old `latest`; without one, `market` is the lowest price. Flipside sends no extra server requests.
  3. Only item searches (the listings of one item) are captured, not the browse list.
  4. On TBC the capture reads the legacy list page (see "Rules for TBC"). A page of any search is captured, not only item searches.
  5. Commodities use the base key, other items the exact key of each listing's link (D20). Battle pets are skipped (D21).
### 3.3 History storage

- Per item, region and ruleset (D15, D22): every daily record (min, market, quantity, scans) for at least 60 days by default; retention is a setting with 60 days as the minimum (D6). Market value still weights the last 14 days.
- Records are packed as numbers in a delimited string per item to keep SavedVariables small; decoded on demand.
- On WoW: Forever the whole market is region-wide per ruleset (D15), so every item's history is stored once, keyed by region and ruleset. When Retail is added, commodities stay region-wide and other items are stored per connected realm.
- Items with no listings within the retention period are pruned.

### 3.4 Freshness and confidence

- Every price carries **age** (hours since last seen) and **samples** (days with data in the window).
- Tooltips show the age once, in the header: "Flipside (updated 2 h ago)". The price table shows the prices of four windows (§5, tooltip design point 15). A formula line can still show age and days with data.
- Operations get two safety settings: *max data age* and *min samples*. If either fails, the item is skipped with the reason "stale price" in the decision log.
- The Flipside AH tab shows when the last full scan ran and when the next is available (a Dashboard comes in Phase 2).

### 3.5 Sharing scan data

- **Synced accounts:** daily records are merged by taking the newest snapshot per item and day, so two accounts on one realm double coverage.
- **Guild sharing (opt-in, off by default, offered during onboarding, D7):** guildmates on the same realm can request missing or newer daily records for specific items over the guild addon channel. Only aggregated daily stats are shared, never raw listings or personal data. Trust rule (user decision of 2026-10-20): the latest price data always wins, no matter who scanned it. A received record replaces your own record for the item only if its scan time is newer. On equal scan times your own record wins.
- **Guild price sharing, built design (2026-10-20, first part; user decision after the bug report "syncing of prices does not work"; in-game checklist open).** Guild only. Party and friends come later. This build shares the latest price summary of each item, not the daily history. Daily records can follow. Files in `Shared/Services/`: `GuildSyncCodec` (pure wire format and reassembly), `GuildPriceStore` (pure store and read path), `GuildSyncQueue` (send queue with its own rate limit, D18), `GuildSync` (controller). `Shared/Core/Init.lua` only wires them (`openGuildSync`, `/flip sync`).
    - **Setting.** Account key `sync.guildEnabled`, default off (D7, D14). The toggle is the check box "Share prices with my guild" on the About page of the Flipside window. If it is off, Flipside sends nothing and ignores all received data. It does not register the addon prefix until the setting is on.
    - **Transport (verified in the Forever and `classic_anniversary` client source, `Blizzard_APIDocumentationGenerated`).** One prefix, `Flipside`. `C_ChatInfo.RegisterAddonMessagePrefix(prefix)`, `C_ChatInfo.SendAddonMessage(prefix, text, "GUILD")` and the event `CHAT_MSG_ADDON(prefix, text, channel, sender, ...)` have the same signature on both clients. The client documentation gives no byte limit. The wiki limit is 255 bytes for the text, so each message holds at most 240 bytes (`GuildSyncCodec.MAX_BYTES`). Text uses only digits, letters and `; , : / . - _`. No `|` and no zero byte. Flipside skips sending if `IsInGuild()` is false. It ignores own messages: it compares the lower-case `Name-Realm` of the sender with the own name, and adds the own realm when the sender has none.
    - **Throttle (own code, no library).** `GuildSyncQueue` sends at most 1 message each second, with a burst of 4. The client refusal codes `AddonMessageThrottle` (3), `ChannelThrottle` (8) and `AddOnMessageLockdown` (11) of `Enum.SendAddonMessageResult` make the queue wait 5 s, then 10 s, 20 s and so on up to 60 s, and send the same message again. After 6 tries it drops the message. Any other code drops the message at once. The queue holds at most 300 messages. These numbers are a safe choice, not a measured limit. Measure them in game. The queue stays short: the sender adds a new set only while fewer than 10 messages wait (lazy cursor, see "What is sent"). A request goes before the queued data messages, but not before a message that waits for a retry. While a message waits for a retry, the sender adds nothing. If a message is dropped after the retries (6 tries), the share goes back to the start of that set, removes its queued messages and pauses for 60 s. Then it builds the set again, so no item is lost.
    - **Protocol version 1.** Request: `1;Q;<scope>;<newest>`. Data chunk: `1;D;<scope>;<setId>;<index>;<total>;<time>;<items>`. An item is `key,min,market,qty,age`, with age in seconds before `<time>`. The scope is the region, the realm (TBC only) and the ruleset (D22, D24). A receiver drops a message with another version or another scope. A set has at most 100 chunks. The receiver keeps one open set for each sender (at most 40 senders), joins chunks in any order, and drops a set when 180 s pass without a new chunk (it was 60 s; the new value covers the longest throttle wait of the sender). A share of many items goes out as many small sets of 30 items (about 4 chunks each), one after the other, each with its own `setId`. The receiver accepts each set on its own. A new set of a sender replaces its open set, so one lost chunk loses only that set. The wire format did not change (version 1), so old and new builds work together.
    - **What is sent.** For each item, the newest record from the local scan store and from the shared store (relay): the min buyout, the market value, the quantity and the original scan time (never the receive time). On equal times the own record is used. Items older than 7 days, items without a price and items with a key that is not digits and `:` are left out. There is no limit on the number of items (decision of 2026-10-21; the old limit of 500 items sent only the first keys of a full scan). The build of the list runs as a scheduler job. The list (newest first, then by key) is the share. The sender walks through it with a cursor in the background: it builds the next set of 30 items only when fewer than 10 messages wait in the queue. At the safe rate (1 message each second, about 8 items each) a full scan of thousands of items takes minutes. This is accepted.
    - **When it is sent.** After a scan that ends with result `ok` or `partial` (not a page scan), a share starts. If a share is still running, the new list joins it: the unsent items and the changed items stay, the sent items that did not change are not sent again, and an item in both lists gets the newest record. The queued messages of the old share are removed and built again. Requests in the queue stay.
    - **Login resend.** The sender saves a marker in the Main DB (account key `sync.guildShare`, one table `{ time, done }` for each scope). `done` is false from the start of a share until the cursor is at the end and all its messages left the queue. The old build has no marker, so nothing is resent after the update. 30 s after login, after the request, the sender starts the share again with the current data if `done` is false (log "resume the share"). If sharing is off or the player has no guild, it does nothing and the marker stays.
    - **Other send rules.** Flipside never sends again when it receives a set (no rebroadcast, no message storm). A received record replaces a stored one only if it is strictly newer, so relayed old data does nothing. Also a request: 30 s after login, and with `/flip sync request`. The request carries the newest scan time that the sender knows (own last scan or newest shared item). A member answers only if its last full scan is more than 60 s newer. It waits a random 2 to 12 s first. It does not answer if it received any data chunk in that time ("someone already answered"). It answers at most once in 10 minutes. A normal request has a 5-minute cooldown. `/flip sync request` ignores the cooldown.
    - **Store and trust rule.** `GuildPriceStore` keeps the received prices in the Main DB, account key `sync.guild`, one table for each scope, at most 5000 items (the oldest go first). For each item it keeps the newest record. It skips values that are not whole numbers, zero prices and times more than one day in the future. The store is separate from the Scan DB. **Trust rule (user decision of 2026-10-20, replaces "received prices only fill gaps"):** the reader compares the scan time of the local latest record and of the shared record of the item key, and uses the newer one. On equal times it uses the local record. If one is missing, it uses the other. **Gap fill (user decision of 2026-10-21):** the newer record still wins, but a part that it lacks comes from the other record. The parts are the latest value (ScanMin, ScanRecent, ScanQty, ScanAge) and the day data (ScanMarket, ScanLow, ScanHigh, ScanHistorical, ScanSamples). A partial scan gives a local record with a latest value and no day data, so it took ScanMarket from the shared record, which has one day entry. Before this rule, such an item gave "invalid price" for ScanMarket.
    - **Read path.** `ns.priceReader` (a `GuildPriceStore` reader) is the store for formulas, the tooltip and the getRecord calls of the Auction House tabs. It returns the newer of the local record and a record made from the shared price (`partial` is true), with the gaps filled from the other record, else nil. The winner is never changed; a record with a filled gap is a new table. On equal times the local record wins. The reader keeps the merged record of an item until the local data, the shared data or the setting changes. It returns no shared data while the setting is off. `IsGuild(key)` is true if any part of the returned record comes from shared data: the shared record is newer, or it fills a gap of a newer local record. `/flip price` reads through it and shows "(guild)" after the key. The tooltip adds a dim line "(guild) prices from guild members" when the item price comes from shared data.
    - **Commands.** `/flip sync` prints three lines: on or off and guild state; the times of the last send, receive and request; and the number of senders in this session, shared items, queued messages and incoming sets. While a share runs, it prints a fourth line "share running: N of M items sent", with "(paused, the guild channel throttles)" during a throttle pause. `/flip sync request` sends a request now.
    - **Log.** Category `sync`: each send, receive, request and reply, and each drop with its reason (version, key mismatch, malformed, incomplete, replaced, busy, disabled, not in a guild, throttle retries).
    - **In-game checklist (open).** Two characters in one guild, one on each client (Forever and TBC Anniversary):
        1. Both off: `/flip sync` shows "off". Run a scan on A. B gets nothing.
        2. Turn on A and B (About page). `/flip sync request` on B. Expect the log lines "request sent" on B and "request ... reply in" on A only if A has a newer scan.
        3. After a full scan on A, B receives. `/flip sync` on B shows senders 1 and shared items above 0.
        4. On B, `/flip price <item>` and a formula `scanmin` for an item that B never scanned show the shared price. The tooltip shows "(guild)".
        5. Scan the same item on B. The tooltip drops the "(guild)" line and shows the local price.
        6. Turn B off. B ignores new messages, and the shared prices disappear from the tooltip. Turn A off. A sends nothing after a scan.
        7. Leave the guild. `/flip sync request` prints "not-in-guild".
        8. Full share: A has a full scan of more than 2000 items. After the scan, `/flip sync` on A prints "share running: N of M items sent", and N grows each few seconds. The queued messages stay under about 15. Check that no message is lost (log has no "dropped" line) and that chat has no error.
        9. After the share ends, B shows shared items near M. An item that A scanned in a full scan (for example Wool Cloth, key 2592) shows a price on B, also if B made a partial scan of it before. `/formula` or the tooltip with `scanmarket` gives a number, not "invalid price".
        10. During a running share on A, run `/flip sync request` on A. The request goes out within a few seconds, not after the share. Start a second scan on A during the share: the share does not start from the beginning, and `/flip sync` shows the new total.
        11. Login resend: on A start a share, then `/reload` before it ends. 30 s after login, the log of A has "resume the share" and the share runs again. After a finished share and a `/reload`, A does not resume.
- **External import slot (D2):** a documented file format so a community-built baseline can be dropped in. Ships empty.

## Price sources

The formula language stays as in the reference (§4.3). AuctionDB sources are replaced by scan sources; personal, crafting, vendor and operation sources carry over unchanged.

| Source | Meaning | TSM equivalent |
| --- | --- | --- |
| `ScanMin` | Lowest buyout in the most recent snapshot | `DBMinBuyout` |
| `ScanRecent` | Market value of the most recent snapshot only | `DBRecent` |
| `ScanMarket` | 14-day recency-weighted market value | `DBMarket` |
| `ScanHistorical` | 60-day average of daily market value | `DBHistorical` |
| `ScanQty` | Units listed in the most recent snapshot | — (new, value source) |
| `ScanAge` | Hours since the item was last seen | — (new, value source) |
| `ScanSamples` | Days with data in the 14-day window | — (new, value source) |
| `ScanLow` | Lowest price (min) seen in the 14-day window, including today (decided 2026-10-14) | — (new) |
| `ScanHigh` | Highest daily market value in the 14-day window, including today (decided 2026-10-14) | — (new) |
| `ImportMarket` | Market value from the optional external file | `DBRegionMarketAvg` (only if imported) |
| `SaleRate` | Your own sold ÷ (sold + expired) for the item, from the ledger (loads `Flipside_Ledger`; §5.8) | `DBRegionSaleRate` (personal, not regional) |

Carried over: `avgBuy`, `avgSell`, `SmartAvgBuy`, `min`/`maxBuy`, `min`/`maxSell`, `Crafting`, `matPrice`, `Destroy`, `vendorBuy`, `vendorSell`, and the operation sources.

**Default selling minimum** (shipped):

```
check(
  first(crafting, scanmarket),
  max(0.25 * avg(crafting, scanmarket, scanhistorical), 1.5 * vendorsell)
)
```

**Staleness is part of the language.** Because `ScanAge` and `ScanSamples` are ordinary value sources, a rule like `ifgt(scanage, 72, invalid, scanmarket)` (treat prices older than 3 days as invalid) needs no new syntax.

### Formula language design (decided 2026-10-14)

1. A missing source value makes the whole formula invalid (no price). The item is skipped with the reason "invalid price". A missing value never counts as 0.
2. The word `invalid` is a value that means "no price".
3. A number without a unit is copper. Money literals work: `10g`, `5s`, `12s70c`. Results are whole copper.
4. The end result is rounded half up to whole copper. Division by zero gives invalid.
5. The decimal separator is a dot only (`0.25`). The comma separates function arguments.
6. Source and function names ignore upper and lower case.
7. Live preview: the chat command `/flip formula <formula> <item link>` now. A window comes with the UI (MVP build step 4).
8. The preview uses the item link given in the command.
9. A formula reads the exact variant record of the item first, then the base item record (same order as `/flip price`).
10. Functions in version one: `min`, `max`, `avg`, `first`, `check`, `ifgt`, `iflt`, `ifeq`, `round`.
    - `min`, `max`, `avg` and `first` skip invalid arguments.
    - `check(a, b)` returns b only if a is valid and above 0.
    - `ifgt(value, limit, then, else)`. `iflt` and `ifeq` use the same argument order.
    - `round(x)` rounds to whole copper.
11. A known source that is not built yet (for example `crafting`) is accepted in a formula and counts as missing for now. The preview says "not available yet".
12. Limits: 500 characters and 16 bracket levels.
13. Custom sources (step 4): a loop between custom sources is refused when saved, and gives invalid at run time.
14. Not in version one: a source for another item (item arguments) and `convert()`. They come with crafting (Phase 2).
15. No TSM source names as aliases (for example no `dbmarket`), in line with D13.
16. The MVP vendoring safety check uses `ScanMarket` only. `Destroy` comes in Phase 3.
17. The default selling minimum ships as written. `first` and `avg` skip the missing crafting value.
18. A vendor sell price of 0 means the vendor does not buy the item. `vendorsell` is then invalid.

**Feedback decisions (2026-10-14)**

7. **Formulas page.** The page explains each function and each source in plain words, as a reference list. The custom source section (save a formula under a name) must be easy to find. There are no user-defined functions with parameters.

## Feature specs

Each feature lists only what differs from, or is unspecified in, the TSM reference. Where nothing is said, behave as the reference section named.

### 5.1 Full scan

A *Full Scan* button sits on the Flipside tab of the Auction House frame with a cooldown countdown (§3.1). When the AH opens and the cooldown is clear, an optional setting starts the scan automatically. Result summary after each scan: items seen, new items, prices changed by more than 30%, and duration.

The scan buttons also show on the start page of the Blizzard Auction House: a small bar with the same scan buttons, a Stop button and one status text. On Forever the bar sits in the bottom strip of the Buy page. On TBC Anniversary it sits in the top strip of the Browse page. It follows the Blizzard page. The profile setting `ui.startPageScanBar` (default on) hides it. A check box on the Flipside tab changes the setting.

On TBC Anniversary the Flipside tab uses the Bids art of the Blizzard frame (full-width list panel, no filter column, no boxes). The tab has three parts. The header strip holds the scan buttons (80 x 22, same style), the Stop button in its own slot after them, and a progress bar to the right. The bar fills from the page of a running page scan. The status text sits on the bar. The body has two halves: the scan data (region, items stored, last scan, last result) on the left and the price lookup with its result on the right. The bottom bar holds the start page check box, Reset cooldown and Open Flipside. Blizzard sets all six art textures again on the next tab click, so the art of the other tabs returns when the user leaves the Flipside tab. The Forever tab layout does not change.

### 5.2 Item groups (reference §4.1)

- Same tree model, exclusive membership and item-string granularity.
- **Starter groups** on first run (later; not in build step 4): common materials per profession, and "Junk" and "Vendor trash" groups pre-wired to Vendoring.
- **Auto profession groups** (later; not in build step 4): one click creates *Profession → Crafts* and *Profession → Materials* from the open profession.
- **Smart filters (new)** (later; not in build step 4): a group can be defined by a rule (e.g. "quality = rare and ilvl ≥ 600 and BoE") instead of a fixed item list. Fixed items always win over rule matches. The auto rules of §5.2a are different: they add items to groups; they do not define a group.

**Groups and operations design (decided 2026-10-14)**

1. A group stores an item as it was added: the base key for plain items and commodities, and an exact variant key only when a specific link is added. Lookup uses the exact key first, then the base key (D20).
2. Smart (rule-based) groups come later, not in build step 4.
3. Starter groups and auto profession groups come later, with the onboarding work. Build step 4 starts with an empty tree that has only the Base group.
    - **Root groups (user request, 2026-10-15).** The Base group (id 1) stays in the data as the hidden parent of all top-level groups, so no data changes. The Groups page tree shows the top-level groups (the children of Base) as its roots, and as many as the player wants. It ends with a node "[No group]". That node is Base: it has the operations that every group and every item of no group inherits (point 5), and it cannot be renamed, moved or deleted. "New group" makes a subgroup of the selected group, or a root group when "[No group]" is selected. There is no "New root" button. A drop on the empty tree, or on "[No group]", moves a group to the top level. The header shows the path without Base.
    - **Create dialogs (user request, 2026-10-17).** The kit has an input window, `Kit.Prompt` (`Shared/UI/Kit/Prompt.lua`). It has a title, a label, a text box, an optional type list above the box, OK and Cancel. Enter is OK. Escape and Cancel close it. OK is off while the trimmed text is empty. The caller can give a `validate` function; its error text shows under the box. If `onOK` gives a text, that text shows as an error and the window stays open. The pages use the store messages, so the name rules are the same as before (empty, duplicate and 40 characters). On the Groups page, "New group" and "Rename" (right-click menu) open this window; the name box under the tree is gone. On the Operations page, "New" opens this window with the type list first, then the name. "Rename", "Duplicate" and "Delete" are in the right-click menu of the operation list. The toolbar has "New" and "Import". "Import" uses the same import flow as the Groups page (`Shared/UI/Pages/RulesImport.lua`) and imports below Base.
      In-game checklist (open, both clients): (1) Groups page: "New group" with a group selected opens the window with the label `Group name (below "<name>")`. Type a name and press Enter: the group appears under the selected group. (2) With "[No group]" selected, the label says `a top-level group` and the group is a root. (3) There is no "New root" button. (4) An empty name keeps OK off. A name that a sibling group has shows the store message under the box and keeps the window open. (5) Escape and Cancel make no group. (6) Operations page: "New" asks for the type, then the name, and selects the new operation. (7) Right-click a row: Rename (starts with the current name), Duplicate (asks for the copy name) and Delete (asks first). (8) The toolbar has no Duplicate, Rename or Delete button. (9) "Import" opens the paste window; a good text shows the preview and then imports.
4. Deleting a group asks first. It deletes the group and its sub-groups, and moves their items to the parent of the deleted group.
5. One operation can be attached to many groups. Each group has at most one operation per type. A sub-group uses the operation of its parent for a type, unless it has its own.
6. Operation types in the MVP: selling, buying, vendoring.
7. Custom sources (named formulas) come in build step 4. A loop between custom sources is refused when saved (see the formula language design).
8. Selling defaults: undercut 1c; duration 24 h; post cap 0 (no cap); below minimum: do not post; above maximum: post at maximum; cancel when undercut: on. Price defaults: minimum = the default selling minimum formula (§4); normal = `scanmarket`; maximum = `2 * scanmarket`.
9. Every operation has two safety settings (§3.4): skip an item if its price data is older than 72 h, or if it has fewer than 3 days of data (`ScanSamples`). Both can be changed for each operation. A selling operation also has the setting "Needs scan data" (`needScanData`, default on). If it is off, the two safety checks do not apply, and a missing normal or maximum price does not stop the post (the 2026-10-15 default operation below).
10. Vendoring: never sell to a vendor an item whose `ScanMarket` is more than 2× its vendor price. Such items are listed for review. Buying default: maximum price = `scanmarket`.
11. Group names have 1-40 characters after trimming, and are unique among sibling groups (case-insensitive). A tree has at most 8 levels below the Base group. The Base group cannot be renamed or deleted.
12. Items are added from bags (select rows in the bag pane, then use the right-arrow button), by name search, or by link. Adding from AH search results comes with build step 6.
13. Profiles stay "Default" only in build step 4 (profile switching is Phase 2). Rules live in the profile scope.

**Feedback decisions (2026-10-14)**

1. **Item search by name** (everywhere a name is searched):
   - Enter starts the search.
   - Items that are already in the target group are hidden from the results.
   - The result list stays until the next search.
   - Text in double quotes (`"Linen Cloth"`) matches that exact name only, without case sensitivity.
   - Text without quotes matches each name that contains the text.
2. **Names for items without scan data.** First use the game client's item cache. If the Auction House is open, then search the AH for the name. No item database ships with Flipside.
3. **Group page.** The page has two inner tabs: "Items" (add and remove items) and "Rules" (the operations for each type). "Items" is the first tab and the default (changed 2026-10-15). The Items tab is a split pane. The left pane lists the bag items. The right pane lists the items of the selected group. Both panes anchor to the page frame and follow its size. A bag item that is already in the selected group is hidden in the left pane. A row is selected by a highlight, with no check box. A click toggles one row. A Shift-click adds the rows from the last clicked row to the clicked row. The right-arrow button (">") between the panes adds the selected bag items to the group. An item that is in another group moves to this group. The left-arrow button ("<") removes the selected group items from the group. Both selections clear after a move, and both lists update at once. The add box (name, link or id) is above the right pane. The bag list reads the bags again when the tab opens and when the page refreshes. The list selection is a Kit.List option (`multiSelect`) with no Flipside name in the Kit (D19).
4. **Drag and drop.** The player drags a group into a parent group or out of it (a move). Lists stay sorted by name. No manual order is stored. Operations sort by name.
5. **Keep amount.** Selling, vendoring and mailing operations get a "Keep in bags" setting (the mailing field is `keep`, §5.5): a number for each item, default 0. That many units of each item stay in the bags. Bank counts are tracked in the MVP (see §5.10), but "Keep in bags" still counts the bags only. Keep-stock rules (D8) have priority over it when they exist.
6. **Export and import of groups** (MVP, see §7.4). The format is a documented, readable, versioned Flipside text format. It holds a group, its sub-groups, their items, and copies of the operations they use. Import shows a summary and asks before it changes anything. It never imports TSM strings (D13). Import rules:
   - The import goes under a parent group that the player picks.
   - If a group name already exists under that parent, the new group gets the suffix " (2)".
   - If an operation has the same type, name and settings, Flipside reuses it. Otherwise it imports a copy named "<name> (imported)".
   - Items that are in another group move to the imported group. The summary shows how many.
   - Custom sources that imported operations use are included. They follow the same rename rule.
8. **Operations page.** Each formula field has an expand button that opens a larger editor. The editor has no example item box (removed 2026-10-17). The preview of a formula shows only if the formula compiles and which sources it uses. A refusal message takes the place of the preview. The field rows are compact (changed 2026-10-17): a simple field (text, number, money, choice) is one line of 28 px, and the label and the control sit on the same middle line. A formula field is 44 px and has one preview line below. The list has the height of its rows, so the item type boxes and the footer follow it with no empty band. A refusal message of a simple field shows to the right of the control. The footer lists the groups that use the operation, one group on each line under "Used by:" (at most 5 groups, then "and N more"); it shows "Used by: none" for an unused operation. The rarity choices show in the colour of the rarity (`Kit.QualityText`). For a mailing operation, the item types are check boxes (`Kit.CheckGrid`, 3 columns) in the editor, below the field list.

#### 5.2a Auto rules (user request, 2026-10-17)

Auto rules put new bag items into groups. The player sets the rules once.

1. **Rule.** A rule has a target group and these filters: a name pattern (regex), a lowest and a highest rarity (quality 0 to 5), and item types (many classes). Every filter is optional, but a rule must set at least one. A rule with no filter cannot be saved and never matches. All filters that a rule sets must match (AND). Empty item types mean any type. The highest rarity 5 (Legendary) has no upper limit. Auto rules may use Legendary; the mailing filters stop at Epic (§5.5).
2. **One global list.** The rules are one ordered list for the profile. The first rule that matches an item wins. Example: rule 1 `^Linen` with Uncommon to Legendary goes to "Uncommon Linen". Rule 2 `^Linen` goes to "Linen". The player changes the order with the Up and Down buttons. The list holds at most 50 rules.
3. **Name pattern.** Flipside has its own small regex engine (`ns.NameRegex.Compile(source)` gives a matcher or an error text; `matcher:Match(name)` gives true or false). The match ignores case and is not anchored unless the pattern has `^` or `$`. The editor shows the compile error as the player types. If the engine is not loaded, a rule with a name pattern never matches.
4. **When it runs.** The runner waits for the bag event `BAG_UPDATE_DELAYED` (0.5 s throttle) and once at login. It checks each bag item that is in no group (the lookup gives Base). The first matching rule adds the item to its group, for good, as a normal item add (D20 keys). An item that is already in a group never moves. An item whose name, rarity or type is not known yet is skipped and tried again on the next bag change. Bound items are not read, as for the other bag lists. The built-in All bag items group, and Base, cannot be targets.
5. **Messages.** One chat line for each batch: "Flipside: N items added to groups by the auto rules".
6. **Switch.** A check box turns the automatic mode off. The default is on. The Apply now button works when the switch is off.
7. **Apply now.** The button shows a confirm dialog with a preview list (item > group, 15 lines and a count of the rest). On confirm, Flipside plans again from the current bags and adds the items.
8. **Deleted group.** A rule whose group was deleted stays in the list, is shown in red with "(no group)", and never matches. The player edits or deletes it.
9. **Storage.** The list (`autoRules`) and the switch (`autoRulesOff`) are saved in the profile group data. A profile from an older version has neither: the list is empty and the switch is on. The group export (§7.4) does not include auto rules.
10. **UI.** The Groups page has a third inner tab, "Auto rules". It has the switch, the buttons Add rule and Apply now, and the rule list. Each row has the order number, the filters, the target group and the buttons Up, Down, Edit and Delete. The Add and Edit buttons open an editor window: pattern box with error line, two rarity drop-downs (each rarity in its quality colour), the item types as a grid of check boxes (`Kit.CheckGrid`, 3 columns, same list as the operation editor; changed 2026-10-17, a pick keeps the editor open and the window grows for the grid), the group drop-down, Save and Cancel.

In-game checklist (open, both clients):
- Open the rule editor. The rarity names show in grey, white, green, blue, purple and orange, in the drop-down button and in each entry. The item types show as check boxes. A click on a box toggles it and the editor stays open. No text is cut off and the Save and Cancel buttons are visible.
- Make groups "Linen" and "Uncommon Linen". Add the two rules of point 2. Put a Linen Cloth and an uncommon Linen item in the bags. After a bag change both go to their groups, and one chat line shows.
- An invalid pattern such as `(` shows an error in the editor and Save stays off.
- Clear all filters of a rule: Save stays off.
- Turn the switch off. New items stay in no group. Apply now shows the preview. Confirm adds them. Cancel adds nothing.
- Up and Down change which rule wins. A rule with a deleted group shows in red.
- An item that is in a group does not move when a rule would match it.
### 5.3 Buying (reference §5.2 Shopping)

- Search by text, filters, group, or "everything in my shopping lists".
- Result columns add **% of ScanMarket** and **data age**.
- Group search uses the Buying operation: max price, and an optional *buy up to keep-stock target* that limits quantity to what Keep stock says is missing.
- Commodity purchases show the quote and total before confirming.
- Price level list. Each column takes a share of the list width: Unit Price and Available 50% each, or 33% each when Stack Price shows. A list of item stack groups gives Available a share of 1.6 against 1 for the other columns, because "50 stacks of 1" is long. Headers and cells are right-aligned. The Kit column option is width = { share = n }.
- Totals row. A row below the price level list, with the label "Total" on the left, shows the total quantity and the total cost of all levels that you can buy. It uses the same columns. The label and the cost are in one cell: the Unit Price column on Forever, and the Stack Price column on a client with no commodity market (TBC), where the cost is a sum of stack prices. It is not selectable. Own levels and levels above the max price are not in the totals. A tooltip on the row says this.
- Max price. The max price belongs to the buying operation: the formula field `maxPrice` (default `scanmarket`, and an empty formula means no limit, see point 20). The Operations page edits it. `BuyingPlan` reads it from the operation of the item group, and the Buying tab only shows and uses the result. The item list on the left shows it for each item, or "no max" in grey. The right pane does not show it.
- Amount box. The box starts at 1 unit (user request, 2026-10-15) and again after each new item or level selection. An empty box means all units up to the selected level, or the next level if no level is selected. The total price shows on the right of the box. It covers the whole range, from the cheapest level up to the selected level. If the user types a number, the box keeps it and the total updates. The tab has no Log button. The jump warning box centres its text.
- Message line. The line shows only real messages: an error, a wait for the Auction House, or the reason why the buy button is off. The panel shows no "buyable", "stop" or "end of results" text.

### 5.4 Selling (reference §5.1 Auctioning)

- Same min / max / normal model, below-min and above-max actions, undercut and cancel rules.
- **Dry run:** runs the post and cancel logic without touching the AH and shows the queue with prices and reasons. The Buying tab has it. The Selling tab has no dry run (removed 2026-10-15, user request).
- **Decision log:** every item gets one reason code (posting at undercut, at normal, below min, stale price, invalid price, keep-in-bags reached, post cap reached).
- Blacklist of sellers works only from targeted searches (full scans carry no seller names).
- **Keep in bags:** the operation has a number for each item (default 0). Posting leaves that many units of the item in the bags (see the feedback decisions in §5.2). The selling rule fields (stack size, keep quantity, post quantity, duration, vendor skip and sample fallback) are in point 27 below.

#### Buying and Selling decisions (step 6, 2026-10-14)

The user decided points 1 to 4. Points 5 to 9 are defaults from the study recommendations. The user can change them.

1. Build order: the Buying tab first, then the Selling tab. Both use the same step 6 stack.
2. Every purchase asks for confirmation in v1 (D26). The confirm shows the final server price, because Forever quotes can rise between the search and the buy. Flipside never buys without a click. One click makes one protected AH call.
3. The default undercut is 1 copper. The operation can override it.
4. Selling has an operation field `stackSize`. The default is a full slot (the maximum stack; the value 0 means this). The client limit caps the value. A commodity posts the whole quantity as one listing. On TBC the operation also has `maxStacks` (point 27, 2026-10-16).
5. Items below the minimum price are skipped (the `belowMin` default, §5.4).
6. No keybinds in v1.
7. Step 6 started on WoW: Forever. TBC Buying is done (2026-10-16): the Buying tab sits in the TBC `AuctionFrame`, next to the "Flipside" tab, in the compact size of the host insets. TBC Selling is done (2026-10-16, see point 14a): the Selling tab sits in the TBC `AuctionFrame` after "Flipside" and "Buying". The TBC Buying rules:
    - The search is an exact-name `QueryAuctionItems` query. The Buying tab reads all result pages (see "Page read" below); `Backend.LiveSearch(itemID, page)` sends one page (0-based, 50 rows). The Selling tab still reads page 0 only. The legacy client allows one query at a time (`CanSendAuctionQuery("list")`). The result is the event `AUCTION_ITEM_LIST_UPDATE`.
    - Every listing is an item auction (no commodity market, no quote). The row ID is the list index of the page that the client shows. A buy is `PlaceAuctionBid("list", index, buyout)`, one protected call for each click.
    - Before the call, the backend reads the row again. It must have the same item, count, buyout and owner as the search row. If not, the buy is refused with "the listing changed, search again" and no AH call.
    - The legacy client has no purchase event with an ID. The backend reads the system text `ERR_AUCTION_WON_S` and `UI_ERROR_MESSAGE` for 20 seconds after the call. If neither comes, the tab shows "no response".
    - **Stack groups (user request, 2026-10-21; replaces the rule "one row for each auction" of 2026-10-20).** Item auctions are the auctions of TBC and the item auctions of Forever (not commodities). The price level list has one row for each stack group. The group key is the item (the exact key of the item link, D20), the seller (`owner`), the buyout and the stack size. Auctions with the same key are one row. Two sellers, two prices or two stack sizes are different rows. The row shows unit price, stack price, Available, seller and time left (codes 1 to 4: Short, Medium, Long, Very long; the lowest code of the group). The rows are sorted by unit price, then by stack size, then by seller. The code is `BuyingPlan.GroupKey` and `BuyingPlan.PriceLevels`. The flavour flag `buyGroupAuctions` is removed.
    - **Available column (2026-10-21).** The column "Quantity" is now "Available". A stack group reads "50 stacks of 1", and one auction reads "1 stack of 20" (`BuyingPlan.AvailableText`). A commodity row on Forever has no stacks and keeps the plain quantity ("x5"). The totals row keeps "x" and the number of items. The Seller column shows when the rows of a stack group have a seller (always on TBC; on Forever when the search result names one owner). The Time left column shows on TBC only.
    - **Buy flow (2026-10-21).** The user presses Buy (or selects a group and presses Buy). The box opens for the first auction of the group that is not yours, and says "Buy one stack: N x item", with the unit price, the total, the seller, the time left and "Available: 50 stacks of 1". The button reads "Buy". One click is one `PlaceAuctionBid` or `PlaceBid` for one stack (D26). While the buy waits for its result, the button is off. After the success the box stays open, the tab reads the rows again, and the button reads "Buy next". Buy next buys the next identical auction of the same group (same item, seller, buyout and stack size), one for each click. The count in "Available" goes down after each buy. A buy never moves on to another group: if the group has no stack left, the box says "No more stacks in this group" and only Close works. An error (`UI_ERROR_MESSAGE`, or a refusal) shows as "Error: ..." in the box. The auction is dropped from the list if it is still there, and the box offers the next stack of the group with "Buy next". A timer or an event never calls `PlaceAuctionBid` or `PlaceBid`.
    - **Auction identity (2026-10-21).** The list indexes shift after a buy or a list update. Before each buy the tab reads the list again (`LiveRows`) and looks for an identical auction: the same group key. It uses the index of the shown auction first. It never takes your own auction, and never one of another price or stack size. If another identical auction exists, the tab buys that one. If none is left in the list that the client shows, it buys nothing and shows "Error: the auction is gone"; the box then reads the page of the next identical auction, or shows "No more stacks in this group". The backend check of point 7 still runs. On Forever the new auction ID comes from the same search result.
    - **Price jump (2026-10-21).** The rule of point 12 is the same (threshold `buying.jumpPercent`, base is the last price bought in the run or the cheapest group), but for an item stack it shows as a line in the confirm box, "Price jumps from X to Y (+Z%)", in red, before the click that buys. A commodity keeps the "Keep buying" dialog. The next stack of the same group has the same price, so it gives no jump.
    - **Your own auctions (2026-10-21).** Your own auctions show as a group with the seller text "You" (grey, as an own level). On TBC the row is yours when the owner equals `UnitName("player")`; on Forever when `containsOwnerItem` is true. Buy is off for the group ("own listing"), and the re-find never takes it. The totals and Buy next skip it.
    - **Page read, TBC (2026-10-21).** The Buying tab reads all pages of the search so that the count is complete. It sends page 0, learns the number of pages from `GetNumAuctionItems("list")` (total divided by 50, `Backend.LivePageCount`), and sends the next page when the client allows (`CanSendAuctionQuery("list")`; the tab waits for the ready event and tries again every 0.5 s). The message line shows "Reading page 2 of 5". The Stop button shows during a read of more than one page and stops it ("read stopped"); the earlier result stays. A new search, or a click on another item, stops the old read and starts again at page 0. Each page has a timer of 10 s; a page that does not come gives "no response". Each row carries its page. Pages are read one after the other, so a seller who posts or an auction that sells during the read can move a row to another page; the count can be off by that much, and the buy re-find still protects the price and the stack size. The Forever item search has one result list and no pages; `LivePageCount` gives nil.
    - **Page read after a buy (2026-10-21).** `PlaceAuctionBid` uses the list that the client shows, so the page of the auction must be in that list. After a buy the tab reads again only the pages that hold the group, from the last page to the first (a buy moves later rows up, so the first page of the group is the one that is live at the end). The result replaces the rows of those pages; other pages stay. This keeps the count exact and costs one query for each page of the group. If the next identical auction is on another page, the box reads that page first (one query, at most 8 for one step). After a full read and when a group is selected, the tab reads the page of the group again if the client list shows another page. These reads are not buys and need no click. Reading all pages again after each buy was rejected: it costs more queries and gives no better count.
    - **In-game checklist, buy stacks (open).** TBC: (1) Search an item that one seller posted as several stacks of 1: one row, "N stacks of 1", with seller and time left, and the header "Available". (2) Two sellers with the same price are two rows. A different stack size or price is a separate row. (3) With more than 50 auctions of the item, the message line shows "Reading page 2 of N", the Stop button shows, and the count includes all pages. Stop ends the read. A new search during the read starts again. (4) Select a group on a later page and press Buy: the box opens ("Buy one stack", "Available: N stacks of M"). Click: exactly one stack is bought. (5) The button now reads "Buy next". Click until the group is empty: the box says "No more stacks in this group". (6) Cancel in the middle: nothing more is bought. (7) Let another player buy a stack of the group while the box is open: the next click buys another identical stack or shows "the auction is gone", never another price or stack size. (8) Your own auction shows as "You" and Buy is off for it. (9) A dearer group shows the price jump line in the box before the click. Forever: (10) Search an item (not a stackable) with several equal auctions: one row "N stacks of M", Buy and Buy next buy one stack for each click. (11) A commodity still shows "x5" under "Available" and the quote flow is as before.
8. The decision log is a table for the session. From step 7 PR9 Flipside also saves it in the ledger (§5.8, changed 2026-10-15). Before PR9 it is not saved. The Ledger page shows each saved entry as the detail of the matching row in its Auctions tab. A dry run shows as a row with the mark "dry run".
9. The buying plan (`BuyingPlan`) is pure logic. It lists the items of all groups that have a Buying operation, with the maximum price for each item. It shows the buyable rows of live search results, and it stops with a reason: "above max price", "own auction only", "no results" or "no max price". For a commodity, the buy unit is a quantity at a quoted unit price. For an item, the buy unit is one auction. The option `showAboveMax` lets the UI show rows above the maximum, but never buy them.
10. The Forever host can add many Flipside tabs (`ns.AuctionTabs.Register`). The Buying tab shows the shopping list and runs live searches (one item, or all items one at a time). It evaluates the rows and logs each decision. It lists the listings of the selected item grouped by price level (unit price, stack price, Available; see point 12a). Item auctions are grouped by seller, price and stack size (point 7). The Stack Price column follows the flavour flag `hasCommodityMarket` (true on Forever, false on TBC and on the other legacy flavours). If the flag is true and the selected item is a commodity, the list has no Stack Price column: the header and the cells are hidden. In all other cases, Stack Price is the unit price times the quantity of the listing that Buy buys. On a legacy client every listing is a stack with a stack buyout, so every level shows a Stack Price.
11. Buy buys the next cheapest price level: the whole quantity at that unit price for a commodity, or the next auction for an item. It needs a ready client, a level that is not yours and a unit price at or under the maximum price. It never buys above the maximum price. Each purchase has two clicks (D26). Click 1 starts a commodity quote (`StartCommoditiesPurchase`) and the confirm box shows the server unit and total price and the quote time left. For an item, click 1 opens the confirm box with the buyout price. Click 2 buys (`ConfirmCommoditiesPurchase`, or `PlaceBid` with the buyout for an item). A quote total above the maximum price times the quantity shows in red, and the button reads "Buy anyway". Cancel, Escape, a closed Auction House or a left tab cancels the quote.
12. Price jump warning: before it buys a level whose unit price is more than the threshold above the previous level bought in this run (or above the first level if none is bought yet), a box says "Price jumps from X to Y (+Z%). Keep buying?" with "Keep buying" and "Stop". The default threshold is 25 percent. The Buying tab edits it, and the profile saves it as `buying.jumpPercent`. "Keep buying" is the click that starts the purchase. "Stop" ends the run.
12a. **Row selection and amount (user request, 2026-10-15).** A click on a row of the price level list selects the level. The row shows the Kit selection highlight. A second click on the same row clears the selection. The button always reads "Buy" (user request, 2026-10-15), with or without a selected level. A click on a row of your own or on an "Above max" row selects it, but the button is off and the message line gives the reason. One click is still one buy (D26), with the same confirm box.
    - **Commodity.** A purchase takes the cheapest units first, so a buy is one purchase of all units from the next cheapest level up to and including the selected level. The confirm box shows the real total. The API cannot skip own units. So if a level in that range is yours, the button is off with the reason "own listing below the selected level".
    - **Amount box.** The box next to the buy button takes a number of units. The default is 1. Empty means all units up to the selected level, or the next level if none is selected. A number N buys the N cheapest units, capped at the units up to the selected level (or the next level). Any text that is not a whole number above 0 turns the button off with a reason. The summary shows the units and the estimated total.
    - **Item.** A buy is one stack, the first auction of the selected stack group that is not yours (see "Buy flow" in point 7). The amount box is off for an item.
    - **Jump warning.** It compares the highest level that the purchase reaches with the previous level bought in this run, or with the cheapest level that is not yours if none is bought yet. A level that is taken in part does not move the run on.
    - **Highlight.** The rows that the next click buys have a fainter highlight. The selected row keeps the selection highlight. The highlight follows the selection and the amount.
    - **Next row in the confirm box (user request, 2026-10-16).** For an item, the next row is the next stack of the same group, with the button "Buy next" (changed 2026-10-21, see point 7); the rest of this bullet is for a commodity. After a buy succeeds, the confirm box stays open. Flipside reads the rows of the item again and waits for the new rows. If the next cheapest row passes the max price and the other buy rules, the box shows it with its own amount and total, and the selection moves to that row. Each buy still needs one click on Confirm (D26); no timer buys. While a buy waits for its result, Confirm is off, so a double click cannot buy twice; it is on again when the next row shows. A commodity quote start (`StartCommodityPurchase`) is protected, so no event may call it. For a commodity, the box first shows an estimate with the button "Get quote". The click asks for a new quote, and the box then shows the quote with Confirm (a second click buys). An item row is read again from the new list, so the backend check of the row (TBC fingerprint) runs again. The box closes when there is no next row, the next row is above the max price, a price jump warning is due (the warning box takes over), the user cancels, the user leaves the tab, the item changes, the new rows do not come (search timeout), or a buy fails (the error text shows as before). If the box cannot find the next row safely, it closes.
    - **Columns.** The list has Unit Price, Stack Price (hidden for a commodity) and Available (was Quantity, changed 2026-10-21; see the stack groups in point 7). It also has Seller and Time left for stack groups. The Status and Listings columns are removed, because the stack count of a group tells the listings. A row of your own or above the maximum is grey.
    - After a buy or a new search result, the selection stays on the same unit price if that level still shows. Else it clears. A new item, source or search list clears it. The "Dry run" box logs "would buy N at X" for the purchase.13. After a success, the tab logs "bought N at X", reads the rows of the item again and moves to the next level. After a failure it logs the reason and reads the rows again. The check box "Dry run" (default off) only logs "would buy N at X". Result events: `COMMODITY_PURCHASE_SUCCEEDED` and `COMMODITY_PURCHASE_FAILED` for a commodity, `AUCTION_HOUSE_PURCHASE_COMPLETED` and `AUCTION_HOUSE_SHOW_ERROR` for an item.
14. The Selling tab lists the contents of the bags as a tree of the player's groups (nested). The roots are the top-level groups (the children of the hidden Base group, id 1; there can be many). The last root is the node "[No group]": it holds the bag items of no group, and it shows whenever there is such an item (changed 2026-10-15; the Base node of the first change the same day is gone). Groups with no bag item are hidden. Bound items are hidden. A group row collapses and expands (UI kit Tree). An item row has the icon, the name with the bag count ("[Linen Cloth] x60") and these columns (see point 19): Your price, Operation, Lowest on AH, Net and Info. The name is the item link in the quality colour (point 26). Before the live result the row shows the expected price (the normal price of the operation, with a "~") in grey. An item with no selling operation shows "no operation" and Flipside never posts it. After point 17, only an item whose Base group lost the Default operation shows this.
14a. **TBC Selling tab (2026-10-16).** The Selling tab uses the same shared code on TBC Anniversary. `LegacyBackend` gives it the calls it needs: `CanPost`, `PostItem`, `ConfirmPostItem`, `Deposit`, `AvailablePostCount`, `IsSellItemValid`, `PostedEvent` and `RefreshOwned`. The rules:
    - **Layout.** The tab is compact, inside the `AuctionFrame`. The host content is 776 x 360 px (§3 item 7): the Buying and Selling panels use a bottom inset of 35 px, so they end above the gold display of the Blizzard frame (`AuctionFrameMoneyFrame`: bottom edge 18 px above the frame, 13 px high, `Blizzard_AuctionUI.xml:87-95`). The Flipside tab keeps its inset of 14 px (its bottom bar starts right of the money display). The panel keeps its parts and its widths (the widest line ends at x 760). Only the list gets shorter: with the toolbar empty the list is 238 px high (10 rows); while the Stop button of the Selling tab shows (Forever only, see the band rule below) it is 210 px (9 rows). The list scrolls. The details pane is 100 px high and the action row is gone (changed 2026-10-16: Post and Skip moved into the pane, point 19), so the list keeps the same top line as before. The Forever layout (point 19) uses the same pane.
    - **Post (multisell rule, 2026-10-16).** One Post click posts several stacks of one item. The backend checks the bag slot, puts the item in the sale slot (`PickupContainerItem`, then `ClickAuctionSellItemButton`), reads it back with `GetAuctionSellItemInfo`, and calls `PostAuction(start, buyout, durationIndex, stackSize, numStacks, false)`. The client needs all six arguments: the sixth is the warning flag (`false` in `AuctionPostMixin:OnClick`, `true` in `ConfirmPost`, Blizzard_AuctionUI.lua lines 2314 and 2329). With five arguments the client raises a "Usage: PostAuction(...)" error (seen in game 2026-10-16). The start price and the buyout are for one stack (`Blizzard_AuctionUI.lua`, classic_anniversary: `StartPost` gives the stack size and the stack count of the sell frame to `PostAuction`). With `numStacks` above 1 the client posts the stacks one after the other, and it needs one hardware event for the whole call. The sale slot reports the items in all bags (`GetAuctionSellItemInfo`: stack size and total count), and the client checks stack size x stack count against that total; so the stacks can come from several bag slots. This is not verified in game: if the client takes the stacks from one slot only, the stack count that the events report is lower, and the post ends as a failure with the count (see Multisell result). The buyout is the price of one stack. The start price is the bid, or the buyout if there is no bid. A post of one stack uses `numStacks` 1.
    - **Queue units (2026-10-16).** The plan makes one unit for all the full stacks of an item (stack size x stack count) and, if items are left, one more unit for the remainder: for example 47 items at stack size 20 give 2 x 20 in the first click and 1 x 7 in the next click. There is no remainder if the operation sets a max stacks value (the user limited the number of stacks) or if the post quantity cap leaves no room. A group selection joins the units of all its items in one queue (point 16); each item keeps its own units, and one click posts one unit. The progress text counts stacks.
    - **Multisell result (2026-10-16).** `PostAuction` with `numStacks` above 1 sends `AUCTION_MULTISELL_START(total)`, then `AUCTION_MULTISELL_UPDATE(created, total)` for each stack, or `AUCTION_MULTISELL_FAILURE` (all checked in the classic_anniversary source: `AuctionFrameAuctions_OnEvent` disables the create button at the start and shows the progress bar). Each stack also gives the system text `ERR_AUCTION_STARTED`. `LegacyBackend` turns these into the event `Flipside.LegacyMultisell` with `kind` ("start", "update" or "failure"), the created count, the total and a text. A failure comes from `AUCTION_MULTISELL_FAILURE`, from `AUCTION_HOUSE_POST_ERROR` or from a `UI_ERROR_MESSAGE` whose text is one of the client `ERR_AUCTION_*` texts (for example `ERR_AUCTION_DATABASE_ERROR`), while a multisell runs (at most 30 s after its last step). The Selling tab waits for this event after the call. It blocks Post, Skip, the manual controls and a bag read until the update count equals the total, a failure arrives, or a timeout of 15 s plus 3 s for each stack ends the wait. At the total the unit is done. A failure or the timeout marks the entry "failed" with the text and the count ("2 of 3 stacks made"); the stacks that the client made count as posted. The row stays in the list with the Info text "failed: ..." and the rest of the stack count (changed 2026-10-16). While the post runs, the Info column reads "posting 2 of 3 stacks". A single-stack post (and a Forever post) waits the same way for the created event of the client (`PostedEvent`: "Auction created." on TBC, `AUCTION_HOUSE_AUCTION_CREATED` on Forever), with the timeout of 18 s; see the row rule in point 19.
    - **Check before the post.** The Selling tab gives the planned item ID. If the bag slot is empty, holds another item, or holds fewer items than the quantity, the backend refuses with a text and makes no `PostAuction` call. It also refuses if the cursor holds an item, or if the item does not go in the sale slot. In these cases it clears the cursor.
    - **Confirm.** If `PostAuction` gives false, the client wants a confirm. The backend hides the client dialog, and the Selling tab asks. `ConfirmPostItem` calls `PostAuction` again with the confirm flag, once, for the same arguments. If `AUCTION_HOUSE_POST_ERROR` or a `UI_ERROR_MESSAGE` comes during the call, the backend refuses with that text. `AUCTION_HOUSE_POST_ERROR` is an event on this client: `AuctionFrame_OnLoad` registers it and shows the static popup of the same name (checked in the classic_anniversary source 2026-10-16). The event comes during the `PostAuction` call. For a multi-stack post, an error text that comes after the call returns is handled by the multisell result rule. For a single-stack post it is not seen (open point).
    - **Duration.** The index is 1 for 12 h, 2 for 24 h and 3 for 48 h (`AuctionFrameAuctions.duration` in the client source, set by `AuctionsRadioButton_OnClick`; user confirmed 2026-10-16: the TBC Anniversary durations are 12, 24 and 48 hours, not 2, 8 and 24). A value with no exact match uses the nearest longer index that exists, and 3 above 48 h. So 2 h gives 1, 13 h gives 2, 30 h gives 3 and 72 h gives 3. A value that is not a number is an error.
    - **Click rule.** `PostAuction` is protected. The backend calls it only inside `PostItem` and `ConfirmPostItem`, and these run only from the Post button or the confirm button. No timer posts. On TBC, Post needs one click for each unit (a unit is all the full stacks of an item, or its remainder). The Post button stays off until the client confirms the last post (changed 2026-10-16; the 1 s lock of the removed Post all button is gone).
    - **Deposit.** `GetAuctionDeposit` works only for the item in the sale slot, so `Deposit` is nil while the slot is empty. Decided 2026-10-16 (user: "We can use the sell slot. That is totally fine to do."): the Selling tab keeps the selected item in the Blizzard sale slot. A select click (mouse) calls `LegacyBackend.HoldSlot`, a protected step that runs only inside the click. It checks that the AH is open and the cursor is empty, puts the bag item in the sale slot (pickup and `ClickAuctionSellItemButton`), and leaves it there. An item that waits for its decision goes in with its first bag stack. For a group, the slot holds the one item that the pane shows (the one Post posts next), else the first item that waits for its decision. With the item in the slot, each redraw of the pane reads `Deposit` again with `GetAuctionDeposit(duration index, start, buyout, stack size, number of stacks)`. That is a plain read with no fill. It runs when the decision of the item arrives (event) and when the price, the stack size, the stack count or the duration changes, and it updates the unit, the entry and the pane. The code releases the slot (`LegacyBackend.ReleaseSlot`: the item goes back to its bag slot, never left on the cursor) when the user selects another item (the same click then fills the slot with the new item), on a Skip click, when the Selling tab is left or hidden (this includes a switch to a Blizzard tab of the AH, so that the Blizzard "Create Auction" slot is not changed), and when the AH closes. A change that is not a click (the item leaves the plan, a bag read) only ends the reads; the next click, the tab leave or the AH close releases the slot. The Post click reuses the kept slot if it holds the right item and enough items (it does not fill twice), keeps the vendor guard, and the slot is empty after the post. After a post the next item is not put in the slot in the same click (the post is still in progress); the next select click or Post click fills it. If the slot cannot fill (cursor busy, locked item, combat, AH hidden), the deposit stays unknown. An unknown deposit shows as "unknown" in the pane and as "Deposit: unknown" in the warning (never 0), and the warning shows Net as "Net (before deposit)". The vendor skip rule keeps the net without the deposit; the Post click guard checks the real deposit. No code calls `PostAuction` outside the Post click. Forever is not changed. `Deposit` takes the prices and the stack count and gives the deposit of all the stacks.
    - **Deposit check at the Post click (decided 2026-10-16).** On each Post click, `PostItem` puts the item in the sale slot and reads the real deposit of all the stacks with `GetAuctionDeposit(duration index, start price, buyout, stack size, number of stacks)`, with the real prices of one stack. If the operation has the vendor rule on and the vendor price is known, the Selling tab then applies the Net rule (price x quantity - AH cut - deposit). If the vendor pays more, the code puts the item back in the bag, calls no `PostAuction`, and shows the vendor box (changed 2026-10-16: one short box). The box has two lines for all the stacks of the post: "Sell to vendor for: N" and "AH net profit: S". S is the price x quantity - AH cut - deposit. The larger value is green (client colour code), the other value has no colour. The deposit is the real one that the pane shows: the pane value if it is known, else the value that this read gives. "Post anyway" posts once in its own click with the same arguments. "Cancel" posts nothing and skips the item with the reason "vendor pays more than the AH". If the user already accepted the box for the item, the check does not ask again. The check does not depend on the field "Skip if vendor pays more". If the client gives no deposit, the post goes on as before. No timer or event calls `PostAuction`.
    - **Result.** The backend emits `Flipside.LegacyPosted` when the system text `ERR_AUCTION_STARTED` comes within 20 s of a post call. The Selling tab then reads the bags again. For a multi-stack post the tab also uses the multisell result. The ledger writes one post record for each created stack (§5.8): the call gives one hint for each stack, and each `Flipside.LegacyPosted` event takes one hint.
    - **Stack controls (2026-10-16).** On TBC the details pane shows "X stack of Y" (the stack count and the stack size, changed 2026-10-16; see point 19, "Pane inputs") for the next click. They start with the plan of the next unit and the user can change them before Post. The stack size is limited to the free items (the count minus the keep quantity) and to the maximum stack of the item. The stack count is limited to the stacks of that size that the bags hold. A change of the stack size keeps the stack count. The choice clears after the post or a skip. Forever shows only the stack size box.
    - **Post delay (2026-10-17).** The client refuses a post that comes too fast after the last one. After each real post call, Post stays off ("Wait..." on the button) until two things are true: the result came (the created event, a failure, or the 18 s timeout of the rule above) and the flavour value `postDelay` passed (TBC 1.0 s; Forever 0.5 s, not tested in game). A timer of `postTimeout` (5 s) ends the lock even with no result, so Post never stays off. The lock starts no post (D26): the next post needs a new click. A failed post keeps its row with the Info text "failed: ..." as before. On TBC, an `ERR_AUCTION_*` UI error or `AUCTION_HOUSE_POST_ERROR` after a one-stack post now gives a failure of 1 stack at once (`LegacyBackend` sets `post.single`), so the user does not wait for the timeout. Forever has no such event yet (open point: the Forever post error events are not checked). The tab writes log lines in the category `selling` when `ns.Log` exists: post click, success, failure, lock timeout, multisell steps and item name requests.
    - **Post throttle gate (2026-10-20).** The client has an own throttle for AH messages, so a fast post gives "Internal auction house error" (`ERR_AUCTION_DATABASE_ERROR`). Post is off while the gate is closed, and the Post click (`_PostStep`) refuses with "The auction house is busy. Wait a moment." and makes no post call. The gate combines with the scan lock and the post lock. TBC: the gate is `CanSendAuctionQuery("list")` (`AuctionClient.CanSendPost`). The client has no event for it, so the tab polls it every 0.25 s on its own timer, only while the tab shows and the gate is closed. Forever: the gate is `C_AuctionHouse.IsThrottledMessageSystemReady()`. The tab sets the button again at `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, `AUCTION_HOUSE_THROTTLED_MESSAGE_SENT`, `AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED` and `AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED` (`AuctionClient.ThrottleEvents`). Forever also ends a post at once on `AUCTION_HOUSE_SHOW_ERROR` or `AUCTION_HOUSE_POST_ERROR` (event `Flipside.ForeverPostFailure`, same data as the TBC multisell failure): the row shows "failed: ..." with the error text, and Post comes back after the gates. Neither the poll nor an event posts or retries (D26).
    - **Item names (2026-10-17).** A bag link of an item that the client has not loaded has empty brackets ("[]"). The row never uses such a link. It shows the name from the bag, then the bracket name of the link, then the client name. If none exists, it shows "item <ID>", asks the client once (`C_Item.RequestLoadItemDataByID`) and draws the rows again when `ITEM_DATA_LOAD_RESULT` arrives (one redraw for 0.2 s of events). The Buying tab list and the Groups page item lists do the same.
    - **In-game checklist for post delay and names (open).** (1) Log in and open the Selling tab at once: no row shows "[]"; a row without a name shows "item <ID>" and gets its name a moment later. (2) Click Post fast on several items: the button reads "Wait..." and stays off until the last post ends and 1 s passed; no client refusal shows. (3) Cause a post error (for example not enough money for the deposit): the row shows "failed: ..." and Post comes back after the delay. (4) Look at the Buying tab and the Groups page after a fresh login: names fill in with no click.
    - **In-game checklist for the post throttle gate (open).** (1) TBC Anniversary: click Post fast on several items: Post is off while the AH is busy and comes back by itself within about a second; no "Internal auction house error" shows. (2) Forever: the same; Post follows the ready event. (3) Click Post while it is off, or use a macro: the pane shows "The auction house is busy. Wait a moment." and no post goes out. (4) Cause a post error: the row shows "failed: ..." at once, not after 18 s, and Post comes back.
    - **In-game checklist for multisell (TBC, open).** (1) With 47 of one item, stack size 20: the first Post click makes 2 auctions of 20, the progress text counts to 2 of 2 and Post stays disabled until it ends; the next click makes one auction of 7. (2) Max stacks 1 gives one auction and no remainder. (3) Check the deposit in the details pane against the Blizzard sell frame for the same prices and stacks. (4) Stacks in several bag slots: the full run posts them all, or the entry shows "failed" with the count made. (5) Close the Auction House or run out of money during a run: the entry shows "failed" with the count. (6) The ledger shows one post record and one deposit for each auction. (7) A stack size of 1 and a stack count of 1 post as before.
    - **No cancel, no dry run.** The Selling tab has no cancel call on Forever, so TBC has none. The dry run and the decision log follow point 8 and §5.4.
15. Selecting a group row selects the group and its subgroups; selecting an item row selects that item. Selecting "[No group]" selects the items of no group. Each item follows the rules of its own group. Nothing is selected when the tab opens. The selection starts the live searches of its items one after the other (queue, ready gating and the rate guard); Post may post an item that has its price while the others still wait (point 16, group queue) and `SellingPlan.Decide` fills the decisions. An item that already has a result is not searched again until the next full read of the bags (a change of the rules, or the end of a queue).
16. Decision: group selection posts the whole group as a one-click-per-auction queue. "Post" makes one protected post for each click (D26): the next stack of an item, or the one listing of a commodity. The button reads "Post" (or "Confirm post" while a confirm is open), and a progress text next to the buttons reads "Posting 3 of 12". "Skip" leaves the next auction. "Post all" and "Skip item" were removed on 2026-10-16 (user decision): Post and Skip are enough. **Group queue (user request, 2026-10-16).** A group or subgroup selection is one queue: the units of every bag item of the group and its subgroups, in tree order, then unit order. Each item builds its units like a single item (`BuildUnits`) with its own operation, inherited from the parent groups. An item with no bag stock is not in the queue. The searches of all items start in sequence when the node is selected, inside the rate limit. Post posts the next ready unit in queue order and passes over an item that has no price yet. If no item is ready, Post is off and the pane and the progress text say "N waiting". The progress text counts the units of the items that have a price. An item that the operation skips shows as skipped with its reason and does not stop the walk. After a price warning or a vendor box, the walk goes on with the other items (Post, Skip). There is no second queue view: the tree, the pane and the progress text show the queue. The panel shows no deposit of the queue. When the queue is empty the tab reads the bags again; it shows no text for it. If the server asks for a confirm (`needsConfirmation`), Flipside shows its own confirm and calls the confirm function on Accept. The tab has no dry run and no log view (removed 2026-10-15); the plan still records each decision for the ledger. The duration hours map to the AH index 1, 2 and 3: 2, 8 and 24 on Forever, 12, 24 and 48 on TBC (confirmed by the user, point 27c). The rule sets the duration. For one manual post, the player can choose the quantity and the duration in the details pane (point 26b). On TBC one click posts several stacks of an item with the client multisell (point 14a).
17. **Default selling operation (user request, 2026-10-15).** Flipside makes one real selling operation named "Default" and attaches it to the Base group. It is made once for each profile, when the profile has no record of it (`defaultSeeded` in the operations data), and only if Base has no selling operation yet. The user can edit, rename or delete it on the Operations page. A deleted Default does not come back, and then an item with no selling operation shows "no operation". Every group and every item of no group uses the operation of the nearest group above it, so Default covers all bag items that have no own selling operation. An item with its own operation keeps it. Settings of Default:
    - Undercut 1 copper. The price is the lowest auction of another seller minus the undercut (the live rows, not scan data).
    - Minimum price `first(vendorsell, 1)`: the vendor sell price as a safety floor when it is known, else 1 copper. This is a default that the user can change. Below the minimum the item is skipped (`belowMin` = skip).
    - Normal price `scanmarket`, used only when no other seller has an auction. If there is no scan value, the item is skipped with "no price".
    - Maximum price `2 * scanmarket`. With no scan value there is no maximum.
    - "Needs scan data" is off: the age and sample checks do not apply, and the item needs no scan record. All other settings keep the schema defaults (duration 24 h, no cap, full stacks).
    - For an operation with "Needs scan data" on (the default for all other operations), a missing normal or maximum price still skips the item. The skip reason names the price and the missing source, for example "no data for min price: scanmarket missing, scan again". Records from a scan before the history fix hold only the latest values, so `scanmarket` stays empty until the next scan stores a snapshot.
18. **Potential profit (user request, 2026-10-15).** For the auctions that are left in the queue:
    - Net = post price x quantity - AH cut - deposit. The deposit is the client quote for each auction (`Deposit`); an unknown quote counts as 0 in the Net number, and the pane shows "Deposit: unknown" and "Net (before deposit)".
    - vs vendor = Net - vendor sell price x quantity. The vendor price is the sell price of the item (`C_Item.GetItemInfo`, return 11, `sellPrice`). The Selling tab does not show vs vendor any more (changed 2026-10-15). The vendor price feeds the vendor warning and the vendor skip rule (points 26 and 27d).
    - AH cut = 5% of the sale price, rounded to the nearest copper (`SellingPlan.AH_CUT`). This is an estimate for the time before a sale. The Forever client source has no constant or API for the cut (searched 2026-10-15). A custom source `ahtax = 0.95` in the user's data uses the same rate.
    - Decided 2026-10-15: the estimate stays at 5%. The ledger does not use the estimate. It uses the real cut from the sale invoice: payout = bid + deposit - consignment (Forever `MailFrame.lua` lines 827-831). The cut is the `consignment` value (§5.8).
    - A negative value shows in red. Each row shows Net. The details pane does not show Net (changed 2026-10-16); the Post warning shows it (point 26). The tab shows no queue total of Net or vs vendor (changed 2026-10-15).
19. **Selling tab layout (user request, 2026-10-15; own design).** The panel has four parts, from top to bottom (sizes for the 800 x 538 Forever Auction House frame; the panel needs about 780 x 440):
    - Toolbar (24 px): "Stop" (it shows while searches run) and the status message. The toolbar row takes no space while the message is empty and "Stop" is hidden (the tab shows no "pick a group or an item" hint there, changed 2026-10-15): the action row, the details pane and the list move up 28 px and the list bottom stays. The tab shows no "search finished" text. The tab has no "Refresh bags", "Dry run" or "Log" (removed 2026-10-15). It reads the bags by itself (point 26).
    - Action row (changed 2026-10-16): the row is gone. "Post" and "Skip" sit in the details pane (next point), each 140 px wide, one under the other (changed 2026-10-16: "Post all" and "Skip item" removed, "Post" and "Skip" use their place). The progress text "Posting 3 of 60" sits in the pane under the operation name on Forever. On TBC it sits in the header band (see the layout rule below). The panel shows no deposit, queue Net or vs vendor text outside the pane. The list reaches the bottom of the panel.
    - **TBC layout (user request, 2026-10-16; Selling and Buying, the host in `AH_TBC/AuctionTabHost.lua`).** Three parts of the Bids art stay free of dead space. (a) Header band: the band between the frame top and the panel (y 22 to 52, right of the portrait, left of the close button) holds the Stop button and the progress text of the Selling tab (`api.band`), so the pane never moves for Stop. A cover texture (client atlas `auctionhouse-background-index`) hides the Bids header art there. The portrait and the close button stay free. (b) Right column: the panel right inset is 12 px (was 34), so the panel reaches the border art of the frame and the mismatched tiles do not show. (c) Bottom right: the two empty button slots of the Bids art (right of the gold display) are in the art itself. A cover frame hides them while a Buying or Selling tab shows. The tab click hook of the host hides the cover for every other tab, so Blizzard art returns. The Flipside tab does not use the cover. Forever has no band: its Stop button stays in the top row of the panel as before.
    - Skip is for the current run only (changed 2026-10-16). A skipped item stays in the tree. A click on it selects it again and makes it a normal item: Skip and the old vendor answer are cleared, the sale slot fills (TBC), and Post is on. An item that the rule skips goes back to the rule skip, so the Post click still asks first (price box, vendor box). After a reselect, the item is normal, and Post posts it when the item is the selection.
    - Details pane (100 px, UI kit Inset, changed 2026-10-16) for the next post of the queue. Left column: the icon, the item name, the operation name, the progress text, and the warning line (point 26, the one message line). Price column: "Unit Price" and "Stack Price" (two money inputs, both editable, linked: see "Pane inputs" below). Stack column: "X stack of Y" (two number boxes, with the labels "Max: n" under them). Right column, from the left: "Duration (hours)" with one radio button for each hour of the flavour (12, 24, 48 on TBC; 2, 8, 24 on Forever; `Kit.RadioGroup`), then "Post" and "Skip" under it. At the right edge: "Deposit:", its value, "Total Price:", its value (below). The right columns are anchored to the right edge of the pane, so a wider pane (Forever) only adds free space in the middle. The pane has no "Net", no "Lowest on AH" and no "vs vendor" line (Net removed 2026-10-16; the others 2026-10-15). When no post is left it shows "Pick a group or an item" or "Nothing to post".
    - **Pane inputs (2026-10-16).** Unit Price is the price of one item (the post uses it). Stack Price is the price of one stack: unit price x stack size. A change of the unit price sets the stack price. A change of the stack price sets the unit price to the stack price divided by the stack size, rounded down to whole copper (1005c for 10 items gives 100c each; the stack box keeps the typed text). A change of the stack size keeps the unit price and changes the stack price. Total Price is the unit price x stack size x number of stacks of the next post (on Forever, one auction: unit price x quantity). Deposit is the deposit of the same post; if it is not known, the pane shows "unknown", never 0. The stack count box ("X") and the stack size box ("Y") show the plan of the next unit. "Max" under X is the free items (the count minus the keep quantity) divided by Y, rounded down, at least 1. "Max" under Y is the free items, limited to the maximum stack of the item (TBC). The values are limited to these maxima. Each change reads the deposit again and changes what Post posts (point 14a). Suggestion: the plan gives full stacks of the maximum stack size (66 items, maximum stack 10: 6 stacks of 10, then one unit of 6); a stack size in the operation replaces the maximum stack size; with fewer items than one maximum stack, one stack of all the items. An edit holds for the item that shows, until another item shows or a post or skip ends the unit. A commodity has no stacks: the stack count box, "stack of", the stack Max label and the Stack Price input are hidden; the unit price and the "Quantity:" box stay. On Forever, an item shows "Stack size:" and no stack count box.
    - Look (changed 2026-10-15): the tree and the details pane use the client Auction House list look, as the Auctions tab list does (`AuctionHouseItemListTemplate`). The background atlas `auctionhouse-background-index` covers the inset background, inside the inset border. Rows use the stripe atlases `auctionhouse-rowstripe-1` and `auctionhouse-rowstripe-2`, the hover atlas `auctionhouse-ui-row-highlight` and the selection atlas `auctionhouse-ui-row-select`. The Buying tab (point 12 and 21) uses the same look. The Flipside window keeps the plain inset look. The Kit takes the atlas names as a `skin` argument (D19); `AuctionTabs.Skin` holds them.
    - Tree (the rest of the panel, rows of 22 px) with a column header line (18 px). The cells of a row line up with the header at every depth: the tree view indents a row by 14 px for each level, and the cells shift back by the same amount. Item columns, as x from the row start and width: Item (name, icon; up to 190 px), Your price (250, 78, right), Operation (336, 80), Lowest on AH (420, 92, right; "none" when no other seller has an auction), Net (518, 78, right), Info (602, the rest). The number columns and their headers are right-aligned. The Info texts are short reasons: "1c under lowest", "no competitor, normal price", "capped at max price", "raised to min price", "below vendor price, skipped" (Default floor) or "below min price, skipped", "no competitor, no market value", "you are already lowest", "no operation", and the reason of a data skip.
20. **Default buying operation (user request, 2026-10-15).** Flipside makes one buying operation named "Default" and attaches it to the Base group. The rules are the same as for the selling Default (point 17): once for each profile (defaultBuyingSeeded in the operations data), only if Base has no buying operation, editable, and a deleted one does not come back. A profile that already has the selling Default also gets the buying one the next time it loads.
    - The maximum price of Default is empty. An empty maximum price formula means no limit. The schema accepts an empty buying maxPrice (field flag optional); the schema default for a new buying operation stays scanmarket.
    - With no limit, BuyingPlan marks the entry 
oMax. It does not run a formula. Every row of another seller is buyable. The summary reads "no max price set". The list row shows "no max".
    - Only the price jump warning (point 12) and the confirm click (D26) protect the buyer. The confirm box never shows the red "above your max price" state for such an entry.
21. **Free search in the Buying tab (user request, 2026-10-15).** The item box above the list accepts an item name (the name index, then the Auction House name search when it is open; text in quotes is an exact name), an item ID, an item link (a shift-click puts the link in the box while it has focus) or a Flipside key such as 25320#s-44. Add (or Enter) puts the item in the current search list. With no list selected, Flipside uses the list "Quick search" and makes it if needed. When several items match, a menu lists up to 12 and the pick adds the item. "Search all" searches every item of the list with the same queue as for the groups (ready gating, rate guard, one search at a time). An item uses the buying operation of its group (or of Base); with none, it uses the built-in Default settings (no max price).
21a. **Name search without a list (user request, 2026-10-17).** A search row sits at the top of the left side, above the source tabs: a box, a Search button and a Clear button. Enter in the box or a click on Search sends an Auction House name query through `ns.ahNameSearch` (Forever: `SendBrowseQuery`; TBC: `QueryAuctionItems` page 0, so at most one page of 50 rows). Both clients match partial names, so `Linen Cloth` finds every item with those words; text in quotes is an exact name and finds only that item. Forever sends the results in batches (`AUCTION_HOUSE_BROWSE_RESULTS_UPDATED` and `AUCTION_HOUSE_BROWSE_RESULTS_ADDED`): the search stays open, adds each batch to the list by item ID, and ends after 1 second with no new batch. The selection stays while the list grows. Each matching item becomes one row in the left list (a flat list, by item ID key, no battle pets). A searched item has no operation: it has no max price, even if the item is in a group. The right pane says "No max price for a searched item", and the confirm box shows the real server price and never the red "above your max price" state. A click on a result starts the live search and the same buy flow as for a group item (price levels, Buy, one click for one buy (D26), price jump warning). The search refuses to start while a live search, a queue, a buy or an earlier name search runs, or while the client is not ready (the rate guard). An empty result shows "no items found". Clear, empty text in the box or a change of source returns to the groups or the list; Clear brings back the earlier selection. Not built: a max price for one search, market value in the result rows, and Add to group (follow-ups).
21b. **Shift-click search (user request, 2026-10-21).** While the Buying tab is shown and the Auction House is open, a shift-click on an item link (bag, bank, chat link, tooltip) puts the exact item name in quotes in the name search box and runs the search of point 21a. An open chat edit box gets the link instead, and so does the item box of point 21 while it has focus. An item that the client has not loaded waits for `ITEM_DATA_LOAD_RESULT`. The hook is a post-hook of `ChatFrameUtil.InsertLink` (WoW: Forever) and of `ChatEdit_InsertLink` (TBC and old callers), so it cannot stop the insert. **In-game checklist (open).** (1) Open the Buying tab. Shift-click a bag item: the box shows its name in quotes and the list shows the match. (2) Click a chat box, then shift-click a bag item: the link goes to chat and no search runs. (3) Open the Blizzard Buy tab. Shift-click a bag item: Blizzard's search bar takes it and Flipside does nothing. (4) Do 1 on both clients.
22. **Saved search lists (user request, 2026-10-15; own design).** 
s.SearchLists (Shared/Services/SearchLists.lua) saves named lists of items in the profile (key searchLists: one table with ersion, 
extID and lists). They are in the profile, next to the groups and the operations, so that a profile copy or reset keeps them together. A list holds each item once (by key). Names are unique without regard to case, 1 to 40 characters. Object: 
s.SearchLists.New(db, { bus, isAuctionHouseOpen }); 
s.searchLists is the live object. Methods: :List() gives { { id, name, count } } sorted by name; :Get(id) gives { id, name, items = { { itemID, key, name } } }; :Create(name, items) gives the id; :Upsert(name, items) replaces the items of the list with that name or makes it, and gives the id; :Rename(id, name); :Delete(id); :AddItem(id, item); :RemoveItem(id, index). A failed call gives nil and a text. A change emits the bus event Flipside.SearchListsChanged.
23. **Open a search list (contract for other features).** The bus event Flipside.SearchListOpen with (listID, autoSearch) makes the Buying tab select that list. If the Auction House is open and autoSearch is true, the tab starts "Search all". If the Auction House is closed, 
s.searchLists keeps the request (:Requested() gives { id, autoSearch }, :ClearRequested() clears it) and the tab applies it the next time it opens, with the search if autoSearch is true.
24. **Buying tab layout (user request, 2026-10-15).** The left side has two sources: "Groups" (the shopping list of the groups) and "Lists". The two sources are tabs on the top edge of the item list (Kit top tabs). The Lists source shows a list picker with New, Rename and Delete (Delete asks to confirm), a name box for New and Rename, the item box with Add, and the items of the selected list. Each item row has a remove button. The right side (price levels, Buy, dry run, jump warning, confirm) is the same for both sources. Lists hold items only, no quantities.
25. **Buying item tree (user request, 2026-10-15).** The item list on the left side is a tree. The group nodes (the same groups as in the Selling tab) hold the item nodes. A group node shows only if it holds an item, directly or in a subgroup. An item that is in no group goes under the last node "Not in a group". An item is in one group only. A click on a group node collapses or expands it and does not select it. The rows are 22 pixels high: a small icon, the name and the maximum price. The selected item row keeps the Kit highlight. A click on an item row selects the item and starts its search at once. This is a read, not a buy, so D26 does not change. If a search runs, the tab holds the new search and starts it when the first search ends. It starts the held search only if the item is still selected. The tab makes no search if live search is not available. The tab has no "Refresh", "Search" or "Search all" button. The tab builds the list again each time it opens or when the source or the search list changes. "Search all" still runs for a search list that another feature opens with autoSearch (point 23). "Stop" shows while such a run is active. The source buttons are on the top row, and the lists and the price levels use the free space.26. **Selling tab feedback, UI part (user request, 2026-10-15).** The rule changes come later (stack size, keep quantity, post quantity, post duration, vendor skip, sample fallback). This point holds only the screen behaviour.
    - **Posted items leave the list.** A real post puts the item on the AH, so the list no longer shows it. The tab reads the bags again by itself (changed 2026-10-15; it has no "Refresh bags" button). It reads at the post event (the AuctionClient `PostedEvent`) and at `BAG_UPDATE_DELAYED`, with no tab switch. It reads at most once each second: an event that comes sooner waits for the end of the second, and the events that come while it waits join it. This sync keeps the decisions of the other items and the queue. If a stack is posted in part, the rest shows as a new entry and starts its own search. An item that the bags no longer hold leaves the list. The sync waits while a server confirm is open and runs when the confirm ends. The row rule below says when a posted row leaves the list. The bag count falls a short time after the post, so the first sync can show the old count; the tab keeps the old entry until the bag count falls.
    - **Row rule (user request, 2026-10-16).** A row leaves the list only when the client confirms its post: the created event (`PostedEvent`) for a one-stack post, or the update that makes the created count equal the total for a multisell. At the click and when the post call returns, the row stays and the Info column reads "posting" (a multisell: "posting 2 of 3 stacks"); Post and Skip are off until the post ends. If the call fails, the client refuses the post, no answer comes before the timeout (15 s plus 3 s for each stack) or a multisell fails in part, the row stays with the status "failed" and the reason in the Info column ("failed: ..."; a part failure adds "(2 of 3 stacks made)"). The pane shows the same reason in red when the selection has no post left. The bag sync then shows the rest of the stack count. A failed row stays until the user clicks the item again; that clears the reason and makes the row ready with the units that the bags now hold. The tab does not read the bags again while a failed row is selected.
    - **Status text rule (user request, 2026-10-16).** The Selling tab has no status or message line at the top. It shows no text for "searching", "auction created", "posting", "all posted", "stopped" or "nothing left to post". The Info column of the row shows the state of each item (searching, posting, failed, skipped, reasons), the pane shows the invalid price and warning lines, and the progress text shows "Posting N of M". Real errors of a post go to the Info column and the pane, never to a top line. The "Stop" button shows while a search queue runs.
    - **Price box (changed 2026-10-15).** The details pane has three number boxes after the label "Price each:": gold, silver and copper, each followed by its client coin icon (the atlases `coin-gold`, `coin-silver` and `coin-copper`, which the Forever client uses in its own money input). They are one Kit widget, `Kit.MoneyInput` (`Shared/UI/Kit/MoneyInput.lua`, D19: no Flipside logic, all input as arguments). Flipside fills the boxes with the suggested price; a part of 0 shows as an empty box. An empty box counts as 0. The boxes take whole numbers only (gold up to 7 digits, silver and copper up to 2). `Kit.MoneyInput` gives `GetCopper()`, `SetCopper(copper)` and `SetEnabled`, and the pure functions `Kit.SplitMoney` and `Kit.JoinMoney`. The price must be from 1 copper up to 100000000000 copper (`SellingTab.CheckPrice`). Post uses the typed price: an item posts with buyout = price x quantity, a commodity with the unit price. The price box belongs to the item that shows. When another item shows, or a new group or item is selected, the box goes back to the suggested price. The next auction of the same item keeps the typed price. Net, deposit and vendor lines follow the typed price. A price outside the range shows "Invalid price: <reason>" in red in the pane, and no post is made.
    - **Info pane.** The pane shows no post time. The column title "Lowest on AH" is the lowest unit price of another seller in the live search of this item (your own auctions do not count; "none" when no other seller has an auction). The pane has no Lowest line and no tooltip for it (removed 2026-10-15). The Net line is green with an up arrow when it is above 0, red with a down arrow when it is below 0, and white with no arrow at 0. The arrows are the client textures `Interface\PetBattles\BattleBar-AbilityBadge-Strong` (up) and `-Weak` (down). The tree rows keep their colours. The pane has no vs vendor line.
    - **Price warning box (changed 2026-10-15; was "Vendor warning").** Post works on any item that has a result, also an item that the rule skips (see the next bullets). A click on Post first opens a square Kit warning box if one of these is true: the rule skips the item; the price is below the minimum price of the rule; the price is above the maximum price of the rule; The vendor case is not a reason of this box (changed 2026-10-16). It has its own short box at the Post click (point 14a, deposit check): "Sell to vendor for: N" and "AH net profit: S", with the larger value in green, and the buttons "Post anyway" and "Cancel". The pane still shows "Sells for more at a vendor: X (net on the AH: Y)" in orange. The price box shows the item link in the quality colour, the quantity and the price, and one line for each reason. It has three buttons. "Post" makes the post in its own click (one protected post, D26). "Skip" leaves the whole item (all its auctions that are left) and logs "skipped by user". "Cancel" makes no post. The box shows once for each item (after "Post" the other auctions of the item post with no question),. After a post or a skip that ends an item, and when the selection is that item, the selection moves to the next item of the list that can still be worked on (the next item starts its live search). A group selection stays as it is, and the pane follows the queue. An item with no selling operation has no price and is not postable. The vendor skip rule (point 27d) is on by default. Then the plan skips an item whose vendor price is higher than the net. A manual Post of such an item shows no "The rule skips this item" line for the vendor reason; the vendor box at the Post click is the one question.
    - **Item link (user request, 2026-10-15).** The name in an item row is the item link (`entry.item.link`, else the link of the client item data) in the quality colour. The mouse over the row shows the item tooltip. A shift-click on the row (`IsModifiedClick("CHATLINK")`) puts the link in the chat edit box, and a click without shift selects the row. A group row has neither.
    - **Rules and groups change (user request, 2026-10-15).** The tab listens for the bus event `Flipside.RulesChanged`. Then it reads the operation, the min price and the max price of every item again, as a full read of the bags does (this is the old "Refresh bags" path), builds the tree again, keeps the selected node and searches its items again. A hidden tab waits and does this when it shows. An open server confirm makes it wait for the end of the confirm. Groups that have no item stay hidden (point 14).
    - **Post all and Skip item removed (user decision, 2026-10-16).** The Selling tab has no "Post all" button, no "Skip item" button, no deposit confirm for a run, no 1 s lock after a post and no run state. "Post" posts the next ready unit of the selection in tree order, and "Skip" leaves the next unit. A group selection is still one queue (point 16): each click of Post posts one unit of the next ready item, so a not-yet-priced item is passed over. A skipped item does not stop the walk. The "ask once for the total deposit" confirm is gone: the deposit of the next post shows in the pane, and the vendor box and the price box still ask first. Forever uses the same tab, so it loses the two buttons too.
    - **Post needs its own click.** The protected AH functions `C_AuctionHouse.PostItem` and `C_AuctionHouse.PostCommodity` (and the two confirm functions) have `HasRestrictions = true` in the Forever client API documentation (`Blizzard_APIDocumentationGenerated/AuctionHouseDocumentation.lua`, branch `forever`, checked 2026-10-15). So each post needs its own click (D26), and one click cannot post many auctions. A timer never makes a post.    - **Quantity and duration of a manual post (26b, issue 219).** The details pane has a stack size or "Quantity:" number box and a "Duration (hours)" radio group (the three hours of the flavour, for example 2, 8, 24 on Forever; `Kit.NumberInput` and `Kit.RadioGroup`; changed 2026-10-16, was a "Time:" drop-down). They apply to the next post of the item that shows. The quantity box starts with the calculated quantity of the next post (a skipped item: the manual plan). The value is limited to 1 up to the count in the bags minus the keep quantity (`SellingTab.ClampQuantity`, `SellingTab.MaxQuantity`); the post call also limits it to the units of the bag slot. An empty or bad box uses the calculated quantity. The choice starts with the duration of the operation (an old 12 or 48 is read as 8 or 24). A change asks the client for a new deposit and updates Deposit and Total Price in the details pane at once. Post uses the chosen quantity and duration; the plan log records them (`quantity`, `duration`). The choice clears after the post or a skip, and the controls show the calculated values for the next post.
    - **Manual post of a skipped item.** If exactly one item is selected and the rule skips it, the details pane shows "The rule skips this item: <reason>. Post asks you first." and the price box holds the price that the plan had in mind (or is empty). "Post" and "Skip" are on. A click on Post opens the same warning box with the reason (and the other lines if they apply; a vendor reason has no line, see point 26). Its "Post" button posts one auction at the typed price: a full stack up to the maximum stack, or all items of a commodity. The log reason is "manual post". A group selection never posts such an item.
    - **Taint.** No new hook and no new restricted event. Every post call stays in the click of a Flipside button, in the click of the "Post" button of the warning box, or in the accept click of the server confirm. The "Skip" and "Cancel" buttons make no protected call.
27. **Selling rule fields (user request, 2026-10-15).** The selling operation holds these fields. The Operations page edits each one. The schema is `OperationSchema` and the rules export lists every field. An old saved operation or export without a field gets the default.

    | Key | Label | Default | Range | Meaning |
    | --- | --- | --- | --- | --- |
    | `stackSize` | Max stack size (TBC: Stack size) | 0 | 0 to 1000 | The most units in one item auction. 0 means a full stack. The client limit (the maximum stack of the item) caps it. |
    | `maxStacks` | Max stacks (TBC only) | 0 | 0 to 1000 | TBC: the most stacks that one run posts for an item. 0 means all the full stacks that the bags hold, and then the rest posts as one smaller stack (the remainder). A number above 0 posts no remainder. Forever has no such field (a commodity has no stacks), and a Forever operation, export and screen do not show it. The field exists only if `ns.Flavour.multisell` is true. |
    | `keepInBags` | Keep quantity | 0 | 0 to 10000 | Units of each item that stay in the bags. They are never posted, also not by a manual post. |
    | `postCap` | Post quantity | 0 | 0 to 5000 | The most to have on the Auction House for each item. 0 means no cap. |
    | `duration` | Post duration | 24 | 2, 8 or 24 (TBC: 12, 24 or 48) | The hours of each auction. The choices come from `ns.Flavour.durations`; the default is `ns.Flavour.defaultDuration`, 24 h on both flavours (changed 2026-10-16; on TBC it was 48). Saved values do not change. |
    | `vendorSkip` | Skip if vendor pays more | on | yes or no | See point 27d. |
    | `minSamples` | Min samples | 3 | 1 to 60 | The fewest price samples for the market value. See point 27e. |

    The fields `minPrice`, `normalPrice`, `maxPrice`, `undercut`, `belowMin`, `aboveMax`, `cancelUndercut`, `needScanData` and `maxDataAgeHours` did not change.
    - **a. Item and commodity.** For an item, the stack size sets the units in each auction, and the post quantity counts auctions. On Forever a unit of an item auction comes from one bag slot, so a slot gives only whole stacks of that size. On TBC one click posts all the full stacks with the client multisell and the remainder follows in the next click (point 14a). A commodity has no stack. So `stackSize` does nothing for a commodity, and the plan posts all free units as one listing. The post quantity of a commodity counts units: units on the Auction House (own listings of the item) plus the new listing must not be more than the value. The plan shortens the listing to fit, and skips the item with "post cap reached" when no room is left.
    - **b. Keep quantity.** Free units = bag count - keep quantity. With no free unit the plan skips the item with "keep in bags reached". Keep stock (D8, Phase 2) will take priority over this field when it exists.
    - **c. Post duration.** The decision carries the duration of the rule, and the post call uses it. `C_AuctionHouse.PostItem` and `PostCommodity` take the duration as a `luaIndex` (`AuctionHouseDocumentation.lua`). The SellFrame of the Forever client (`Blizzard_AuctionHouseSellFrame.lua`) lists three choices as index 1, 2 and 3. The user confirmed on 2026-10-15 that the hours on WoW: Forever are 2, 8 and 24 (the source we read does not show the hour text). Flipside maps 2, 8 and 24 hours to 1, 2 and 3 in `ForeverBackend`. A saved `duration` of 12 or 48 (from an older version) is read as 8 or 24 (`SellingPlan.NormalizeDuration`: the nearest valid value). The saved data does not change. The details pane has a duration choice for one manual post (point 26b). TBC Anniversary has 12, 24 and 48 hours (user confirmed 2026-10-16; the Classic AH UI sets `AuctionFrameAuctions.duration` to 1, 2 or 3). `ns.Flavour.durations` holds the three hours of the flavour (`Core_TBC/Flavour.lua`), and `SellingPlan.DURATIONS` and the `duration` choices read it. `LegacyBackend` maps 12, 24 and 48 hours to the indexes 1, 2 and 3 (point 14a). Settings schema version 2 migrates a saved TBC `duration` of an operation so that the index stays the same: 2 becomes 12, 8 becomes 24 and 24 becomes 48 (`ns.MigrateDurations`, from `ns.Flavour.legacyDurations`). Forever data does not change. An import of an old export on TBC with 2, 8 or 24 is not converted: 2 and 8 fail the check.
    - **d. Vendor skip.** The rule is on by default. After the plan has a post and the client has the deposit quote, the Selling tab compares the vendor sell price of the units with the net of the post (price x quantity - AH cut - deposit, point 18). If the vendor price is higher, the item is skipped with the reason "vendor pays more than the AH". The Info column reads "vendor pays more, skipped". With no vendor price the rule skips nothing. A group post leaves the skipped item out. With the field off, the plan does not skip an item because of the vendor price, but Post still opens the vendor box of point 14a when the vendor pays more, with the real deposit (changed 2026-10-16). The rule is one: (price x quantity x 0.95) - deposit < vendor price x quantity (`SellingPlan.Profit`, `SellingTab.VendorBetter`). A manual Post of a skipped item opens the same box.
    - **e. Sample fallback.** This applies when "Needs scan data" is on and the scan record of the item has fewer samples than `minSamples`, and the data is not too old. Old data still skips the item. The market value from so few samples is not safe, so the plan does not use the normal price. It uses the lowest listing of another seller instead: price = lowest listing - undercut (the live rows, as in point 17). The reason is "few samples, using the cheapest listing". The minimum price, the maximum price, "below min", "above max" and "already lowest" apply as for any other price. If no other seller has a listing, the plan keeps the earlier behaviour: it skips the item with "too few samples: N of M".
    - **f. Manual post.** A manual Post (point 26) follows the max stack size (one auction of at most that many units). It never posts the kept quantity. If no free unit is left, Post is off for the item.
    - **g. Queue limits.** Each queue entry has the auctions that the stack size, the keep quantity and the post quantity allow. The progress count follows these limits.

### 5.5 Mailing (reference §5.4 Mailing)

Decision of 2026-10-16: mailing is a fourth operation type, "mailing", on groups, like selling, buying and vendoring. It replaces the separate mail list. Groups and subgroups inherit it in the usual way (§5.2): a group uses the mailing operation of the nearest group above it. Mailing moves from Phase 2 into the MVP work.

**Operation fields** (`OperationSchema`, type `mailing`; no safety fields, because the operation reads no prices):

| Key | Label | Default | Range | Meaning |
| --- | --- | --- | --- | --- |
| `recipient` | Recipient | empty (required) | 1 to 64 characters | The character that gets the mail: `Name` or `Name-Realm`. Any name is allowed. |
| `keep` | Keep in bags | 0 | 0 to 10000 | Units of each item that stay in the bags. 0 means send all. |
| `maxSend` | Send up to | 0 | 0 to 100000 | The most units of each item to send in one run. 0 means no limit. |
| `minQuality` | Lowest rarity | 0 (Poor) | 0 to 4 | Send only items of this rarity or better. Rarities: Poor 0, Common 1, Uncommon 2, Rare 3, Epic 4. The choices show in the colour of the rarity. |
| `maxQuality` | Highest rarity | 4 (Epic) | 0 to 4 | Send only items of this rarity or worse. Epic is the highest choice. A saved value of 5 becomes 4 in `OperationSchema.Normalize`. |
| `itemClasses` | Item types | empty | text of class ids, for example `2,4` | Send only items of the chosen item types (item classes). Empty means any type. The user can choose many types. |

**Item filters (2026-10-17).** An item must pass all filters of its operation (AND), also an item that a group lists. The filters work on both clients.
- The item types come from the client at run time: `Enum.ItemClass` gives the class ids and `C_Item.GetItemClassInfo(id)` gives the names (`MailClient.ItemClasses`). Both APIs are in the Forever client source and in the classic_anniversary source, with the same ids 0 to 20. A class with no name and an obsolete class are not offered. The classes Quest, Key and WoW Token are not offered, and Quiver and Container are one entry "Container" for both class ids (changed 2026-10-17). The code finds the classes by their `Enum.ItemClass` names, not by the shown name. A saved set with only Quiver or only Container shows the entry as checked. A click writes both ids. A saved id of a removed class shows no box and is dropped when the user changes the boxes. Each flavour shows its own types. The editor shows the types as check boxes in a grid (`Kit.CheckGrid`) in the editor frame. A click toggles one box and nothing closes. Each name is left-aligned next to its box.
- **Legendary never goes by mail (2026-10-17).** `MailingPlan` never mails an item of rarity 5 or more (Legendary, Artifact, Heirloom), whatever the settings. The old rule "Legendary means no upper limit" is removed for mailing. Auto rules (§5.2a) still allow Legendary.
- The rarity of a slot comes from `C_Container.GetContainerItemInfo` (`quality`). The class comes from `C_Item.GetItemInfoInstant` (the sixth value). Both need no item cache, so an item never waits for a load. If the rarity or the class is not known and a filter on it is on, the item does not pass.
- An item that fails the filters is left alone and is not in the skip report. A later selected group can still take it.
- An operation from an older save has none of the new fields. `OperationSchema.Normalize` gives it the defaults (no filter), so it acts as before.
- **Soulbound.** A slot with `isBound` from the container info is never mailed. A Bind on Equip item that is not bound yet is mailed. A quest item (class Quest) is also skipped. The planner skips a bound slot with the reason `soulbound`; this covers account-bound items that the client reports as bound.
- **All bag items.** The built-in group "All bag items" (`RulesStore:EnsureAllBagsGroup`, made under Base when the mailing view starts) takes every bag item that is in no group. The user attaches a mailing operation to it in the Groups tab, like to any group. It lists no item of its own (`AddItem` refuses it). The planner skips a bag item that is soulbound without a report (the list would be very long). Without a recipient it sends nothing. If the user deletes the group, the next start makes it again. An export lists it as an ordinary empty group.

**Planner** (`Shared/Services/MailingPlan.lua`, pure, no WoW call). Input: the groups to run, each with its items and its effective mailing operation; the bag slots (item key, bag, slot, count, flags `soulbound`, `quest`, `unmailable`; the rarity `quality` and the item `class`); the name of the own character. Output: a list of mails and a list of skipped slots with the reason. Item keys follow D20.
- For each item: sendable = (total in all its bag slots - keep), capped by `maxSend` when `maxSend` is above 0. The total counts every slot, also a slot that cannot be mailed.
- The planner sends whole bag slots only (no stack split). It takes slots **largest first** (then by bag and slot), because this needs the fewest attachments. A slot that is larger than the units left to send is not sent. The next smaller slot can still fit.
- A mail has one recipient and up to 12 attachments. The planner collects the attachments for each recipient, in group order and item order, and starts a new mail after 12. Recipient names match without regard to case.
- An item follows the first group that lists it. Items that no selected group lists are not touched.
- Skip reasons: `keep` (the slot does not fit in the units above the keep amount), `send limit` (it does not fit in `maxSend`), `soulbound`, `quest item`, `unmailable`, `no recipient` (the operation is missing or has an empty recipient), `recipient is self`. A name without a realm matches the own character by name; if both names have a realm, the whole name must match.
- `MailingPlan.GroupsFor(rules, groupIDs)` lists the given groups and their subgroups with their items and effective mailing operation.
- `MailingPlan.GroupsForOperation(rules, opID)` lists the groups of one mailing rule (changed 2026-10-18). It walks the group tree and lists each group below Base whose effective mailing operation is `opID`. This covers the groups with the operation attached, the groups that inherit it and the built-in All bag items group. Base is not listed. A subgroup that has its own mailing operation belongs to that operation, not to the one of its parent.

**Orchestrator defaults** (the user can change them later):
- The recipient is a field of the operation. Any name is allowed. If the name is not a known own character from the holdings (§5.10), the view shows a warning but still allows the run.
- One summary and one confirm for each run: the view lists the mails and the skipped items, then the user confirms once.
- Postage is recorded in the ledger as an expense (§5.8).
- An item that needs the confirm for an unrefundable mail (items that the recipient cannot return) is skipped and reported.
- Soulbound, quest and unmailable items are skipped and reported.

**Mail view and send run** (built 2026-10-17; wide layout 2026-10-17). The mailing view sits inside Blizzard's `MailFrame`, which gets wider while the mailbox is open (not a floating frame, not a tab). The Inbox tab shows the compact inbox list (changed 2026-10-18, see "Compact inbox"). `MailHost` places the view on `MAIL_SHOW` and takes the layout away on `MAIL_CLOSED`. One host serves both flavours.
- **View and host (split).** `MailingView` (`Shared/Features/Mailing/MailingView.lua`) takes a parent frame, its deps and an optional size. It knows nothing about its place: it builds `view.frame` and the host anchors it. `MailHost` owns the place. It has a table of layouts, `MailHost.LAYOUTS`; each layout is `function(deps, host)` that returns `{ Open(mailFrame), Close(mailFrame) }`. Today there is one layout, `wide`.
- **Wide layout.** Open: read the width of `MailFrame`, make it 380 px wider, and keep `InboxFrame` and `SendMailFrame` at the old width (on Forever they are anchored at two corners of `MailFrame` and would stretch; the host anchors them at TOPLEFT and BOTTOMLEFT with the old width). The `ButtonFrameTemplate` border and background of `MailFrame` stretch with it, so the wide frame has the client look. The view fills the new strip over the full height (from the old right edge, 2 px below the top, 2 px from the right edge, level with the bottom). See "Blizzard alignment" for the layout inside the view. Close (on `MAIL_CLOSED`): set the old width and the old anchors back and hide the view. Only client assets are used. Both clients inherit `ButtonFrameTemplate` for `MailFrame`; the TBC `InboxFrame` and `SendMailFrame` have a fixed size at one anchor, so the host does not change them there. In both clients the host also anchors OpenMailFrame to the top right of MailFrame (x 46, as Forever does; TBC anchors it to InboxFrame, which would put it over the view) and sets the saved anchor back on close.
- **Switch to a tab.** Add a new function to `MailHost.LAYOUTS`, for example `tab`: its `Open` makes or shows a Flipside tab page in `MailFrame` and anchors `host.view.frame` in it (the view is made with `deps.create(parent, size)`); its `Close` hides it. Then set `mode = "tab"` in `openMailing` in `Shared/Core/Init.lua`. `MailingView` and the send run do not change.
- **Blizzard alignment (2026-10-19).** The view looks like part of `MailFrame`. It is the same on the Inbox tab and on the Send Mail tab, in both clients.
  - **Header.** The text "Flipside mailing" uses `GameFontNormal`, the font of the client title, and sits on the row of the client title (the centre is 10 px below the top of the view). It is not a large title.
  - **Column titles and list.** A row of small grey column titles (Rule, To, Groups, Filter) is above the list. The list is a Kit list with the client inset (`InsetFrameTemplate`; both clients have it), 4 px from the left and right edge. It starts 58 px below the top, where the client Inbox inset starts. It ends 4 px above the bottom bar, so the list fills the height of the panel.
  - **Columns of a rule row.** Rule name (72 px), recipient (58 px), groups (48 px), then the filter summary, which takes the space up to the Run button (34 px). A text that is too long shows cut with "...". The tooltip of the row has the full text (recipient, every group, the full filter, the mails that are ready).
  - **Bottom bar.** The status line, Run all and Stop sit on one row at the bottom, with the height and the baseline of the client bottom button of the tab that shows: Open All on the Inbox tab, Cancel (the Send button row) on the Send Mail tab. The status line is on the left, Run all and Stop (70 px each) are on the right. `MailHost` puts a small child frame in `InboxFrame` and in `SendMailFrame`. The `OnShow` script of that frame (a script of our own frame, not a hook) calls `MailingView:AlignBar(ref, fallback)`. `AlignBar` reads the bottom edge and the height of the client button when the client has laid it out (`GetBottom`). If it has not, it uses `ns.Flavour.mailBar` (bottom offset and height). The values come from the client XML: Forever Open All is centred 26 px up and 24 px high, Cancel is 4 px up and 22 px high (`Blizzard_MailFrame/MailFrame.xml`); TBC Open All is centred 114 px up, Cancel is 92 px up (classic_anniversary `Classic/MailFrame.xml`).
- **Rule list (changed 2026-10-18).** The view lists the mailing rules, that is the mailing operations (`RulesStore:ListOperations("mailing")`), as compact rows in a Kit list. The row height is 18 px, the same as the Ledger list. The user selects no group: a rule knows its groups (`MailingPlan.GroupsForOperation`). Each row shows the rule name, the recipient, the number of groups ("3 groups"), a short filter summary (the rarity range, for example "Unc-Epic", and the number of item types, for example "2 types"; "any item" if the rule has no filter) and a Run button. The tooltip of a row lists the recipient, every group by name, the filter, and the mails and items that are ready. A recipient that is not an own character (holdings, §5.10) shows in red and the tooltip says so; the run is still allowed. A rule with no recipient, or with no group, shows grey with a disabled Run button, and the filter column shows the reason ("no recipient", "no groups"). The Run all button runs every rule that can run, in list order. The list has no group tree and no selection.
- **Run and Run all.** Run plans the mails of that rule only (`MailingPlan.Build` with `GroupsForOperation`). Run all plans each rule and joins the mails in rule order. Both ask for one confirm ("Send N mails to X, Y?") and then use the same send run. If the plan has no mail, the view shows "Nothing to send for <rule>" and starts no run. The send sequence (up to 12 attachments, `BAG_UPDATE_DELAYED`, flavour delays) is unchanged.
- **Status line and log (changed 2026-10-18).** The old result box at the bottom of the view is removed. It was a list that showed the result of the last run: the mails sent, the postage, each recipient, the stop reason and each skipped item. The view now has one status line on the bottom bar, left of the buttons: the rules and mails that are ready, "Mail 2 of 3 (1 sent)" during a run, and after a run "Sent 2 mails, postage 1g, stopped: mailbox closed, 2 skipped". The detail lines go to the log (`ns.Log.Write("mail", "info", line)`; `/flip log`).
- **Compact inbox (2026-10-18).** `InboxList` (`Shared/Features/Mailing/InboxList.lua`) replaces the seven fixed mail buttons of the client Inbox tab. It is a Kit list in `InboxFrame`. Its top and left edge and its width are those of `MailItem1`. It reaches down to 4 px above the Open All button (`InboxList.Anchor`; 2026-10-19), so it is taller than the seven client buttons: about 14 rows are visible in both clients (`InboxList.VisibleRows(height)` = height / 22). It has one row for each mail, in a scroll list (2026-10-20: the row pitch is 22 px: 20 px of content and a 2 px gap with a 1 px separator line at the bottom; the icon sits in a 20 px brown slot, the client texture `Interface\Buttons\UI-Slot-Background` with `SetTexCoord` 0 to 0.640625, with no tint; the icon is 18 px with its edges trimmed by `SetTexCoord` 0.07 to 0.93; the slot has 3 px of space at its left and 3 px before the sender; an empty row shows the same slot) with no pages (more mails scroll). The list frame is 10 levels above `InboxFrame` and has a solid parchment background (a warm tan colour, 2026-10-20), so the seven client buttons, which `InboxList` hides, and their art never show through. Text is dark for parchment: the sender is brown, the subject is near black, a read mail is a lighter brown, and the days left and COD are dark green or dark red. The separator is dark brown. The selection and the hover are a brown tint with a normal blend. Open All stays where the client puts it, at the bottom of the Inbox area. If the client has no Open All, the list ends at `MailItem7`. A row shows the mail icon (the package icon, or the stationery icon for a mail with no package and for a GM mail), the sender, the subject, the number of attachments (`x3`), the money or the COD amount (red) and the time left (green days, red hours when under one day). Unread mail shows the sender in gold and the subject in white; read mail shows grey with a desaturated icon. The mail that is open shows the selection highlight. The tooltip of a row shows the subject, the sender, the attachments, the money and the COD amount.
  - **API.** `GetInboxNumItems()` (first result: the number of mails in the list) and `GetInboxHeaderInfo(index)` (results 1 to 9: package icon, stationery icon, sender, subject, money, COD, days left, item count, was read; result 13: is GM). The two clients return these in the same order (Forever `Blizzard_MailFrame/MailFrame.lua`, classic_anniversary `Blizzard_UIPanels_Game/Classic/MailFrame.lua`, checked 2026-10-18).
  - **Open a mail.** A click calls the client function `InboxFrame_OnClick(button, index)`. Both clients have it as a global. It reads only `button:GetChecked()`, so the code passes a small table whose `GetChecked` returns true to open the mail, or false to close it if `InboxFrame.openMailID` is already the index. The client function sets `openMailID`, updates and shows `OpenMailFrame`, and hides it again on the second click. The addon calls no protected function and does not replace a client function. If `InboxFrame_OnClick` does not exist, the list is not made and the client buttons stay.
  - **Client frames.** While the list shows, the host hides `MailItem1` to `MailItem7` and the page buttons (TBC: `InboxPrevPageButton`, `InboxNextPageButton`; Forever: `InboxFrame.PrevPageButton`, `NextPageButton`, `PageTurnIndicatorLeft`, `PageTurnIndicatorRight`). It remembers which frame was shown. It shows them again on `MAIL_CLOSED`, and when the list cannot read the mails. The client keeps updating the hidden buttons.
  - **Refresh.** The list reads the mails again on `MAIL_SHOW`, on `MAIL_INBOX_UPDATE`, after a click and when `OpenMailFrame` hides. The scroll position stays (`retainScroll` option of `Kit.CreateList`). A Shift-click takes the contents (next bullet).
  - **Shift-click: take all (2026-10-18).** A click with the client modifier `MAILAUTOLOOTTOGGLE` (Shift by default) first takes all money and attachments of that mail, then opens it. This is what `InboxFrame_OnModifiedClick` does on both clients: it calls `AutoLootMailItem(index)` if the COD amount is 0, then `InboxFrame_OnClick`. The list calls the same client function `AutoLootMailItem(index)`. It is not a protected function, and the client calls it from its button click only. It needs no wait between items, because the server takes the whole mail. No step needs a hardware event other than the click itself. A normal click does not take anything.
    - A COD mail is never taken. The mail opens, the chat shows "COD mail skipped: Shift-click never pays", and the user pays in the open-mail frame as before.
    - A mail with attachments is not taken when the bags have no free slot (`C_Container.GetContainerNumFreeSlots` for bags 0 to `NUM_BAG_SLOTS`). The chat shows "Bags are full". A mail with only money is still taken. If the bags fill during the take, the client stops the take and shows its own error.
    - Each step writes a line to the log, category `mail` (take, skip for COD, skip for nothing to take, stop for full bags).
  - **Layouts.** The compact inbox does not depend on the layout: `MailHost` shows it on `MAIL_SHOW` for every layout. Only the wide layout exists today. The rule list needs a layout that gives it a place.- **Send mode (decided 2026-10-17): one confirm, then all mails go out in sequence.** The user clicks Run (or Run all) once and confirms once ("Send N mails to X, Y?"). No click is needed for each mail. The client charges the postage; the view cannot show it before the attach calls, so the result shows the real total.
- `SendMail` needs no hardware event. The probe `MailTest` showed on TBC Anniversary that it works from a timer and from an event handler, and while the Inbox tab shows. **This is confirmed on TBC only. It is not confirmed on Forever.**
- **Wait rule** (`Shared/Services/MailingRun.lua`). After `MAIL_SEND_SUCCESS` the run waits for `BAG_UPDATE_DELAYED` (fallback 5 s), then a flavour delay (`ns.Flavour.mailDelay`, 0.5 s on TBC; the same value on Forever until the Forever probe shows another value), then reads the bags again. Without this wait the next mail attached a stale slot and got no event. The run never reuses a slot that holds the sent item.
- **Each mail:** read the bags; find the planned slot again (the planned slot if it still holds the item, else a slot with the same item and count that is not locked); attach with `PickupContainerItem` and `ClickSendMailItemButton(index)`; wait 0.2 s so that a lock event can arrive; read the attachments back; compare the postage (`GetSendMailPrice`) with the gold; send. A mail has up to 12 attachments (confirmed on TBC).
- `SendMail` takes `(name, subject, body)` on TBC and `(name, subject, body, replyMailID)` on Forever (`ns.Flavour.sendMailArgs`). Neither client source has `ClearSendMail`; the run clears an attachment with `ClickSendMailItemButton(index, true)` (the right click of the client UI).
- **Stops:** `MAIL_CLOSED`, the Stop button (a mail in flight finishes first), not enough gold for the postage. `MAIL_LOCK_SEND_ITEMS` (the client wants a confirm for an item that the recipient cannot return): the run clears that item, reports it as skipped and sends the rest; it never accepts. `MAIL_FAILED` or no result after 10 s (an unknown recipient, a full mailbox, the text of the last `UI_ERROR_MESSAGE` is the reason): the rest of that recipient is skipped and the run goes on with the next recipient.
- **Result:** mails sent, items for each recipient, the postage total, and the skipped items with the reason (the planner reasons, "item not found in the bags", the lock and failure reasons).
- **Ledger (changed 2026-10-17):** the send post-hook of the ledger writes the records of every sent mail, for this run and for the Blizzard Send tab alike (§5.8, "Ledger hooks"). A mail gives one `mailPostage` expense, one `mailMoneySent` expense if gold goes with it, and one `mailSent` row for each attachment, with the item, the quantity and the recipient. The run itself writes no ledger record and sends no claim, so there is no second record.

**In-game checklist (mailing).**
1. **Forever probe first.** On the Forever client run the `MailTest` probe again: `click 5`, `timer 5` and `fill 12` (README of `MailTest`). All 5 mails and the 12-attachment mail must arrive. If a step fails, tune `mailDelay` in `Core_Forever/Flavour.lua` or report the failure; do not use the mailing view before this.
2. Open a mailbox. The mail frame gets wider and the Flipside mailing view fills the new strip. The Inbox and Send tabs keep their look and work (open a mail, take an attachment, write and send a mail by hand). Open a mail on the Inbox: note where Blizzard shows the open-mail frame. Close the mailbox. The frame has its old width, the Inbox and Send tabs look as before, and the view is gone. Open the mailbox again: the same.
3. Compact inbox. The Inbox tab shows one list with a row for each mail (icon, sender, subject, attachments, money or COD, time left) and no client mail buttons and no page buttons. A row is about as high as a row in the Ledger. Use a mailbox with more than 7 mails: all mails show in the scroll list, and the scroll position stays when the list refreshes. Unread mail is gold and white, read mail is grey. Click a row: the client open-mail frame shows that mail at the right edge of the mail frame. The row shows the selection highlight. Click the same row again: the open-mail frame closes. Take an attachment or the money in the open mail: the list refreshes and the row changes. Close the open-mail frame with its X: the highlight goes. Hover a row: the tooltip shows the subject, the sender and the attachments. Shift-click a mail with attachments and money: all items and the money go to the bags and the mail opens. Shift-click a COD mail: nothing is paid, the chat says so, and the mail opens. Fill the bags and Shift-click a mail with items: nothing is taken and the chat says "Bags are full". `/flip log` shows the "mail" lines for each case. A normal click takes nothing. Check that the Send Mail tab still works and that no "action blocked" message shows in the chat. Close the mailbox: open it again, the compact list shows. Check this on both clients.
4. Make a mailing operation with a recipient that is an own character, attach it to a group and put items of that group in the bags. The view shows a row for the rule with its name, the recipient, "1 group", the filter summary and a Run button. Attach the rule to a second group: the row says "2 groups" and the tooltip lists both. A subgroup of an attached group counts as a group of the rule. A subgroup with a different mailing operation does not. Attach a rule to All bag items: it lists that group. A recipient that is no own character shows red. A rule with no recipient, or with no group, is grey with a disabled Run button and the reason.
5. Click Run on one rule: one confirm shows with the mails of that rule only; cancel it and check that nothing is sent. Click Run again and confirm. All mails of that rule go out with no further click; the status line counts them. Check the mails at the recipient (items, stack sizes, subject). Click Run all with two rules: one confirm lists the mails of both rules, in rule order. The bottom of the view has no result box. After a run the status line shows the sent mails, the postage and the skipped items. Open the log (`/flip log`, category "mail"): the lines of the result show there.6. Use a group with more than 12 slots of items. The run sends more than one mail, each with up to 12 attachments.
7. Click Stop during a run with 3 or more mails. The mail in flight arrives, no later mail is sent.
8. Close the mailbox during a run. The run stops with "mailbox closed" and the items return to the bags.
9. Use a recipient that does not exist. The mail fails, the rest of that recipient is skipped, and the result shows the reason.
10. Put a soulbound item, a quest item and an item that the client wants to confirm (a non-refundable item) in a mail group. The first two show as skipped; the third is cleared and shown as skipped, and no confirm window stays open.
11. Spend most of the gold. The run stops with "not enough money for the postage" before the mail that costs too much.
12. Open the Ledger. Each sent mail has a "Mail postage" expense with the right amount and the recipient. No second "Unknown" expense shows for the same postage.
13. Item filters: open the mailing operation in the Operations tab. It shows Lowest rarity, Highest rarity and Item types. The rarity choices stop at Epic and show in their quality colour, in the button and in each entry. Highest rarity is Epic for a new operation. The Item types are check boxes with the item types of the client below the fields; choose two or more and the boxes stay checked. The field rows are one line each, with the label next to its control and no empty band. The item type names sit next to their boxes. Quest, Key, WoW Token and Generic (obsolete) are not in the list, and Container is one entry. Under the boxes, "Used by:" lists one group on each line. Nothing is cut off. The editor has no example item box. Put a Legendary item in a mail group: it is never in a mail. Close the window and open it again: the values stay. Make a rule "Uncommon and better, not soulbound, to a character" on the group All bag items and put a green item, a white item, a soulbound blue item and an unbound blue BoE item in the bags. Only the green item and the blue BoE item are in the mails. Choose the type Armor only: no weapon is sent. Check this on both clients.
14. Do the checks 2 to 13 on both clients (Forever and TBC Anniversary).
**Keep stock (D8).** D8 says keep stock beats every outgoing rule. The `keep` field of a mailing operation is a per-operation floor, as `keepInBags` is for selling. When keep-stock rules exist (Phase 2), the planner reads the keep-stock target of an item and uses the larger of the two numbers. Going below the target needs the same **Override stock** button, for one run only. Mailing does not change D8.

**Export.** The rules export lists the mailing operation like any other operation. The recipient is exported as typed (no placeholder in this step).

**Inbox (unchanged).** Open by type, with a running gold total. There is no open-all button in the MVP. When the user opens the mail, Flipside reads the invoices and feeds the ledger (§5.8, decided 2026-10-15).
### 5.6 Keep stock (new, unifies reference restock settings)

Keep stock is one rule type that says *how many of an item should be where*. Other features read it instead of each having their own restock fields.

| Field | Meaning |
| --- | --- |
| Target | Units to hold (number or formula) |
| Where | Character, and location: bags, bank, warband bank, reagent bag |
| Counts | Which locations count toward the target (e.g. bags + bank) |
| Sources | Where to refill from, in order: own bank, alts by mail, AH buy, craft |
| Excess | What to do above target: leave, move to bank, mail to seller, post |

How features use it: Banking moves to and from the bank; Mailing sends shortfalls from alts; Buying limits group purchases to the shortfall; Crafting restock queues the shortfall; Selling never posts below the keep amount.

**Precedence (D8).** Keep stock beats every outgoing rule — selling, mailing, vendoring and excess moves. Example: a selling rule says "sell all Runecloth" and a keep-stock rule says "keep 2 stacks of Runecloth". Selling posts everything above 2 stacks and logs "kept for stock: 2 stacks" in the decision log. Going below the target needs an explicit **Override stock** button, which applies to that one run only and is recorded in the decision log.

### 5.7 Vendoring (reference §5.5)

- Sell junk and groups marked for vendor; buy vendor reagents up to Keep stock targets.
- **Safety:** never auto-vendor an item whose `ScanMarket` or `Destroy` value (MVP: ScanMarket only; Destroy from Phase 3) is more than a set multiple of its vendor price (default 2×); such items are listed for review instead.
- Buyback tab with one-click undo of the last sale batch.
- **Keep in bags:** the operation has a number for each item (default 0). Vendoring leaves that many units of the item in the bags (see the feedback decisions in §5.2).

### 5.7a Destroy window (added 2026-10-18)

A free window, opened and closed with `/flip destroy`. It helps the player to disenchant many bag items, one cast for each click.

- **List:** the bag items that match the rules and are not ignored. A row shows the icon, the name in the colour of its quality, the required level and bag/slot. Bound items are included. The list reads the bags again on `BAG_UPDATE_DELAYED` (at most one read every 0.3 seconds).
- **Rules** (saved in the account scope of the settings DB, key `destroy.rules`; all characters share them). Defaults: quality Uncommon to Epic (Legendary never), level rule on with gap 1, unequippable rule on.
  - Only armor and weapon items count. Shirts, tabards, cosmetic armor and fishing poles do not.
  - Level rule: matches if the required level is at most the player level minus the gap.
  - Unequippable rule: matches if the player class can never equip the item. A fixed table of armor and weapon subclasses for each class decides this (`DestroyRules.CanEquip`). It does not use `IsUsableItem`, because that function depends on the level and on skills. A class that is not in the table never matches.
  - Combination: the quality is in the range AND (the level rule matches OR the unequippable rule matches). A sub-rule that is off does not count. If both are off, the quality alone decides.
- **Actions** for the current item (the selected row, else the first row):
  - **Destroy:** a secure button (`SecureActionButtonTemplate`) with `type = "macro"` and `macrotext = "/cast <Disenchant>\n/use <bag> <slot>"`. The spell name comes from spell 13262. One click is one cast. In combat the button is disabled and the attributes do not change. If the player does not know Disenchant, the button is disabled and a message shows.
  - **Ignore:** adds the item id to the ignore list (account scope, key `destroy.ignored`). The item never shows again, in any stack.
  - **Skip:** hides that bag slot until `/reload`. The skip list is not saved.
- **Ignored tab:** lists the ignored items, each with a Remove button.
- The window cannot open for the first time in combat, because the Destroy button is secure. The code adds no hook.
- Follow-up (not built): show the value of the item and the value of its disenchant result, before and after.
- Files: `Shared/Services/DestroyRules.lua` (rules, no frame code), `Shared/Features/Destroy/DestroyWindow.lua` (window).

### 5.8 Ledger (reference §5.7)

- Same record types and views (sales, purchases, other income and expenses, expired, cancelled, resale).
- **CSV export** of any view, in a documented column format.
- `SaleRate` per item from your own sold and expired counts (§4).
- Retention: full records for 180 days, then daily sums (configurable). See the ledger design below.
- The ledger also records the source of each money or item change, and the money that comes in from each source (decided 2026-10-15).

**Ledger design (decided 2026-10-15)**

The user approved points 1 to 10 on 2026-10-15. They are binding. The idea is similar to the Journalator addon. Flipside copies no name, code or string format from it.

1. **Storage (changes D25).**
   - The ledger lives in the load-on-demand addon `Flipside_Ledger`. Its SavedVariables are `FlipsideLedgerDB` (TBC: `FlipsideLedgerDB_TBC`).
   - During play, Flipside writes each new record to a buffer in the Main DB (`ledger.buffer`).
   - Flipside loads the addon (`C_AddOns.LoadAddOn`) and moves the buffer into `FlipsideLedgerDB` in these cases: the user opens the Ledger page, a feature needs the ledger (for example `SaleRate`), the buffer reaches the cap, or the next login finds a buffer that is not empty.
   - The cap is 500 records (setting `ledger.bufferCap`). The Main DB is saved at logout, so the buffer is not lost.
   - At the cap Flipside forces the load and the move. It does this out of combat only. If the player is in combat, it waits until combat ends.
   - Safe default: Flipside does not merge at logout. It is not verified that an addon that loads during `PLAYER_LOGOUT` saves its variables.
   - If the load fails (the addon is missing or disabled), the buffer grows to a hard limit of 2,000 records. Then Flipside drops the oldest record for each new record, counts the drops, and shows one warning in chat for each session.
   - The Main DB holds no ledger records after the move.
   - The ledger settings are in the account scope of the Main DB. The keys and defaults are: `ledger.buffer` (the record list), `ledger.bufferCap` 500, `ledger.hardLimit` 2000, `ledger.retentionDays` 180, `ledger.mobWindow` 60, `ledger.logDays` 30 and `ledger.debug` false.
   - Access point (decided 2026-10-15, PR1): `Flipside_Ledger` has no Lua code and no shared table. All ledger code is in `Flipside` (`LedgerBuffer`, `LedgerStore`, `LedgerLoader`). After `LoadAddOn` returns, the client has put the saved table in the global `FlipsideLedgerDB` (TBC: `FlipsideLedgerDB_TBC`), and `LedgerStore` works on that table. No new global exists. The TBC ledger TOC is `Flipside_Ledger_TBC.toc`.
2. **Retention.**
   - Full records are kept for 180 days (setting `ledger.retentionDays`). This is the retention rule that §5.8 already gave.
   - After that, a daily sum replaces them for each character, source and item key. The daily sum holds the day number, a record count, the quantity, the money in and the money out.
   - The roll-up runs when the ledger addon loads, and once for each day. The daily sums stay, so `SaleRate` still works after 180 days.
3. **Scope and key.**
   - Records are for each character (`Name-Realm`). The page has a filter for one character or for all characters.
   - The key format follows D22. `FlipsideLedgerDB` stores `records[region][ruleset][Name-Realm]`. The region is the client region text. The ruleset is "standard" on Forever.
   - The ledger needs no extra realm key (D24). `Name-Realm` already holds the realm. The ruleset keeps a later split of the data possible without a rewrite.
4. **Loot.**
   - Flipside writes one record for each drop (all detail): one for each item and one for the looted money.
   - The mob is the name of the last kill of the player in the combat log. If there is no kill in the last 60 s (setting `ledger.mobWindow`), the mob is "unknown".
   - `GetLootSourceInfo` does not exist in the Forever client (checked against Ketho/wow-ui-source-forever commit bd2470a). Flipside does not use it.
   - Looted money is recorded with its mob.
   - The item value in the record is the vendor price at loot time. The `ScanMarket` value is computed when the user views the page. It is never stored.
5. **Mail.**
   - Flipside reads the invoices when the user opens the mail. There is no open-all button in the MVP (§5.5).
   - The mail indexes shift when mail leaves the inbox. A mail is therefore never found again by its index.
   - Each mail gets a fingerprint: sender, subject, money, attached item keys and quantities, and the invoice values. Two equal mails in one read get an occurrence number.
   - Flipside saves the fingerprints for 31 days. A fingerprint that is already saved is not recorded again.
   - Risk: a new sale that is equal to an older sale in the saved window (same buyer, item, quantity and price) can be missed. A check in PR3 looks at this risk.
6. **Deposit and cut.**
   - A deposit is an expense when the auction is posted. A sale refunds the deposit.
   - The cut comes from the sale invoice: payout = bid + deposit - consignment (Forever `MailFrame.lua` lines 827-831).
   - The estimate before a sale can still use 5% (§5.4 point 18). The ledger uses the real invoice cut.
   - A sale gives one record (decided 2026-10-15, PR3, changes the first text): source `ahSale`, `money` = the payout that arrived, `bid`, `deposit` (the refund) and `cut` (consignment) as fields. A second record for the deposit would count the payout twice or split it wrong, because bid + deposit is not the payout. The source `ahDepositRefund` is not written; it stays valid for old data.
7. **Day boundary.** A ledger day starts at 00:00 UTC by the server clock (`GetServerTime`). Day number = floor(server time / 86,400). This is the same as D4 and `ScanClock`.
8. **Decision logs.**
   - The Buying and Selling decision logs are saved in the ledger (type `log`). This changes §5.4 point 8.
   - A log record holds the time, character, tab, action (dry run, buy next or post next), item key, reason code, price, quantity and `dryRun`. It has the `ctx` of the trade it explains.
   - Flipside writes the log records of a run when the run ends. It keeps them for 30 days (setting `ledger.logDays`) and then deletes them, with no daily sum. The user decided this on 2026-10-15.
   - Decision log records have no tab of their own. The Ledger page shows them as the detail of the matching Auctions row (point 9).
9. **Ledger page.**
   - The page is in the Flipside window (`/flip`). It has these inner tabs: Overview (first and default), Sales, Purchases, Auctions, Loot and Expenses (deposits, repairs, vendor purchases). The tab "Income by source" was removed on 2026-10-15 (user decision): money from Auction House sales belongs in Sales. `LedgerStore:SumsBySource` stays in the store.
   - Each tab has a totals row, a date range filter and the character filter.
   - The Auctions tab shows the Auction House activity of the character: posts (item, quantity, price, deposit), cancels, expired auctions and purchases at the Auction House.
   - A row of a post or purchase has a detail line (or a tooltip) with the matching log record: action and reason. The match uses `ctx`.
   - A dry run has no trade. Its log record is a row of its own in the Auctions tab, with the mark "dry run".
   - A row older than the log retention has no detail line.
   - CSV export stays in scope (build step 7 PR8, with a documented column format).
   - Page design (PR7, `LedgerPage`). The page loads the ledger each time it opens (`LedgerLoader:Ensure`). It shows "Loading ledger..." until the ledger is loaded, or the reason of a failed load. It reads data only.
   - Filters: the character (All characters, then the current character, then the others) and the date range (Today, 7 days, 30 days, 180 days, All). A range counts whole UTC ledger days and ends today. The default is the current character and 30 days. Flipside saves the last choice in the character scope (`ledger.view.char`, `ledger.view.range`). The graph uses the saved date range when the page opens.
   - **Server and character filter (TBC only, decided 2026-10-18, user request).** The flavour value `ledgerRealmFilter` is true on TBC Anniversary and false on Forever. The reason is that TBC mail does not cross servers. If it is false, the page has the character filter above and nothing changes. If it is true, two dropdowns replace the character dropdown. The Server dropdown lists each realm that has ledger records and the current realm, even with no records. The current realm is first and the realm "Unknown" is last. The Character dropdown lists "All" and each character of the selected server that has records, by name only. The default is the current server and All. A change of server resets the character to All. The selection filters the rows, the totals and the balance graph, like the date range. "All" means every character of the selected server. Flipside saves the choice in the character scope (`ledger.view.realm`, `ledger.view.char`). If the saved server or character has no records, the page uses the defaults. Owner data: the ledger stores no separate realm field. Each record has `char` as "Name-Realm", which is also the key in `FlipsideLedgerDB`. The page takes the realm from the text after the first "-". A key with no "-" (an old record with no owner data) shows under the server "Unknown". The change adds no field to `LedgerRecord` and does not change the layout of the ledger DB (D25). A filter change writes a debug line in the log (category "ledger").
   - The header and the row cells use one column definition (`LedgerPage.Columns`): same x offset, width and justify. The Qty and Money columns are right-justified. Only the header takes the list insets, because the rows already sit inside the list.
   - Each tab builds its rows only when it shows. The list is virtual. Rows are newest first. The time shows in local time. A daily sum shows as one row with the mark "daily total (count)" and the UTC date.
   - Columns of the record tabs. All have Date, Item, Qty and Money. The Character column shows only for All characters. The last column is Buyer (Sales), Seller (Purchases), Detail (Auctions), Mob (Loot) or Type (Expenses). Loot also has a Value column (vendor price × quantity).
   - Tab contents: Sales shows type `sale`. Purchases shows type `purchase`. Expenses shows type `expense`. Loot shows type `loot`. Auctions shows `post`, `expired`, `cancelled`, AH `purchase` and dry run logs.
   - Each tab has a totals row with money in, money out and net of the visible rows, and the row count.
   - If no record matches, the tab shows "No records yet. The ledger records money from loot, vendors, mail, trades, quests and the Auction House."
   - **Overview tab (user request, 2026-10-15).** The Overview is the first inner tab and the default. It combines all entries in one place. Flipside builds it only when it shows, like the other tabs.
   - Totals: the Overview has no summary strip (removed 2026-10-15, user decision). The totals row at the bottom shows Money in, Money out and Net. They use the current character filter and date range. They count every record and every daily sum with a money flow, from every source. The direction rule is the same as in the store and the balance graph (`LedgerRecord.Direction`). Net is green if it is above 0 and red if it is below 0.
   - List: every record and daily sum of the range, newest first. Columns: Date/time, Character (only for All characters), Type, Item, Qty, Money and Detail. Money shows a green "+" for money in and a red "−" for money out, with the shared money formatter. A record with no money (post, expired, cancelled, log) shows with an empty Money cell. Detail is the buyer, seller or mob, the reason of a log, or "daily total (count)".
   - Type labels (by source): AH sale, AH purchase, AH post, Deposit, Deposit refund, Outbid refund, AH expired, AH cancelled, Loot, Vendor sale, Vendor purchase, Repair, Mail money, Mail sent, Mail money sent, Trade, Quest, Flight path, Training, Bank slot, Stable, Barber, Talent reset, Guild bank and Unknown. The Mail sent rows have money 0 and show in the Overview and in Expenses. A decision log shows "Log". A dry run log shows "Dry run".
   - Income records (vendor sale, quest, mail money, trade, refunds) are in no other tab, so only the Overview counts them. The Purchases and Auctions tabs both show the AH purchase.
   - The balance graph stays above the inner tabs and shows on every tab. The page does not save the last inner tab: it always opens on the Overview.   - **Balance graph (decided 2026-10-15).** The page shows a line graph of the gold balance above the inner tabs. The graph is 130 px high and as wide as the page. The button "Hide graph" or "Show graph" in the filter row hides it. The list then gets the room. Flipside saves the choice in the character scope (`ledger.view.graph`, default shown).
   - The graph follows the character filter and the date range. The Kit widget `Kit.LineGraph` draws it (`Shared/UI/Kit/Graph.lua`). The balance maths are in `LedgerBalance`.
   - Points: the range "Today" has one point for each record, from 00:00 UTC to now. A longer range has one point for each ledger day (UTC), at the end of the day. The last point is now. "All" starts at the first day with money. A series has at most 365 points. Flipside thins a longer series.
   - Balance: balance(t) = anchor + (money change up to t) - (money change up to the anchor time). The money change of a full record follows its type: money in is plus, money out is minus. A daily sum gives money in minus money out. Records with the source "unknown" count. Records that are still in the buffer count. A record without a money flow (post, expired, cancelled, log) gives 0. The balance is never below 0.
   - Anchor of the current character: the live `GetMoney()`. Anchor of any other character: its saved balance. Flipside saves the balance of the current character at `PLAYER_LOGIN` and at `PLAYER_LOGOUT` in the character scope of the Main DB (`ledger.balance` = `{ copper, time }`). The ledger store has no balance of its own.
   - "All characters" draws the sum of the characters. A character without an anchor is left out. A note under the graph names it: "Not in the graph, no balance known yet: ...".
   - Y axis: it starts at 0 and ends at a clean value above the highest balance. It has 3 to 5 labels. The step is 1, 2 or 5 times a power of 10 in the unit. The unit is copper, silver or gold. It is the largest unit that fits the highest balance at least twice. The labels use the money formatter. The X axis has the date at the start, the middle and the end. The date is the UTC ledger day. For "Today" it is the local time.
   - Hover: the mouse over the graph shows a tooltip with the date and the balance of the nearest point.
   - Flipside computes the points again only when the character, the range, the stored records, the buffered records or the live money change. It also computes them again after each minute.
   - Closed point (PR3, decided 2026-10-15): the sale record stores in `money` the amount that really arrives (bid + deposit - consignment, the mail money). The fields `bid`, `deposit` and `cut` are detail only. The graph uses `money` only, so it counts a sale once and at the real value.
10. **Money tracking.**
    - Flipside keeps the last value of `GetMoney()`. On `PLAYER_MONEY` it computes the change and labels it with the open context: merchant, loot, trade, mail, quest or Auction House.
    - A change with no open context gets the source "unknown".
    - A module that already wrote a record for a change (for example an invoice) claims the amount. The tracker then writes no second record for it.
    - Known risk: `PLAYER_MONEY` has no payload. The order of the events (money event against the context event) is not verified.
    - An in-game probe checks the risks (build step 7 PR0).

    **Money tracker rules (decided 2026-10-15, PR2).** The code is `LedgerMoney`. The values below are named constants in that file.
    - Events: client events and reads, and exactly four read-only post-hooks (the rule "Ledger hooks" below, user decision 2026-10-17). Flipside adds no other `hooksecurefunc` and no restricted event. `COMBAT_LOG_EVENT_UNFILTERED` is restricted, so `LedgerMoney` refuses to subscribe to it. Each event was checked in the Forever API documents: none has `HasRestrictions`.
    - Windows: `MERCHANT_SHOW`/`MERCHANT_CLOSED`, `LOOT_OPENED`/`LOOT_CLOSED`, `TRADE_SHOW`/`TRADE_CLOSED`, `MAIL_SHOW`/`MAIL_CLOSED` and `AUCTION_HOUSE_SHOW`/`AUCTION_HOUSE_CLOSED`. Service windows (decided 2026-10-18): `TAXIMAP_OPENED`/`TAXIMAP_CLOSED`, `TRAINER_SHOW`/`TRAINER_CLOSED`, `PET_STABLE_SHOW`/`PET_STABLE_CLOSED`, `BANKFRAME_OPENED`/`BANKFRAME_CLOSED`, `GUILDBANKFRAME_OPENED`/`GUILDBANKFRAME_CLOSED` and `BARBER_SHOP_OPEN`/`BARBER_SHOP_CLOSE`. Each opening makes a new context id, for example `merchant:3`. The records of one window share it.
    - Loot tail: `LOOT_TAIL_SECONDS` = 1 s. The loot context stays open for 1 s after `LOOT_CLOSED`, because money can arrive after the close. No other window has a tail until the probe shows a need.
    - Quest: `QUEST_TURNED_IN` gives `moneyReward`. A change of the same amount in `QUEST_WINDOW_SECONDS` = 1 s, before or after the event, is a quest record. The event and `PLAYER_MONEY` come from one server packet, so 1 s is enough. It is short, so a real unknown change waits only 1 s. An open window does not stop the match.
    - Hold: a gain with no open context waits `QUEST_WINDOW_SECONDS` for a quest event. Then it becomes "unknown". A spend with no open context becomes "unknown" at once.
    - Priority, highest first: quest (amount match only), trade, loot, Auction House, merchant, mail. Trade is first because the other player moves the money. Loot is a short action, so it is more specific than a frame that stays open. The last three are frames that stay open, and the client closes one before it opens the next. The service windows come after mail, in this order: taxi, trainer, stable, bank, guild bank, barber.
    - Labels: merchant gives `vendorSale` (gain) or `vendorPurchase` (spend), and `repair` for a spend that equals the repair cost (see "Item detail", changed 2026-10-17). Loot gives `loot` (gain only). Trade gives `trade`. Mail gives `mailMoney` (gain only). A change that does not fit its context (for example a spend in a loot window) is "unknown". Service labels (2026-10-18, spends only unless noted): the taxi window gives `flight`, the trainer window `training`, the pet stable window `stable`, the bank window `bankSlot`, the barber window `barber`, and the guild bank window `guildBank` (gain and spend). A gain in a taxi, trainer, stable, bank or barber window is "unknown". Taxi has a tail of `TAXI_TAIL_SECONDS` = 3 s, because the server takes the fare after it closes the map. Talent reset: `CONFIRM_TALENT_WIPE(cost, respecType)` stores the cost. A spend of exactly that cost in `WIPE_SECONDS` = 60 s (the user must confirm a dialog) is `talentReset`. The amount match comes before the context, like a quest. A repair paid by the guild bank changes no player money, so it has no record.
    - Secret values: Flipside checks each payload and `GetMoney()` with `issecretvalue` when the function exists. If a needed value is secret, Flipside writes no record and counts one skip. The count shows in `/flip ledgerdebug`.
    - Claim: another module can call `Claim(amount, direction)`. The next change of that amount and direction inside `CLAIM_SECONDS` = 5 s gets no record.
    - Context for later PRs: `Context(kind)` gives the open context id. PR3 to PR6 write their item records with that `ctx`. The tracker still writes the money record. A module that writes its own money record must claim the amount. `ClaimGroup(parts, direction, seconds)` claims an action that can show as one total change or as separate part changes (a mail with postage and gold); `ReleaseClaims` frees the claims of an action that failed. Mail is the exception: `LedgerMail` sets a matcher that the tracker calls first for a gain in the mail context (see "Mail invoices").
    - Auction House merge rule. The money change is the truth and gives the amount. The events and the calls only add detail (item, quantity). Flipside writes one record for each money change. `AuctionClient.OnCall` tells `LedgerMoney` about each buy or post call of Flipside (a plain wrap, no hook). The bid post-hook (`OnBid`) gives the hint of a buy in Blizzard's own tab. Both come to `AddBuyHint`, which merges hints with the same auction ID, so a buy of the Buying tab gives one hint. A call makes a hint. The events `COMMODITY_PURCHASE_SUCCEEDED`, `COMMODITY_PURCHASED` and `AUCTION_HOUSE_PURCHASE_COMPLETED` confirm the hint, or make one for a buy in Blizzard's own tab. A spend in the Auction House context takes the oldest hint, and a confirmed hint comes first. If it finds no hint, it waits `QUEST_WINDOW_SECONDS` for one. If none comes, the record is "unknown" and Flipside counts it as unpaired. A hint ends after `HINT_SECONDS` = 10 s, because the server can be slow. The quote total is never a second record.
    - A buy gives one `ahPurchase` record. The call of the Buying tab gives the quantity only when `GetAuctionInfoByID` has it; otherwise the quantity is 0. The bid hook (changed 2026-10-17) reads the auction at once after the call: the item from `itemLink`, or from `itemKey.itemID` when the link is nil, and the quantity 1 when the info has none (a Forever item auction is one item). A bid below the buyout is also an `ahPurchase`; the record type has no bid. On TBC the backend `AuctionInfo(index)` reads the list row (link, count, buyout, owner) before the buy call, so the hint has the item. The list index is the auction ID, and the won-auction mail adds no second record.
    - A post gives two records with the same `ctx`: `ahPost` (type `post`, no money, with item, quantity, buyout and the deposit from the client estimate) at `AUCTION_HOUSE_AUCTION_CREATED`, and `ahDeposit` (an expense with the real deposit) at the money change. A confirm call replaces the post call of the same post.
        **Ledger hooks (decided 2026-10-17, user decision).** The rule "Flipside adds no `hooksecurefunc`" changes to this exact list of four read-only post-hooks. No other hook is allowed without a new user decision.
    - `SendMail` (both clients): reads the send form after the call (the form clears only at `MAIL_SEND_SUCCESS`, Forever `MailFrame.lua` 152-153, TBC `MailFrame.lua` 54-55): the recipient, `GetSendMailItem(1..12)`, `GetSendMailMoney()` and `GetSendMailPrice()`. `GetSendMailItemLink` exists in neither client source, so the item key comes from the item ID.
    - `BuyMerchantItem` (both clients): reads `GetMerchantItemLink(index)` and the price and stack size of the merchant item.
    - `C_AuctionHouse.PlaceBid` (Forever) and `PlaceAuctionBid` (TBC, list type `"list"` only): read the auction before it leaves the client data. `ConfirmCommoditiesPurchase` is not hooked: `COMMODITY_PURCHASED(itemID, quantity)` gives the commodity item and quantity.
    - Each hook only reads data, runs inside a `pcall`, and never calls a protected function. A failing hook does nothing. The code is `LedgerHooks`. The bid hook is in the flavour backend (`Backend.HookBid`, through `AuctionClient.HookBid`), because the auction API stays out of `Shared/` (D23). `MailClient` calls `SendMail` by name each time, so the hook also runs for the mailing run.
    - **Item detail (2026-10-17).** The tracker still writes one money record for each change; the modules below only add fields or no-money rows.
    - Mail send (`MailingLedger`): the hook claims the postage, the gold and their total for 30 s (a Forever mail to a stranger can wait for a confirm dialog). At `MAIL_SEND_SUCCESS` it writes `mailPostage`, `mailMoneySent` (recipient as counterparty) and one `mailSent` row for each attachment (item, quantity, recipient, money 0). `MAIL_FAILED` frees the claims. A send with no result in 120 s is dropped.
    - Vendor sale (`LedgerVendor`): the sale takes the newest unused entry of the buyback list (`GetNumBuybackItems`, `GetBuybackItemInfo`, `GetBuybackItemLink`) whose price equals the money change (the price is the total of the stack; a per-unit price also matches). The entries of the list at `MERCHANT_SHOW` are not used. If no entry matches, the tracker waits `QUEST_WINDOW_SECONDS` once and reads the list again.
    - Vendor purchase (`LedgerVendor`): the hook gives index and quantity; the cost is price × quantity ÷ stack size (the quantity counts items; no quantity means one stack, as in Blizzard `MerchantFrame.lua`). The first purchase with that amount in 10 s gives the item and quantity.
    - Repair (`LedgerVendor`): a spend equal to `GetRepairAllCost()` (read at `MERCHANT_SHOW` and `MERCHANT_UPDATE`; the last value above 0 is kept until the window closes) is source `repair`. A repair of one item and a guild-bank repair are not found.
    - **Seller of an Auction House purchase (decided 2026-10-18, user request).** The bid hook and the Buying tab call read the seller with `AuctionInfo` and put it on the buy hint. The `ahPurchase` record then has `counterparty` = the seller. What each client gives: TBC `GetAuctionItemInfo("list", index)` returns the owner as value 14 (`owner`, then `ownerFullName`). The value can be nil or empty while the client loads names; then the record has no seller. Forever `C_AuctionHouse.GetAuctionInfoByID` returns `AuctionInfo` with no owner field (itemKey, itemLink, minBid, bidAmount, buyoutAmount, bidder). For an item auction `AuctionInfo` in `ForeverBackend` searches the last item search result list (`GetNumItemSearchResults`, `GetItemSearchResultInfo`, at most 500 rows) for the same `auctionID`. `ItemSearchResultInfo.owners` is a list of owner names. The seller is taken only if the list has exactly one name. A commodity purchase has no owner (`CommoditySearchResultInfo.owners` is a summary of many sellers and the buy has no auction ID), so a commodity record has no seller. Later the won-auction mail can fill the seller (see "Mail invoices").
- **Trade partner (2026-10-18).** At `TRADE_SHOW` the tracker reads `UnitName("NPC")` (the unit that Blizzard `TradeFrame.lua` uses). The name is the `counterparty` of the `trade` records of that window. A read that fails gives no counterparty.
- **Flight destination (2026-10-18).** At `TAXIMAP_OPENED` the tracker reads the reachable nodes with `NumTaxiNodes`, `TaxiNodeGetType` ("REACHABLE"), `TaxiNodeName` and `TaxiNodeCost` (read-only globals on both clients, used by `TaxiFrame.lua`). The fare is the money change. The destination is `place` only if exactly one reachable node has that fare. The call `TakeTaxiNode` is not hooked (it is not one of the four hooks), so a fare that fits two nodes has no destination. Follow-up: a fifth hook on `TakeTaxiNode` would give the node, but needs a new user decision.
- Not covered: a buy-out in the TBC Bids tab (list type `"bidder"`), loot items, quest items, trade items.
- Debug: if the setting `ledger.debug` (default false) is true, `LedgerMoney` keeps a ring of the last 200 events with `GetTime()` times. `/flip ledgerdebug` prints the counters and the last 30 lines. Use it to check the event order in game (PR0).
**Sources and record types**

The `source` field is one of these values. The `type` field sets the view.

| Source | Type | Written by |
| --- | --- | --- |
| `ahSale` | `sale` | Sale invoice (PR3); money = the payout that arrived |
| `ahPurchase` | `purchase` | Auction House context (PR2) |
| `ahPost` | `post` | Auction House context (PR2); item, quantity, buyout price and deposit; no money change |
| `ahDeposit` | `expense` | Auction House context (PR2) |
| `log` | `log` | Decision log (PR9); no money change |
| `ahDepositRefund` | `income` | Not written (the refund is a field of `ahSale`, PR3); valid for old data |
| `ahOutbidRefund` | `income` | Mail with the outbid subject (PR3); the bid that returns |
| `ahExpired`, `ahCancelled` | `expired`, `cancelled` | Mail (PR3); no money; used by `SaleRate` |
| `loot` | `loot` | Loot window (PR4); one record for each item and one for money |
| `vendorSale` | `income` | Merchant context (PR5); item and quantity from the buyback list (2026-10-17) |
| `vendorPurchase` | `expense` | Merchant context (PR5); item and quantity from the `BuyMerchantItem` hook (2026-10-17) |
| `repair` | `expense` | Merchant context; a spend equal to the repair cost (2026-10-17) |
| `mailMoney` | `income` | Mail from players (PR3) |
| `mailPostage` | `expense` | Send hook (2026-10-17, changed from the mailing run); one record for each sent mail, the recipient is the counterparty |
| `mailMoneySent` | `expense` | Send hook (2026-10-17); the gold sent with a mail, the recipient is the counterparty |
| `mailSent` | `expense` | Send hook (2026-10-17); one row for each attachment: item, quantity, recipient; money 0 |
| `trade` | `income` or `expense` | Trade context (PR6) |
| `quest` | `income` | Quest context (PR6) |
| `flight` | `expense` | Taxi window (2026-10-18); `place` = the destination when exactly one reachable node has the fare |
| `training` | `expense` | Trainer window (2026-10-18) |
| `bankSlot` | `expense` | Bank window (2026-10-18); a bank slot purchase |
| `stable` | `expense` | Pet stable window (2026-10-18) |
| `barber` | `expense` | Barber shop window (2026-10-18) |
| `talentReset` | `expense` | `CONFIRM_TALENT_WIPE` cost match (2026-10-18) |
| `guildBank` | `income` or `expense` | Guild bank window (2026-10-18); gold deposit or withdrawal |
| `unknown` | `income` or `expense` | Money tracker (PR2) |

**In-game checklist (ledger item detail, 2026-10-17).** Run each step on WoW: Forever and on TBC Anniversary. Open the Ledger page after each step. Each step must give one row for each money change.
1. Blizzard Send tab: send one item with 1 gold to another character. Expect `Mail postage`, `Mail money sent` and one `Mail sent` row with the item, the quantity and the recipient. On Forever, send to a stranger and confirm the dialog.
2. Flipside mailing view: send a group with 2 mails. Expect the same rows for each mail, once only.
3. Send a mail and cancel it (a mail to an unknown name gives `MAIL_FAILED`). Expect no row, and no `Unknown` row for the postage.
4. Sell one stack and one single item to a vendor. Expect `Vendor sale` rows with the item and the quantity. Sell the same item twice. Expect two rows.
5. Buy 1 item and 5 items of a stack to a vendor. Expect `Vendor purchase` rows with the item and the quantity.
6. Repair all. Expect one `Repair` row with the cost.
7. Buy an item auction at the buyout in Blizzard's Auction House tab. Expect one `AH purchase` row with the item. On Forever, buy a commodity too.
8. Buy an item in the Flipside Buying tab. Expect one row, not two.
9. Turn on `ledger.debug` and run `/flip ledgerdebug`. Expect no `unpaired` count for these steps.

**Record fields**

| Field | Meaning |
| --- | --- |
| `time` | Server time in UTC, whole seconds |
| `char` | Character, `Name-Realm` |
| `type` | `sale`, `purchase`, `post`, `income`, `expense`, `loot`, `expired`, `cancelled` or `log` |
| `action`, `reason`, `tab`, `dryRun` | Log records only: the action (dry run, buy next or post next), the reason code, the tab (Buying or Selling) and the dry run flag |
| `source` | Value from the source table |
| `item` | Item key (D20); empty for money only |
| `itemName` | Item name, only when a mail gave a name and no item key could be found (PR3) |
| `qty` | Item quantity; 0 for money only |
| `money` | Whole copper, never negative; the type gives the direction |
| `mob` | Mob name for loot; "unknown" if no kill matches |
| `ctx` | Context id: the kind and a number for each session, for example `loot:12`; records of one event share it |
| `fp` | Mail fingerprint (mail records only) |
| `invoiceType`, `counterparty`, `bid`, `buyout`, `deposit`, `cut` | The fields that the invoice gives: the invoice type, the other player, the bid, the buyout, the deposit and the cut (`consignment`) |
| `counterparty` | Optional (2026-10-18). The other player: the buyer of an `ahSale`, the seller of an `ahPurchase`, the partner of a `trade`, the recipient of a mail send, the sender of `mailMoney`. An old record has none |
| `place` | Optional (2026-10-18). Text. The destination of a `flight` |
| `value` | Vendor price at loot time (loot items only) |
| `id` | Stable record id, "<time hex>-<random hex>". `LedgerStore:Move` sets it on each new record. An old record gets it when the user first edits it (2026-10-18) |
| `note` | Free text from the user (edit only) |
| `edited`, `orig` | `edited` is true after an edit. `orig` holds the first values of the editable fields and of `type` and `itemName` (2026-10-18) |

**In-game checklist (ledger counterparty and money sources, 2026-10-18).** Run each step on TBC Anniversary and on Forever. Turn on `ledger.debug` first.
1. Sell an item at the Auction House with another character as the buyer. Take the money from the mail. Expect one `AH sale` row with the buyer in the Buyer column (Sales) and in Detail (Overview). TBC: this needs `GetInboxInvoiceInfo`; if the buyer is empty, `/flip ledgerdebug` shows the raw invoice fields.
2. Buy an item auction in Blizzard's Auction House tab. TBC: expect the seller in the Seller column (Purchases) and "Bought from ..." in Auctions. Forever: expect the seller if the item search list had one owner; for a commodity expect no seller.
3. Open the mailbox. Open the won-auction mail of step 2. Expect the seller on the purchase row if it had none (only while the record is not yet moved to the ledger addon). Open the mailbox again: no change.
4. Open the flight map. Take a flight. Expect one `Flight path` row with the fare, and the destination in Detail when only one node has that fare. Open the map and close it with no flight: expect no row.
5. Repair all at a vendor. Expect one `Repair` row. TBC: repair with guild funds. Expect no row and no `Unknown` row.
6. Train one skill. Expect `Training`. Buy a bank slot. Expect `Bank slot`. Stable a pet (hunter). Expect `Stable`. On Forever, use a barber. Expect `Barber`.
7. Reset talents at the trainer and confirm the dialog. Expect `Talent reset` with the cost. Cancel the dialog: expect no row.
8. Open the guild bank. Deposit 1 gold, then withdraw 1 gold. Expect two `Guild bank` rows (one in, one out).
9. Trade 1 gold with another player. Expect a `Trade` row with the partner in Detail. If it shows `Unknown`, `/flip ledgerdebug` shows whether `PLAYER_MONEY` came after `TRADE_CLOSED`.
10. Turn in a quest with a money reward and loot money from a mob. Expect `Quest` and `Loot` rows, as before.

**In-game checklist (ledger server filter, 2026-10-18).** Run on TBC Anniversary, then on Forever.
1. TBC: open the Ledger page. A Server and a Character dropdown show next to the date range. They do not overlap the range, the graph button or the status text.
2. TBC: the Server dropdown shows the current server first, with the name as in game. The Character dropdown shows "All" and the characters of that server, by name only.
3. TBC: pick another server that has records. The character resets to All. The rows, the totals and the graph show only that server.
4. TBC: pick one character. The rows, the totals and the graph show only that character.
5. TBC: reload the UI. The page opens with the same server and character. Remove all records of that character (or use a new profile): the page opens on the current server and All.
6. TBC: `/flip log` shows a "ledger" debug line for each change (the setting for debug lines must be on).
7. Forever: the Ledger page shows the single character dropdown and works as before.
**Edit a ledger entry (decided 2026-10-18).** The user can correct one full record.
- Open the menu with a right click on a row of the Ledger page. "Edit..." opens the edit window. "Revert" shows only for an edited record. A daily total (a record past the retention days) and a decision log record cannot be edited.
- The window has the fields in `LedgerEdit.FIELDS`: source (drop-down of all sources), item (empty, an item link, an item id or an item name from the name index; the user can also drop an item from the cursor on the box; the window adds no hook, because the ledger allows only four hooks), quantity, amount, who (`counterparty`, empty clears it; added 2026-10-18) and note. Time, character and type are not editable. A new source sets the type: the type stays if the source allows it, else the type with the same money direction.
- Rules: the amount is a whole number of copper, 0 or more. The quantity is a whole number, 0 or more. The source must be known. A quantity above 0 needs an item. A bad value gives a message and the window stays open.
- Store: `LedgerStore:UpdateRecord(char, id, changes)` and `LedgerStore:RevertRecord(char, id)`. They work on the loaded store (D25) and change the record in place, so `FlipsideLedgerDB` keeps the edit. A record in the Main DB buffer is not on the page, so it is not editable. A read-only store refuses an edit.
- Record id: `LedgerStore:Move` gives each new record an id. A record from before this change has none. `LedgerStore:IdOf(char, record)` finds the record by table identity in the list of the character and gives it an id at the first edit. After that, `UpdateRecord` finds it by id.
- Silent update (2026-10-18): `UpdateRecord(char, id, changes, silent)` with `silent` true sets the fields and sets no `orig` and no `edited`. `LedgerStore:FillCounterparty` uses it for the seller of a won-auction mail. A revert restores `counterparty` with the other editable fields.
- First values: the first edit keeps the old values in `orig` and sets `edited`. Later edits keep the same `orig`. "Revert" restores `orig` and removes both marks.
- Sums: the daily sums hold only records past the retention days. The queries read the full records as they are now, and the roll-up reads the edited values. So no sum needs a correction, and the day (the time) does not change.
- Page: an edited row starts the Detail text with "*". The note shows in the Detail text. The tooltip of the row shows the note and the first values. The table, the totals and the graph draw again after a save or a revert.
- Log: each edit and revert writes one info line in the category "ledger".

**In-game checklist (ledger edit, 2026-10-18).** Run on WoW: Forever and on TBC Anniversary.
1. Open the Ledger page. Right-click a sale row. The menu shows "Edit..." and no "Revert".
2. Click "Edit...". The window shows the source, item, quantity, amount and note of the row.
3. Change the amount and add a note. Click Save. The row shows "*" and the note in Detail. The totals and the graph change.
4. Point at the row. The tooltip shows the note and the first values.
5. Edit the item four ways: drop an item from the bags on the item box (click the box with the item on the cursor), paste an item link, type an item id, type an item name. Each gives the item in the row. `GetCursorInfo` must give "item" on both clients.
6. Clear the item and keep a quantity above 0. A message shows and the window stays open.
7. Change the source to one in the other direction (a sale to a vendor purchase). The row moves to the matching tab and the totals follow.
8. Right-click the row and pick "Revert". The first values come back and the "*" goes.
9. Reload the UI. An edited row still shows its edit.
10. `/flip log` shows one "ledger" info line for each edit and revert.

**Mail invoices (decided 2026-10-15, PR3).** The code is `LedgerMail`.
- Invoice fields. Forever `Blizzard_MailFrame/MailFrame.lua` (lines 575 and 785) reads `GetInboxInvoiceInfo(index)` as: invoiceType, itemName, playerName, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count, commerceAuction. The types are `seller`, `buyer` and `seller_temp_invoice`. The payout of a `seller` invoice is bid + deposit - consignment (lines 827-831). For a sale with count > 1 the client shows bid / count as the unit price, so `bid` is the total. `GetInboxHeaderInfo` gives: packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount, wasRead, wasReturned, textCreated, canReply, isGM, firstItemQuantity, firstItemLink (lines 340 and 761).
- `GetInboxText` is called for a mail that has money and no invoice. The client gives the invoice fields only after it reads the mail text (it calls `GetInboxText` before `GetInboxInvoiceInfo`, lines 572 and 776). Without this call, `GetInboxInvoiceInfo` returns nil for an unopened mail, and a sale was recorded as `mailMoney`. So `LedgerMail` calls `api.text(index)` on each inbox read, then reads the invoice again. This happens before the money gain is classified. The call marks the mail as read. This is a visible side effect for a mail with money that is not an Auction House mail (a mail from a player). The subject match stays as the fallback. A mail with no invoice and no subject match is still `mailMoney`. A secret header skips the call. TBC calls it too (changed 2026-10-18). The Forever API documents have no entry for `GetInboxText` or `GetInboxInvoiceInfo`. In game check: see the checklist of the PR. If a sale subject comes without invoice fields, the sale still gets a record from the mail money, with the item name from the subject, and the counter `without invoice` goes up.
- Events: `MAIL_SHOW` (new snapshot), `MAIL_INBOX_UPDATE` (debounced read, `DEBOUNCE_SECONDS` = 0.3, changed 2026-10-20) and `MAIL_CLOSED` (snapshot ends). A read first builds a cheap header signature (count and the header fields of each mail). If the signature is the same as at the last full read, the read stops: no invoice call, no hash, no match. `GetInboxText` is called once for each mail identity (index, sender, subject) until the next `MAIL_SHOW` or `MAIL_CLOSED`. The match uses a table keyed by sender and subject. No `hooksecurefunc` on `TakeInboxMoney`, `TakeInboxItem`, `AutoLootMailItem` or any `C_` function. No restricted event.
- Snapshot: for each mail the index, sender, subject, money, item count, first item, invoice fields and the fingerprint. A new read is matched with the old snapshot by sender and subject and no less money (the index is not used). Money that left a mail (the money went down, or the mail is gone) is a "drop".
- Which mail is an Auction House mail. The invoice type decides first: `seller` is a sale, `seller_temp_invoice` is a pending sale (no record, the payout comes in a later `seller` mail), `buyer` is a purchase. Without an invoice, the subject is compared with the patterns that `LedgerMail` builds from the client global strings `AUCTION_SOLD_MAIL_SUBJECT`, `AUCTION_EXPIRED_MAIL_SUBJECT`, `AUCTION_REMOVED_MAIL_SUBJECT` (cancelled), `AUCTION_OUTBID_MAIL_SUBJECT` and `AUCTION_WON_MAIL_SUBJECT`. These names are not in the Forever source dump (the global strings are not in it), so they are not verified. A missing global turns off only its own kind. The module never matches English text.
- Claim order (both orders of `PLAYER_MONEY` and `MAIL_INBOX_UPDATE` are handled). When `PLAYER_MONEY` gives a gain in the mail context, the tracker calls the mail matcher before it labels the gain. The matcher does not read the inbox (changed 2026-10-20): it schedules the debounced read, so a burst of money takes gives one full read. (a) If the drop is already known, `LedgerMail` writes the record and the tracker writes none. (b) If no drop matches, the tracker holds the gain for `QUEST_WINDOW_SECONDS`. `LedgerMail` settles held gains when the scheduled read runs, and releases the held gain (`ReleaseHeldMail`). If `MAIL_CLOSED` comes before that read and the client still gives the inbox, it reads once. If the inbox reads empty, it pairs the held gains with the mails of the last snapshot that have the same money amount, and it keeps no other drop. (c) If no mail claims the gain in that time, the tracker writes `mailMoney`. (d) A drop that gets no money change in `PENDING_SECONDS` = 10: a sale invoice still gets its record and `Claim(amount, "in")`, so a late money change gets no second record. If one money change is the sum of all open drops (the player took several mails at once), `LedgerMail` writes one record for each drop.
- Records: `ahSale` for a sale invoice (item, quantity, `money` = the amount that arrived, `bid`, `buyout`, `deposit`, `cut`, `counterparty` = the buyer, `invoiceType`, `ctx`). `ahOutbidRefund` for the outbid mail. `mailMoney` for every other mail with money. A buyer invoice gives no money record: the Auction House purchase is a record from PR2, and the item comes in the mail. The item name is resolved to a key with the item name index when exactly one item has the name; else the record keeps `itemName`.
- Expired and cancelled: one rule. A record (`ahExpired` or `ahCancelled`, no money) is written when the mail is first seen in the inbox, not when the item is taken. The item and quantity come from the header (first attachment). The mail subject sets the kind.
- Fingerprint: a hash of sender, subject, the invoice values (or the mail money if there is no invoice), item count, first item and quantity, plus an occurrence number. A mail with money takes the lowest number that is not saved and not used in the snapshot, so a new sale equal to an old one is not lost. Another mail takes its place among equal mails. A matched mail keeps its fingerprint. Flipside saves fingerprints in the account setting `ledger.mailFps` for 31 days. A saved fingerprint blocks a second record. The residual risk: after a reload, an equal expired mail whose twin was removed gets the number 1 again and its record is skipped.
- Secret values: a mail with a secret header or invoice field is skipped and counted.
- TBC (changed 2026-10-18): the flavour value `hasMailInvoices` is true. `GetInboxInvoiceInfo(index)` in `classic_anniversary` `Blizzard_UIPanels_Game/Classic/MailFrame.lua` (lines 376 and 514) returns the same fields in the same order as Forever, including `count` and `commerceAuction`. The client calls `GetInboxText` first there too. So a TBC sale gets the buyer, the bid, the deposit and the cut. If a TBC invoice is missing, the subject patterns still work, so a sale gets a record from the mail money.
- Won-auction mail (2026-10-18). A mail with the won subject (`AUCTION_WON_MAIL_SUBJECT`) has money 0, but its buyer invoice (`buyer`) names the seller in `playerName`. `LedgerMail` reads the mail text of such a mail like it does for a mail with money (the mail becomes read). On the first sight of the mail, it sets `counterparty` = the seller on the newest `ahPurchase` record of this character that has no counterparty, the same item key and a matching quantity (an unknown quantity matches). It saves the mail fingerprint, so a mail fills one record only. It changes a record in the Main DB buffer first (`LedgerBuffer:FillCounterparty`). If none matches and the ledger addon is loaded, it changes a record in `FlipsideLedgerDB` (`LedgerStore:FillCounterparty`, which uses `UpdateRecord` in silent mode). That change sets no `edited` and no `orig`. If the addon is not loaded, a record that already moved is not changed. The bid hook may already have set the seller (TBC list row); then this step changes nothing. The counter `sellers` in `/flip ledgerdebug` counts the records it filled.
- Debug: `/flip ledgerdebug` prints the mail counters. With `ledger.debug` on, the ring holds the raw invoice fields.

**Packaging.** The release has two addon folders: `Flipside` and `Flipside_Ledger`. The TOC of `Flipside_Ledger` has `## LoadOnDemand: 1` and `## Dependencies: Flipside`.

### 5.9 Sniper (reference §5.2)

- Repeats searches for a chosen watch list or groups; on Retail with a delay to respect throttles.
- Threshold defaults to a percentage of `ScanMarket` and refuses to alert when the price is stale.
- Sound and screen flash on hit; one-click buyout.

### 5.10 Others carried over

Operations and formulas (§4.2–4.3), tooltips and inventory tracking (reference §5.11; for Flipside, see the "Tooltips and inventory design" block below), crafting and queue (§5.3), dashboard (§5.8), destroying (§5.9) and the Task List (§5.10) behave as in the reference, using scan sources in place of AuctionDB.

**Tooltips and inventory design (decided 2026-10-14)**

1. **Bank.** The bank is tracked in the MVP. Flipside saves the bank contents when the bank is open and shows the age of that count. "Keep in bags" still counts the bags only.
2. **Guild bank.** Later, not in build step 5.
3. **Mail and own auctions.** Tracked in the MVP. Equipped items come later.
4. **Characters.** All characters of the account, on every realm on Forever. On TBC the tooltip shows and counts only the characters of the current realm (changed 2026-10-21; `ns.Flavour.countsCurrentRealmOnly`). See point 17.
5. **Tooltip settings.** The tooltip lines are set on a new "Tooltip" tab in the Flipside window. They are stored in the profile.
6. **Stack total.** Shown while Alt is held. Shift is Blizzard's compare key. Each entry has an `altStack` flag (changed 2026-10-14), default on, set with the check box "Hold Alt for stack value" in the Tooltip tab. An entry with the flag off shows the per-item value while Alt is held. If the price table has the flag off, its title has no "stack of N". A stored line without the flag gets the default on. Alt behaviour (changed 2026-10-21, point 17): the label shows the count ("Min x20"), and the tooltip builds again when Alt goes up or down.
7. **Data line.** Superseded by point 15. A custom formula line shows "Label 12g 40s", and can add " · 3 h old" and " · 9/14 days" when its age and days settings are on. The days are the days with data in the 14-day window (`ScanSamples`).
8. **Money (changed 2026-10-14).** Every non-zero unit shows: "12g 40s 7c", "3s 25c", "1g 5c". A zero unit does not show. Zero is one copper unit. A negative value has a minus sign before the units. By default each unit shows the game's gold, silver or copper coin icon. If the game option Colorblind Mode is on, each unit shows the letter g, s or c: "12g 40s 7c", "0c", "-3s 25c". The formatter calls the client function `GetMoneyString(money, true)`, which reads the option at each call. A change of the option shows at the next redraw or tooltip. Flipside has no setting that overrides the option (changed 2026-10-15). Values round half up to whole copper, and Flipside never shortens a value to one unit. Gold has thousands separators ("1,234g"). Chat, the AH tab, the Formula page and the Operations page use the same formatter.
9. **Default lines.** The price table (point 15), group path, selling operation, and counts per character. The formula lines Market, Min and Max are no longer defaults.
10a. **Quest items.** Flipside adds no tooltip line to a quest item (item class 12, read with `C_Item.GetItemInfoInstant`); if the class is not known, the lines show as usual.
10b. **Items with no vendor value.** Flipside adds no tooltip line to an item with a vendor sell price of 0 (11th return of `C_Item.GetItemInfo`), because such an item usually cannot be sold on the AH. If a scan record exists for the item key, the lines show. If the sell price is not known, the lines show as usual.
10c. **Keys and soulbound items.** Flipside adds no tooltip line to a key (item class 13), even with scan data. It adds none to an item with bind type bind-on-pickup (1) or quest (4), or account-bound where the client defines it (14th return of `C_Item.GetItemInfo`). It adds none to an item that `C_Item.IsBound` reports as bound, but only when the tooltip owner is a bag or equipment slot. A chat link or AH row has no owner, so that check is skipped. If the class or bind type is not known, the lines show as usual.
10. **Combat and missing data.** Tooltip lines show in combat too. Items without data show "invalid price".
11. **Budget.** At most 1 ms per tooltip once the data is loaded. This is measured in game.
12. **Dashboard.** Phase 2, as in the feature list. The scan time and cooldown stay on the AH tab.
13. **Forget character.** A function removes only the inventory of that character. The button comes later.
14. **Min, max and average.** Superseded by point 15 for the default tooltip. The formula sources `ScanLow`, `ScanHigh` and `ScanMarket` (§4) still mean the last 14 days.

15. **Price table (decided 2026-10-14).** The tooltip shows the prices as a table. The title line is "Flipside (updated 2 h ago)"; the age is that of the latest scan. With Alt and a stack, it is "Flipside (updated 2 h ago, stack of 5)" and all cells are multiplied by the stack count.
    ```
    Flipside (updated 2 h ago)
            Min    Avg    Max    Market
    1d      ...
    14d     ...
    30d     ...
    60d     ...
    ```
    - Rows are windows by server day (UTC, `ScanClock`). 1d is today. 14d, 30d and 60d are N days with today included. The data keeps 60 days.
    - **Min**: the lowest buyout seen in the window (the lowest snapshot or daily `min`).
    - **Avg**: the mean of the daily lowest buyouts. For 1d it is the mean of the snapshot lows of today.
    - **Max**: the highest daily lowest buyout. For 1d it is the highest snapshot low of today.
    - **Market**: the mean of the daily market values. For 1d it is the mean of the snapshot market values of today.
    - Today is the snapshots of today. Without snapshots, the latest scan counts as today if it is from today. Older days are the daily records.
    - A cell without data shows "-"; the table keeps its shape. An item with no data at all shows one line "Prices  invalid price" and no table.
    - The table is a line of the Tooltip tab ("Price table"). The player can turn it off or move it. It cannot be removed or edited. Formula lines of the player show below or above it as ordered. It is not a formula line, so it does not use the formula language.
    - Drawing: `GameTooltip` lines have only a left and a right text. Flipside reserves one blank tooltip line per table row (the header row and four windows), draws the five columns in its own frame over them, and sets `SetMinimumWidth` so that the table fits. The frame hides on `OnTooltipCleared` and `OnHide`. Both clients have `GetLeftLine`, `NumLines` and `SetMinimumWidth` (checked in the Forever source and the TBC Anniversary source).
    - Migration: a stored version 1 tooltip setting with the untouched Market, Min and Max lines gets the price table in their place, at the top. Changed, turned-off and custom lines stay below it.
16. **Vendor price, periods and stats (decided 2026-10-20).**
    - **Vendor sell price.** A row "Vendor:" shows the unit sell price (11th return of `C_Item.GetItemInfo`). It is blue (`|cff4fa3ff`, constant `TooltipLines.VENDOR_COLOR`) on both sides. It is on by default. The check box "Vendor" on the Tooltip tab turns it off (renamed 2026-10-21). With Alt and a stack, the row shows the stack total ("Vendor x4:"), as the other rows do. The row is hidden when the price is 0 or not known. The client item tooltip also has its own "Sell Price" line (`GameTooltip_OnTooltipAddMoney`, Forever and TBC Anniversary source), so the player sees two vendor lines. The player can turn off the Flipside row.
    - **Periods.** The check boxes 1d, 14d, 30d and 60d of the Tooltip tab turn each window on or off. All are on by default. If no window is on, the price rows do not show.
    - **Stats.** The check boxes Min, Avg, Max and Market turn each column on or off. All are on by default. The columns keep the order of the table. If no stat is on, the price rows do not show.
    - **Layout.** With two or more stats, the price table shows only the selected columns. With one stat, the table is replaced by one row for each window, such as "14d market  1g 2s", under the same title line.
17. **Tooltip polish (decided 2026-10-21, user requests).**
    - **Counts.** The character rows show the name only, with no realm. If two shown characters have the same name on different realms, those two show "Name-Realm". On TBC the rows and the "Total" cover only the characters of the current realm (`GetNormalizedRealmName`); if the realm is not known, all characters show. Forever shows all realms.
    - **Class colour.** Each name has the colour of its class (`RAID_CLASS_COLORS`, entry `colorStr` or red, green and blue; both clients have the table). The class file (`UnitClass("player")`, second result) is saved in the holdings value of the character (`class`, version stays 1) at each login. Old data has no class and shows white. An unknown class file also shows white.
    - **Line colour.** A formula line has an optional colour `color = { r, g, b }` (parts 0 to 1) in the tooltip settings. The Tooltip tab has a swatch at the label box and a button "Default colour". A click on the swatch opens `ColorPickerFrame`: `SetupColorPickerAndShow(info)` with `swatchFunc` and `cancelFunc` where the client has it, else the fields `func`, `cancelFunc` and `previousValues`. Each change saves. Cancel gives the old colour back (or none). The row (label and value) uses the colour; a line with no colour looks as before. The price table has no colour.
    - **Alt.** The Alt code existed (`altStack`, hook stack count) but the tooltip did not change when Alt went up or down over an item. Now `Tooltip.Attach` subscribes to `MODIFIER_STATE_CHANGED`. If the key is an Alt key, the state differs from the last build and the tooltip is shown, it runs the `OnEnter` script of the tooltip owner. The client then builds the tooltip again and the hook runs. The stack count comes from the bag slot (Forever `GetBagID`, or the item location of a bank button; TBC the `ContainerFrame` parent or the `BankFrameItem` button). The label shows the count: "Min x20" (a final colon stays last: "Vendor x4:"). The table title keeps "stack of N". An unknown stack gives the value of one item.
    - **In-game checklist.** Forever and TBC: (a) vendor row is blue and reads "Vendor:"; the check box reads "Vendor". (b) Counts show class-coloured names with no realm. (c) TBC: a character on another realm does not show and is not in the total. (d) Forever: a second character with the same name on another realm shows "Name-Realm" for both. (e) A swatch click opens the colour picker; OK saves; Cancel restores; "Default colour" resets; the tooltip uses the colour. (f) Hover a stack in a bag and press and release Alt: the tooltip changes at once, with "x20" in the labels. (g) The same in a bank slot. (h) No Lua error and no "action blocked" message after step f.
    - **Storage.** The tooltip settings keep `showVendor`, `periods` (by window label) and `stats` (`min`, `avg`, `max`, `market`). A stored setting without these keys gets the defaults (all on).
    - In-game check: see the Tooltip tab list in the checklist of §5 (vendor row, each window, each stat subset).
### 5.11 Great Deals (new)

Right after each full scan, before raw listings are discarded, every listing is compared with the item's `ScanMarket` from *before* this scan, so a flood of cheap listings can't lower its own benchmark.

- **Deal rule** (a formula, default): unit price ≤ 60% of `ScanMarket`, `ScanSamples` ≥ 5, and saving ≥ 50g per unit. All three are editable.
- **Scope:** items in chosen groups (default) or everything.
- **Output:** a sortable list — item, price, market, % of market, quantity at that price, potential profit.
- **Buying:** replicate results can't be purchased directly, so *Buy* runs a targeted search for that item and opens it in Buying at the deal price.
- The list is kept until the next full scan and marks rows already gone after a targeted search.

### 5.12 Price history chart (new)

- Opens from the item tooltip (modifier-click) or any item row.
- Lines: daily `ScanMarket` and `ScanMin`; bars: listed quantity. Your own ledger sales and purchases appear as markers.
- Ranges: 7, 14, 30, 60 days and all retained data (D6).
- Hover shows the day's values and how many scans the day is based on; partial-day data is drawn lighter.

### 5.13 Deposit-aware posting (new)

On Retail the deposit is returned on sale and lost on expiry; the AH keeps a cut of the sale (the estimate is 5%; see §5.4 point 18).

- Before posting, estimate expected value per auction: `P(sale) × (price × 0.95) − (1 − P(sale)) × deposit`.
- `P(sale)` = your `SaleRate` for the item; if fewer than 5 past auctions, use a setting (default 30%) and say so in the decision log.
- Deposit comes from Blizzard's deposit calculators for items and commodities.
- If expected value is below a threshold (default 0), the item is skipped with reason "deposit risk" and the numbers shown. A per-operation toggle turns the check off.

### 5.14 Craft profit ranking (new)

- After each full scan, recompute `Crafting` cost and crafted value for every recipe known by any of your characters.
- Ranked list: recipe, crafter, cost, value, profit, profit %, and data age of the least fresh input.
- Recipes with stale or thin data (min-samples rule) drop to the bottom, flagged.
- *Queue* adds the craft to the crafting queue up to the Keep stock target, or a quantity you type.

### 5.14a Craft profit panel (added 2026-10-19)

A small panel docks to the right side of the profession window (`TradeSkillFrame` on TBC, `ProfessionsFrame` on WoW: Forever). It shows the cost and the profit of the selected recipe. It adds no hook.

- **Reagents:** icon, name, quantity, unit price and line cost. A reagent with no price shows "no price". A slot with quality tiers uses its first item. Optional and modifying slots do not count (see "Retail crafting details" in Needs scoping).
- **Craft cost:** the sum of the line costs. If a reagent has no price, the panel shows "at least" and the profit is "at most".
- **Item value:** the AH price of one item times the average made, (min + max) / 2.
- **Profit:** value - AH cut - cost. The cut is `SellingPlan.AH_CUT` (5%, §5.4 point 18). The panel shows the profit in green or red, and the profit as a percent of the cost.
- **No item result** (an enchant): the panel shows the cost and "No item to sell".
- **Prices** come from two formulas in the account scope of the settings DB. Reagent price, key `crafting.reagentFormula`, default `min(vendorbuy, scanmin)`. Item value, key `crafting.itemFormula`, default `scanmin`. `vendorbuy` is a later source (see Price sources), so today it is invalid and `min` skips it. If a formula is invalid for an item, the item has no price. The Formulas button of the panel edits both formulas.
- **Refresh:** on `TRADE_SKILL_SHOW` (show), `TRADE_SKILL_CLOSE` (hide), `TRADE_SKILL_UPDATE` (TBC), `TRADE_SKILL_LIST_UPDATE` and `TRADE_SKILL_DATA_SOURCE_CHANGED` (Forever), `Flipside.ScanFinished` and `Flipside.PriceCaptured`. The panel also reads the selected recipe every 0.2 s in an OnUpdate of its own frame, and draws again only when it changes.
- **API:** TBC uses `GetTradeSkillSelectionIndex`, `GetTradeSkillInfo`, `GetTradeSkillItemLink`, `GetTradeSkillNumMade`, `GetTradeSkillNumReagents`, `GetTradeSkillReagentInfo` and `GetTradeSkillReagentItemLink`. Forever uses `ProfessionsFrame.CraftingPage.SchematicForm:GetRecipeInfo()` and `C_TradeSkillUI.GetRecipeSchematic`. A missing API gives "Not supported on this client".
- Files: `Shared/Services/CraftCost.lua` (no frame code), `Shared/Features/Crafting/CraftClient.lua` (client adapter), `Shared/Features/Crafting/CraftPanel.lua` (panel).
- Follow-up (not built): the `crafting` and `matprice` formula sources, the ranking in 5.14, and quality tiers.

### 5.15 Presets and undo (new)

- **Presets:** ready-made operations to start from, e.g. "Safe seller" (never below 80% of market), "Fast undercut", "Material buyer" (max 90% of market, buy up to stock) and "Flipper" (buy below 60%, sell at market). Presets are copied, never linked, so editing one doesn't change others.
- **Undo:** every change to groups, operations and keep-stock rules is recorded per profile. Undo and redo the last 50 changes, plus *Restore snapshot* for a full profile state saved daily (last 7 kept).

## TBC Anniversary port

The TBC Anniversary port follows D11 and D23 to D25. It is a full port, including the AH tab.

### AuctionClient interface
Each `AH_<Flavour>/` folder has one AuctionClient backend. Shared code calls only this interface:

- Scan start.
- Scan done event.
- Row count.
- Row read.
- Row link.
- Name search.
- Owned auctions.
- Owned event.
- AH host (the frame that holds the Flipside tab).
- Cooldown.

### Flavour config
Each `Core_<Flavour>/Flavour.lua` sets these fields:

- Bag IDs.
- Bank IDs. On TBC the list includes container -1.
- Scan cooldown.
- Ruleset (D22, D24).

### Rules for TBC
- Passive capture (ScanCapture) is on for TBC. It reads the legacy list. The rules of §3.2 apply (D5, partial results, keys).
  - Event: `AUCTION_ITEM_LIST_UPDATE`. Many events come for one query, so Flipside reads the page once, when no event came for 0.3 s.
  - Page: `GetNumAuctionItems("list")` and `GetAuctionItemInfo("list", i)` (count, buyout of the whole stack, item ID) and `GetAuctionItemLink`. The unit price is the buyout divided by the count.
  - A page is complete (replaces the day's value) if the number of rows equals the total of the query. Otherwise it is partial (latest only).
  - Keys: a stackable item uses the base key, other items the exact key of the link (D20). A row without a link uses the item ID if the item is stackable; Flipside skips other rows without a link.
  - Excluded: a Flipside full scan, a Flipside name search, any get-all query (also from another addon) and a page of more than 50 rows. A hook on `QueryAuctionItems` tells Flipside which query is current. Any other query is captured, also the queries of other addons that use the same global.
- The TBC full scan uses the legacy "get all" query. The ScanTest TBC spike (`ScanTest_TBC.toc`, pull request #86) tests its behaviour first.

### TBC scan modes
The backend lists the scan modes with `ScanModes()`. Forever returns nil and keeps one full scan (ReplicateItems).

| Mode | Slash | Call | Wait after the read |
|---|---|---|---|
| Full | `/flip scan` | get all query | Refresh for up to 90 s, until every item has a key. |
| Fast | `/flip scan fast` | get all query | Refresh for up to 8 s. |
| Page | `/flip scan page` | browse query, page by page, no get all | Refresh each page for up to 2 s. |

- The refresh window is the backend value `ScanRefreshSeconds(mode)`.
- In each refresh poll (once each second) the engine asks for item data of the items that still need a link, and reads the missing links again by row index. The list is still valid, because the engine does not leave the list.
- A failed item load does not stop the scan. The next poll asks again. The diagnostics count the items that are still failed as `failed`.
- Page scan: wait for `CanSendAuctionQuery()` before each page, query `page` 0, 1, 2 and so on (50 rows for each page), read the page after `AUCTION_ITEM_LIST_UPDATE`, and read its missing links again for a short time. The engine adds all pages to one result and commits once. Progress shows "page N of M"; M is the second `GetNumAuctionItems("list")` value divided by 50. The Stop button works. The page mode needs no get all permission and sets no cooldown.
- The Flipside tab shows one button for each mode. The get all modes are disabled while get all is on cooldown, and the tab shows the time left. The page button stays enabled.

### TBC key rule for a row without a link
A row can have an item ID and no link, because the client has no item data yet. D20 says the base key is the item ID, unless a suffix or random property that only the link shows changes it.

1. If the stack size is more than 1, the key is the item ID. No link is necessary.
2. Otherwise the engine uses the link to make the key. A row without a link waits for the refresh.
3. After the refresh window, a row still without a link gets the item ID key if the item info says that the item cannot have a random suffix (the item class is not weapon and not armor). The diagnostics count these items as `keyedWithoutLink`.
4. If the item info is not available and no row of the item has a link, the item ID key is also used and counted in `keyedWithoutLink`.
5. A weapon or armor item without a link stays pending. Its rows get no key. The item keeps its old data and the summary counts it as pending.
6. If some rows of an item have a link, the rows without a link of a weapon or armor item are not stored.

Risk: rule 4 can put a suffix item without item info under the base key. Rule 3 can also be wrong for an unusual item class. The `keyedWithoutLink` count lets the in-game check find these cases.

### Forever scan retry
Updated 2026-10-16 (the user approved it). The Forever backend gives `ScanRefreshSeconds()`. It is the no-progress time (15 s), not a cap on the total wait. The engine does this for each Forever scan:

1. The engine reads all rows in frame slices right after the done event. A row with a link and full info (`hasAllInfo`) is accepted at once.
2. The engine asks at once for the item data of every item that has an unloaded row (no link, or `hasAllInfo` is not true). It also asks for items with an unknown commodity status. It does not ask one item at a time.
3. When the data of an item arrives (`ITEM_DATA_LOAD_RESULT` through the item cache), the engine reads the rows of that item again by index. The replicate list stays valid after the scan. A row that is still not loaded gets a new read once each second. A failed load gets a new request once each second.
4. A write needs all rows of an item, so that the minimum buyout and the quantity are right. The engine writes each item once, when all its rows are accepted.
5. The wait ends when no item is outstanding, or when the Auction House closes, or when no row was accepted for the no-progress time. There is no global time cap. An item can load after more than 40 s if rows are still accepted.
6. Key rule at the end: an item without a link is stored under the base key if the client says it is a commodity (or, without that answer, the maximum stack size is more than 1). Other items stay pending, for example gear without a link.
7. A pending item gets no write and keeps its old data. All keyed items get a normal snapshot (today and latest), also if other items stay pending (see §3.2 rule 9).
8. If the Auction House closes before the done event, the scan stops with the result "stopped" and saves nothing. If it closes during the read, the scan is partial (§3.2 rule 9).
9. The Forever diagnostics line shows `rows R, written W, pending N items (P rows), failed F, nilLink L, notAllInfo A, retried T; wait S s, read S s, item load S s`. `wait` is the time to the done event. `read` is the row read. `item load` is the time from the first request to the end of the wait. `nilLink` and `notAllInfo` count the pending items by reason. `retried` counts the items that got a new request or read after the first one. The scan DB `diag` table keeps the last 5 runs.
10. The summary says "complete with N pending" if the read was complete and N items stay pending. It says "partial" only if the read was incomplete.
### TBC scan diagnostics
The `legacy scan:` line and the `diag` entries of the scan DB have `mode`, `keys`, `pending`, `failed`, `keyedWithoutLink`, `refreshSeconds` and `pages` (page mode) in addition to the row counts.

### Open in-game checks
- Scan modes: Full, Fast and Page scan on TBC Anniversary (see the in-game checklist in the pull request).
- Interface number. 20505 is from memory.
- `NUM_BAG_SLOTS` and `NUM_BANKBAGSLOTS`.
- The getAll row count and cooldown.
- The return values of `GetAuctionItemInfo`.
- Does `tooltip:GetItem()` work in `OnTooltipSetItem`?
- Can the addon add a fourth `AuctionFrame` tab without taint?
- Are auctions shared across connected realms?
## Architecture

The whole "outside the game" layer from the reference (§2) is gone: no servers, no desktop app, no AppHelper. Price data enters only through the Auction House API and is stored in its own Scan DB.

&#91;embedded content: In-game-only architecture · 2 layers, 3 addon tiers\]

Features sit on shared services, which sit on the framework; the scan engine is a service, so every feature reads the same prices and freshness data.

## Visual style

Flipside looks like the WoW: Forever UI: the classic stone, parchment and gold-trim frames of the original UI, with no tint and no own art (D17).

### Using Blizzard's textures

[Gethe/wow-ui-textures](https://github.com/Gethe/wow-ui-textures) is a mirror of the game's UI textures converted to PNG. It is a **catalogue, not an asset source**:

- Use it to browse and preview textures and find their in-game paths.
- In code, reference Blizzard textures by in-game path or atlas name (e.g. `Interface\DialogFrame\UI-DialogBox-Border`). The client already has them, so nothing is redistributed.
- Verify each path exists in the Forever client (its interface source, see Handover) before using it; Forever's art may differ from Retail's.
- **Never ship Blizzard textures, or upscaled or edited copies of them, in the addon.** They are Blizzard's art, the mirror states no licence, and Flipside's MIT licence can't cover them.

### Flipside's own textures

Obsolete (D17, changed 2026-10-14). Flipside has no own art and ships no texture. It uses only the client's own assets.

### Palette

Obsolete: the bronze palette is removed (D17, changed 2026-10-14). Flipside uses the client's own colours and font colours, untinted.

Gold, silver and copper coin amounts keep the game's own coin colours so money reads instantly. Profit and loss never rely on colour alone (add + / − signs and icons), and text must meet WCAG AA contrast on its background.

### Rules for the UI kit

- Every colour, texture and font comes from one theme table. Ship one theme: untinted game art.
- Use the game's own fonts (Friz Quadrata via the standard font objects) so text matches the client; ship no font without a compatible licence.
- Borders and edges are pixel-perfect at any UI scale.
- Frames follow the classic layout language: title bar with portrait-style icon, tabs along the bottom edge, close button top-right.
- Tab style and size (2026-10-15, user feedback on TBC). The Kit takes the tab template as an option, and the caller passes it from `ns.Flavour` (`pageTabTemplate`, `topTabTemplate`, `topTabPadding`, `topTabMinWidth`). TBC uses `CharacterFrameTabButtonTemplate` for the bottom tabs, as the Character and Auction House frames do. Top tabs size to their text plus padding, with a minimum width. If the bottom tabs are wider than the window, the Kit shrinks them evenly with `PanelTemplates_TabResize` and the text truncates.
- The kit lives in `Shared/UI/Kit/` and has no reference to Flipside code or names, so other addons can reuse it (D19).

### UI layout (decided 2026-10-14)

- Every Auction House feature is embedded in Blizzard's Auction House frame (`AuctionHouseFrame`). Flipside adds its own tabs to it when needed. There is no replacement frame.
- A separate Flipside window, like the reference main window, holds groups, operations, settings and the formula preview.
- The Flipside window starts at 800 x 540, the same as the AH frame. The player resizes it with a grip in the bottom-right corner. The minimum is 800 x 540. The maximum is the screen size (`UIParent`). The character setting `ui.windowSize` (`{ width, height }`) saves the size when the drag stops. The window restores it on create. The Kit window takes the option `resize = { minWidth, minHeight, maxWidth, maxHeight, get, set }` and uses `SetResizeBounds`, or `SetMinResize` and `SetMaxResize` on an older client. The pages anchor to the content frame and fill the window.
- The AH frame gets the tab "Flipside". It has the full scan button, the cooldown, the scan status and the item price lookup. WoW: Forever and TBC also get the tab "Buying" after it (TBC: 2026-10-16). The Selling tab comes on Forever now and on TBC in the next pull request. A flavour host (`AH_<Flavour>/AuctionTabHost.lua`) adds one tab for each registered entry after the Flipside tab and uses one click hook.
- **Price lookup input** (the AH tab box and `/flip price`). It accepts four forms:
  1. An item name (the name index and the choice list).
  2. An item ID, for example `785`.
  3. An item link (shift-click into the box).
  4. A Flipside key, for example `25320#s-44`.
- The lookup shows the stored values first. A link or a name gives the item name for the refresh.
- **Targeted refresh.** If the Auction House is open, the lookup also searches that one item and stores the fresh price through the capture. Then it shows the rows again (the tab) or prints the fresh price (`/flip price`). The result follows the capture rules of §3.2.
  - TBC: `QueryAuctionItems(name, nil, nil, 0, false, 0, false, true, nil)`. The eighth argument is `exactMatch`. The name comes from the link, the name match or the item cache. If no name is known, the lookup says so.
  - Forever: `C_AuctionHouse.SendSearchQuery(itemKey, {}, true)` with an item key made from the item ID. The existing search capture events store the result.
  - A running Flipside scan or name search blocks the refresh. If the Auction House is closed, the lookup shows the stored data and the hint "open the Auction House to refresh this price".
- `/flip` without arguments opens the Flipside window. A button on the Flipside AH tab opens it too.
- **Minimap button.** A round button sits on the edge of the minimap (`Minimap`, round in Forever). It shows a client icon.
  - A left click shows the window on the Ledger page. If the window already shows the Ledger page, the click hides the window.
  - The tooltip shows "Flipside", "Left click: open the ledger" and a drag hint.
  - The player drags the button around the minimap edge. The account setting `ui.minimapAngle` (degrees) saves the place when the drag stops.
  - The account setting `ui.minimapHidden` (default false) hides the button. `/flip minimap` changes the setting and prints the new state.
  - The button is a Kit widget, `Kit.CreateMinimapButton`. It takes the icon, the tooltip lines and the callbacks as arguments. It uses no library (D18).
- **Window pages.** The order of the tabs is Ledger, Groups, Operations, Tooltip, Formulas, About (changed 2026-10-17). The Ledger page is the first page. Formulas and About were in a Settings view behind a cog button. The cog and the Settings view are removed. The six tabs fit in the 800 px minimum width on both clients (the Kit shrinks them evenly if they do not).
- In-game checklist (window tabs): the title bar has no cog. The tab row shows six tabs. Formulas and About open as pages. Check this on both clients at the minimum width; no tab overlaps another.
- **Window position.** The window keeps its last place on the screen.
  - The Kit window takes the option `savePosition = { get, set }`. When a drag stops, it calls `set` with `{ point, relativePoint, x, y }`. On create, it reads the value with `get`.
  - The account setting `ui.windowPosition` holds the value. Flipside does not use the client layout cache for this.
  - The Kit ignores a value that is not valid or is off the screen, and centres the window. The window is also clamped to the screen.
  - `/flip resetpos` centres the window and clears the saved value.
- The window can open in combat (plain show, no protected actions). Escape closes it.
- One untinted theme table.
- The chat commands stay for now: `/flip scan`, `scan stop`, `scan reset`, `price`, `formula` and `version`.
- First UI stack: the UI kit (`Shared/UI/Kit/`), the Flipside window with a formula preview page, and the Flipside AH tab. The groups and operations UI come with build step 4.

## Storage, profiles, sync and import/export

The reference model (§7–9) is kept: one account-wide SavedVariable, flat scope-prefixed keys, profiles for rules and per-character data for holdings. The changes are a second SavedVariable for scan data and open formats.

### 7.1 SavedVariables split

| File | Holds | Why separate |
| --- | --- | --- |
| Main DB | Settings, profiles, groups, operations, keep-stock rules, inventory, the small ledger buffer (§5.8) | Small; changes every session |
| Scan DB | Daily price history per region and ruleset (§3.3) | Large; can be reset or shared without touching settings |
| Ledger DB (`FlipsideLedgerDB`, addon `Flipside_Ledger`, changed 2026-10-15) | Ledger records and daily sums (§5.8) | Large; loads only on demand; can be reset without touching settings |

| Log DB (`FlipsideLogDB`, added 2026-10-17) | The diagnostics log (§7.5) | Small ring buffer; can be cleared in the log window |

A corrupted or oversized scan DB or ledger DB can be wiped from settings without losing configuration. All three carry a schema version with migrations on load. The Main DB holds only the ledger buffer (at most the cap in §5.8), not the ledger.

**Main DB design (decided 2026-10-14)**

- Scopes: account, profile and character. Keys are flat, with Flipside's own scope prefixes.
- A map in the account scope connects each character to a profile. The default profile is named "Default". When a profile is deleted, its characters move to "Default". "Default" cannot be deleted.
- D9: the last full-scan time is stored in the Main DB, account scope, so a Scan DB reset does not reset the cooldown timer.
- Each DB has one integer schema version. Migrations run forward only, in sequence, on a copy of the data. A failed migration keeps the old data and loads read-only. A DB that was written by a newer Flipside version loads read-only with a warning. Unknown keys are kept, never dropped.

### 7.2 Profiles

As in the reference §8.1: per-character profile, reset / rename / duplicate / create, global-operations option, per-realm and per-character ignore on each operation. Keep-stock rules live in the profile. The recipient of a mailing operation is part of the operation and so lives in the profile too.

### 7.3 Account sync

As in the reference §8.2 (pairing, single-writer rows, timestamp versioning, throttled transport), plus:

- Scan DB records are shared and merged per item and day (§3.5).
- A sync status panel: last contact per account, rows behind, and a *Resync now* button.
- Profiles are sent only on request, as in TSM.

### 7.4 Import and export

- One documented, readable, versioned text format for groups, operations, custom sources and keep-stock rules.
- **MVP (feedback decision 2026-10-14):** export and import of groups, with their sub-groups, items, the operations they use and the custom sources those operations use. Keep-stock rules stay Phase 2. Mailing operations are in the MVP export (§5.5). The import rules are in §5.2. D13 still applies: no TSM strings.
- A version header and a human-readable preview before import, with item and operation deselection (reference §9.2). In the MVP the import shows a summary and asks before it changes anything.
- Plain item lists accepted, as in the reference §9.3.
- Ledger CSV export (§5.8).
- Optional external price file in the import slot (D2).

### 7.5 Diagnostics log (added 2026-10-17)

Flipside keeps a log of what it does, so that the user can see what happened and share it.

- Storage: its own SavedVariable `FlipsideLogDB` in both TOC files. The data is in `WTF/Account/<account>/SavedVariables/Flipside.lua` (Forever) or `Flipside_TBC.lua` (TBC Anniversary). The log survives `/reload` and logout.
- Entry: time (whole seconds and milliseconds), level, category and one line of text. The level is `debug`, `info`, `warn` or `error`. A category is a short word: `core`, `scan`, `mail`, `ledger`, `buying`, `selling`, `auction` or `event`.
- Ring buffer: the default cap is 3000 entries (100 to 20000). The oldest entries go first. Debug entries are off by default. The `info`, `warn` and `error` entries are always stored.
- Session marker: each login writes one `info` entry with the addon version, the flavour, the client version, build and interface number, the realm and the character.
- Event trace: off by default. If it is on, the log also holds the events that Flipside listens to, with the first arguments, as `debug` entries of category `event`. The event bus makes these entries. It registers no extra event.
- Errors: if an event handler or a job fails, the log gets an `error` entry with a short stack. Flipside does not replace the global error handler.
- Code: `ns.Log.Write(category, level, text)` and `ns.Log.Writef(category, level, fmt, ...)` never raise an error. If the format fails, the entry holds the raw format text.
- Window: the button "Open log" on the About page and the slash command `/flip log` open it. The list shows time, level (in colour), category and text. The user can set the order (newest or oldest first), the lowest level, one category and a search text. "Copy" opens a box with the shown entries as plain text, selected for Ctrl+C. "Clear" asks for a confirm. Two check boxes set the debug entries and the event trace.

In-game checklist (diagnostics log):
1. Log in. Open the log with `/flip log`. The first entry is the session marker with the correct version, client, realm and character.
2. Click "Open log" on the About page. The same window opens.
3. Do a scan. The log shows "started" and a finished line with the counts.
4. Set the level to "Errors only". Only error entries stay. Type a word in the search box. The list narrows at once.
5. Click "Copy". Press Ctrl+C. Paste the text in a text editor. It has one line for each shown entry.
6. Click "Clear" and accept. The list is empty.
7. Switch "Debug entries" on and do a mailing run. The log shows each mail and each ledger record.
8. Switch "Event trace" on and open the Auction House. The log shows events of category `event`.
9. Use `/reload`. The entries are still there. Check that `FlipsideLogDB` is in the SavedVariables file.


The MVP is done when a player on WoW: Forever can scan, see prices in tooltips, buy and sell by group rules, vendor junk safely and see profit in the ledger. Phases follow the Phase column in the feature list; changing a dropdown there moves a feature.

| Phase | Goal | Features | Done when |
| --- | --- | --- | --- |
| MVP | Scan → price → buy / sell → profit, one realm | Full scan, groups, operations and formulas, tooltips, inventory tracking, buying, selling (dry run and decision log: Buying tab and ledger only), vendoring, mailing (the mailing operation and the mail view, §5.5), ledger, Great Deals, export and import of groups and operations | A week of daily use on one realm with no errors, under 5 s of scan processing on a mid-size realm (Flipside processing time; see §3.2 scan engine design) |
| Phase 2 | Run a multi-character business | Keep stock, banking, crafting and queue, sniper, profiles, import/export of keep-stock rules, dashboard, price history chart, deposit-aware posting, craft profit ranking, presets and undo | A crafter-and-seller pair of alts restocks and sells through one session without manual moves |
| Phase 3 | Multi-account and polish | Account sync (incl. scan data), Task List, destroying, guild scan sharing (guild part built 2026-10-20, §3.5; party and friends later), then Retail | Two accounts on one realm share inventory, ledger and prices |

**Spike 0: full-scan test (build first).** A throwaway addon, *ScanTest*, that answers whether the full scan works on WoW: Forever before the scan engine is built.

- `/scantest` at the Auction House calls `C_AuctionHouse.ReplicateItems` inside `pcall`; report "API not available" if the function is missing.
- Wait up to 60 s for `REPLICATE_ITEM_LIST_UPDATE`; no event = "no response (cooldown or blocked)".
- Read rows with `GetReplicateItemInfo` in slices of 1,000 per frame. Count: rows, unique items, total quantity, rows with a buyout, rows missing item info, and rows whose item stacks above 1 (commodities).
- Measure: time to first event, processing time, and Lua memory before and after.
- Save each run to SavedVariables with date, client build and results; print a summary; store the last attempt time to show the 15-minute cooldown.
- Warn the player before running that a full scan has disconnected clients on busy servers in the past.

**Pass:** the event fires, row count is plausible for a busy market, commodities are included, processing finishes without freezing or disconnecting.

**Spike 0 result** (user's test, 2026-10-14, WoW: Forever client 1.60.1, three runs)

- Result: pass. `C_AuctionHouse.ReplicateItems` exists and `REPLICATE_ITEM_LIST_UPDATE` fires.
- Run 1: result ok; time to first event 11,828 ms; processing 2,420 ms in 73 frames (counting only, slices of 1,000 rows); Lua memory 132,317 KB before and 134,176 KB after (+1,859 KB); 72,968 rows; 3,071 unique items; total quantity 500,441; 72,967 rows with a buyout; 5,534 rows with missing item info; 25,252 rows whose item stacks above 1; 18,039 rows with unknown stack size; 0 empty rows.
- The row index of `GetReplicateItemInfo` starts at 0 (0 empty rows with indexes 0 to n-1).
- Item data is incomplete directly after a scan (5,534 rows without full info, 18,039 rows without a stack size). The scan engine needs an item-load step before it uses names, links or stack sizes. The count of stackable rows is thus a lower limit.
- Stackable items are in the results. It is not proven that "stackable" equals "commodity" on Forever (D15 is supported, not proven).
- Run 2, a few minutes after run 1: no event in 60 s ("no response (cooldown or blocked)"). A cooldown probably exists. Its length (15 minutes) is not proven.
- Run 3: result ok; time to first event 9,059 ms; processing 1,944 ms in 59 frames; Lua memory 114,371 KB before and 116,740 KB after (+2,369 KB); 58,739 rows; 3,010 unique items; total quantity 420,885; 58,738 rows with a buyout; 4,867 rows with missing item info; 20,696 rows whose item stacks above 1; 14,362 rows with unknown stack size; 0 empty rows. The run time is not recorded, so the run does not measure the cooldown length.
- Saved timestamps from the SavedVariables file: run 1 at server time 1791930182 (2026-10-14 00:23:01 local), run 2 at 1791930290 (00:24:49), 108 s after run 1, no response.
- The addon loaded with `## Interface: 16001` and without "Load out of date AddOns". `GetBuildInfo` in the user's client gives interface 16001, client build 70338 and `WOW_PROJECT_ID` 18 (login line: `ScanTest: client 1.60.1, build 70338, interface 16001, project id 18`). The interface number is confirmed.
- The Forever client source (Ketho/wow-ui-source-forever, commit bd2470a, client 1.60.1.70009; the source check used build 70009, which is older than the user's build 70338) has no interface number in its TOC files and states no cooldown for `ReplicateItems`.
- Not yet known: freeze or stutter during the read (the user did not report one), the SavedVariables file content, and a third run after more than 15 minutes.

**Build order inside the MVP**

1. Framework: settings DB with scopes, event bus, coroutine scheduler, item-string normaliser, item info cache.
2. Full scan and the snapshot pipeline, then scan price sources.
3. Formula compiler (tokenise → tree → evaluate), with live preview.
4. Groups and operations UI.
5. Tooltips and inventory tracking. The tooltip price lines are configurable with the same formula language as operations. The player can show min, max and average values.
6. AH tabs in Blizzard's Auction House frame: Buying, then Selling with dry run and decision log. Two new tabs, Selling and Buying (similar to the well-known Auctionator layout, in our own design), work from the player's groups and their operations.
7. Mailbox parsing and the ledger; then Vendoring; then Mailing (the mailing operation and planner first, §5.5; the send run and the mail view after an in-game probe). The ledger design is in §5.8. The work is split into pull requests (decided 2026-10-15):

| PR | Content | Depends on |
| --- | --- | --- |
| PR0 | In-game probe: `PLAYER_MONEY` and context event order, combat log kill event, invoice fields, mail index shift | None |
| PR1 | Ledger store and the `Flipside_Ledger` addon, with the buffer, the cap and the daily sums | None |
| PR2 | Money tracker, with the Auction House purchase and deposit records | PR0, PR1 |
| PR3 | Mail invoices: sales, deposit refunds, expired, mail money, fingerprints | PR0, PR1, PR2 |
| PR4 | Loot: items, money and the mob | PR0, PR1, PR2 |
| PR5 | Vendor and repair | PR0, PR1, PR2 |
| PR6 | Trade and quest | PR0, PR1, PR2 |
| PR7 | Ledger page with the inner tabs (Sales, Purchases, Auctions, Loot, Expenses; "Income by source" removed in PR3) and the filters | PR1; the tabs show the sources of PR2 to PR6 that exist |
| PR8 | CSV export | PR7 |
| PR9 | Decision logs of Buying and Selling saved in the ledger, and shown as the detail of the Auctions rows (dry run rows included) | PR1, PR2, PR7 and the step 6 tabs |

PR3 to PR6 can go in any order after PR2.

**Test strategy:** the formula compiler, market-value algorithm, selling decision rules and keep-stock maths are pure functions, so they get unit tests run outside the game (plain Lua with a mocked API). In-game features get a scripted checklist per release.

## Needs scoping

TSM behaviours this spec doesn't cover yet. Change the status as each one gets specified; "Scoped" means it has its own section above.

| Area | What to specify | TSM reference | Status |
| --- | --- | --- | --- |
| UI and flow | Windows, AH tabs, settings layout, contextual frames | §6 | Partly scoped (2026-10-14: AH tabs, Flipside window, size, entry points; page layouts open; Groups and Operations pages: build step 4) |
| TBC AH tabs | Buying tab and Selling tab in the TBC `AuctionFrame`: done (Buying 2026-10-16; Selling 2026-10-16; TBC multisell posting of several stacks in one click, with the Stack size and Max stacks fields, 2026-10-16, in this pull request; in-game checklists open, see §3 items 7 and 14a) | §3, §6 | Scoped (in-game checks open) |
| Mailing | The mailing operation, the planner and the mail view (§5.5) | §5.4 | Partly scoped (2026-10-17: operation, planner, rules, view and send run built; the view sits in a wider `MailFrame` (wide layout, rules list; a tab layout needs only a new `MailHost.LAYOUTS` entry); item filters (rarity range, many item types) and the built-in All bag items group built 2026-10-17; rules list with Run and Run all (2026-10-18, replaces the group tree) and the compact inbox list (2026-10-18); send mode decided: one confirm, then all mails in sequence, confirmed in game on TBC only; open: the Forever probe (`MailTest` second round) and the in-game checklist on both clients) |
| Auto rules for groups | Rules that add new bag items to groups by name pattern, rarity and item type (§5.2a) | - | Partly scoped (2026-10-17: rules, runner, tab and Apply now built; the name pattern uses Shared/Services/NameRegex.lua; in-game checklist open; open: export of rules, a bank or mail trigger) |
| Destroy window | Free window to disenchant bag items by rules, with ignore and skip (§5.7a) | - | Scoped (2026-10-18; in-game checklist open; open: value before and after the disenchant) |
| Craft profit panel | Panel at the profession window with reagent cost, AH value and profit of the selected recipe (§5.14a) | - | Scoped (2026-10-19; in-game checklist open; open: vendor buy price source, quality tiers, optional reagents) |
| Guild price sharing | Opt-in sharing of scan prices over the guild addon channel; trust rule; throttle (§3.5) | - | Partly scoped (2026-10-20: guild channel built with its own queue, codec, store, read path and /flip sync; the toggle is on the About page; the trust rule is applied as proposed; in-game checklist open; open: party and friends, daily history, the measured throttle limits, the onboarding choice) |
| Onboarding | First-run steps: starter groups, presets, guild-sharing choice (D7), first scan (starter groups moved here, 2026-10-14) | §6.3 | Needs scoping |
| One-click macro and keybinds | Bindable button for post, cancel, buy, craft next | §3, §6.2 | Partly scoped (2026-10-14: no keybinds in v1; every buy is one click, D26) |
| My Auctions view | Own auctions list replacing Blizzard's Auctions tab (Blizzard's Auctions tab stays; decision B) | §3 | Needs scoping |
| Commodities vs items | Separate buy, sell and snipe paths for region commodities and individual listings | §3 | Partly scoped (2026-10-14: buy unit and post size defined in the step 6 decisions; 2026-10-15: stack size, post quantity in units and the vendor skip for a commodity, §5.4 point 27; snipe open) |
| Auction House cut | The real cut rate in Forever for the profit estimate (§5.4 point 18) | §5.4 | Scoped (2026-10-15: the estimate before a sale uses 5%; the ledger uses the real cut from the sale invoice, §5.8) |
| Ledger | Storage, retention, record types, money tracking, loot, mail, page, build step 7 PR split | §5.7 | Scoped (2026-10-15; §5.8; Phase stays MVP). 2026-10-17: item detail for mail sends, vendor sales and buys, repairs and AH buys, with four read-only post-hooks (user decision). 2026-10-18: server and character filter on the TBC Ledger page. 2026-10-18: counterparty (buyer, seller, trade partner) and new money sources: flight path, training, bank slot, stable, barber, talent reset, guild bank. 2026-10-18: edit and revert of one full record from the Ledger page (§5.8; in-game checklist open) |
| Retail crafting details | Quality tiers and optional reagents in item identity and crafting cost | §5.3 | Needs scoping |
| Smaller settings | Forget character (function in step 5, button later), ignore guilds, sale and purchase sounds, chat output, slash commands | §5.11, §8.3 | Needs scoping |
| Performance budgets | Memory, SavedVariables size, login time, tooltip speed (tooltip: 1 ms, decided 2026-10-14), scan processing | §10.3 | Needs scoping |
| Combat lockdown | What is deferred or disabled in combat | §3 | Needs scoping |
| Localisation | String tables, number and money formats, client languages (decimal separator in formulas decided: dot only) | §10.3 | Needs scoping |
| Diagnostics log | In-game log with a window, filters and copy; instrumentation of scan, mailing, ledger, buying and the event bus (§7.5) | - | Scoped (2026-10-17; in-game checklist open; open: log lines for Selling, a title-bar button, the global error handler) |
| Error handling and recovery | Failed posts and buys, disconnects mid-scan, corrupted data | §7.6 | Partly scoped (2026-10-14: a buy is confirmed with the final server price, D26; failures open) |
| Later flavours | Retail differences: AH API, professions, banks, commodities. TBC Anniversary is in scope (D11, D23–D25); its open points are the TBC spike results | §3 | Partly scoped |

## Open questions

- [ ] Check "Flipside" is free on CurseForge, Wago and GitHub, and that /flip doesn't clash with a popular addon.
- [x] Does the full scan work on WoW: Forever, how long does it take, and does it include commodities? Answer: it works; the first event came after 11,828 ms and processing took 2,420 ms. Stackable items are included. Not proven: that "stackable" equals "commodity". See the Spike 0 result in §8.
- [ ] Length of the full-scan cooldown, and whether a failed attempt restarts it. Run 2 got no event; the 15-minute length is not proven.
- [ ] Full-scan size limits on the busiest realms — test for disconnects and processing time.
- [ ] Scan DB size at 60+ days of retention — measure before fixing the storage format.
- [ ] Guild sharing trust rule (§3.5): the user changed the rule on 2026-10-20 to "latest scan time wins, own wins a tie" (it was "received data only fills gaps"). Also built: relay of the newest own and shared records with their original scan times, sharing after `partial` scans, and merge of unsent queued sets per item. Changed 2026-10-21: no cap on the items of a share (lazy cursor in small sets), gap fill per source in the reader, and a resend at login of an unfinished share. Confirm after the in-game checklist.
- [ ] Default thresholds: Great Deals (60% of market, 5 samples, 50g saving — likely too high for Forever's economy) and deposit-aware fallback sale rate (30%).
- [ ] Features possibly forgotten — check against your play: crafting order fulfilment, item-level price buckets for gear, BMAH watch list (Forever has a BMAH). Trade and gold tracking are in the ledger (§5.8).
