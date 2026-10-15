# Flipside spec

Oct 13, 2026 · @Limpan

Flipside is a World of Warcraft economy addon rebuilt from the TSM analysis, with in-game scanning as its only price source. This tab records what we keep, change or add; for how TSM behaves today, see TradeSkillMaster: Analysis & Product Specification.

## Handover to Claude Code

Start with Spike 0 (§8), then follow the MVP build order. Everything below applies to every task.

1. **Clean room.** Build from this spec only. Never copy TSM code, assets, names or string formats. Points marked *(inferred)* in the TSM reference are guesses to verify, not facts.
2. **API source of truth.** Check every Blizzard API against the Forever client's interface code ([Ketho/wow-ui-source-forever](https://github.com/Ketho/wow-ui-source-forever)) and the API pages on [warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/World_of_Warcraft_API). Forever may differ from Retail; when they disagree, the Forever source wins.
3. **Project setup.**
   - Folder layout: `Shared/Core/` (framework), `Shared/Services/`, `Shared/Features/<Name>/`, `Shared/UI/`, `Shared/Libs/`, `Shared/Locales/`, `Tests/`.
   - TOC with the Forever interface number taken from the client source (the source has no interface number; 16001 comes from `GetBuildInfo` in the client), and both SavedVariables (Main DB, Scan DB, §7.1).
   - Lint with luacheck; WoW globals declared in its config.
   - Unit tests with busted and a mocked WoW API, for the pure logic: formula compiler, market-value algorithm, selling decisions, keep-stock maths, deposit-aware maths.
   - Packaging for CurseForge and Wago via a release workflow.
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
| D25 | TBC uses its own SavedVariables names: `FlipsideDB_TBC` and `FlipsideScanDB_TBC`. These are the names in `Flipside.toc` plus `_TBC` | Shared SavedVariables | 2026-10-14 |
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
| Mail lists exportable | Share mailing setups with recipients as placeholders | §5.5 |

## Feature list

Nine features come from your list, twelve are ones TSM users rely on that are easy to forget, and five are new improvements (D10). The MVP is the smallest set that lets a player scan, price, buy, sell and see profit. Change any phase with its dropdown.

| Feature | What it does | Change vs TSM | From | Phase |
| --- | --- | --- | --- | --- |
| Full scan | Captures every AH listing and builds local price history | Replaces AuctionDB downloads (D1) | You | MVP |
| Buying | Search the AH, buy below a max price, restock materials | Same as Shopping; adds "% of market" and data-age columns | You | MVP |
| Selling | Post and cancel by rules with min / max / normal prices | Same as Auctioning; adds dry run and decision log | You | MVP |
| Item groups | Organise items into a tree that rules apply to | Same model; adds starter groups and auto profession groups (later; not in build step 4) | You | MVP |
| Mail lists | Send grouped items to named characters automatically | Same as Mailing operations; adds reusable recipient lists | You | Phase 2 |
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
| Import and export | Share groups and operations as text (MVP); mail lists and keep-stock rules later (Phase 2) | Open, documented format | Added | MVP |
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
- Some rows arrive without item info. Queue those for item-info load and retry them for at most 30 s (see "Forever scan retry"). An item without data after the wait gets no new snapshot and keeps its old data. The other items are stored in full (see the scan engine design in §3.2).
- On very busy realms the call has disconnected clients before (a fix in 9.0.2 removed seller names). Seller names are therefore never available from a full scan; blacklist features must use targeted searches.
- WoW: Forever lists the same full-scan call in Blizzard's API (confirm behaviour in the beta); older Classic clients use the older "get all" query, also on a cooldown; the snapshot pipeline after it is the same.

### 3.2 Snapshot pipeline

1. **Collect** rows into a temporary per-item list of unit buyouts and quantities (bid-only listings skipped).
2. **Reduce** each item to snapshot stats: min buyout, market value (the outlier filter from the reference §4.3), listed quantity, auction count.
3. **Merge** into today's bucket for that item; keep up to 4 snapshots per day (a fifth drops the oldest); the day's record is their average. A targeted search newer than the day's full scan replaces that day's value for the searched item (D5).
4. **Roll up** at the first scan after the server day changes (D4) and also at login: today's bucket becomes one daily record.
5. **Discard** raw listings. Only daily records and today's bucket are saved.

Rows can arrive without full item info, so the pipeline loads item data before it uses names, links or stack sizes (see Spike 0 result in §8).

All steps run as coroutines that yield each frame, with a progress bar. A scan is partial only if the read is incomplete (for example the AH closes during the read); a partial scan updates only the "latest" values (see the scan engine design below).

**Scan engine design (decided 2026-10-14)**

