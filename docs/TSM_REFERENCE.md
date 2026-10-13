# TradeSkillMaster: Analysis & Product Specification

Oct 7, 2026 · @Limpan

## Executive summary

TradeSkillMaster (TSM) is a rules-driven economy suite for World of Warcraft: the player sorts items into **groups**, attaches **operations** (parameterised rules written in a price-formula language), and TSM then executes repetitive economic work — posting, cancelling, buying, crafting, mailing, banking, vendoring and destroying — while recording every transaction in a ledger.

It is three cooperating products, not one addon:

- **TradeSkillMaster addon** (Lua, runs in the game client): the UI, rules engine, automation and local database.
- **TSM\_AppHelper addon**: a thin data-carrier addon whose Lua files are rewritten by the desktop app with fresh market data; the game can only read data from disk at load time, so this is the injection channel.
- **TSM Desktop Application + tradeskillmaster.com**: downloads regional and realm price data, keeps addons updated, backs up SavedVariables and uploads ledger data to the web.

The current line is TSM 4.x (v4.14.73 on WoWInterface, updated 24 July 2026 for Retail 12.0.7 and Classic flavours) ([WoWInterface](https://wowinterface.com/downloads/info24165-TradeSkillMaster.html)). TSM4 launched 28 July 2018 and merged the previously separate module addons (Auctioning, Crafting, Mailing, Shopping, etc.) into one core addon plus AppHelper ([TSM blog](https://blog.tradeskillmaster.com/2018/07/)). The vendor's known-issues page, last updated 11 August 2026, targets Retail Midnight patch 12.1 ([Known issues](https://tradeskillmaster.helpjuice.com/en_US/known_issues/known-issues-in-retail-wow)).

**How to read this document.** Sections 2–4 explain the architecture and the two core abstractions everything hangs on (groups/operations and price sources). Section 5 specifies each feature module. Sections 6–9 cover UI flow, storage, profiles and import/export. Statements about internal implementation that are not in TSM's public documentation are marked *(inferred)* — they describe how a faithful re-implementation should behave, based on the observable behaviour and the WoW addon platform's constraints, not TSM's proprietary source.

## Architecture overview

TSM is split across the game client, the disk and TSM's own services because a WoW addon can neither make network calls nor write files while the game runs. Market data therefore travels in as rewritten addon files, and user data travels out only through SavedVariables after logout.

&#91;embedded content: TSM architecture · 3 layers, 9 components\]

The desktop app is the only bridge between TSM's servers and the game; inside the client, every state-changing action passes from the TSM addon through Blizzard's APIs, one click at a time.

### Inside the addon

TSM4 merged the old module addons into one core addon, so its internals are layered rather than split by addon ([TSM4 release](https://blog.tradeskillmaster.com/2018/07/)). The layering below is *inferred* from behaviour and is the recommended structure for a re-implementation.

| Layer | Responsibilities |
| --- | --- |
| Framework | Event bus, cooperative coroutine scheduler (keeps scans from freezing frames), own UI widget toolkit, indexed in-memory database, scoped settings store, logging and error capture |
| Services | Item-string normalisation and item info cache, inventory tracker (bags, banks, mail, AH), price-source registry and custom-string compiler, throttled AH query queue, mail and merchant parsers, sync transport |
| Feature modules | Auctioning, Shopping, Sniper, Crafting, Mailing, Vendoring, Banking, Accounting, Destroying, Tooltips, Task List — each consuming groups and its own operation type |
| UI | Main window (configuration) and contextual frames (execution), all built from the shared widget toolkit |

TSM also exposes a public price API so other addons can evaluate TSM price sources and custom strings for an item; addons such as pet-value and transmog-mailing tools use it to read values like `DBMarket` and `DBRegionMarketAvg` *(observed)*.

## What TSM extends or replaces from Blizzard

TSM does not modify the game; it sits on Blizzard's addon API. Its pattern is consistent: when a Blizzard interaction frame opens (Auction House, profession, mailbox, merchant, bank), TSM shows its own frame in place of — or beside — the default one, with a button to switch back to the Blizzard UI. Every state-changing action is still executed through Blizzard's API and is subject to its restrictions.

| Blizzard surface | TSM behaviour | Underlying API family (Retail) |
| --- | --- | --- |
| Auction House frame | Replaced by TSM AH frame with Browse/Shopping, Auctioning, My Auctions and Sniper tabs; *My Auctions* replaces Blizzard's *Auctions* tab ([TSM4 release](https://blog.tradeskillmaster.com/2018/07/)) | `C_AuctionHouse` search, post, cancel, purchase, owned-auction queries |
| Profession (tradeskill) window | Replaced by TSM Crafting frame with profit columns, queue and material view | `C_TradeSkillUI` recipe info, reagent/quality data, craft |
| Mailbox | TSM Mailing frame: bulk open/collect, group-based sending, quick-send | Inbox and send-mail APIs |
| Merchant (vendor) | TSM Vendoring frame: buy with stack math, sell by group, buyback | Merchant APIs |
| Bank, reagent bank, warband bank, guild bank | TSM Banking frame for warehousing rules | `C_Container`, bank/warband bank APIs |
| Item tooltips | Extra lines appended (prices, inventory counts, destroy values, ledger stats) | Tooltip post-processing hooks |
| Bags | Read-only scanning for inventory tracking and destroy candidates | Container item info + bag update events |
| Disenchant / Mill / Prospect | Destroying window drives the spell on the next eligible item | Secure action buttons (protected spell-on-item cast) |
| Chat addon channel | Account sync and profile transfer between characters | Addon message comms |
| SavedVariables | All persistent state | Per-account `WTF\…\SavedVariables\*.lua` written at logout/reload |

### Platform constraints the design must respect

- **Hardware-event gating.** Posting, buying and cancelling auctions, and crafting, are protected: each call must originate from a real key or mouse press. That is why TSM is "one click per action" — a scan prepares a queue, and each *Post*/*Cancel*/*Buy*/*Craft* button press performs exactly the next item. The TSM macro maps that button to a key or scroll wheel; Blizzard has progressively narrowed what it can drive (for example *Destroy Next* is no longer available in the macro) ([Known issues](https://tradeskillmaster.helpjuice.com/en_US/known_issues/known-issues-in-retail-wow)).
- **Search throttling.** Since patch 8.3 the AH has no pages and no "newest first" sort, and searches are throttled (100 searches per 60 s at launch, with a stricter throttle briefly applied in June 2020 that led TSM to disable Sniper temporarily) ([TSM blog](https://blog.tradeskillmaster.com/auction-house-throttling/)). Every scan engine must be a rate-limited queue that pauses and resumes. Sniper became a loop of repeated searches over a target list rather than "read the last page" ([Wowhead](https://www.wowhead.com/news=312308/wowhead-economy-weekly-wrap-up-122-childrens-week-professions-market-prices)).
- **Commodities vs items.** Retail splits the AH into *commodities* (stackable, region-wide order book, buy-by-quantity, no per-seller cancel targeting) and *items* (individual listings with item level/bonus IDs). Auctioning, Shopping and Sniper logic needs two code paths.
- **Combat lockdown.** Protected frames and secure buttons cannot be created or reconfigured in combat; TSM must defer UI rebuilds until combat ends *(platform rule)*.
- **No network, no file I/O.** An addon cannot fetch data or write files at runtime. Market data therefore arrives only by an external program rewriting addon files before login (see section 2), and data leaves the game only via SavedVariables after logout/reload.
- **Flavour divergence.** Classic flavours retain the older paged AH API, different professions and no warband bank; TSM ships one codebase with per-flavour feature flags (the WoWInterface build lists Retail, Classic and TBC compatibility).

## Core concepts: groups, operations and the price language

Every TSM module is driven by the same three primitives. A re-implementation must get these right first; the feature modules are mostly executors over them.

### 4.1 Groups

A group is a named container of items that should be handled the same way ([Groups docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-groups)).

- **Tree structure.** Groups nest arbitrarily (parent → sub-group). The tree is displayed alphabetically; drag-and-drop re-parents a group, and dropping on the Base Group makes it top-level. Deleting a group deletes its whole subtree.
- **Base Group.** A permanent, undeletable root that implicitly contains every item in the game not explicitly assigned elsewhere. The default Auctioning operation is attached to it, so ungrouped items still have a fallback rule.
- **Item membership is exclusive.** An item lives in exactly one group. Adding it to another group moves it. *Remove* with Shift held moves items up to the parent instead of out of the tree.
- **Item identity granularity.** Items are keyed by a normalised *item string*, not the bare item ID. Users choose whether ungrouped items are matched by exact variant (bonus IDs/stats), by item level only, or by base item — so one group can hold "all 619 ilvl BoEs" while another holds a specific stat roll.
- **Inheritance.** Operations attach to a group and are inherited by sub-groups unless the sub-group overrides that module *(observed behaviour)*.

### 4.2 Operations

An operation is a named, reusable parameter set for exactly one module (Auctioning, Crafting, Mailing, Shopping, Sniper, Vendoring, Warehousing). A group holds an ordered list of operations per module; one operation can be attached to many groups. Every numeric field in an operation accepts a custom string (below), validated against a range — e.g. Auctioning fields accept values that evaluate between 0 and 50,000 ([Auctioning docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1072146-tsm-addon-auctioning-operations)).

Shared management options on every operation type:

- Rename, reset to defaults, duplicate.
- **Ignore on faction-realms** and **ignore on characters** — so one profile can be shared broadly while specific realms or alts skip a rule.
- A Group Management pane listing every group the operation is attached to, with jump-to-group links.

| Module | What its operation decides |
| --- | --- |
| Auctioning | When and at what price to post, cancel and repost |
| Crafting | How many to queue (min/max restock), minimum profit to queue |
| Mailing | Which character receives the group, how many to keep/send |
| Shopping | Max price to buy at, whether to show above-max results |
| Sniper | The "below price" at which a new listing is a snipe |
| Vendoring | Sell to / buy from vendor, keep quantities, value thresholds |
| Warehousing | Bags ↔ bank/warbank movement and restock quantities |

### 4.3 Custom strings (the price language)

Custom strings are a small expression language that evaluates to a copper value (or *invalid*) for a given item. They are what make TSM rules portable across items: one rule like "post at 120% of market, never below 1.5× vendor" works for every item in a group ([Custom Strings](https://tradeskillmaster.helpjuice.com/addon/what-are-custom-strings)).

**Grammar elements**

- **Money literals**: `10g`, `5s`, `12s70c`.
- **Numbers and percentages**: `150% dbmarket` ≡ `1.5 * dbmarket`.
- **Operators**: `+ - * /` with parentheses.
- **Price sources** (item → copper): see table below.
- **Value sources** (item → number, e.g. counts in inventory).
- **Functions**: standard (`min`, `max`, `avg`, `first`, `check`, `round`…) and logic (`ifgt`, `iflt`, `ifeq`…). Invalid arguments are silently skipped by aggregate functions; `check(a, b)` returns *b* only if *a* is valid and > 0.
- **Custom sources**: user-named variables holding a custom string, referenceable from any other string.
- `convert(source)` — values an item via a hard-coded conversion table (e.g. lower-tier reagents).

**Default Auctioning minimum price, as shipped:**

```
check(
  first(crafting, dbmarket, dbregionmarketavg),
  max(0.25 * avg(crafting, dbmarket, dbregionmarketavg), 1.5 * vendorsell)
)
```

It refuses to price an item with no crafting cost or market data, and floors the price at 1.5× vendor sell ([TSM blog, Aug 2023](https://blog.tradeskillmaster.com/2023/08/)).

**Evaluation engine.** Since v4.13 strings are compiled like a small language: tokenise → abstract syntax tree → optimiser (constant folding, `%`→multiply, algebraic merging, de-duplicating source lookups) → generated Lua function that fetches each source at most once and lazily. The token/AST form keeps enough position data to point the user at the exact error location. A re-implementation should cache the compiled function per string and invalidate it when a referenced custom source changes.

**Price sources**

| Source | Provider | Meaning |
| --- | --- | --- |
| `DBMinBuyout` | AuctionDB (realm) | Lowest buyout at last data snapshot (≈ 30 min+ old); invalid if none listed |
| `DBMarket` | AuctionDB (realm) | Outlier-filtered, 14-day weighted average of listing prices |
| `DBRecent` | AuctionDB (realm) | Same filter, latest snapshot only, no time averaging |
| `DBHistorical` | AuctionDB (realm) | 60-day average of `DBMarket` |
| `DBRegionMarketAvg` | AuctionDB (region) | Mean of `DBMarket` across the region's realms |
| `DBRegionHistorical` | AuctionDB (region) | 60-day average of `DBRegionMarketAvg` |
| `DBRegionSaleAvg` | AuctionDB (region) | Average actual sale/purchase price, crowd-sourced from users' Accounting uploads |
| `avgBuy` / `avgSell`, `min*`/`max*` | Accounting | From the user's own ledger |
| `SmartAvgBuy` | Accounting | Average of the last *X* purchases, where *X* = quantity currently owned |
| `Crafting` / `matPrice` | Crafting | Recipe cost = Σ material prices; material price method is configurable |
| `Destroy` | Core | Expected value of mill/prospect/disenchant results |
| `vendorBuy` / `vendorSell` | Core | Vendor prices (`vendorBuy` learnt only after visiting a vendor that sells it) |
| `AuctioningOpMin/Max/Normal`, `ShoppingOpMax`, `SniperOpMax` | Operations | Values from the operation attached to the item's group |

Source: [Price sources](https://support.tradeskillmaster.com/custom-strings/which-price-sources-can-i-use-and-what-do-they-mean). The default `matPrice` is `min(dbmarket, crafting, vendorbuy, convert(dbmarket))` ([Wowhead economy column](https://cn.wowhead.com/news/wowhead-economy-weekly-wrap-up-191-korthite-crystal-market-crash-323878)). Third-party addons also expose their own sources through TSM's public price API.

**DBMarket algorithm** (per item, per snapshot) ([AuctionDB Market Value](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/auctiondb-market-value)):

1. Sort unit buyouts ascending. Consider at most the lowest 30%; after the first 15%, cut at the first jump of ≥ 20% between consecutive auctions.
2. Drop points more than 1.5 standard deviations from the mean of what remains.
3. Average the survivors → the snapshot value.
4. Average all of today's snapshots into a daily value; combine the last 14 days plus today with a steep recency weighting (half-life a little over 2 days).

## Feature specifications

Each module below is specified as: purpose → operation fields → runtime behaviour → outputs. Field names follow the TSM UI; where a module's fields are not in the public docs they are marked *(approximate)*.

### 5.1 Auctioning (post, cancel, scan)

**Purpose:** remove manual decisions about when and at what price to post. The user defines a band (minimum, maximum) and a fallback (normal); TSM undercuts competition inside the band and follows a configured rule outside it ([Auctioning docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1072146-tsm-addon-auctioning-operations)).

**Operation fields**

| Tab | Field | Rule |
| --- | --- | --- |
| Posting | Duration | 12 / 24 / 48 h |
| Posting | Post cap | Max units to have posted; 0 disables posting |
| Posting | Keep in bags | Units never posted |
| Posting | Max expires | Stop posting after N expiries of this item |
| Posting | Bid % of buyout | 0–100%; bid never below minimum |
| Posting | Undercut | Default 0c on Retail (LIFO ordering), 1c on Classic |
| Posting | Minimum / Maximum / Normal price | Custom strings; normal may exceed maximum to "set the market" |
| Posting | Below-minimum action | Don't post · post at min · post at max · post at normal · ignore auctions below min |
| Posting | Above-maximum action | Don't post · post at min · post at max · post at normal |
| Details | Ignore auctions by duration | Skip competitors with short/medium/long time left |
| Details | Blacklisted players | Always undercut these sellers, even below minimum |
| Canceling | Cancel undercut | Cancel when undercut or matched later on Retail |
| Canceling | Cancel to repost higher | Cancel when competition has gone and a higher post price is now valid |
| Canceling | Repost threshold | Minimum price gain required to cancel-and-repost |

**Pricing decision (per item, post scan)**

1. Evaluate min, max, normal for the item. Any invalid → skip with reason "invalid price".
2. Find the lowest competing buyout, excluding own auctions, ignored durations, and (if set) auctions below minimum.
3. No competition → post at normal.
4. Competition below min → apply below-minimum action (blacklisted sellers are undercut regardless).
5. Competition above max → apply above-maximum action.
6. Otherwise → post at lowest − undercut.
7. Quantity = min(post cap − already posted, owned − keep in bags), respecting stack rules per flavour.

**Cancel scan** evaluates each owned auction against the same rules and queues it if undercut or repost-higher applies. Both scans produce a queue; the user presses one button per action (hardware-event constraint). Each row displays the item, the decided price, and a reason code ("undercutting", "posting at normal", "below min, not posting") — the reason log is essential for user trust.

### 5.2 Shopping (Browse) and Sniper

**Shopping** is a search engine over the AH. Inputs: free-text search with filter syntax (item level, required level, quality, class, max quantity, max price, "exact"), a saved/recent search list, a group-based search (scan all items in selected groups using each group's Shopping operation), and premium *Great Deals* searches. Results are grouped per item with a per-unit price, percentage of market value, and a buyout or post action. Buy confirmations are optional.

*Shopping operation fields (approximate):* maximum shopping price (custom string), show items above max price, restock quantity and which inventory sources count toward it.

**Sniper** repeats a search continuously to catch underpriced new listings. On Retail it is effectively a Shopping operation re-run until stopped, with a 30-second delay between searches, and it does not run on the Base Group; on Classic it reads the AH's last page, which holds the newest posts ([Sniper docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-sniper-operations)). Its single key field is the maximum price. Matching results play an alert and are listed for one-click buyout.

### 5.3 Crafting

**Purpose:** decide what is profitable to craft, queue it, source the materials, and craft in bulk.

- **Profession scan.** On opening a profession, TSM reads every known recipe, its reagents (including optional/finishing reagents and quality tiers on Retail), and stores them per character. This is what makes `Crafting` and `matPrice` sources available for items the player can make; `Crafting` is invalid for recipes the user does not know ([Price sources](https://support.tradeskillmaster.com/custom-strings/which-price-sources-can-i-use-and-what-do-they-mean)).
- **Crafts list.** Each recipe row shows craft cost, crafted item value, profit and profit %, number craftable now, and number in queue. Filters by profession, group, profitability.
- **Crafting operation (approximate):** min restock, max restock, minimum profit (custom string), crafted-value source. "Restock queue" adds `max restock − owned` for every craft whose profit clears the minimum.
- **Queue.** Aggregated across characters and professions, shows total cost, expected profit, and the materials shortfall. A **Craft Next** button crafts the next queued recipe the current character can make.
- **Materials tab.** Per-material price method override (default `matPrice` formula is configurable globally).
- **Gathering.** From the queue's shortfall, TSM builds a gather plan: which alts/banks/mail hold each material, what to buy from the AH or vendors, and what to craft as intermediates; this feeds the Task List.

### 5.4 Mailing

Mailing distributes items between alts with rules ([Mailing docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-mailing-operations)). Operation fields: target character (Name-Realm for connected realms), keep amount, max quantity per run, restock-target-to-max, and which of the target's inventory areas count toward restock. Mailing operations do not run on the Base Group and are excluded from group exports.

The Mailing frame has tabs for **Inbox** (open all, open by type — sales, buys, cancels, expires, other — with a running gold total), **Send** (quick send with gold/COD), **Groups** (send every grouped item per its operation), and **Other** (send all disenchantables / excess gold to a named character). Inbox processing is the main input to Accounting: each opened AH mail is parsed into a sale, purchase, cancel or expiry record.

### 5.5 Vendoring

Replaces the merchant frame with tabs for **Buy** (with quantity input that respects stack and price), **Sell** (bag list with vendor value vs. market value, sell-all-junk, sell by group) and **Buyback**. *Vendoring operation (approximate):* enable buying with restock quantity and sources; enable selling with keep quantity, sell-after-N-expires, sell only if market value is below a threshold, and a destroy-value guard so items worth disenchanting are not vendored.

### 5.6 Banking / Warehousing

The Banking frame opens with the bank, reagent bank, warband bank or guild bank, and moves items in bulk by group. *Warehousing operation (approximate):* move quantity, keep in bags, keep in bank, restock quantity, restock keep-in-bags. Quick actions include *move all grouped items to bank*, *restock bags*, and *empty bags*. Slash commands `/tsm put` and `/tsm get` drive moves; Retail currently has known reliability issues with bank moves and bonus-ID items ([Known issues](https://tradeskillmaster.helpjuice.com/en_US/known_issues/known-issues-in-retail-wow)).

### 5.7 Accounting and the Ledger

**Collection.** Records come from mail parsing (AH sales, purchases, cancels, expiries, COD), trades, vendor sales/purchases, repair bills, postage, money transfers and mission rewards. Purchases made directly through TSM's AH UI are recorded at purchase time *(observed)*.

**Ledger views** ([Ledger docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-ledger)):

- **Inventory** — every item TSM knows about, with counts per location (total, bags, bank, mail, alts, guild, on AH) and a total value from a session-only value source.
- **Revenue** — Sales (by type: auction, COD, trade, vendor), Other (missions, transfers), Resale (items both bought and sold, with avg buy, avg sell, profit, profit %).
- **Expenses** — Purchases (same types) and Other (postage, repairs, transfers).
- **Failed auctions** — Expired and Cancelled; these cannot be deleted, whereas sale and purchase records can be removed by right-click.
- **Item detail** — quantity, average and total price over all time / 7 days / 30 days, top trading partners, full record list.

### 5.8 Dashboard

The home tab of the main window ([Dashboard docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-dashboard)): news feed from the TSM blog; a green/yellow/red status icon for app sync and price-data age; current gold with a realm-faction total on hover; a gold-over-time chart (character multi-select, preset ranges, drag-to-zoom, green if up, red if down); and summary tiles for high/low gold, average sales and purchases, top single sale/purchase, and Sales / Expenses / Profit totals with per-day averages and top item — all bound to the chart's selected range.

### 5.9 Destroying

When bags contain items that can be disenchanted, milled or prospected, a small Destroying window lists them with the expected `Destroy` value. A single button (a secure action button) casts the correct spell on the next item; results are logged to learn yields. Retail destroy data for items from Dragonflight onward is currently unavailable ([Known issues](https://tradeskillmaster.helpjuice.com/en_US/known_issues/known-issues-in-retail-wow)).

### 5.10 Task List

A floating, context-aware checklist that turns the crafting queue and gather plan into concrete steps: "log into Alt-A, collect 40 Herb X from mail", "buy 200 Ore at the AH", "craft 12 Flask", "visit Ink Trader". Each task offers a button that performs the action when the relevant frame is open. It is the glue that sequences Crafting, Mailing, Banking, Shopping and Vendoring.

### 5.11 Tooltips and inventory tracking

TSM appends configurable lines to every item tooltip: chosen price sources (any custom string), Crafting cost and profit, Destroy value with per-result breakdown, vendor prices, ledger stats (avg buy/sell, expires), group and operation membership, and inventory counts per character, bank, mail, guild and AH, with an option to show totals for the stack under the cursor. Inventory tracking scans bags, banks, mail and owned auctions on every relevant event and keeps per-character snapshots so alts' holdings are visible without logging in; characters can be "forgotten" and guild banks ignored in settings ([General settings](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-general-settings)).

## UI and user flow

TSM's UI has one **configuration window** (opened anywhere) and several **contextual frames** that appear only when the matching Blizzard frame opens. Configuration happens in the first; execution happens in the second, always against the same group tree.

### 6.1 Windows and tabs

| Window | Opens when | Tabs / regions |
| --- | --- | --- |
| Main window | `/tsm` or minimap icon | Dashboard · Operations · Groups · Ledger · Settings |
| Auction House frame | AH opened | Browse (Shopping) · Sniper · Auctioning · My Auctions |
| Crafting frame | Profession opened | Crafts list · Queue · Materials · Gathering |
| Mailing frame | Mailbox opened | Inbox · Groups · Quick Send · Other |
| Vendoring frame | Merchant opened | Buy · Sell · Buyback · Groups |
| Banking frame | Any bank opened | Warehousing · Auctioning · Mailing (group actions) |
| Destroying window | Destroyable items in bags | Item list + Destroy Next button |
| Task List | Queue has pending steps | Ordered steps with action buttons |

Tab names reflect the TSM4 layout as documented; exact naming varies by flavour. Every contextual frame carries a *switch to default UI* control, and a user preference remembers which UI to show per frame *(observed)*.

### 6.2 Shared UI components

- **Group tree selector** — the same tree (with checkboxes, search, expand/collapse) appears on the left of Auctioning, Shopping, Mailing, Vendoring and Banking frames. Selecting groups and pressing *Scan* / *Send* / *Move* is the universal "run my rules" gesture.
- **Scrolling data table** — virtualised rows, sortable columns, a header context menu to hide columns, and row selection with Shift/Ctrl ranges. Used for scan results, ledger, inventory and crafts.
- **Custom-string input** — a text field with live validation that shows the evaluated value for a sample item and highlights the error position (enabled by the v4.13 parser).
- **Action bar** — the primary *Post / Cancel / Buy / Craft Next* button plus a progress indicator ("12 / 48") and a *Skip* control. This is the hardware-event bottleneck, so it is always large and bindable via the TSM macro.
- **Window chrome** — draggable, resizable; Shift + resize scales the whole window ([TSM blog, v4.2](https://blog.tradeskillmaster.com/?p=427)).

### 6.3 Configuration flow (first run)

1. Install addon + AppHelper; install the desktop app, log in, choose realms (10 on a free account).
2. Log in to the game. Dashboard status icon turns green once AppHelper data loads.
3. **Groups tab** → create groups or paste an import string. New groups start with the Base Group's operations inherited.
4. **Operations tab** → create or tune operations per module; attach them to groups from the operation's Group Management pane or the group's Operations sub-tab.
5. **Settings** → tooltip lines, default material price, custom sources, macro binding.

### 6.4 Execution flow (a typical session)

1. **Mailbox** — open all; Accounting records sales and purchases; Groups tab sends materials to the crafter.
2. **Bank** — warehousing restocks bags with items to sell or craft from.
3. **Profession** — restock queue; Craft Next until done; Task List flags missing materials.
4. **Auction House** — Shopping buys missing materials; Auctioning *Post scan* → press Post repeatedly; *Cancel scan* → press Cancel repeatedly; optionally leave Sniper running.
5. **Vendor** — sell junk and low-value grouped items; buy vendor reagents.
6. **Dashboard / Ledger** — review profit for the period.

The ordering is not enforced; the Task List suggests it when a craft queue exists.

## Data storage

TSM keeps all state in one Lua table, `TradeSkillMasterDB`, declared as an account-wide SavedVariable. WoW serialises it to `WTF/Account/<ACCOUNT>/SavedVariables/TradeSkillMaster.lua` on logout or `/reload`. Rather than nested per-scope tables (the AceDB approach), TSM uses a **flat key space where each key encodes its scope** — a design choice that keeps lookups O(1), makes per-scope enumeration a prefix scan, and lets sync and export pick keys by pattern.

### 7.1 Scoped key format

Keys have the shape `<scope>@<scopeKey>@<settingName>`. A real SavedVariables dump shows keys such as `p@Default@items`, `f@Alliance - Arthas@inventory`, `c@Caek - Arthas@auctionPrices` and `g@ @customPriceSources` ([SavedVariables dump, 2016](https://pastebin.com/2NjLyHzf)). That dump predates TSM4, so treat the exact setting names as illustrative; the scheme itself is the part to replicate.

| Prefix | Scope | Scope key | Holds (examples) |
| --- | --- | --- | --- |
| `g` | Global | single space | Custom sources, global operations, window positions, vendor price cache, sound prefs |
| `p` | Profile | profile name | Groups, item→group map, operations, tooltip options, UI prefs |
| `r` | Realm | realm name | Realm-wide data such as ledger records *(inferred for TSM4)* |
| `f` | Faction-realm | `Faction - Realm` | Per-character inventory snapshots, guild vaults, character list, sync metadata |
| `c` | Character | `Name - Realm` | Per-character caches (auction state, messages, professions) |
| `s` | Sync | `Name - Faction - Realm` | Data that is owned by one character and replicated to synced accounts *(inferred for TSM4)* |

Top-level bookkeeping keys:

- `_version` — schema version, driving migrations on load.
- `_scopeKeys` — the list of known keys per scope (all characters, realms, faction-realms, profiles) so the addon can enumerate without scanning.
- `_currentProfile` — map of character → active profile name.
- `_hash` — a hash of the settings schema/defaults used to detect when defaults changed *(inferred)*.

### 7.2 Core entities

```
p@<profile>@groups      : { [groupPath] = { [module] = { opName, ... }, ... } }
p@<profile>@items       : { [itemString] = groupPath }
p@<profile>@operations  : { [module] = { [opName] = { field = value | customString, ... } } }
g@ @customPriceSources  : { [name] = customString }
f@<f-r>@inventory       : { [char] = { bag={}, bank={}, reagentBank={}, mail={}, auction={} } }  -- itemString → qty
f@<f-r>@pendingMail     : { [char] = { { mailType, items, arrivalTime }, ... } }
f@<f-r>@syncMetadata    : { [table] = { [char] = { owner = accountKey, lastUpdate = epoch } } }
```

- **Group path** is a string with a reserved separator between levels, so the tree is reconstructed from the keys and item membership is a flat map — moving a group renames keys rather than restructuring tables *(inferred)*.
- **Item strings** normalise item identity: `i:<itemID>` for the base item, extra fields for random suffix / bonus IDs / modifiers (e.g. `i:3740:-84`), `p:<speciesID>` for battle pets. Grouping granularity (exact variant vs. ilvl vs. base) is applied when converting a live item link into an item string.
- **Operation fields** store either a number/boolean or the raw custom-string text; strings are compiled lazily and cached in memory, never persisted compiled.
- **Global operations toggle.** When *store operations globally* is enabled, operations live under the global scope and become available to every profile — but are then excluded from profile transfers to synced accounts ([General settings](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-general-settings)).

### 7.3 Ledger storage

Accounting volume is the largest data set (years of sales across many characters). TSM stores records compactly as delimited text blocks per record type (sales, buys, income, expenses, expired, cancelled), each row holding item string, stack size, quantity, unit price, other party, player, time, and source (Auction / COD / Trade / Vendor) *(inferred from behaviour; field names may differ)*. Text blocks are cheap to serialise, can be appended without rebuilding tables, and double as the CSV export format. Old records are merged into daily summaries after a configurable age to cap file size *(inferred)*.

### 7.4 Runtime database

In memory, TSM loads hot data into an internal indexed query layer (tables with typed fields, secondary indexes and joinable queries) used by every scrolling table and scan *(inferred from observed UI behaviour and TSM4's speed claims)*. A re-implementation should separate the **persisted format** (flat scoped keys, compact strings) from the **runtime model** (indexed rows) and rebuild indexes on login.

Other runtime caches:

- **Item info cache** — names, quality, class, vendor prices, keyed by item string. It is rebuilt whenever the game client version changes, such as after a hotfix ([Known issues](https://tradeskillmaster.helpjuice.com/en_US/known_issues/known-issues-in-retail-wow)).
- **Price cache** — per-frame memo of custom-string results, invalidated on data load, custom source edit or inventory change.

### 7.5 Market data (AppHelper)

Market data is not in `TradeSkillMasterDB`. The desktop app writes it into the TSM\_AppHelper addon's Lua files as data blobs per region and realm (commodity and non-commodity sets), each carrying a download timestamp, a field list and packed rows *(format inferred)*. On login AppHelper hands the blobs to TSM, which decodes them into the AuctionDB sources lazily, by item, to keep load time and memory low. The Dashboard status icon reports the age of this data ([Dashboard docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-dashboard)).

The reverse channel is the SavedVariables files: after logout the desktop app reads them to take backups and, for premium accounts, to upload ledger data to the web Ledger ([Premium FAQ](https://tradeskillmaster.helpjuice.com/en_US/addon/what-are-the-benefits-of-tsm-premium)). Region sale data (`DBRegionSaleAvg`) is aggregated server-side from these uploads.

### 7.6 Integrity and migrations

- Every load runs schema migrations from `_version` to current, with per-key upgrade functions.
- Unknown or invalid keys are dropped; missing keys fall back to registered defaults.
- Writes are atomic only at logout (WoW's model), so a crash loses the session. TSM mitigates this through the app's automated backups (premium keeps up to 20 pinned backups).

## Profiles and multi-account sync

TSM separates **what you want to do** (profiles: groups, operations, UI preferences) from **what you have** (character, realm and faction-realm data: inventory, gold, professions, ledger). Profiles are swappable per character; owned data is not, and is instead replicated between accounts by sync.

### 8.1 Profiles

- **Assignment.** Each character points at exactly one profile; the map lives in `_currentProfile`. A new character defaults to `Default`.
- **Contents.** Everything under the `p@<profile>@` prefix: the group tree and item map, operations (unless stored globally), tooltip and UI preferences.
- **Management** ([General settings](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-general-settings)): activate via a toggle beside the profile name; reset to defaults; rename; duplicate; create new (with default settings).
- **Global operations mode.** Moves operations out of the profile so every profile shares them. Trade-off: profile sends to synced accounts then carry no operations.
- **Per-realm and per-character scoping inside a profile.** Rather than forcing separate profiles, each operation can be ignored on chosen faction-realms or characters, so one profile can serve a multi-realm setup ([Auctioning docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1072146-tsm-addon-auctioning-operations)).
- **Deleting a profile** in use by any character must reassign those characters to `Default` first *(required behaviour)*.

**Typical split-profile patterns.** A *crafter* profile with Crafting and Mailing-out operations; a *seller* profile with Auctioning and Mailing-in operations; a *Classic* profile for a different game flavour. Because groups live in the profile, users who want shared groups but different rules should duplicate a profile and then edit only operations.

### 8.2 Account sync

Sync connects two or more Battle.net/WoW accounts so each sees the other's characters as if local (inventory in tooltips, gold totals, crafters available for the queue, ledger totals).

**Pairing protocol**

1. On account A, enter the name of a character on account B that is online, on the same realm and the same faction ([General settings](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-general-settings)).
2. A sends a connection request over the addon whisper channel; B's player accepts the prompt.
3. Both sides exchange account keys and store each other in the faction-realm's sync account list.
4. Initial full sync, then incremental sync whenever both accounts have a character online on that realm-faction.

The vendor notes the initial setup can appear to connect indefinitely and suggests adding the two characters as friends first; sync can also cause occasional performance issues ([Known issues](https://tradeskillmaster.helpjuice.com/en_US/known_issues/known-issues-in-retail-wow)).

**Data model.** Each replicated table carries per-character metadata — an `owner` account key and a `lastUpdate` timestamp — visible in SavedVariables as `syncMetadata` ([SavedVariables dump](https://pastebin.com/2NjLyHzf)). Rules a re-implementation should follow:

- **Single writer.** Only the owning account modifies a character's rows; others hold read-only replicas. This removes merge conflicts.
- **Version by timestamp.** On connect, peers exchange `{table, character, lastUpdate}` digests and request only stale rows.
- **Throttled transport.** Addon messages have size and rate limits; payloads are serialised, compressed and chunked, and sent in the background to avoid frame-rate drops *(platform constraint; TSM's specific encoding not public)*.
- **What syncs** *(observed)*: character list and classes, gold, inventory per location, professions/known recipes (for cross-account crafting queues), pending mail, ledger records.
- **What does not sync automatically:** profiles. Since v4.2 a user can explicitly **send an entire profile** to a synced account, which copies groups and (if not global) operations ([TSM blog, v4.2](https://blog.tradeskillmaster.com/?p=427)).

### 8.3 Character and guild data hygiene

- **Forget character** removes all knowledge of a character — professions, inventory and gold.
- **Ignore guilds** excludes a guild bank from inventory tracking.
- Both settings are realm-faction scoped, matching where the data lives.

## Import and export

TSM moves configuration between players and installs through four channels: copy-paste strings, profile send to a synced account, the website's published groups, and desktop-app backups. Owned data (ledger, inventory) moves only by sync, backup or the web Ledger.

| Channel | What moves | Direction | Requires |
| --- | --- | --- | --- |
| Export / import string | Groups, sub-groups, items, operations, custom sources | Any player → any player | Nothing |
| Plain item list | Items only | Any text → a group | Nothing |
| Send profile | Whole profile (groups + operations unless global) | Account → synced account | Account sync |
| Published group (website) | Group + operations, via share link | Web → game (import) | Free to use; publishing from synced groups needs Premium Gold |
| App backups | Entire SavedVariables | Cloud → local restore | Desktop app; cloud copies need Premium |

### 9.1 Export string

The Export dialog on any group shows ([Groups docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-groups)): the group name; which sub-groups to include; a toggle to exclude operations; a toggle to exclude custom sources referenced by those operations; the string; and counts of items, sub-groups, operations and custom sources.

**Payload** *(structure inferred; TSM's encoding is not publicly documented)*:

```
{
  version,                         -- export format version
  groups:   [ relativeGroupPath, ... ],
  items:    { [itemString] = relativeGroupPath },
  groupOperations: { [relativeGroupPath] = { [module] = { opName, ... } } },
  operations: { [module] = { [opName] = { ...fields } } },
  customSources: { [name] = customString }
}
```

The table is serialised, compressed and encoded to a printable string so it survives chat, forums and Discord. Requirements for a re-implementation:

- **Relative paths.** Paths are stored relative to the exported root so the tree can be grafted anywhere.
- **Closure over references.** If an exported operation's custom string references a custom source, that source is included unless excluded — otherwise the import produces invalid prices.
- **Module exclusions.** Mailing operations are never exported, because target character names are account-specific ([Mailing docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-mailing-operations)).
- **Size.** Large exports (thousands of items) must remain pasteable; compression is mandatory.

### 9.2 Import flow

1. Paste the string in the Groups tab's import dialog (also reachable from the Import/Export area).
2. TSM decodes and validates it, then shows an **Import Summary**: counts of groups, operations and items.
3. The user can remove specific items and individual operations before confirming, and only the selection is imported ([TSM 4.5 release](https://blog.tradeskillmaster.com/tradeskillmaster-4-5-released/)).
4. Options include whether to move items already in other groups and whether to skip previously imported operations ([TSM4 release](https://blog.tradeskillmaster.com/2018/07/)).
5. Confirming always creates a new top-level group named *Imported Group* that the user then renames and re-parents ([Groups docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-groups)).

**Conflict rules** a re-implementation should define explicitly:

- **Item already grouped elsewhere** → keep existing placement by default; offer "move imported items".
- **Operation name collision** → rename the imported one with a suffix, or skip if identical, or overwrite if the user chooses.
- **Custom source collision** → never silently overwrite; prompt.
- **Unknown price source in a string** → import it, mark the operation invalid, surface a warning (e.g. sources retired in 4.5 such as `dbglobalmarketavg`, which TSM handled with an in-game remapping prompt).

### 9.3 Plain item lists

The import field also accepts a comma-separated list of item strings or IDs (e.g. `i:152505,i:152506`), which simply populates a group with items. This is how many community spreadsheets and websites share groups *(observed)*.

### 9.4 Website groups

After the September 2024 website relaunch, Premium Gold users can view their in-game groups and assigned operations on the website by account and profile, and publish a group to get a shareable link that imports group and operations in one step ([TSM blog, Sept 2024](https://blog.tradeskillmaster.com/2024/09/)). Searching and using public groups remains free; TSM has said it is exploring syncing a group straight into the game via the desktop app ([Public groups](https://blog.tradeskillmaster.com/?p=1110)).

### 9.5 Owned-data export

The ledger is exported off-machine by the desktop app (premium web Ledger and region sale aggregates). Backups capture the full SavedVariables for restore, and the recommended fix when settings are lost is to close WoW and restore a backup from the app. In-game CSV export of ledger records is not documented in the current knowledge base — see Open questions.

## Desktop app, web services and non-functional requirements

### 10.1 Desktop application

Responsibilities: log in with the TSM account email; install and update both TradeSkillMaster and TSM\_AppHelper per game flavour from its Addon Version tab; download price data for the realms the user configured on the website; back up SavedVariables; upload ledger data for premium analytics ([Desktop app setup](https://support.tradeskillmaster.com/tsm-desktop-application/how-do-i-set-up-the-tsm-desktop-application)). Users verify it is working by checking the *TSM AuctionDB* timestamp in an item tooltip. Premium subscribers' addons are updated automatically by the app ([TSM blog, Aug 2023](https://blog.tradeskillmaster.com/2023/08/)).

**Data pipeline** *(inferred)*: TSM's servers poll Blizzard's Auction House web API roughly hourly per connected-realm and per region commodity market, compute AuctionDB statistics server-side (the outlier algorithm in 4.3), and publish per-realm and per-region packages that the app downloads and writes into AppHelper. Sale data for `DBRegionSaleAvg` comes from aggregated user ledger uploads.

### 10.2 Plans (since 4 September 2024)

| Plan | Price (billed annually) | Realms in app | Notable features |
| --- | --- | --- | --- |
| Free | $0 | 10 | Desktop app with price data; basic AH analysis on the website |
| Gold | from $3.00/month | 25 | Basic web Ledger, BMAH view, cloud setting backups, email alerts, Great Deals in-game, beta access |
| Platinum | from $7.50/month | Unlimited | Extensive Ledger analysis, performance tracking, sale price/quantity charts, Discord alerts |

Sources: [TSM blog, Sept 2024](https://blog.tradeskillmaster.com/2024/09/), [Desktop app setup](https://support.tradeskillmaster.com/tsm-desktop-application/how-do-i-set-up-the-tsm-desktop-application). An older Premium FAQ cites a single premium plan with up to 40 extra realms; it predates the 2024 tiers ([Premium FAQ](https://tradeskillmaster.helpjuice.com/en_US/addon/what-are-the-benefits-of-tsm-premium)).

### 10.3 Non-functional requirements

- **Load time.** AppHelper data for 10+ realms is large; decode lazily per item and never block the login loading screen with full parsing.
- **Memory.** Market data, item cache and ledger are the top consumers; store packed numeric arrays rather than per-item tables where possible.
- **Frame budget.** All scans, sync and data processing run as cooperative coroutines yielding each frame, so the game never stalls; long work shows progress.
- **Throttle-aware scanning.** Every AH query goes through one queue that tracks Blizzard's throttle and pauses and resumes transparently.
- **Hardware-event compliance.** No protected action fires outside a user click or key press; the UI makes the next action obvious and bindable.
- **Robustness to patches.** Expect Blizzard to change APIs each major patch (8.3 AH rewrite; Retail macro limits; warband bank). Isolate each Blizzard API family behind an adapter layer per flavour.
- **Determinism and explainability.** Every automated decision (post price, skip, cancel, queue quantity) records a human-readable reason shown in the UI.
- **Data safety.** Schema migrations are idempotent; corrupted keys are dropped individually rather than wiping the DB; backups are taken outside the game.
- **Localisation.** All UI strings localised; item matching never depends on localised names (always item strings).

### 10.4 Open questions for the re-implementation

- Exact TSM4 export-string encoding (serializer, compression, prefix) — needed only if imports from real TSM strings must be supported.
- Whether the current addon offers in-game CSV export of ledger records.
- The precise set of tables replicated by account sync in v4.14, and whether a `s@` sync scope exists as inferred.
- The default Sniper maximum price custom string (TSM's own docs list it as "Coming Soon").
- How Retail crafting quality tiers and optional reagents are represented in item strings and crafting cost.

### Sources

- [WoWInterface — TradeSkillMaster v4.14.73](https://wowinterface.com/downloads/info24165-TradeSkillMaster.html)
- [CurseForge — TradeSkillMaster](https://curseforge.com/wow/addons/tradeskill-master)
- [TSM Addon: General Settings](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-general-settings)
- [TSM Addon: Auctioning Operations](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1072146-tsm-addon-auctioning-operations)
- [TSM Addon: Sniper Operations](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-sniper-operations)
- [TSM Addon: Mailing Operations](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-mailing-operations)
- [TSM Addon: Groups](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-groups)
- [TSM Addon: Dashboard](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-dashboard)
- [TSM Addon: Ledger](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/tsm-addon-ledger)
- [AuctionDB Market Value](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/auctiondb-market-value)
- [Which Price Sources can I use](https://support.tradeskillmaster.com/custom-strings/which-price-sources-can-i-use-and-what-do-they-mean)
- [What are Custom Strings?](https://tradeskillmaster.helpjuice.com/addon/what-are-custom-strings)
- [Known issues in Retail WoW](https://tradeskillmaster.helpjuice.com/en_US/known_issues/known-issues-in-retail-wow)
- [How do I set up the TSM Desktop Application](https://support.tradeskillmaster.com/tsm-desktop-application/how-do-i-set-up-the-tsm-desktop-application)
- [What do I get with TSM Premium?](https://tradeskillmaster.helpjuice.com/en_US/addon/what-are-the-benefits-of-tsm-premium)
- [TSM blog — TSM4 release (July 2018)](https://blog.tradeskillmaster.com/2018/07/)
- [TSM blog — 4.2 release](https://blog.tradeskillmaster.com/?p=427)
- [TSM blog — 4.5 release](https://blog.tradeskillmaster.com/tradeskillmaster-4-5-released/)
- [TSM blog — Auction House Throttling](https://blog.tradeskillmaster.com/auction-house-throttling/)
- [TSM blog — New Custom String Parsing (Aug 2023)](https://blog.tradeskillmaster.com/2023/08/)
- [TSM blog — New website and Premium plans (Sept 2024)](https://blog.tradeskillmaster.com/2024/09/)
- [TSM blog — Re-introducing Public TSM Groups](https://blog.tradeskillmaster.com/?p=1110)
- [Wowhead — Sniper after 8.3](https://www.wowhead.com/news=312308/wowhead-economy-weekly-wrap-up-122-childrens-week-professions-market-prices)
- [Wowhead — MatPrice explained](https://cn.wowhead.com/news/wowhead-economy-weekly-wrap-up-191-korthite-crystal-market-crash-323878)
- [TradeSkillMasterDB SavedVariables dump (2016)](https://pastebin.com/2NjLyHzf)
