local manifest = require("Tests.manifest")

describe("CraftClient", function()
    local ns, selected, rows, links

    -- A fake of the TradeSkill API (TBC Anniversary).
    local function tradeSkillApi()
        local api = {
            TradeSkillFrame = { IsShown = function() return true end },
            GetTradeSkillSelectionIndex = function() return selected end,
            GetTradeSkillInfo = function(index)
                local row = rows[index]
                return row and row.name, row and row.type
            end,
            GetTradeSkillNumMade = function() return 1, 3 end,
            GetTradeSkillNumReagents = function(index) return #rows[index].reagents end,
            GetTradeSkillReagentInfo = function(index, position)
                local reagent = rows[index].reagents[position]
                return reagent.name, reagent.icon, reagent.count, 0
            end,
            GetTradeSkillReagentItemLink = function(index, position)
                return links.reagent[rows[index].reagents[position].itemID]
            end,
            GetTradeSkillItemLink = function(index) return rows[index].link end,
            GetTradeSkillIcon = function() return "icon" end,
        }
        return api
    end

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("CraftClient")))("Flipside", ns)
        selected = 2
        links = { reagent = { [11] = "|cffffffff|Hitem:11::::::::|h[Linen]|h|r", [12] = "|Hitem:12::::|h[Thread]|h" } }
        rows = {
            { name = "Cloth", type = "header", reagents = {} },
            {
                name = "Bolt of Linen",
                type = "optimal",
                link = "|cffffffff|Hitem:2996::::::::|h[Bolt]|h|r",
                reagents = {
                    { itemID = 11, name = "Linen", icon = "i11", count = 2 },
                    { itemID = 12, name = "Thread", icon = "i12", count = 1 },
                },
            },
            { name = "Enchant Boots", type = "optimal", link = "|cffffd000|Henchant:7867|h[Enchant]|h|r",
                reagents = { { itemID = 11, name = "Linen", icon = "i11", count = 1 } } },
        }
    end)

    describe("tradeskill path", function()
        local client

        before_each(function()
            client = ns.CraftClient.New(tradeSkillApi())
        end)

        it("picks the TradeSkill API and its events", function()
            assert.are.equal("tradeskill", client:Path())
            assert.is_true(client:Supported())
            assert.are.same({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE" }, client:Events())
            assert.is_not_nil(client:Host())
        end)

        it("reads the reagents, the item and the made range", function()
            local recipe = client:Read()
            assert.are.equal(2, recipe.key)
            assert.are.equal(2996, recipe.itemID)
            assert.are.equal(1, recipe.madeMin)
            assert.are.equal(3, recipe.madeMax)
            assert.are.same({
                { itemID = 11, count = 2, name = "Linen", icon = "i11" },
                { itemID = 12, count = 1, name = "Thread", icon = "i12" },
            }, recipe.reagents)
        end)

        it("gives no item for an enchant", function()
            selected = 3
            local recipe = client:Read()
            assert.is_nil(recipe.itemID)
            assert.are.equal(1, #recipe.reagents)
        end)

        it("gives nil for a header row and for no selection", function()
            selected = 1
            assert.is_nil(client:Read())
            assert.is_nil(client:SelectionKey())
            selected = 0
            assert.is_nil(client:Read())
        end)

        it("follows the selected index in the selection key", function()
            assert.are.equal(2, client:SelectionKey())
            selected = 3
            assert.are.equal(3, client:SelectionKey())
        end)

        it("does not raise if an API call fails", function()
            local api = tradeSkillApi()
            api.GetTradeSkillNumMade = function() error("boom") end
            local recipe = ns.CraftClient.New(api):Read()
            assert.is_nil(recipe.madeMin)
        end)
    end)

    describe("professions path", function()
        local api, recipeInfo, schematic

        before_each(function()
            recipeInfo = { recipeID = 500 }
            schematic = {
                name = "Healing Potion",
                icon = "pi",
                outputItemID = 600,
                quantityMin = 1,
                quantityMax = 2,
                reagentSlotSchematics = {
                    { reagentType = 1, quantityRequired = 3, reagents = { { itemID = 21 }, { itemID = 22 } } },
                    { reagentType = 0, quantityRequired = 1, reagents = { { itemID = 31 } } },
                    { reagentType = 1, quantityRequired = 1, reagents = { { currencyID = 5 } } },
                },
            }
            api = {
                ProfessionsFrame = {
                    CraftingPage = { SchematicForm = { GetRecipeInfo = function() return recipeInfo end } },
                },
                C_TradeSkillUI = { GetRecipeSchematic = function() return schematic end },
                C_Item = {
                    GetItemNameByID = function(id) return "N" .. id end,
                    GetItemIconByID = function(id) return "I" .. id end,
                },
            }
        end)

        it("picks the Professions API and its events", function()
            local client = ns.CraftClient.New(api)
            assert.are.equal("professions", client:Path())
            assert.is_true(client:Supported())
            assert.is_not_nil(client:Host())
            assert.is_false(#client:Events() == 0)
        end)

        it("reads basic slots with the first item of each slot", function()
            local recipe = ns.CraftClient.New(api):Read()
            assert.are.equal(500, recipe.key)
            assert.are.equal(600, recipe.itemID)
            assert.are.equal(2, recipe.madeMax)
            assert.are.same({ { itemID = 21, count = 3, name = "N21", icon = "I21" } }, recipe.reagents)
        end)

        it("gives no item for a recipe with no output item", function()
            schematic.outputItemID = nil
            assert.is_nil(ns.CraftClient.New(api):Read().itemID)
        end)

        it("gives nil when no recipe is selected", function()
            recipeInfo = nil
            local client = ns.CraftClient.New(api)
            assert.is_nil(client:Read())
            assert.is_nil(client:SelectionKey())
        end)
    end)

    describe("no known API", function()
        it("is not supported and still listens for show and close", function()
            local client = ns.CraftClient.New({})
            assert.is_false(client:Supported())
            assert.is_nil(client:Read())
            assert.is_nil(client:Host())
            assert.are.same({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE" }, client:Events())
        end)
    end)
end)