- A `/reload` or logout during a scan discards the run. Nothing of it is saved.
- After the rows are read, the scan retries for at most 30 s (backend value `ScanRefreshSeconds`; see "Forever scan retry"). An item without data after the wait is pending. It gets no write and keeps its old data. It gets a new attempt at the next scan. The other items are stored as a complete scan, and the summary says "complete with N pending".
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
- **Guild sharing (opt-in, off by default, offered during onboarding, D7):** guildmates on the same realm can request missing or newer daily records for specific items over the guild addon channel. Only aggregated daily stats are shared, never raw listings or personal data. Proposed trust rule: received records only fill days you have no data for and never override your own scans.
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
| `SaleRate` | Your own sold ÷ (sold + expired) for the item, from the ledger | `DBRegionSaleRate` (personal, not regional) |

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

### 5.2 Item groups (reference §4.1)

- Same tree model, exclusive membership and item-string granularity.
- **Starter groups** on first run (later; not in build step 4): common materials per profession, and "Junk" and "Vendor trash" groups pre-wired to Vendoring.
- **Auto profession groups** (later; not in build step 4): one click creates *Profession → Crafts* and *Profession → Materials* from the open profession.
- **Smart filters (new)** (later; not in build step 4): a group can be defined by a rule (e.g. "quality = rare and ilvl ≥ 600 and BoE") instead of a fixed item list. Fixed items always win over rule matches.

**Groups and operations design (decided 2026-10-14)**

1. A group stores an item as it was added: the base key for plain items and commodities, and an exact variant key only when a specific link is added. Lookup uses the exact key first, then the base key (D20).
2. Smart (rule-based) groups come later, not in build step 4.
3. Starter groups and auto profession groups come later, with the onboarding work. Build step 4 starts with an empty tree that has only the Base group.
4. Deleting a group asks first. It deletes the group and its sub-groups, and moves their items to the parent of the deleted group.
5. One operation can be attached to many groups. Each group has at most one operation per type. A sub-group uses the operation of its parent for a type, unless it has its own.
6. Operation types in the MVP: selling, buying, vendoring.
7. Custom sources (named formulas) come in build step 4. A loop between custom sources is refused when saved (see the formula language design).
8. Selling defaults: undercut 1c; duration 24 h; post cap 0 (no cap); below minimum: do not post; above maximum: post at maximum; cancel when undercut: on. Price defaults: minimum = the default selling minimum formula (§4); normal = `scanmarket`; maximum = `2 * scanmarket`.
9. Every operation has two safety settings (§3.4): skip an item if its price data is older than 72 h, or if it has fewer than 3 days of data (`ScanSamples`). Both can be changed for each operation. A selling operation also has the setting "Needs scan data" (`needScanData`, default on). If it is off, the two safety checks do not apply, and a missing normal or maximum price does not stop the post (the 2026-10-15 default operation below).
10. Vendoring: never sell to a vendor an item whose `ScanMarket` is more than 2× its vendor price. Such items are listed for review. Buying default: maximum price = `scanmarket`.
11. Group names have 1-40 characters after trimming, and are unique among sibling groups (case-insensitive). A tree has at most 8 levels below the Base group. The Base group cannot be renamed or deleted.
12. Items are added from bags (one button reads all bags), by name search, or by link. Adding from AH search results comes with build step 6.
13. Profiles stay "Default" only in build step 4 (profile switching is Phase 2). Rules live in the profile scope.

**Feedback decisions (2026-10-14)**

1. **Item search by name** (everywhere a name is searched):
   - Enter starts the search.
   - Items that are already in the target group are hidden from the results.
   - The result list stays until the next search.
   - Text in double quotes (`"Linen Cloth"`) matches that exact name only, without case sensitivity.
   - Text without quotes matches each name that contains the text.
2. **Names for items without scan data.** First use the game client's item cache. If the Auction House is open, then search the AH for the name. No item database ships with Flipside.
3. **Group page.** The page has two inner tabs: "Rules" (the operations for each type) and "Items" (add and remove items).
4. **Drag and drop.** The player drags a group into a parent group or out of it (a move). Lists stay sorted by name. No manual order is stored. Operations sort by name.
5. **Keep amount.** Selling and vendoring operations get a "Keep in bags" setting: a number for each item, default 0. That many units of each item stay in the bags. Bank counts are tracked in the MVP (see §5.10), but "Keep in bags" still counts the bags only. Keep-stock rules (D8) have priority over it when they exist.
6. **Export and import of groups** (MVP, see §7.4). The format is a documented, readable, versioned Flipside text format. It holds a group, its sub-groups, their items, and copies of the operations they use. Import shows a summary and asks before it changes anything. It never imports TSM strings (D13). Import rules:
   - The import goes under a parent group that the player picks.
   - If a group name already exists under that parent, the new group gets the suffix " (2)".
   - If an operation has the same type, name and settings, Flipside reuses it. Otherwise it imports a copy named "<name> (imported)".
   - Items that are in another group move to the imported group. The summary shows how many.
   - Custom sources that imported operations use are included. They follow the same rename rule.
8. **Operations page.** Each formula field has an expand button that opens a larger editor. Each preview line has more space below it.

