local _, ns = ...

-- The CSV text of ledger records (SPEC 5.8, "CSV export"). Pure: no frames, no WoW API.
-- One fixed column set holds every record type. A cell is empty where a column does not apply.
local LedgerCsv = {}
ns.LedgerCsv = LedgerCsv

local SECONDS_PER_DAY = 86400
local LINE_END = "\r\n"

-- The header names of the columns, in order.
LedgerCsv.COLUMNS = {
    "time_utc", "character", "type", "source", "item_key", "item_name", "quantity", "money_copper", "records",
    "counterparty", "bid", "buyout", "deposit", "cut", "value", "loot_source", "place", "note",
}

-- The year, month and day of a day number (days since 1970-01-01, UTC).
local function civil(days)
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local year = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local day = doy - math.floor((153 * mp + 2) / 5) + 1
    local month = mp < 10 and mp + 3 or mp - 9
    if month <= 2 then
        year = year + 1
    end
    return year, month, day
end

-- Returns a server time in seconds as UTC text "YYYY-MM-DD HH:MM:SS".
function LedgerCsv.TimeText(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    local days = math.floor(seconds / SECONDS_PER_DAY)
    local rest = seconds - days * SECONDS_PER_DAY
    local year, month, day = civil(days)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d", year, month, day,
        math.floor(rest / 3600), math.floor(rest % 3600 / 60), rest % 60)
end

-- Returns one cell as CSV text (RFC 4180): a cell with a comma, a quote or a line break is in quotes, and a quote
-- inside it is doubled. nil is an empty cell.
function LedgerCsv.Escape(value)
    if value == nil then
        return ""
    end
    local text = tostring(value)
    if text:find('[,"\r\n]') then
        return '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end

local function signedMoney(record)
    local direction = ns.LedgerRecord and ns.LedgerRecord.Direction(record.type)
    if direction == "in" then
        return record.money
    elseif direction == "out" then
        return record.money and -record.money or nil
    end
    return nil
end

-- The cells of a full record, in the order of COLUMNS.
local function recordCells(record)
    return {
        LedgerCsv.TimeText(record.time), record.char, record.type, record.source, record.item, record.itemName,
        record.qty, signedMoney(record), 1, record.counterparty, record.bid, record.buyout, record.deposit,
        record.cut, record.value, record.mob, record.place, record.note,
    }
end

-- The cells of a daily sum: { char, day, source, item, count, qty, moneyIn, moneyOut }. The type is "daily".
local function sumCells(sum)
    return {
        LedgerCsv.TimeText(sum.day * SECONDS_PER_DAY), sum.char, "daily", sum.source, sum.item, nil,
        sum.qty, (sum.moneyIn or 0) - (sum.moneyOut or 0), sum.count,
    }
end

local function line(cells)
    local parts = {}
    for index = 1, #LedgerCsv.COLUMNS do
        parts[index] = LedgerCsv.Escape(cells[index])
    end
    return table.concat(parts, ",")
end

-- Returns the CSV text: the header, then one line for each record and each daily sum, oldest first. Log records
-- (decision logs) are left out. Lines end with CR LF, also the last one.
-- records: full ledger records. sums: daily sums, each with the field char added.
function LedgerCsv.Build(records, sums)
    local rows = {}
    for _, record in ipairs(records or {}) do
        if record.type ~= "log" then
            rows[#rows + 1] = { time = record.time, cells = recordCells(record) }
        end
    end
    for _, sum in ipairs(sums or {}) do
        rows[#rows + 1] = { time = sum.day * SECONDS_PER_DAY, cells = sumCells(sum) }
    end
    for index, row in ipairs(rows) do
        row.order = index
    end
    table.sort(rows, function(a, b)
        if a.time ~= b.time then
            return a.time < b.time
        end
        return a.order < b.order
    end)
    local lines = { table.concat(LedgerCsv.COLUMNS, ",") }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = line(row.cells)
    end
    return table.concat(lines, LINE_END) .. LINE_END
end
