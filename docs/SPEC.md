# Flipside spec

Oct 13, 2026 · @Limpan

Flipside is a World of Warcraft economy addon rebuilt from the TSM analysis, with in-game scanning as its only price source. This tab records what we keep, change or add; for how TSM behaves today, see TradeSkillMaster: Analysis & Product Specification.

## Handover to Claude Code

Start with Spike 0 (§8), then follow the MVP build order. Everything below applies to every task.

1. **Clean room.** Build from this spec only. Never copy TSM code, assets, names or string formats. Points marked *(inferred)* in the TSM reference are guesses to verify, not facts.
2. **API source of truth.** Check every Blizzard API against the Forever client's interface code ([Ketho/wow-ui-source-forever](https://github.com/Ketho/wow-ui-source-forever)) and the API pages on [warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/World_of_Warcraft_API). Forever may differ from Retail; when they disagree, the Forever source wins.
3. **Project setup.**
   - Folder layout: `Core/` (framework), `Services/`, `Features/<Name>/`, `UI/`, `Libs/`, `Locales/`, `Tests/`.
   - TOC with the Forever interface number taken from the client source (the source has no interface number; 16001 comes from `GetBuildInfo` in the client), and both SavedVariables (Main DB, Scan DB, §7.1).
   - Lint with luacheck; WoW globals declared in its config.
   - Unit tests with busted and a mocked WoW API, for the pure logic: formula compiler, market-value algorithm, selling decisions, keep-stock maths, deposit-aware maths.
   - Packaging for CurseForge and Wago via a release workflow.
4. **Libraries.** Decide in the first task whether to use common libraries (e.g. Ace3, LibSerialize, LibDeflate) or write our own; check each licence is compatible with MIT (D12) and list them in the README. The decision is made: see D18.
5. **Repo CLAUDE.md** containing: the link to this spec; the build order; "Decisions D1–D22 are binding — ask before changing one"; "When something gets scoped, update the Needs scoping table"; the definition of done below.
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
| D11 | Launch on WoW: Forever; later TBC Anniversary, then Retail | Retail-first | 2026-10-13 |
| D12 | Licence: MIT | Proprietary | 2026-10-13 |
| D13 | No import of TSM group strings | — | 2026-10-13 |
| D14 | Guild sharing ships, behind an on/off toggle | — | 2026-10-13 |
| D15 | WoW: Forever has one region-wide market per ruleset (mega-server), with stackables traded as commodities; all price data is keyed by region and ruleset | Per-realm AuctionDB data | 2026-10-13 |
| D16 | The addon is called Flipside; slash commands /flipside and /flip | — | 2026-10-13 |
| D17 | Visual style: WoW: Forever classic look in bronze and copper; Blizzard textures referenced by path, never shipped; Flipside's own art drawn at 2–4× resolution | TSM's flat dark theme | 2026-10-13 |
| D18 | No Ace3. Flipside writes its own framework (settings DB, event bus, coroutine scheduler, slash commands) and its own UI kit. No third-party library ships in the MVP. The use of AceComm with ChatThrottleLib for guild sharing is decided again at Phase 3 | — | 2026-10-14 |
| D19 | The UI kit is reusable for other addons: style only (theme table, frames, buttons, tabs, lists), with no Flipside logic and no reference to Flipside code or names. It lives in `UI/Kit/` in this repository and can be extracted to a library later | — | 2026-10-14 |
| D20 | Item identity: the item key is built from item link fields: item id, suffix id and bonus ids. Enchants, gems, unique id, link level and specialization are not part of the key. Commodities (stackable items) use the item id only. Granularity (base item or exact variant) is chosen when a group or price source matches, not when data is stored. Keys never contain localised names. Flipside uses its own text form for keys, not TSM's | — | 2026-10-14 |
| D21 | Battle pets are out of the MVP | — | 2026-10-14 |
| D22 | Scan data is keyed by region and ruleset (refines D15). The region comes from the client. Each stored record also has a ruleset field that has one fixed value in the MVP; real rulesets (for example hardcore or self-found) can come later without a rewrite of stored data | — | 2026-10-14 |

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
| Rule-based (smart) groups | Groups that fill themselves by item properties | §5.2 |
| Starter groups and presets | Useful on the first day, not after a week of setup | §5.2, §5.15 |
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
| Item groups | Organise items into a tree that rules apply to | Same model; adds starter groups and auto profession groups | You | MVP |
| Mail lists | Send grouped items to named characters automatically | Same as Mailing operations; adds reusable recipient lists | You | Phase 2 |
| Keep stock | Hold target quantities per character and location | Unifies TSM restock settings from Mailing, Banking and Shopping | You | Phase 2 |
| Vendoring | Sell junk and low-value items, buy vendor reagents | Same as Vendoring; adds "never vendor above X" safety | You | MVP |
| Ledger | Record sales, purchases, fees and failures; show profit | Same as Accounting; adds documented CSV export | You | MVP |
| Sniper | Repeat searches to catch underpriced new listings | Same as Sniper; uses local scan prices for thresholds | You | Phase 2 |
| Operations and price formulas | Reusable rules with a formula language | Same language; new local price sources; live formula preview | Added | MVP |
| Tooltips | Prices, counts and history on every item | Adds data age and scan count to price lines | Added | MVP |
| Inventory tracking | Counts per character, bank, mail, AH, guild | Same | Added | MVP |
| Decision log and dry run | Shows why each item was posted, skipped or cancelled | New | Added | MVP |
| Crafting and queue | Profit per recipe, restock queue, craft next | Same | Added | Phase 2 |
| Banking | Move groups between bags, bank and warband bank | Folded into Keep stock rules | Added | Phase 2 |
| Profiles | Swap rule sets per character | Same | Added | Phase 2 |
| Import and export | Share groups and operations as strings | Open, documented format | Added | Phase 2 |
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
| Passive capture | Any search done by Buying, Selling or Sniper | Full depth for searched items | None extra | Keeps watched items fresh between full scans |

