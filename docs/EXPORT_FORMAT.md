# Flipside rules export format

Flipside exports a group, its sub-groups, their items, the operations they use and the custom sources those operations use. The format is plain text. You can read it and compare two exports with a diff tool. It has no compression and no Base64. Flipside does not accept TSM strings.

## Lines

- The first line is the header: `FLIPSIDE-RULES 1`. The number is the format version.
- Each line is one record. Fields are separated by a bar (`|`).
- A line that starts with `#`, and an empty line, are ignored. Windows line endings are accepted.
- Inside a field, these escapes are used: `\\` for a backslash, `\|` for a bar, `\n` for a line feed, `\r` for a carriage return. Names can contain any text.

## Records

| Record | Fields | Meaning |
|---|---|---|
| `group` | `id`, `parent id`, `name` | A group. The id is local to the file. The first group is the exported group and has an empty parent id. A parent comes before its children. |
| `item` | `group id`, `item key` | An item in a group. The key follows the Flipside item key rules. It never contains a name. |
| `op` | `id`, `type`, `name` | An operation. The type is `selling`, `buying` or `vendoring`. |
| `set` | `op id`, `key`, `tag`, `value` | One setting of an operation. The tag is `s` for text (formulas too), `n` for a number, `b` for `true` or `false`. |
| `attach` | `group id`, `type`, `op id` | A group uses an operation of this type. |
| `source` | `name`, `formula text` | A custom source. |

The exported group also gets an `attach` record for each operation that it inherits from a group outside the export.

## Example

```text
FLIPSIDE-RULES 1
group|1||Herbs
group|2|1|Flowers
item|1|100
item|2|200
op|1|selling|Fast sell
set|1|minPrice|s|mybase
set|1|normalPrice|s|scanmarket
set|1|maxPrice|s|2 * scanmarket
set|1|undercut|n|1
set|1|duration|n|24
set|1|postCap|n|0
set|1|belowMin|s|skip
set|1|aboveMax|s|postAtMax
set|1|cancelUndercut|b|true
set|1|maxDataAgeHours|n|72
set|1|minSamples|n|3
attach|1|selling|1
source|mybase|scanmarket * 2
```

## Import rules

- The player picks a parent group. The exported group goes below it.
- If the parent has a sub-group with the same name, the new group gets ` (2)`, ` (3)` and so on.
- An operation with the same type, name and settings is reused.
- If the name is taken and the settings differ, the operation is imported as `<name> (imported)`, then `<name> (imported 2)` and so on.
- A custom source with the same name and the same text is reused.
- If the text differs, the source is imported as `<name>_imported`. Each imported formula that used the old name uses the new name.
- An item that is in another group moves to the imported group. The preview shows how many.
- A file with a newer version number is refused.
- Flipside shows a summary and asks before it changes anything.
- The import is not all-or-nothing. It checks the file, the depth limit and the names first. If a later step fails, the import stops and tells which step. Earlier steps stay in the profile.