### 5.3 Buying (reference §5.2 Shopping)

- Search by text, filters, group, or "everything in my shopping lists".
- Result columns add **% of ScanMarket** and **data age**.
- Group search uses the Buying operation: max price, and an optional *buy up to keep-stock target* that limits quantity to what Keep stock says is missing.
- Commodity purchases show the quote and total before confirming.

### 5.4 Selling (reference §5.1 Auctioning)

- Same min / max / normal model, below-min and above-max actions, undercut and cancel rules.
- **Dry run:** runs the post and cancel logic without touching the AH and shows the queue with prices and reasons.
- **Decision log:** every item gets one reason code (posting at undercut, at normal, below min, stale price, invalid price, keep-in-bags reached, post cap reached).
- Blacklist of sellers works only from targeted searches (full scans carry no seller names).
- **Keep in bags:** the operation has a number for each item (default 0). Posting leaves that many units of the item in the bags (see the feedback decisions in §5.2).

#### Buying and Selling decisions (step 6, 2026-10-14)

The user decided points 1 to 4. Points 5 to 9 are defaults from the study recommendations. The user can change them.

1. Build order: the Buying tab first, then the Selling tab. Both use the same step 6 stack.
2. Every purchase asks for confirmation in v1 (D26). The confirm shows the final server price, because Forever quotes can rise between the search and the buy. Flipside never buys without a click. One click makes one protected AH call.
3. The default undercut is 1 copper. The operation can override it.
4. Selling has an operation field `stackSize`. The default is a full slot (the maximum stack; the value 0 means this). The client limit caps the value. A commodity posts the whole quantity as one listing.
5. Items below the minimum price are skipped (the `belowMin` default, §5.4).
6. No keybinds in v1.
7. TBC Buying and Selling come later. Step 6 starts on WoW: Forever only.
8. The decision log is a table for the session. Flipside does not save it.
9. The buying plan (`BuyingPlan`) is pure logic. It lists the items of all groups that have a Buying operation, with the maximum price for each item. It shows the buyable rows of live search results, and it stops with a reason: "above max price", "own auction only", "no results" or "no max price". For a commodity, the buy unit is a quantity at a quoted unit price. For an item, the buy unit is one auction. The option `showAboveMax` lets the UI show rows above the maximum, but never buy them.
10. The Forever host can add many Flipside tabs (`ns.AuctionTabs.Register`). The Buying tab shows the shopping list and runs live searches (one item, or all items one at a time). It evaluates the rows and logs each decision. It lists the listings of the selected item grouped by price level (unit price, total quantity, number of listings, own marker). The Stack Price column follows the flavour flag `hasCommodityMarket` (true on Forever, false on TBC and on the other legacy flavours). If the flag is true and the selected item is a commodity, the list has no Stack Price column: the header and the cells are hidden, and the Status column takes the space. In all other cases, Stack Price is the unit price times the quantity of the listing that Buy next buys. On a legacy client every listing is a stack with a stack buyout, so every level shows a Stack Price.
11. Buy next buys the next cheapest price level: the whole quantity at that unit price for a commodity, or the next auction for an item. It needs a ready client, a level that is not yours and a unit price at or under the maximum price. It never buys above the maximum price. Each purchase has two clicks (D26). Click 1 starts a commodity quote (`StartCommoditiesPurchase`) and the confirm box shows the server unit and total price and the quote time left. For an item, click 1 opens the confirm box with the buyout price. Click 2 buys (`ConfirmCommoditiesPurchase`, or `PlaceBid` with the buyout for an item). A quote total above the maximum price times the quantity shows in red, and the button reads "Buy anyway". Cancel, Escape, a closed Auction House or a left tab cancels the quote.
12. Price jump warning: before it buys a level whose unit price is more than the threshold above the previous level bought in this run (or above the first level if none is bought yet), a box says "Price jumps from X to Y (+Z%). Keep buying?" with "Keep buying" and "Stop". The default threshold is 25 percent. The Buying tab edits it, and the profile saves it as `buying.jumpPercent`. "Keep buying" is the click that starts the purchase. "Stop" ends the run.
13. After a success, the tab logs "bought N at X", reads the rows of the item again and moves to the next level. After a failure it logs the reason and reads the rows again. The check box "Dry run" (default off) only logs "would buy N at X". Result events: `COMMODITY_PURCHASE_SUCCEEDED` and `COMMODITY_PURCHASE_FAILED` for a commodity, `AUCTION_HOUSE_PURCHASE_COMPLETED` and `AUCTION_HOUSE_SHOW_ERROR` for an item.
14. The Selling tab (Forever only) lists the contents of the bags as a tree of the player's groups (nested). A final section "[No group]" holds the bag items of no group. Groups with no bag item are hidden. Bound items are hidden. A group row collapses and expands (UI kit Tree). An item row has the icon, the name with the bag count ("Linen Cloth x60") and these columns (see point 19): Your price, Operation, Lowest, Net and Info. Before the live result the row shows the expected price (the normal price of the operation, with a "~") in grey. An item with no selling operation shows "no operation" and Flipside never posts it. After point 17, only an item whose Base group lost the Default operation shows this.
15. Selecting a group row selects the group and its subgroups; selecting an item row selects that item. The selection starts the live searches of its items (queue, ready gating and the rate guard) and `SellingPlan.Decide` fills the decisions. An item that already has a result is not searched again until "Refresh bags".
16. Decision: group selection posts the whole group as a one-click-per-auction queue. "Post" makes one protected post for each click (D26): the next stack of an item, or the one listing of a commodity. The button reads "Post" (or "Confirm post" while a confirm is open), and a progress text next to it reads "Posting 3 of 12". "Skip" leaves the next auction. The total deposit of the queue shows next to the progress text. When the queue is empty the tab says "all posted" and reads the bags again. If the server asks for a confirm (`needsConfirmation`), Flipside shows its own confirm and calls the confirm function on Accept. The "Dry run" box (default off) only logs. The Log button shows the session log. The duration hours 12, 24 and 48 map to the AH index 1, 2 and 3; this mapping is not verified yet.
17. **Default selling operation (user request, 2026-10-15).** Flipside makes one real selling operation named "Default" and attaches it to the Base group. It is made once for each profile, when the profile has no record of it (`defaultSeeded` in the operations data), and only if Base has no selling operation yet. The user can edit, rename or delete it on the Operations page. A deleted Default does not come back, and then an item with no selling operation shows "no operation". Every group and every item of no group uses the operation of the nearest group above it, so Default covers all bag items that have no own selling operation. An item with its own operation keeps it. Settings of Default:
    - Undercut 1 copper. The price is the lowest auction of another seller minus the undercut (the live rows, not scan data).
    - Minimum price `first(vendorsell, 1)`: the vendor sell price as a safety floor when it is known, else 1 copper. This is a default that the user can change. Below the minimum the item is skipped (`belowMin` = skip).
    - Normal price `scanmarket`, used only when no other seller has an auction. If there is no scan value, the item is skipped with "no price".
    - Maximum price `2 * scanmarket`. With no scan value there is no maximum.
    - "Needs scan data" is off: the age and sample checks do not apply, and the item needs no scan record. All other settings keep the schema defaults (duration 24 h, no cap, full stacks).
    - For an operation with "Needs scan data" on (the default for all other operations), a missing normal or maximum price still skips the item. The skip reason names the price and the missing source, for example "no data for min price: scanmarket missing, scan again". Records from a scan before the history fix hold only the latest values, so `scanmarket` stays empty until the next scan stores a snapshot.
