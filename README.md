# Flipside

Flipside is an auction house and economy addon for World of Warcraft: Forever. It helps a player buy, sell, craft and track items by rules. All price data comes from the player's own scans in the game client.

## Status
Spike 0. Only the throwaway test addon `ScanTest` exists. It checks if the full Auction House scan works on WoW: Forever. See `ScanTest/README.md`.

The interface number 16001 in the TOC files is confirmed by `GetBuildInfo` in the client (build 70338).

## Licence
MIT. See `LICENSE`.

## Development setup
The tools are Lua 5.1, luarocks, luacheck and busted. Code must run on Lua 5.1.

Use the "x64 Native Tools Command Prompt for VS 2022". The C compiler needs its `INCLUDE` and `LIB` variables. Without them the build fails with `assert.h: no include path set`. Do all install steps in this prompt.

`mise` cannot build Lua on Windows. Do not use it.

1. Install `hererocks`: `pip install hererocks`.
2. Add `.` to PATH for this prompt: `set PATH=.;%PATH%`. Python 3.12 and later does not find `install.bat` in the current folder. Without this step the luarocks install fails with `couldn't run install.bat /?`.
3. Install Lua 5.1 and luarocks in the repository root: `hererocks lua51 -l 5.1 -r https://github.com/luarocks/luarocks@v3.11.1`. The `-r latest` option gives luarocks 3.8.0, which fails.
4. Put the tools in PATH: `set PATH=%CD%\lua51\bin;%PATH%`. In PowerShell use `$env:PATH = "$PWD\lua51\bin;$env:PATH"`.
5. Install the tools in the same prompt: `luarocks install luacheck`, then `luarocks install busted`. The `lua-term` and `luafilesystem` rocks need the C compiler.
6. Run the lint from the repository root: `luacheck .`
7. Run the tests from the repository root: `busted`

After step 5, the tools run in any shell that has `lua51\bin` in PATH. The `lua51` folder is not in git.
## Libraries
No third-party library is used at this time. The `Libs/` folder is empty.

## Documents
- `docs/SPEC.md`: the specification.
- `docs/TSM_REFERENCE.md`: background only.
- `ScanTest/README.md`: how to run Spike 0.

## Releases

GitHub Actions packages the addon with the BigWigs packager. The zip goes to GitHub releases.

The tag name sets the channel:

| Tag | Channel | GitHub release |
|---|---|---|
| `v0.1.0` | release | release |
| `v0.1.0-beta.1` | beta | pre-release |
| `v0.1.0-alpha.1` | alpha | pre-release |

Cut a release:

```text
git tag v0.1.0
git push origin v0.1.0
```

Use `v0.1.0-beta.1` for a beta and `v0.1.0-alpha.1` for an alpha.

Each push to `main` creates an alpha pre-release named `vX.Y.(Z+1)-alpha.N`. X.Y.Z is the latest release tag. N is the workflow run number. The workflow keeps the 10 newest alpha builds and deletes older ones with their tags. It never deletes releases or betas.

WowUp: add the GitHub repository URL. Choose the Alpha channel to get alpha builds, Beta for beta tags, and Stable for releases.

CurseForge and Wago need no code change. Add the IDs to `Flipside.toc` (`## X-Curse-Project-ID: <id>` and `## X-Wago-ID: <id>`). Add the secrets `CF_API_TOKEN` and `WAGO_API_TOKEN` in the GitHub repository settings. The packager skips a site that has no ID or no token.
