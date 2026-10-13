# Flipside

Flipside is an auction house and economy addon for World of Warcraft: Forever. It helps a player buy, sell, craft and track items by rules. All price data comes from the player's own scans in the game client.

## Status
Spike 0. Only the throwaway test addon `ScanTest` exists. It checks if the full Auction House scan works on WoW: Forever. See `ScanTest/README.md`.

The interface number 16001 in the TOC files is calculated from client version 1.60.1. It is not verified.

## Licence
MIT.

## Development setup
The tools are Lua 5.1, luarocks, luacheck and busted. Code must run on Lua 5.1.

1. Install Lua 5.1 and luarocks for Windows. One way is the `hererocks` tool (needs Python and a C compiler):
   `pip install hererocks`, then `hererocks lua51 -l 5.1 -r latest`.
2. Activate the environment: `lua51\bin\activate.ps1` (PowerShell).
3. Install the tools: `luarocks install luacheck`, then `luarocks install busted`.
4. Run the lint from the repository root: `luacheck .`
5. Run the tests from the repository root: `busted`

## Libraries
No third-party library is used at this time. The `Libs/` folder is empty.

## Documents
- `docs/SPEC.md`: the specification.
- `docs/TSM_REFERENCE.md`: background only.
- `ScanTest/README.md`: how to run Spike 0.