18. **Potential profit (user request, 2026-10-15).** For the auctions that are left in the queue:
    - Net = post price x quantity - AH cut - deposit. The deposit is the client quote for each auction (`Deposit`); an unknown quote counts as 0.
    - vs vendor = Net - vendor sell price x quantity. The vendor price is the sell price of the item (`C_Item.GetItemInfo`, return 11, `sellPrice`). If it is unknown or 0, vs vendor shows "-".
    - AH cut = 5% of the sale price, rounded to the nearest copper (`SellingPlan.AH_CUT`). **Unverified:** the Forever client source has no constant or API for the cut (searched 2026-10-15; the sale invoice mail returns the real cut after a sale). The rate is a Needs scoping item. A custom source `ahtax = 0.95` in the user's data uses the same rate.
    - A negative value shows in red. A vs vendor gain shows in green. Each row shows Net; the bottom bar shows the total Net and the total vs vendor of the queue. If one item of the queue has no vendor price, the total vs vendor shows "-".
19. **Selling tab layout (user request, 2026-10-15; own design).** The panel has four parts, from top to bottom (sizes for the 800 x 538 Forever Auction House frame; the panel needs about 780 x 440):
    - Toolbar (24 px): "Refresh bags", "Stop", the status message, the "Dry run (log only)" box and "Log".
    - Details pane (72 px, UI kit Inset) for the next post of the queue. Left: the icon, the item name, the operation name, "Price X each | buyout Y per auction", and "N x S | D h" (auctions left x stack size, duration). Right: "Deposit", "Lowest", "Net" and "vs vendor" of the auctions that are left of this item. When no post is left it shows "Pick a group or an item" or "Nothing to post".
    - Tree (about 12 rows of 22 px) with a column header line (18 px). Item columns, as x from the row start and width: Item (name, icon; up to 190 px), Your price (250, 78, right), Operation (336, 80), Lowest (420, 78, right; "none" when no other seller has an auction), Net (504, 78, right), Info (590, 160). The Info texts are short reasons: "1c under lowest", "no competitor, normal price", "capped at max price", "raised to min price", "below vendor price, skipped" (Default floor) or "below min price, skipped", "no competitor, no market value", "you are already lowest", "no operation", and the reason of a data skip.
    - Bottom bar (34 px): "Post", "Skip", "Posting 3 of 60", the queue deposit, the queue Net and the queue vs vendor. The Log button swaps the tree for the session log.
