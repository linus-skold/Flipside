local manifest = require("Tests.manifest")

describe("TooltipHook", function()
    local ns, calls, onItem, reports, processor

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("TooltipHook")))("Flipside", ns)
        calls, reports = {}, {}
        onItem = function(tooltip, link)
            calls[#calls + 1] = { tooltip = tooltip, link = link }
        end
        processor = { AddTooltipPostCall = function(kind, fn) processor.kind, processor.fn = kind, fn end }
    end)

    local function install(extra)
        local opts = { report = function(m) reports[#reports + 1] = m end, processor = processor, itemType = 0,
            itemLinkByGUID = function(guid) return guid == "G1" and "item:77" or nil end }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return ns.TooltipHook.Install(onItem, opts)
    end

    it("registers one item post call", function()
        assert.is_function(install())
        assert.are.equal(0, processor.kind)
    end)

    it("reports a missing processor", function()
        assert.is_nil(install({ processor = false }))
        assert.is_nil(install({ itemType = nil, processor = {} }))
        assert.are.equal("tooltip hook not available", reports[1])
    end)

    it("reports a failing registration", function()
        processor.AddTooltipPostCall = function() error("nope") end
        assert.is_nil(install())
        assert.is_truthy(reports[1]:find("tooltip hook failed", 1, true))
    end)

    it("gives the link from the guid, the hyperlink or the id", function()
        install()
        local tip = {}
        processor.fn(tip, { guid = "G1" })
        processor.fn(tip, { hyperlink = "item:5" })
        processor.fn(tip, { id = 9 })
        processor.fn(tip, { guid = "G2", id = 3 })
        assert.are.equal("item:77", calls[1].link)
        assert.are.equal("item:5", calls[2].link)
        assert.are.equal("item:9", calls[3].link)
        assert.are.equal("item:3", calls[4].link)
        assert.are.equal(tip, calls[1].tooltip)
    end)

    it("gives a nil link without usable data", function()
        install()
        processor.fn({}, {})
        processor.fn({}, nil)
        assert.is_nil(calls[1].link)
        assert.are.equal(2, #calls)
    end)

    it("reports a failing link lookup and skips the item", function()
        install({ itemLinkByGUID = function() error("bad guid") end })
        processor.fn({}, { guid = "G1" })
        assert.are.equal(0, #calls)
        assert.is_truthy(reports[1]:find("bad guid", 1, true))
    end)
end)
