# MailTest

MailTest is a throwaway addon. It answers one question: can an addon send several mails in a row from one click, and from a timer with no click? Flipside will build its mail feature on the answer. Do not ship it.

## Install
1. Copy the `MailTest` folder to `<WoW folder>\Interface\AddOns\`. Do this for WoW: Forever and for TBC Anniversary.
2. The folder has two TOC files: `MailTest.toc` (Forever, 16001) and `MailTest_TBC.toc` (TBC, 20505). Each client loads its own file.
3. If the TBC client says the addon is out of date, tick "Load out of date AddOns".
4. Type `/reload` or start the game.

## Prepare
1. Use two characters on the same account and realm. Mail the items to your own alt.
2. Put at least 5 bag slots of one cheap item in your bags. Use 5 separate stacks of one item.
3. Get the item ID from the item link or from Wowhead.
4. Stand at a mailbox and open it.
5. Type `/mailtest target <AltName>`.
6. Type `/mailtest item <itemID>`.
7. Type `/mailtest status` to check the settings.

## Test sequence (do it on both clients)
Run each test with the tab named in the table. Switch the tab at the mailbox before the test.
Between tests, wait until the item stacks are back in your bags, or put more stacks in your bags.

| Test | Tab shown | Command | Action |
| --- | --- | --- | --- |
| 1 | Send Mail tab (`MailFrameTab2`) | `/mailtest fill N` | Send one mail with up to N stacks attached (1 to 12). |
| `/mailtest delay S` | Set the extra wait in seconds after `BAG_UPDATE_DELAYED` (default 0.5). |
| `/mailtest direct` | Read the output. |
| 2 | Send Mail tab | `/mailtest click 5` | Click the "Send 5" button once. |
| 3 | Inbox tab (`MailFrameTab1`) | `/mailtest click 5` | Click the "Send 5" button once. |
| 4 | Send Mail tab | `/mailtest timer 5` | Do not click. Do not press a key. Wait. |
| 5 | Inbox tab | `/mailtest timer 5` | Do not click. Do not press a key. Wait. |

Each output line starts with `MailTest` and `GetTime()`. Each run ends with a SUMMARY block.
The SUMMARY shows the tab state (`sendTabShown`, `inboxTabShown`), sends tried, success events, failed events, blocked events, pcall errors and seconds between sends.
After the tests, copy the chat lines (or take a screenshot) and send them. Include the client name for each test.

## Second round (after the first result)
The first result: `SendMail` works from a timer and with the Inbox tab shown. Mail 2 used a stale bag slot and got no event.
The probe now waits for `BAG_UPDATE_DELAYED` and an extra delay after each mail, skips locked and used slots, and stops if nothing is attached.
Run these steps on both clients, with at least 12 stacks of the item in your bags:
1. `/mailtest click 5` and click the button once.
2. `/mailtest timer 5` and do not click.
3. `/mailtest fill 12`. This sends one mail with 12 attachments.
4. If mail 2 still gets no event, run `/mailtest delay 1.5` and repeat step 1.
Send the chat output. Look for the lines "waiting for BAG_UPDATE_DELAYED", "delay done" and each "attach" line.

## What the output means
| Result | Meaning |
| --- | --- |
| Test 2 shows N `MAIL_SEND_SUCCESS` events and 0 blocked | One click can send all N mails. The next mail starts from the event handler. |
| Test 2 stops after mail 1 with `ADDON_ACTION_BLOCKED`, `ADDON_ACTION_FORBIDDEN` or a pcall error | One click sends only one mail. Flipside needs one click for each mail. |
| Test 4 shows N success events and 0 blocked | A timer can send mail with no click. |
| Test 4 shows blocked events, a pcall error or `UI_ERROR_MESSAGE` | A timer cannot send mail. Flipside needs a click. |
| Test 1 sends the mail | A slash command counts as a user action for `SendMail`. |
| Test 3 or 5 fails but test 2 or 4 works | The Send Mail tab must be shown. |
| `attach failed` | `ClickSendMailItemButton` did not attach the item. The mail frame state is wrong, or the item is locked. |
| `no event after 10s` | `SendMail` did not give `MAIL_SEND_SUCCESS` or `MAIL_FAILED`. |
| `MAIL_FAILED` | The server refused the mail. Read the `UI_ERROR_MESSAGE` line before it. |
| `seconds between sends` | The time from one `SendMail` call to the next. It shows the server delay between mails. |

Postage shows as `postage copper=` for each mail.

## Slash commands
| Command | Action |
| --- | --- |
| `/mailtest target <Name>` | Set the recipient. |
| `/mailtest item <itemID>` | Set the item. Each mail has one bag slot of this item. |
| `/mailtest click N` | Show a small "Send N" button. One click starts N mails in a row. |
| `/mailtest timer N` | Start N mails from `C_Timer.After(1, ...)`, with no click. |
| `/mailtest fill N` | Send one mail with up to N stacks attached (1 to 12). |
| `/mailtest delay S` | Set the extra wait in seconds after `BAG_UPDATE_DELAYED` (default 0.5). |
| `/mailtest direct` | Send one mail from the slash command. |
| `/mailtest status` | Show the settings and the visible tab. |

The probe logs `MAIL_SEND_SUCCESS`, `MAIL_FAILED`, `MAIL_SEND_INFO_UPDATE`, `MAIL_LOCK_SEND_ITEMS`, `UI_ERROR_MESSAGE`, `ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN`.
It uses no hook and writes to no Blizzard table.