Full-scan facts that shape the design ([Warcraft Wiki](https://warcraft.wiki.gg/wiki/API:C_AuctionHouse.ReplicateItems)):

- The cooldown is per account, not per character. Store the time of the last scan call account-wide in SavedVariables, and show the shared countdown on every character (D9).
- Results are read by index, and the client handles about 2,000 item-info events per frame. The reader must process in slices of roughly 1,000–2,000 rows per frame.
- Some rows arrive without item info. Queue those for item-info load and wait at most 30 s for them. Items without data after 30 s are left out and the snapshot is marked partial (see the scan engine design in §3.2).
- On very busy realms the call has disconnected clients before (a fix in 9.0.2 removed seller names). Seller names are therefore never available from a full scan; blacklist features must use targeted searches.
- WoW: Forever lists the same full-scan call in Blizzard's API (confirm behaviour in the beta); older Classic clients use the older "get all" query, also on a cooldown; the snapshot pipeline after it is the same.

### 3.2 Snapshot pipeline

1. **Collect** rows into a temporary per-item list of unit buyouts and quantities (bid-only listings skipped).
2. **Reduce** each item to snapshot stats: min buyout, market value (the outlier filter from the reference §4.3), listed quantity, auction count.
3. **Merge** into today's bucket for that item; keep up to 4 snapshots per day (a fifth drops the oldest); the day's record is their average. A targeted search newer than the day's full scan replaces that day's value for the searched item (D5).
4. **Roll up** at the first scan after the server day changes (D4) and also at login: today's bucket becomes one daily record.
5. **Discard** raw listings. Only daily records and today's bucket are saved.

Rows can arrive without full item info, so the pipeline loads item data before it uses names, links or stack sizes (see Spike 0 result in §8).

All steps run as coroutines that yield each frame, with a progress bar. A scan interrupted by closing the AH is marked partial; its data updates only the "latest" values (see the scan engine design below).

**Scan engine design (decided 2026-10-14)**

- A `/reload` or logout during a scan discards the run. Nothing of it is saved.
- After the rows are read, the scan waits at most 30 s for item data. Items without data after 30 s are left out of the snapshot, which is marked partial. They get a new attempt at the next scan.
1. **Stored format.** One record per item per region and ruleset, stored as one delimited string per item (§3.3). Gear and other non-stackable items use the D20 exact key. Commodities use the base key. Money is whole copper. Days are integer day numbers.
2. **Market value.** The "lowest 30%" and "first 15%" rules count auctions, not units. Outliers are removed with the population standard deviation. The market value is the plain (unweighted) average of the remaining unit prices, rounded half up to whole copper.
3. **Price day (D4).** A day starts at 00:00 UTC by the server clock (`GetServerTime`). Day number = floor(server time / 86,400).
4. **Region and ruleset.** Region is the client's region text (`GetCurrentRegionName`, for example "EU"). Ruleset is the fixed value "standard" in the MVP. The client's standard-mode flag (`C_GameRules.IsStandard`) is stored next to it as information.
5. **Commodity detection.** After the item loads, ask the client (`C_AuctionHouse.GetItemKeyInfo`, field `isCommodity`). If the client gives no answer, use "maximum stack size above 1". Cases where both answers exist and disagree are counted and reported, so they can be checked in game.
6. **Cooldown.** The 15-minute timer starts when the scan is called, not when data arrives. Flipside refuses a new full scan before the timer ends and shows the time left. The 15 minutes stays an assumption until measured (open question).
7. **Start before the AH frame exists.** `/flip scan` (or `/flipside scan`) at the open Auction House shows a warning popup. Accept starts the scan.
8. **Snapshots and roll-up.** Keep up to 4 snapshots per day; a fifth drops the oldest. The day's record is the average of the day's snapshots. Roll-up into history happens at the first scan of a new day and also at login.
9. **Partial scans** (AH closed during the read, or items not loaded within 30 s). The data updates the item's "latest" values. It does not enter the day's snapshots or the history. Only a complete scan does that. A complete scan replaces the "latest" values.
10. **Processing-time target.** "Under 5 s of scan processing" means Flipside's own processing time (CPU time of scan work). It excludes the server delay before the first event and the item-load wait. It is measured on the largest Forever run (about 73,000 rows).
### 3.3 History storage

- Per item, region and ruleset (D15, D22): every daily record (min, market, quantity, scans) for at least 60 days by default; retention is a setting with 60 days as the minimum (D6). Market value still weights the last 14 days.
- Records are packed as numbers in a delimited string per item to keep SavedVariables small; decoded on demand.
- On WoW: Forever the whole market is region-wide per ruleset (D15), so every item's history is stored once, keyed by region and ruleset. When Retail is added, commodities stay region-wide and other items are stored per connected realm.
- Items with no listings within the retention period are pruned.

### 3.4 Freshness and confidence

- Every price carries **age** (hours since last seen) and **samples** (days with data in the window).
- Tooltips show both, e.g. "Market 12g 40s · 3 h old · 9/14 days".
- Operations get two safety settings: *max data age* and *min samples*. If either fails, the item is skipped with the reason "stale price" in the decision log.
- The Dashboard shows when the last full scan ran and when the next is available.

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

**Staleness is part of the language.** Because `ScanAge` and `ScanSamples` are ordinary value sources, a rule like `ifgt(scanage, 72, 0, scanmarket)` (treat prices older than 3 days as invalid) needs no new syntax.

## Feature specs

Each feature lists only what differs from, or is unspecified in, the TSM reference. Where nothing is said, behave as the reference section named.

### 5.1 Full scan

A *Full Scan* button sits in the AH frame header with a cooldown countdown (§3.1). When the AH opens and the cooldown is clear, an optional setting starts the scan automatically. Result summary after each scan: items seen, new items, prices changed by more than 30%, and duration.

### 5.2 Item groups (reference §4.1)

- Same tree model, exclusive membership and item-string granularity.
- **Starter groups** on first run: common materials per profession, and "Junk" and "Vendor trash" groups pre-wired to Vendoring.
- **Auto profession groups:** one click creates *Profession → Crafts* and *Profession → Materials* from the open profession.
- **Smart filters (new):** a group can be defined by a rule (e.g. "quality = rare and ilvl ≥ 600 and BoE") instead of a fixed item list. Fixed items always win over rule matches.

### 5.3 Buying (reference §5.2 Shopping)

- Search by text, filters, group, or "everything in my shopping lists".
- Result columns add **% of ScanMarket** and **data age**.
- Group search uses the Buying operation: max price, and an optional *buy up to keep-stock target* that limits quantity to what Keep stock says is missing.
- Commodity purchases show the quote and total before confirming.

### 5.4 Selling (reference §5.1 Auctioning)

- Same min / max / normal model, below-min and above-max actions, undercut and cancel rules.
- **Dry run:** runs the post and cancel logic without touching the AH and shows the queue with prices and reasons.
- **Decision log:** every item gets one reason code (posting at undercut, at normal, below min, stale price, keep-in-bags reached, post cap reached).
- Blacklist of sellers works only from targeted searches (full scans carry no seller names).

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
- **Safety:** never auto-vendor an item whose `ScanMarket` or `Destroy` value is more than a set multiple of its vendor price (default 2×); such items are listed for review instead.
- Buyback tab with one-click undo of the last sale batch.

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

Operations and formulas (§4.2–4.3), tooltips and inventory tracking (§5.11), crafting and queue (§5.3), dashboard (§5.8), destroying (§5.9) and the Task List (§5.10) behave as in the reference, using scan sources in place of AuctionDB.

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

## Architecture

The whole "outside the game" layer from the reference (§2) is gone: no servers, no desktop app, no AppHelper. Price data enters only through the Auction House API and is stored in its own Scan DB.

&#91;embedded content: In-game-only architecture · 2 layers, 3 addon tiers\]

Features sit on shared services, which sit on the framework; the scan engine is a service, so every feature reads the same prices and freshness data.

## Visual style

Flipside should look like it belongs in WoW: Forever: the classic stone, parchment and gold-trim frames of the original UI, shifted towards bronze and copper and drawn crisply at modern resolutions (D17).

### Using Blizzard's textures

[Gethe/wow-ui-textures](https://github.com/Gethe/wow-ui-textures) is a mirror of the game's UI textures converted to PNG. It is a **catalogue, not an asset source**:

- Use it to browse and preview textures and find their in-game paths.
- In code, reference Blizzard textures by in-game path or atlas name (e.g. `Interface\DialogFrame\UI-DialogBox-Border`). The client already has them, so nothing is redistributed.
- Verify each path exists in the Forever client (its interface source, see Handover) before using it; Forever's art may differ from Retail's.
- **Never ship Blizzard textures, or upscaled or edited copies of them, in the addon.** They are Blizzard's art, the mirror states no licence, and Flipside's MIT licence can't cover them.

### Flipside's own textures

- Original art drawn for Flipside in the classic idiom: bevelled bronze trim, rivets, worn parchment, coin and scale motifs.
- Drawn at 2× or 4× the classic texture size so frames stay sharp at high UI scale; power-of-two dimensions, saved as TGA or BLP.
- Licensed with the code (MIT) or under CC BY 4.0; state which in the README.
- Until custom art exists, tint Blizzard frame textures towards bronze with vertex colouring and desaturation, so the look is right from day one.

### Palette (starting points)

| Token | Hex | Use |
| --- | --- | --- |
| Bronze | `#B0793A` | Frame trim, active tabs, primary buttons |
| Deep bronze | `#6E4A26` | Borders, pressed states, dividers |
| Copper | `#B87333` | Highlights, selection, hover |
| Burnished highlight | `#E3B778` | Headings, focused controls |
| Verdigris | `#4A9C8C` | Accent for profit, deals and good states |
| Parchment | `#E8D9B5` | Light panels, item detail pages |
| Dark stone | `#1C1712` | Window backgrounds |

Gold, silver and copper coin amounts keep the game's own coin colours so money reads instantly. Profit and loss never rely on colour alone (add + / − signs and icons), and text must meet WCAG AA contrast on its background.

### Rules for the UI kit

- Every colour, texture and font comes from one theme table. Ship two themes: **Flipside Bronze** (default) and **Blizzard Classic** (untinted game art).
- Use the game's own fonts (Friz Quadrata via the standard font objects) so text matches the client; ship no font without a compatible licence.
- Borders and edges are pixel-perfect at any UI scale.
- Frames follow the classic layout language: title bar with portrait-style icon, tabs along the bottom edge, close button top-right.
- The kit lives in `UI/Kit/` and has no reference to Flipside code or names, so other addons can reuse it (D19).

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

- One documented string format for groups, operations, custom sources, keep-stock rules and mail lists (recipients replaced by placeholders).
- A version header and a human-readable preview before import, with item and operation deselection (reference §9.2).
- Plain item lists accepted, as in the reference §9.3.
- Ledger CSV export (§5.8).
- Optional external price file in the import slot (D2).

## MVP scope and phases

The MVP is done when a player on WoW: Forever can scan, see prices in tooltips, buy and sell by group rules, vendor junk safely and see profit in the ledger. Phases follow the Phase column in the feature list; changing a dropdown there moves a feature.

| Phase | Goal | Features | Done when |
| --- | --- | --- | --- |
| MVP | Scan → price → buy / sell → profit, one realm | Full scan, groups, operations and formulas, tooltips, inventory tracking, buying, selling with dry run and decision log, vendoring, ledger, Great Deals | A week of daily use on one realm with no errors, under 5 s of scan processing on a mid-size realm (Flipside processing time; see §3.2 scan engine design) |
| Phase 2 | Run a multi-character business | Mail lists, keep stock, banking, crafting and queue, sniper, profiles, import/export, dashboard, price history chart, deposit-aware posting, craft profit ranking, presets and undo | A crafter-and-seller pair of alts restocks and sells through one session without manual moves |
| Phase 3 | Multi-account and polish | Account sync (incl. scan data), Task List, destroying, guild scan sharing, TBC Anniversary, then Retail | Two accounts on one realm share inventory, ledger and prices |

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
5. Tooltips and inventory tracking.
6. AH frame: Buying, then Selling with dry run and decision log.
7. Mailbox parsing and the ledger; then Vendoring.

**Test strategy:** the formula compiler, market-value algorithm, selling decision rules and keep-stock maths are pure functions, so they get unit tests run outside the game (plain Lua with a mocked API). In-game features get a scripted checklist per release.

## Needs scoping

TSM behaviours this spec doesn't cover yet. Change the status as each one gets specified; "Scoped" means it has its own section above.

| Area | What to specify | TSM reference | Status |
| --- | --- | --- | --- |
| UI and flow | Windows, AH tabs, settings layout, contextual frames | §6 | Needs scoping |
| Onboarding | First-run steps: starter groups, presets, guild-sharing choice (D7), first scan | §6.3 | Needs scoping |
| One-click macro and keybinds | Bindable button for post, cancel, buy, craft next | §3, §6.2 | Needs scoping |
| My Auctions view | Own auctions list replacing Blizzard's Auctions tab | §3 | Needs scoping |
| Commodities vs items | Separate buy, sell and snipe paths for region commodities and individual listings | §3 | Needs scoping |
| Retail crafting details | Quality tiers and optional reagents in item identity and crafting cost | §5.3 | Needs scoping |
| Smaller settings | Forget character, ignore guilds, sale and purchase sounds, chat output, slash commands | §5.11, §8.3 | Needs scoping |
| Performance budgets | Memory, SavedVariables size, login time, tooltip speed, scan processing | §10.3 | Needs scoping |
| Combat lockdown | What is deferred or disabled in combat | §3 | Needs scoping |
| Localisation | String tables, number and money formats, client languages | §10.3 | Needs scoping |
| Error handling and recovery | Failed posts and buys, disconnects mid-scan, corrupted data | §7.6 | Needs scoping |
| Later flavours | TBC Anniversary and Retail differences: AH API, professions, banks, commodities | §3 | Needs scoping |

## Open questions

- [ ] Check "Flipside" is free on CurseForge, Wago and GitHub, and that /flip doesn't clash with a popular addon.
- [x] Does the full scan work on WoW: Forever, how long does it take, and does it include commodities? Answer: it works; the first event came after 11,828 ms and processing took 2,420 ms. Stackable items are included. Not proven: that "stackable" equals "commodity". See the Spike 0 result in §8.
- [ ] Length of the full-scan cooldown, and whether a failed attempt restarts it. Run 2 got no event; the 15-minute length is not proven.
- [ ] Full-scan size limits on the busiest realms — test for disconnects and processing time.
- [ ] Scan DB size at 60+ days of retention — measure before fixing the storage format.
- [ ] Guild sharing trust rule (§3.5): confirm "received data only fills gaps, never overrides your own scans".
- [ ] Default thresholds: Great Deals (60% of market, 5 samples, 50g saving — likely too high for Forever's economy) and deposit-aware fallback sale rate (30%).
- [ ] Features possibly forgotten — check against your play: crafting order fulfilment, trade-window tracking, item-level price buckets for gear, BMAH watch list (Forever has a BMAH), gold tracking per character.