20. **Default buying operation (user request, 2026-10-15).** Flipside makes one buying operation named "Default" and attaches it to the Base group. The rules are the same as for the selling Default (point 17): once for each profile (defaultBuyingSeeded in the operations data), only if Base has no buying operation, editable, and a deleted one does not come back. A profile that already has the selling Default also gets the buying one the next time it loads.
    - The maximum price of Default is empty. An empty maximum price formula means no limit. The schema accepts an empty buying maxPrice (field flag optional); the schema default for a new buying operation stays scanmarket.
    - With no limit, BuyingPlan marks the entry 
oMax. It does not run a formula. Every row of another seller is buyable. The summary reads "no max price set". The list row shows "no max".
    - Only the price jump warning (point 12) and the confirm click (D26) protect the buyer. The confirm box never shows the red "above your max price" state for such an entry.
21. **Free search in the Buying tab (user request, 2026-10-15).** The item box above the list accepts an item name (the name index, then the Auction House name search when it is open; text in quotes is an exact name), an item ID, an item link (a shift-click puts the link in the box while it has focus) or a Flipside key such as 25320#s-44. Add (or Enter) puts the item in the current search list. With no list selected, Flipside uses the list "Quick search" and makes it if needed. When several items match, a menu lists up to 12 and the pick adds the item. "Search all" searches every item of the list with the same queue as for the groups (ready gating, rate guard, one search at a time). An item uses the buying operation of its group (or of Base); with none, it uses the built-in Default settings (no max price).
22. **Saved search lists (user request, 2026-10-15; own design).** 
s.SearchLists (Shared/Services/SearchLists.lua) saves named lists of items in the profile (key searchLists: one table with ersion, 
extID and lists). They are in the profile, next to the groups and the operations, so that a profile copy or reset keeps them together. A list holds each item once (by key). Names are unique without regard to case, 1 to 40 characters. Object: 
s.SearchLists.New(db, { bus, isAuctionHouseOpen }); 
s.searchLists is the live object. Methods: :List() gives { { id, name, count } } sorted by name; :Get(id) gives { id, name, items = { { itemID, key, name } } }; :Create(name, items) gives the id; :Upsert(name, items) replaces the items of the list with that name or makes it, and gives the id; :Rename(id, name); :Delete(id); :AddItem(id, item); :RemoveItem(id, index). A failed call gives nil and a text. A change emits the bus event Flipside.SearchListsChanged.
23. **Open a search list (contract for other features).** The bus event Flipside.SearchListOpen with (listID, autoSearch) makes the Buying tab select that list. If the Auction House is open and autoSearch is true, the tab starts "Search all". If the Auction House is closed, 
s.searchLists keeps the request (:Requested() gives { id, autoSearch }, :ClearRequested() clears it) and the tab applies it the next time it opens, with the search if autoSearch is true.
24. **Buying tab layout (user request, 2026-10-15).** The left side has two sources: "Groups" (the shopping list of the groups) and "Search lists". The Search lists source shows a list picker with New, Rename and Delete (Delete asks to confirm), a name box for New and Rename, the item box with Add, and the items of the selected list. Each item row has a remove button. The right side (price levels, Buy next, dry run, jump warning, confirm) is the same for both sources. Lists hold items only, no quantities.
25. **Buying item tree (user request, 2026-10-15).** The item list on the left side is a tree. The group nodes (the same groups as in the Selling tab) hold the item nodes. A group node shows only if it holds an item, directly or in a subgroup. An item that is in no group goes under the last node "Not in a group". An item is in one group only. A click on a group node collapses or expands it and does not select it. The rows are 22 pixels high: a small icon, the name and the maximum price. The selected item row keeps the Kit highlight. A click on an item row selects the item and starts its search at once. This is a read, not a buy, so D26 does not change. If a search runs, the tab holds the new search and starts it when the first search ends. It starts the held search only if the item is still selected. The tab makes no search if live search is not available. The tab has no "Refresh", "Search" or "Search all" button. The tab builds the list again each time it opens or when the source or the search list changes. "Search all" still runs for a search list that another feature opens with autoSearch (point 23). "Stop" shows while such a run is active. The source buttons are on the top row, and the lists and the price levels use the free space.

### 5.5 Mail lists (reference §5.4 Mailing)

- A **mail list** is a named rule set: "send group X to character Y, keep N, send up to M".
- Recipients can be saved once and reused across lists (alt names, Name-Realm).
- One button sends everything due at this mailbox; a summary shows what will be sent before sending.
- Inbox: open all, open by type, with a running gold total; opening feeds the ledger.
- Unlike TSM, mail lists *can* be exported, with recipient names stripped and replaced by placeholders.

