# ScanTest

ScanTest is a throwaway addon. It tests if the full Auction House scan works on WoW: Forever.

## Install
1. Copy the `ScanTest` folder to `<WoW Forever folder>\Interface\AddOns\`.
2. You do not need "Load out of date AddOns". The interface number 16001 is confirmed by `GetBuildInfo` (build 70338).
3. Type `/reload` or start the game.
4. At login, ScanTest prints one line with the client version, build number, interface number and project id.

## Test
1. Go to an auctioneer and open the Auction House.
2. Type `/scantest`.
3. Read the warning. A full scan has disconnected clients on busy servers in the past.
4. Click Accept. Wait. The wait can be up to 60 seconds.
5. Read the summary in the chat.
6. Type `/reload` or log out. The client then writes the SavedVariables.
7. Send the file `WTF\Account\<ACCOUNT>\SavedVariables\ScanTest.lua`.
8. Run the test again inside 15 minutes. This tests the cooldown. The warning shows the time that remains. You can continue.

## Summary lines
| Line | Meaning |
| --- | --- |
| result | `ok`, `no response (cooldown or blocked)`, `call failed` or `API not available` |
| time to first event | Time from the call to `REPLICATE_ITEM_LIST_UPDATE` |
| processing time | Time to read all rows, and the number of frames used |
| memory | Lua memory (KB) before and after, and the difference |
| rows | Number of rows read |
| unique items | Number of different item ids |
| total quantity | Sum of the item counts |
| rows with buyout | Rows with a buyout price above 0 |
| missing info | Rows where `hasAllInfo` is not true |
| stackable | Rows where the item stacks above 1 (commodities) |
| stack size unknown | Rows with an item id but no stack size |
| empty rows | Rows with no item id. Many empty rows can mean that the index base is wrong. |

## Pass criteria
- The event fires.
- The row count is plausible for a busy market.
- Commodities are included (stackable rows above 0).
- Processing finishes without a freeze or a disconnect.

## Not verified
- The length of the cooldown (15 minutes is not proven).
- If the results include commodities (stackable rows are included; "stackable" equals "commodity" is not proven).

The test confirmed that the index base of `GetReplicateItemInfo` starts at 0 (0 to n-1).
