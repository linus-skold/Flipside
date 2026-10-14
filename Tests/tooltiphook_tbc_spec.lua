local manifest = require("Tests.manifest")

local TOC = "Flipside_TBC.toc"

describe("TooltipHook on TBC", function()
    local ns, calls, reports, frames, alt, infoCalls

    local function newFrame(link, owner)
        local f = { scripts = {}, hookCount = 0, link = link, owner = owner }
        function f:HookScript(name, fn)
            self.hookCount = self.hookCount + 1
            self.scripts[name] = fn
        end
        function f:GetItem() return "Name", self.link end
        function f:GetOwner() return self.owner end
        return f
    end

    local function button(bagFrameName, bagID, slot)
        local parent = { GetName = function() return bagFrameName end, GetID = function() return bagID end }
        return { GetParent = function() return parent end, GetID = function() return slot end }
    end

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("TooltipHook", TOC)))("Flipside", ns)
        calls, reports, alt, infoCalls = {}, {}, false, {}
        frames = {
            GameTooltip = newFrame("item:1"),
            ItemRefTooltip = newFrame("item:2"),
            ShoppingTooltip1 = newFrame("item:3"),
            ShoppingTooltip2 = newFrame("item:4"),
        }
    end)

    local function install(extra)
        local opts = {
            report = function(m) reports[#reports + 1] = m end,
            frames = frames,
            isAltDown = function() return alt end,
            containerItemInfo = function(bag, slot)
                infoCalls[#infoCalls + 1] = { bag, slot }
                return { stackCount = 7 }
            end,
        }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return ns.TooltipHook.Install(function(tooltip, link, stack)
            calls[#calls + 1] = { tooltip = tooltip, link = link, stack = stack }
        end, opts)
    end

    it("is the first file in the TOC after Tooltip", function()
        local files = manifest.files(TOC)
        assert.are.equal(manifest.indexOf(files, "Tooltip") + 1, manifest.indexOf(files, "TooltipHook"))
    end)

    it("hooks OnTooltipSetItem on all four frames", function()
        assert.is_table(install())
        for name, f in pairs(frames) do
            assert.are.equal(1, f.hookCount, name)
            assert.is_function(f.scripts.OnTooltipSetItem, name)
        end
    end)

    it("calls onItem with the tooltip and the GetItem link", function()
        install()
        frames.ItemRefTooltip.scripts.OnTooltipSetItem(frames.ItemRefTooltip)
        assert.are.equal(1, #calls)
        assert.are.equal(frames.ItemRefTooltip, calls[1].tooltip)
        assert.are.equal("item:2", calls[1].link)
        assert.is_nil(calls[1].stack)
    end)

    it("hooks each frame only once", function()
        install()
        install()
        assert.are.equal(1, frames.GameTooltip.hookCount)
        assert.are.equal(1, frames.ShoppingTooltip2.hookCount)
    end)

    it("passes a nil link when GetItem gives none", function()
        install()
        frames.GameTooltip.link = nil
        frames.GameTooltip.scripts.OnTooltipSetItem(frames.GameTooltip)
        assert.is_nil(calls[1].link)
    end)

    it("reports once per missing required frame and keeps going without the optional ones", function()
        frames.GameTooltip, frames.ShoppingTooltip1 = nil, nil
        assert.is_nil(install())
        assert.are.same({ "tooltip hook not available" }, reports)
    end)

    it("reports when HookScript is missing", function()
        frames.GameTooltip.HookScript = nil
        frames.ItemRefTooltip.HookScript = nil
        assert.is_nil(install())
        assert.are.equal("tooltip hook not available", reports[1])
    end)

    it("still installs if only ItemRefTooltip is missing", function()
        frames.ItemRefTooltip = nil
        assert.is_table(install())
        assert.are.equal(1, #reports)
        assert.are.equal(1, frames.GameTooltip.hookCount)
    end)

    it("reports a HookScript error", function()
        frames.GameTooltip.HookScript = function() error("boom") end
        assert.is_nil(install())
        assert.is_truthy(reports[1]:find("tooltip hook failed", 1, true))
    end)

    describe("stack count", function()
        it("reads the ContainerFrame parent ID with Alt down", function()
            alt = true
            frames.GameTooltip.owner = button("ContainerFrame2", 1, 6)
            install()
            frames.GameTooltip.scripts.OnTooltipSetItem(frames.GameTooltip)
            assert.are.equal(7, calls[1].stack)
            assert.are.same({ { 1, 6 } }, infoCalls)
        end)

        it("gives no stack count without Alt", function()
            frames.GameTooltip.owner = button("ContainerFrame2", 1, 6)
            install()
            frames.GameTooltip.scripts.OnTooltipSetItem(frames.GameTooltip)
            assert.is_nil(calls[1].stack)
            assert.are.equal(0, #infoCalls)
        end)

        it("gives no stack count for an owner outside a ContainerFrame", function()
            alt = true
            frames.GameTooltip.owner = button("BankFrame", 0, 3)
            install()
            frames.GameTooltip.scripts.OnTooltipSetItem(frames.GameTooltip)
            assert.is_nil(calls[1].stack)
            assert.are.equal(0, #infoCalls)
        end)

        it("gives no stack count when there is no owner", function()
            alt = true
            install()
            frames.GameTooltip.scripts.OnTooltipSetItem(frames.GameTooltip)
            assert.is_nil(calls[1].stack)
        end)
    end)
end)