### 5.6 Keep stock (new, unifies reference restock settings)

Keep stock is one rule type that says *how many of an item should be where*. Other features read it instead of each having their own restock fields.

| Field | Meaning |
| --- | --- |
| Target | Units to hold (number or formula) |
| Where | Character, and location: bags, bank, warband bank, reagent bag |
| Counts | Which locations count toward the target (e.g. bags + bank) |
| Sources | Where to refill from, in order: own bank, alts by mail, AH buy, craft |
| Excess | What to do above target: leave, move to bank, mail to seller, post |

How features use it: Banking moves to and from the bank; Mail lists send shortfalls from alts; Buying limits group purchases to the shortfall; Crafting restock queues the shortfall; Selling never posts below the keep amount.

**Precedence (D8).** Keep stock beats every outgoing rule — selling, mail lists, vendoring and excess moves. Example: a selling rule says "sell all Runecloth" and a keep-stock rule says "keep 2 stacks of Runecloth". Selling posts everything above 2 stacks and logs "kept for stock: 2 stacks" in the decision log. Going below the target needs an explicit **Override stock** button, which applies to that one run only and is recorded in the decision log.

### 5.7 Vendoring (reference §5.5)

- Sell junk and groups marked for vendor; buy vendor reagents up to Keep stock targets.
- **Safety:** never auto-vendor an item whose `ScanMarket` or `Destroy` value (MVP: ScanMarket only; Destroy from Phase 3) is more than a set multiple of its vendor price (default 2×); such items are listed for review instead.
- Buyback tab with one-click undo of the last sale batch.
- **Keep in bags:** the operation has a number for each item (default 0). Vendoring leaves that many units of the item in the bags (see the feedback decisions in §5.2).

### 5.8 Ledger (reference §5.7)

- Same record types and views (sales, purchases, other income and expenses, expired, cancelled, resale).
- **CSV export** of any view, in a documented column format.
- `SaleRate` per item from your own sold and expired counts (§4).
- Retention: full records for 180 days, then daily summaries per item (configurable).

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
4. **Characters.** All characters of the account, on every realm.
5. **Tooltip settings.** The tooltip lines are set on a new "Tooltip" tab in the Flipside window. They are stored in the profile.
6. **Stack total.** Shown while Alt is held. Shift is Blizzard's compare key. Each entry has an `altStack` flag (changed 2026-10-14), default on, set with the check box "Hold Alt for stack value" in the Tooltip tab. An entry with the flag off shows the per-item value while Alt is held. If the price table has the flag off, its title has no "stack of N". A stored line without the flag gets the default on.
7. **Data line.** Superseded by point 15. A custom formula line shows "Label 12g 40s", and can add " · 3 h old" and " · 9/14 days" when its age and days settings are on. The days are the days with data in the 14-day window (`ScanSamples`).
8. **Money (changed 2026-10-14).** Every non-zero unit shows: "12g 40s 7c", "3s 25c", "1g 5c". A zero unit does not show. Zero is "0c". A negative value has a minus sign: "-3s 25c". Values round half up to whole copper, and Flipside never shortens a value to one unit. Gold has thousands separators ("1,234g"). Chat, the AH tab, the Formula page and the Operations page use the same formatter.
9. **Default lines.** The price table (point 15), group path, selling operation, and counts per character. The formula lines Market, Min and Max are no longer defaults.
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

On Retail the deposit is returned on sale and lost on expiry; the AH keeps a 5% cut of the sale.

- Before posting, estimate expected value per auction: `P(sale) × (price × 0.95) − (1 − P(sale)) × deposit`.
- `P(sale)` = your `SaleRate` for the item; if fewer than 5 past auctions, use a setting (default 30%) and say so in the decision log.
- Deposit comes from Blizzard's deposit calculators for items and commodities.
- If expected value is below a threshold (default 0), the item is skipped with reason "deposit risk" and the numbers shown. A per-operation toggle turns the check off.

### 5.14 Craft profit ranking (new)

- After each full scan, recompute `Crafting` cost and crafted value for every recipe known by any of your characters.
- Ranked list: recipe, crafter, cost, value, profit, profit %, and data age of the least fresh input.
- Recipes with stale or thin data (min-samples rule) drop to the bottom, flagged.
- *Queue* adds the craft to the crafting queue up to the Keep stock target, or a quantity you type.

### 5.15 Presets and undo (new)

- **Presets:** ready-made operations to start from, e.g. "Safe seller" (never below 80% of market), "Fast undercut", "Material buyer" (max 90% of market, buy up to stock) and "Flipper" (buy below 60%, sell at market). Presets are copied, never linked, so editing one doesn't change others.
- **Undo:** every change to groups, operations, keep-stock rules and mail lists is recorded per profile. Undo and redo the last 50 changes, plus *Restore snapshot* for a full profile state saved daily (last 7 kept).

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
The Forever backend gives `ScanRefreshSeconds()` (30 s). The engine uses the refresh loop of the TBC modes for each Forever scan:

