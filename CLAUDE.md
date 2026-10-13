# Flipside

Flipside is a World of Warcraft: Forever auction house addon. Lua 5.1. Licence MIT.

## Documents
- Spec: `docs/SPEC.md`. Read it first.
- `docs/TSM_REFERENCE.md` is background only.

## Rules
- Clean room: build from the spec only. Never copy TSM code, assets, names or string formats.
- API source of truth: check each Blizzard API in the Forever client source (Ketho/wow-ui-source-forever, branch `forever`) and on warcraft.wiki.gg. If they disagree, the Forever source wins.
- Decisions D1–D17 are binding — ask before changing one
- When something gets scoped, update the Needs scoping table
- If a task depends on an open question in the spec, stop and ask.

## Build order
0. Spike 0: the `ScanTest/` addon (full-scan test).
1. Framework: settings DB with scopes, event bus, coroutine scheduler, item-string normaliser, item info cache.
2. Full scan and the snapshot pipeline, then scan price sources.
3. Formula compiler, with live preview.
4. Groups and operations UI.
5. Tooltips and inventory tracking.
6. AH frame: Buying, then Selling with dry run and decision log.
7. Mailbox parsing and the ledger; then Vendoring.

## Definition of done
Unit tests pass; luacheck is clean; the feature's in-game checklist passes on WoW: Forever; the spec section is updated if behaviour changed; the Phase dropdown and Needs scoping status reflect reality.

## Layout
`Core/` framework, `Services/`, `Features/<Name>/`, `UI/`, `Libs/` (empty, no third-party library), `Locales/`, `Tests/` (busted specs and `wow_mock.lua`), `ScanTest/` (throwaway Spike 0 addon).

## Commands
- Lint: `luacheck .`
- Tests: `busted`
