local manifest = require("Tests.manifest")

describe("RecipeSearch", function()
    local ns, bus, deps, calls, said, page, form, recipeInfo, schematic, button, lists, buying, ahOpen, hooks, built

    -- A Blizzard frame fake: writing a field raises an error (taint rule).
    local function guarded(fields)
        return setmetatable({}, {
            __index = fields,
            __newindex = function(_, key)
                error("write to a Blizzard field: " .. tostring(key), 2)
            end,
        })
    end

    local function makeButton()
        local b = { shown = true, alpha = 1, scripts = {}, points = {} }
        function b.SetSize() end
        function b:SetText(text) self.text = text end
        function b:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function b:SetShown(value) self.shown = value end
        function b:SetAlpha(value) self.alpha = value end
        function b:SetScript(name, fn) self.scripts[name] = fn end
        return b
    end

    local function makeTooltip()
        local t = { lines = {} }
        function t.SetOwner() end
        function t:SetText(text) self.lines[#self.lines + 1] = text end
        function t:Show() self.shown = true end
        function t:Hide() self.shown = false end
        return t
    end

    local function makeDeps(extra)
        local d = {
            bus = bus,
            getPage = function() return page end,
            getSchematic = function(recipeID, isRecraft)
                calls[#calls + 1] = { "schematic", recipeID, isRecraft }
                return schematic
            end,
            itemName = function(id) return "Item" .. id end,
            lists = function() return lists end,
            buyingTab = function() return buying end,
            isAuctionHouseOpen = function() return ahOpen end,
            openEvent = "AH_OPEN",
            closeEvent = "AH_CLOSE",
            say = function(text) said[#said + 1] = text end,
            hook = function(target, name, fn)
                hooks[#hooks + 1] = { target = target, name = name, fn = fn }
            end,
            createFrame = function(kind, _, parent, template)
                built[#built + 1] = { kind = kind, parent = parent, template = template }
                button = makeButton()
                return button
            end,
            tooltip = makeTooltip(),
        }
        for k, v in pairs(extra or {}) do
            d[k] = v
        end
        return d
    end

    local function slot(reagentType, ids)
        local reagents = {}
        for _, id in ipairs(ids) do
            reagents[#reagents + 1] = { itemID = id }
        end
        return { reagentType = reagentType, reagents = reagents }
    end

    before_each(function()
        ns = { ReportError = function() end }
        assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
        assert(loadfile(manifest.path("RecipeSearch")))("Flipside", ns)
        bus = ns.EventBus.New()
        calls, said, hooks, built = {}, {}, {}, {}
        ahOpen = true
        recipeInfo = { recipeID = 100, name = "Healing Potion", isRecraft = false }
        schematic = {
            reagentSlotSchematics = {
                slot(1, { 11 }),
                slot(1, { 21, 22, 23 }),
                slot(0, { 31 }),
                slot(2, { 41 }),
                slot(1, { 11 }),
                { reagentType = 1, reagents = { { currencyID = 5 } } },
            },
        }
        form = guarded({ GetRecipeInfo = function() return recipeInfo end })
        page = guarded({ SchematicForm = form, CreateAllButton = guarded({}) })
        lists = {
            Upsert = function(_, name, items)
                calls[#calls + 1] = { "upsert", name, items }
                return "L1"
            end,
        }
        buying = { Select = function() calls[#calls + 1] = { "select" } end }
        bus:Subscribe("Flipside.SearchListOpen", "spec", function(event, id, flag)
            calls[#calls + 1] = { "emit", event, id, flag }
        end)
    end)

    local function click()
        button.scripts.OnClick()
    end

    describe("Reagents", function()
        it("keeps basic items, each quality tier, and drops duplicates, optional slots and currencies", function()
            local items = ns.RecipeSearch.Reagents(schematic, function(id) return "N" .. id end)
            local ids = {}
            for _, item in ipairs(items) do
                ids[#ids + 1] = item.itemID
            end
            assert.are.same({ 11, 21, 22, 23 }, ids)
            assert.are.equal("N21", items[2].name)
        end)

        it("uses a placeholder name when the name is not known", function()
            local items = ns.RecipeSearch.Reagents(schematic, function() return nil end)
            assert.are.equal("item:11", items[1].name)
        end)

        it("returns an empty list for a missing schematic", function()
            assert.are.same({}, ns.RecipeSearch.Reagents(nil))
        end)
    end)

    describe("Attach", function()
        it("creates the button once, as a child of the crafting page", function()
            deps = makeDeps()
            ns.RecipeSearch.Attach(deps)
            bus:Emit("ADDON_LOADED", "Blizzard_Professions")
            assert.are.equal(1, #built)
            assert.are.equal(page, built[1].parent)
            assert.are.equal("Search AH", button.text)
        end)

        it("creates the button only after the profession addon loads", function()
            local present
            deps = makeDeps({ getPage = function() return present end })
            ns.RecipeSearch.Attach(deps)
            assert.are.equal(0, #built)
            bus:Emit("ADDON_LOADED", "Other")
            assert.are.equal(0, #built)
            present = page
            bus:Emit("ADDON_LOADED", "Blizzard_Professions")
            bus:Emit("ADDON_LOADED", "Blizzard_Professions")
            assert.are.equal(1, #built)
            assert.is_false(bus:HasSubscribers("ADDON_LOADED"))
        end)

        it("shows the button only while a recipe is selected", function()
            deps = makeDeps()
            ns.RecipeSearch.Attach(deps)
            assert.is_true(button.shown)
            assert.are.equal("Init", hooks[1].name)
            assert.are.equal(form, hooks[1].target)
            recipeInfo = nil
            hooks[1].fn()
            assert.is_false(button.shown)
            recipeInfo = { recipeID = 7, name = "X" }
            hooks[1].fn()
            assert.is_true(button.shown)
        end)

        it("anchors above the Create All button and writes no Blizzard field", function()
            deps = makeDeps()
            assert.has_no.errors(function()
                ns.RecipeSearch.Attach(deps)
                click()
                hooks[1].fn()
            end)
            assert.are.equal(page.CreateAllButton, button.points[1][2])
        end)

        it("does nothing without a bus or hook", function()
            assert.has_no.errors(function()
                ns.RecipeSearch.Attach({ bus = false, getPage = function() return page end })
            end)
        end)
    end)

    describe("click", function()
        before_each(function()
            deps = makeDeps()
            ns.RecipeSearch.Attach(deps)
        end)

        it("saves the list, emits the open event and opens the Buying tab", function()
            click()
            assert.are.same({ "schematic", 100, false }, calls[1])
            assert.are.equal("upsert", calls[2][1])
            assert.are.equal("Recipe: Healing Potion", calls[2][2])
            assert.are.equal(4, #calls[2][3])
            assert.are.same({ "emit", "Flipside.SearchListOpen", "L1", true }, calls[3])
            assert.are.same({ "select" }, calls[4])
        end)

        it("passes the recraft flag", function()
            recipeInfo.isRecraft = true
            click()
            assert.are.same({ "schematic", 100, true }, calls[1])
        end)

        it("saves the list but does not open the tab when the Auction House is closed", function()
            ahOpen = false
            click()
            assert.are.equal("upsert", calls[2][1])
            assert.are.equal("emit", calls[3][1])
            assert.is_nil(calls[4])
        end)

        it("shows the matching tooltip text", function()
            button.scripts.OnEnter(button)
            ahOpen = false
            button.scripts.OnEnter(button)
            assert.are.equal("Open the Auction House to search", deps.tooltip.lines[2])
            assert.is_truthy(deps.tooltip.lines[1]:find("Auction House"))
            button.scripts.OnLeave()
            assert.is_false(deps.tooltip.shown)
        end)

        it("updates the look when the Auction House opens or closes", function()
            ahOpen = false
            bus:Emit("AH_CLOSE")
            assert.are.equal(0.6, button.alpha)
            ahOpen = true
            bus:Emit("AH_OPEN")
            assert.are.equal(1, button.alpha)
        end)

        it("prints one line and does nothing when the list module is missing", function()
            lists = nil
            click()
            assert.are.equal(1, #said)
            assert.are.equal(1, #calls)
        end)

        it("prints one line when the recipe has no reagent", function()
            schematic = { reagentSlotSchematics = {} }
            click()
            assert.are.equal(1, #said)
            assert.is_nil(calls[2])
        end)

        it("reports an error from the list module", function()
            lists = { Upsert = function() error("boom") end }
            click()
            assert.is_truthy(said[1]:find("boom"))
        end)

        it("does nothing without a selected recipe", function()
            recipeInfo = nil
            click()
            assert.are.equal(0, #calls)
            assert.are.equal(0, #said)
        end)
    end)
end)