1. In each poll (once each second) the engine resets the failed item loads and asks again for the items that are still pending (a row has no link, or `hasAllInfo` is not true). It also asks for the items with an unknown commodity status. It then reads the rows of these items again by index. The replicate list stays valid after the scan.
2. A load that ends "failed" gets a new request in the next poll.
3. Key rule after the window: an item without a link is stored under the base key if the client says it is a commodity (or, without that answer, the maximum stack size is more than 1). Other items stay pending, for example gear without a link. A commodity item needs no retry.
4. A pending item gets no write and keeps its old data. All keyed items get a normal snapshot (today and latest), also if other items stay pending (see §3.2 rule 9).
5. The Forever diagnostics line shows `pending N, failed F (load failed), nilLink L, notAllInfo A, retried R, refresh S s`. `nilLink` and `notAllInfo` count the pending items by reason. `retried` counts the items that got a request in poll 2 or later. The scan DB `diag` table keeps the last 5 runs.
6. The summary says "complete with N pending" if the read was complete and N items stay pending. It says "partial" only if the read was incomplete.

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
- The kit lives in `Shared/UI/Kit/` and has no reference to Flipside code or names, so other addons can reuse it (D19).

### UI layout (decided 2026-10-14)

- Every Auction House feature is embedded in Blizzard's Auction House frame (`AuctionHouseFrame`). Flipside adds its own tabs to it when needed. There is no replacement frame.
- A separate Flipside window, like the reference main window, holds groups, operations, settings and the formula preview.
- The Flipside window has a fixed size of 800 x 540, the same as the AH frame.
- The AH frame gets one tab, "Flipside". It has the full scan button, the cooldown, the scan status and the item price lookup.
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
- The window can open in combat (plain show, no protected actions). Escape closes it.
- One untinted theme table.
- The chat commands stay for now: `/flip scan`, `scan stop`, `scan reset`, `price`, `formula` and `version`.
- First UI stack: the UI kit (`Shared/UI/Kit/`), the Flipside window with a formula preview page, and the Flipside AH tab. The groups and operations UI come with build step 4.

## Storage, profiles, sync and import/export

The reference model (§7–9) is kept: one account-wide SavedVariable, flat scope-prefixed keys, profiles for rules and per-character data for holdings. The changes are a second SavedVariable for scan data and open formats.

### 7.1 SavedVariables split

| File | Holds | Why separate |
| --- | --- | --- |
| Main DB | Settings, profiles, groups, operations, keep-stock rules, inventory, ledger | Small; changes every session |
| Scan DB | Daily price history per region and ruleset (§3.3) | Large; can be reset or shared without touching settings |

A corrupted or oversized scan DB can be wiped from settings without losing configuration. Both carry a schema version with migrations on load.

**Main DB design (decided 2026-10-14)**

- Scopes: account, profile and character. Keys are flat, with Flipside's own scope prefixes.
- A map in the account scope connects each character to a profile. The default profile is named "Default". When a profile is deleted, its characters move to "Default". "Default" cannot be deleted.
- D9: the last full-scan time is stored in the Main DB, account scope, so a Scan DB reset does not reset the cooldown timer.
- Each DB has one integer schema version. Migrations run forward only, in sequence, on a copy of the data. A failed migration keeps the old data and loads read-only. A DB that was written by a newer Flipside version loads read-only with a warning. Unknown keys are kept, never dropped.

### 7.2 Profiles

As in the reference §8.1: per-character profile, reset / rename / duplicate / create, global-operations option, per-realm and per-character ignore on each operation. Keep-stock rules and mail lists live in the profile; recipient names are kept separately per account so a shared profile works on every account.

### 7.3 Account sync

As in the reference §8.2 (pairing, single-writer rows, timestamp versioning, throttled transport), plus:

- Scan DB records are shared and merged per item and day (§3.5).
- A sync status panel: last contact per account, rows behind, and a *Resync now* button.
- Profiles are sent only on request, as in TSM.

### 7.4 Import and export

- One documented, readable, versioned text format for groups, operations, custom sources, keep-stock rules and mail lists (recipients replaced by placeholders).
- **MVP (feedback decision 2026-10-14):** export and import of groups, with their sub-groups, items, the operations they use and the custom sources those operations use. Keep-stock rules and mail lists stay Phase 2. The import rules are in §5.2. D13 still applies: no TSM strings.
- A version header and a human-readable preview before import, with item and operation deselection (reference §9.2). In the MVP the import shows a summary and asks before it changes anything.
- Plain item lists accepted, as in the reference §9.3.
- Ledger CSV export (§5.8).
- Optional external price file in the import slot (D2).

## MVP scope and phases

The MVP is done when a player on WoW: Forever can scan, see prices in tooltips, buy and sell by group rules, vendor junk safely and see profit in the ledger. Phases follow the Phase column in the feature list; changing a dropdown there moves a feature.

