local manifest = require("Tests.manifest")

local function read(path)
    local handle = assert(io.open(path, "rb"))
    local text = handle:read("*a")
    handle:close()
    return text
end

local MODULES = { "LedgerRecord", "LedgerBuffer", "LedgerStore", "LedgerLoader" }

describe("ledger packaging", function()
    for _, toc in ipairs({ "Flipside.toc", "Flipside_TBC.toc" }) do
        it(toc .. " lists the ledger modules in load order before Init", function()
            local files = manifest.files(toc)
            local last = manifest.indexOf(files, "Init")
            local previous = manifest.indexOf(files, "TooltipLines")
            for _, name in ipairs(MODULES) do
                local index = manifest.indexOf(files, name)
                assert.is_not_nil(index, name .. " is not in " .. toc)
                assert.is_true(index > previous, name .. " is out of order")
                assert.is_true(index < last)
                previous = index
            end
        end)
    end

    it("names the ledger SavedVariables of each flavour in the flavour file", function()
        assert.is_truthy(read("Core_Forever/Flavour.lua"):find('ledger = "FlipsideLedgerDB"', 1, true))
        assert.is_truthy(read("Core_TBC/Flavour.lua"):find('ledger = "FlipsideLedgerDB_TBC"', 1, true))
    end)

    it("gives the ledger addon a TOC for each flavour", function()
        local forever = read("Flipside_Ledger/Flipside_Ledger.toc")
        local tbc = read("Flipside_Ledger/Flipside_Ledger_TBC.toc")
        local main = read("Flipside.toc")
        local mainTbc = read("Flipside_TBC.toc")
        for _, text in ipairs({ forever, tbc }) do
            assert.is_truthy(text:find("## LoadOnDemand: 1", 1, true))
            assert.is_truthy(text:find("## Dependencies: Flipside", 1, true))
        end
        assert.is_truthy(forever:find("## SavedVariables: FlipsideLedgerDB\n", 1, true))
        assert.is_truthy(tbc:find("## SavedVariables: FlipsideLedgerDB_TBC\n", 1, true))
        assert.are.equal(main:match("## Interface: (%d+)"), forever:match("## Interface: (%d+)"))
        assert.are.equal(mainTbc:match("## Interface: (%d+)"), tbc:match("## Interface: (%d+)"))
        assert.are.same({}, manifest.files("Flipside_Ledger/Flipside_Ledger.toc"))
    end)

    it("ships both folders in the release", function()
        local pkgmeta = read(".pkgmeta")
        assert.is_truthy(pkgmeta:find("package-as: Flipside\n", 1, true))
        assert.is_truthy(pkgmeta:find("move-folders:\n  Flipside/Flipside_Ledger: Flipside_Ledger", 1, true))
    end)
end)
