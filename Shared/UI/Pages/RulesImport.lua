local _, ns = ...

-- The import flow of the rules: paste dialog, preview, confirm, apply.
-- The Groups page and the Operations page share it.

local RulesImport = {}
ns.RulesImport = RulesImport

local IMPORT_CONFIRM = "FLIPSIDE_IMPORT_CONFIRM"
local IMPORT_DIALOG = "FLIPSIDE_IMPORT_DIALOG"

-- Return the text of an import preview in plain words.
function RulesImport.Describe(parentName, summary)
    local lines = {
        string.format('Import below "%s":', parentName),
        "Groups: " .. summary.groups,
        string.format("Items: %d (%d move from other groups)", summary.items, summary.itemsMoved),
        string.format("Operations: %d new, %d reused", summary.operationsNew, summary.operationsReused),
        string.format("Custom sources: %d new, %d reused", summary.customNew, summary.customReused),
    }
    if #summary.renames > 0 then
        local parts = {}
        for _, rename in ipairs(summary.renames) do
            parts[#parts + 1] = string.format('%s "%s" becomes "%s"', rename.kind, rename.from, rename.to)
        end
        lines[#lines + 1] = "Renames: " .. table.concat(parts, "; ")
    end
    return table.concat(lines, "\n")
end

-- Open the paste dialog. The import goes below the group options.parentID.
-- deps: rules, customSources and compile(text).
-- options: parentID, say(text, good) (good is true for a success), refresh(),
-- onApplied(result) (runs after a good import, before refresh). Returns the dialog, or nil when import is off.
function RulesImport.Open(deps, options)
    local Kit, rules, say = ns.Kit, deps.rules, options.say
    if not deps.customSources then
        say("import is not available")
        return nil
    end
    local parentID = options.parentID

    local function apply(data)
        local ok, result = ns.RulesExport.Apply(rules, deps.customSources, data, parentID, deps.compile)
        if not ok then
            say(tostring(result))
            options.refresh()
            return
        end
        if options.onApplied then
            options.onApplied(result)
        end
        options.refresh()
        say(string.format("Imported %d groups and %d items", result.groups, result.items), true)
    end

    local function onText(text)
        local data, message = ns.RulesExport.Parse(text)
        if not data then
            say(tostring(message))
            return
        end
        local summary, previewMessage = ns.RulesExport.Preview(rules, deps.customSources, data, parentID)
        if not summary then
            say(tostring(previewMessage))
            return
        end
        say("")
        Kit.Confirm(IMPORT_CONFIRM, RulesImport.Describe(tostring(rules:Name(parentID)), summary), function()
            apply(data)
        end)
    end

    say("")
    local dialog = Kit.EditorDialog(IMPORT_DIALOG, {
        help = "Paste an export text. It is imported below the group in the title.",
    })
    dialog:Open("Import below " .. tostring(rules:Name(parentID)), "", onText)
    return dialog
end