| Phase | Goal | Features | Done when |
| --- | --- | --- | --- |
| MVP | Scan → price → buy / sell → profit, one realm | Full scan, groups, operations and formulas, tooltips, inventory tracking, buying, selling with dry run and decision log, vendoring, ledger, Great Deals, export and import of groups and operations | A week of daily use on one realm with no errors, under 5 s of scan processing on a mid-size realm (Flipside processing time; see §3.2 scan engine design) |
| Phase 2 | Run a multi-character business | Mail lists, keep stock, banking, crafting and queue, sniper, profiles, import/export of mail lists and keep-stock rules, dashboard, price history chart, deposit-aware posting, craft profit ranking, presets and undo | A crafter-and-seller pair of alts restocks and sells through one session without manual moves |
| Phase 3 | Multi-account and polish | Account sync (incl. scan data), Task List, destroying, guild scan sharing, then Retail | Two accounts on one realm share inventory, ledger and prices |

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
7. Mailbox parsing and the ledger; then Vendoring.

**Test strategy:** the formula compiler, market-value algorithm, selling decision rules and keep-stock maths are pure functions, so they get unit tests run outside the game (plain Lua with a mocked API). In-game features get a scripted checklist per release.

## Needs scoping

TSM behaviours this spec doesn't cover yet. Change the status as each one gets specified; "Scoped" means it has its own section above.

| Area | What to specify | TSM reference | Status |
| --- | --- | --- | --- |
| UI and flow | Windows, AH tabs, settings layout, contextual frames | §6 | Partly scoped (2026-10-14: AH tabs, Flipside window, size, entry points; page layouts open; Groups and Operations pages: build step 4) |
| Onboarding | First-run steps: starter groups, presets, guild-sharing choice (D7), first scan (starter groups moved here, 2026-10-14) | §6.3 | Needs scoping |
| One-click macro and keybinds | Bindable button for post, cancel, buy, craft next | §3, §6.2 | Partly scoped (2026-10-14: no keybinds in v1; every buy is one click, D26) |
| My Auctions view | Own auctions list replacing Blizzard's Auctions tab (Blizzard's Auctions tab stays; decision B) | §3 | Needs scoping |
| Commodities vs items | Separate buy, sell and snipe paths for region commodities and individual listings | §3 | Partly scoped (2026-10-14: buy unit and post size defined in the step 6 decisions; snipe open) |
| Auction House cut | The real cut rate in Forever for the profit estimate (§5.4 point 18); today 5% is a constant that no client source confirms | §5.4 | Needs scoping (2026-10-15: 5% used, unverified) |
| Retail crafting details | Quality tiers and optional reagents in item identity and crafting cost | §5.3 | Needs scoping |
| Smaller settings | Forget character (function in step 5, button later), ignore guilds, sale and purchase sounds, chat output, slash commands | §5.11, §8.3 | Needs scoping |
| Performance budgets | Memory, SavedVariables size, login time, tooltip speed (tooltip: 1 ms, decided 2026-10-14), scan processing | §10.3 | Needs scoping |
| Combat lockdown | What is deferred or disabled in combat | §3 | Needs scoping |
| Localisation | String tables, number and money formats, client languages (decimal separator in formulas decided: dot only) | §10.3 | Needs scoping |
| Error handling and recovery | Failed posts and buys, disconnects mid-scan, corrupted data | §7.6 | Partly scoped (2026-10-14: a buy is confirmed with the final server price, D26; failures open) |
| Later flavours | Retail differences: AH API, professions, banks, commodities. TBC Anniversary is in scope (D11, D23–D25); its open points are the TBC spike results | §3 | Partly scoped |

## Open questions

- [ ] Check "Flipside" is free on CurseForge, Wago and GitHub, and that /flip doesn't clash with a popular addon.
- [x] Does the full scan work on WoW: Forever, how long does it take, and does it include commodities? Answer: it works; the first event came after 11,828 ms and processing took 2,420 ms. Stackable items are included. Not proven: that "stackable" equals "commodity". See the Spike 0 result in §8.
- [ ] Length of the full-scan cooldown, and whether a failed attempt restarts it. Run 2 got no event; the 15-minute length is not proven.
- [ ] Full-scan size limits on the busiest realms — test for disconnects and processing time.
- [ ] Scan DB size at 60+ days of retention — measure before fixing the storage format.
- [ ] Guild sharing trust rule (§3.5): confirm "received data only fills gaps, never overrides your own scans".
- [ ] Default thresholds: Great Deals (60% of market, 5 samples, 50g saving — likely too high for Forever's economy) and deposit-aware fallback sale rate (30%).
- [ ] Features possibly forgotten — check against your play: crafting order fulfilment, trade-window tracking, item-level price buckets for gear, BMAH watch list (Forever has a BMAH), gold tracking per character.
