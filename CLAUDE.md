# Flipside

Flipside is a World of Warcraft: Forever auction house addon. Lua 5.1. Licence MIT.

## Documents
- Spec: `docs/SPEC.md`. Read it first.
- `docs/TSM_REFERENCE.md` is background only.

## Rules
- Clean room: build from the spec only. Never copy TSM code, assets, names or string formats.
- API source of truth: check each Blizzard API in the Forever client source (Ketho/wow-ui-source-forever, branch `forever`) and on warcraft.wiki.gg. If they disagree, the Forever source wins.
- Decisions D1–D22 are binding — ask before changing one
- When something gets scoped, update the Needs scoping table
- If a task depends on an open question in the spec, stop and ask.

## Build order
0. Spike 0: the `ScanTest/` addon (full-scan test).
1. Framework: settings DB with scopes, event bus, coroutine scheduler, item-string normaliser, item info cache.
2. Full scan and the snapshot pipeline, then scan price sources.
3. Formula compiler, with live preview.
4. Groups and operations UI.
5. Tooltips and inventory tracking.
6. AH tabs in Blizzard's Auction House frame: Buying, then Selling with dry run and decision log.
7. Mailbox parsing and the ledger; then Vendoring.

## Definition of done
Unit tests pass; luacheck is clean; the feature's in-game checklist passes on WoW: Forever; the spec section is updated if behaviour changed; the Phase dropdown and Needs scoping status reflect reality.

## Layout
`Core/` framework, `Services/`, `Features/<Name>/`, `UI/`, `UI/Kit/`, `Libs/` (empty, no third-party library), `Locales/`, `Tests/` (busted specs and `wow_mock.lua`), `ScanTest/` (throwaway Spike 0 addon).
- `UI/Kit/`: reusable style kit, no Flipside logic (D19).
- Kit modules in UI/Kit/: Theme, Window, Widgets, Tabs, List, Combat. They take all input as arguments and use no Flipside name, 
s service or chat output (D19).
- No third-party library is used (D18).
- Core modules: `EventBus`, `Scheduler`, `ItemString`, `SettingsDB`, `ItemInfoCache`, `Init`. Core files start with `local _, ns = ...` and write no globals (`Init` also reads the addon name and sets the slash globals).
- Scan modules in `Services/`: `ScanClock`, `ScanRecord`, `ScanMarket`, `ScanKey`, `ScanCooldown`, `ScanBucket`, `ScanStore`, `ScanRows`, `ScanItemLoad`, `ScanSources`, `ScanEngine`, `ScanCapture`.
- Formula modules in `Services/`: `FormulaParse`, `FormulaFunctions`, `FormulaSources`, `FormulaLookup`, 
`FormulaEval`, `FormulaRun`.
- `UI/MainWindow.lua`, `UI/Pages/`, `Features/AuctionTab/`.
- UI: Flipside tabs inside Blizzard's AuctionHouseFrame, plus the Flipside window (800 x 540); only client assets.
- Item keys follow D20; no battle pets in the MVP (D21); scan data is keyed by region and ruleset (D22).

## Commands
- Lint: `luacheck .`
- Tests: `busted`
