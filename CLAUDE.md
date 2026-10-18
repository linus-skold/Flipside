# Flipside

Flipside is a World of Warcraft: Forever auction house addon. Lua 5.1. Licence MIT.

## Documents
- Spec: `docs/SPEC.md`. Read it first.
- `docs/TSM_REFERENCE.md` is background only.

## Rules
- Clean room: build from the spec only. Never copy TSM code, assets, names or string formats.
- API source of truth: check each Blizzard API in the Forever client source (Ketho/wow-ui-source-forever, branch `forever`) and on warcraft.wiki.gg. If they disagree, the Forever source wins.
- Decisions D1–D25 are binding — ask before changing one
- When something gets scoped, update the Needs scoping table
- If a task depends on an open question in the spec, stop and ask.

## Build order
0. Spike 0: the `ScanTest/` addon (full-scan test).
1. Framework: settings DB with scopes, event bus, coroutine scheduler, item-string normaliser, item info cache.
2. Full scan and the snapshot pipeline, then scan price sources.
3. Formula compiler, with live preview.
4. Groups and operations UI.
5. Tooltips and inventory tracking; tooltip price lines configurable with formulas (min, max, average).
6. AH tabs in Blizzard's Auction House frame: Buying, then Selling with dry run and decision log. Selling and Buying tabs in Blizzard's AH frame that use the groups.
7. Mailbox parsing and the ledger; then Vendoring.

## Definition of done
Unit tests pass and luacheck is clean. This means that the CI checks of the pull request are green. The feature's in-game checklist passes on WoW: Forever; the spec section is updated if behaviour changed; the Phase dropdown and Needs scoping status reflect reality.

## Testing
- Workers (implementer, explorer) do not run `busted` or `luacheck` on disk. GitHub Actions (`.github/workflows/ci.yml`) runs both on each pull request.
- The implementer writes and updates the unit tests in `Tests/` for each change. Its report says: `tests: not run on disk (CI)`.
- The orchestrator pushes the branch and opens the pull request. Then it runs `gh pr checks <pr> --watch`.
- If a check fails, the orchestrator gets the failed lines with `gh run view <run-id> --log-failed`. It keeps only the last 60 lines and sends them to the same implementer.
- The implementer fixes the failure with a new commit on its worktree branch. The orchestrator pushes again. Do not force-push.

## Pull requests
Decision of 2026-10-15: use GitHub stacked PRs (`gh-stack`) for all new work, so that merges are easy.
- Stack each new PR on the top open PR branch. Use `main` as the base only when no PR is open.
- A worker starts its branch from the top branch.
- Create the PR with `gh pr create --base <top branch> --head <branch>`.
- Then run `gh stack link <bottom> ... <top>` (branch names or PR numbers, bottom to top). To grow a stack, run `gh stack link <stack number> <new branch>`.
- Merge with `gh stack merge` or the GitHub stack UI. It merges the stack bottom-up in one step.
- Do not squash-merge one PR from the middle of a stack.
- After a merge, run `gh stack sync`. If a branch has conflicts, merge the base into it.
- Do not rebase a pushed branch. Never force-push. Never push to `main`.

## Layout
Per D23 the layout moves to `Shared/`, `Core_<Flavour>/` and `AH_<Flavour>/` in a later pull request. The lists below show the current layout.
`Shared/Core/` framework, `Shared/Services/`, `Shared/Features/<Name>/`, `Shared/UI/`, `Shared/UI/Kit/`, `Shared/UI/Pages/`, `Shared/Libs/` (empty, no third-party library), `Shared/Locales/`, `Tests/` (busted specs and `wow_mock.lua`), `ScanTest/` (throwaway Spike 0 addon), `Flipside_Ledger/` (load-on-demand ledger addon, `FlipsideLedgerDB`, D25 and spec §5.8; comes with step 7).
- `Shared/UI/Kit/`: reusable style kit, no Flipside logic (D19).
- Kit modules in Shared/UI/Kit/: Theme, Window, Widgets, Prompt, MoneyInput, Tabs, List, Tree, Combat, Graph, MinimapButton. They take all input as arguments and use no Flipside name, 
s service or chat output (D19).
- No third-party library is used (D18).
- Core modules: `Log` (diagnostics log, `FlipsideLogDB`, spec 7.5; `Shared/UI/LogWindow.lua` is its window), `EventBus`, `Scheduler`, `ItemString`, `SettingsDB`, `ItemInfoCache`, `Init`. Core files start with `local _, ns = ...` and write no globals (`Init` also reads the addon name and sets the slash globals). Other modules write log lines through a local `log` helper that skips the call when `ns.Log` is nil.
- Scan modules in `Shared/Services/`: `ScanClock`, `ScanRecord`, `ScanMarket`, `ScanKey`, `ScanCooldown`, `ScanBucket`, `ScanStore`, `ScanRows`, `ScanItemLoad`, `ScanSources`, `ScanEngine`, `ScanCapture`.
- Formula modules in `Shared/Services/`: `FormulaParse`, `FormulaFunctions`, `FormulaSources`, `FormulaLookup`, 
`FormulaEval`, `FormulaRun`.
- Tooltip and inventory modules in `Shared/Services/`: `Holdings`, `HoldingsRead`, `TooltipConfig`, `TooltipLines`. `Shared/Features/Inventory/InventoryCapture.lua` reads bags, bank, mail and own auctions into the holdings. `Shared/Features/Tooltip/Tooltip.lua` adds the lines; `Core_Forever/TooltipHook.lua` installs the client hook. `Shared/UI/Pages/TooltipPage.lua` is the Tooltip tab. Slash: `/flip tooltipstats`, `/flip forget <Name-Realm>`.
- Ledger modules in `Shared/Services/`: `LedgerRecord`, `LedgerBuffer`, `LedgerStore`, `LedgerLoader`. The load-on-demand addon `Flipside_Ledger/` (repo root) has only TOC files (`Flipside_Ledger.toc`, `Flipside_Ledger_TBC.toc`) and no Lua code (SPEC 5.8).
- Destroy modules: `Shared/Services/DestroyRules.lua` (rules and ignore list, no frame code) and `Shared/Features/Destroy/DestroyWindow.lua` (window, slash `/flip destroy`, SPEC 5.7a).
- Rules modules in `Shared/Services/`: `ItemNameIndex`, `OperationSchema`, `GroupTree`, `BagItems`, `RulesStore`, `CustomSources`, `AHNameSearch`, `RulesExport`.
- Mailing modules in `Shared/Services/`: `MailingPlan`, `MailClient`, `MailingRun`, `MailingLedger`. `Shared/Features/Mailing/` has `MailingView` (a self-contained view: parent frame in, no place) and `MailHost` (one host for both flavours; its `LAYOUTS` table places the view, today `wide`: `MailFrame` gets wider and holds the view, SPEC 5.5).
- `Shared/UI/MainWindow.lua`, `Shared/UI/Pages/` (`GroupsPage`, `OperationsPage`, `FormulaPage`, `LedgerPage`, `RulesImport`), `Shared/Features/AuctionTab/` (panel); `AH_Forever/AuctionTabHost.lua` owns AuctionHouseFrame. Flavour folders `Core_<Flavour>/` and `AH_<Flavour>/` come later (D23).
- UI: Flipside tabs inside Blizzard's AuctionHouseFrame, plus the Flipside window (800 x 540 minimum, resizable); only client assets.
- Item keys follow D20; no battle pets in the MVP (D21); scan data is keyed by region and ruleset (D22).

## Commands
These commands are for CI and for the user. Agents do not run them.
- Lint: `luacheck .`
- Tests: `busted`
