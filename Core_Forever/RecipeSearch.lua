local _, ns = ...

-- WoW: Forever profession helper. It adds a "Search AH" button to the Blizzard crafting page.
-- The click opens the basic reagents of the selected recipe, with their amounts, as an unsaved list in the Buying tab.
-- The click stores nothing. The user saves the list in the Buying tab (Save button).
-- It only reads Blizzard frames (taint). The button is a child of the crafting page and anchors to it.
local RecipeSearch = {}
ns.RecipeSearch = RecipeSearch

local OWNER = "Flipside.RecipeSearch"
local ADDON = "Blizzard_Professions"
local LIST_PREFIX = "Recipe: "
local TEMP_EVENT = "Flipside.SearchListTemp"
local BUTTON_TEMPLATE = "UIPanelButtonTemplate"
local BASIC = 1 -- Enum.CraftingReagentType.Basic (ProfessionConstantsDocumentation.lua:203)
-- The button sits above the Create All button of the crafting page (Blizzard_ProfessionsCrafting.lua:268).
-- Change only this table to move it.
local LAYOUT = { width = 100, height = 22, x = 0, y = 4 }
local TEXT = "Search the reagents of this recipe on the Auction House"

-- Returns the basic reagent items of a schematic as a list of { itemID, name, count }, without duplicates.
-- Modifying, finishing and automatic slots give none. A slot with quality tiers gives each tier.
-- count is quantityRequired of the slot times amount (a whole number, 1 if missing). An item in two slots adds up.
-- Only the first tier of a slot has the count. The other tiers have none, because the user buys one tier.
-- itemName(itemID) is optional and returns the name or nil.
function RecipeSearch.Reagents(schematic, itemName, amount)
    amount = (type(amount) == "number" and amount >= 1) and math.floor(amount) or 1
    local items, seen = {}, {}
    local slots = type(schematic) == "table" and schematic.reagentSlotSchematics or nil
    if type(slots) ~= "table" then
        return items
    end
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or BASIC
    for _, slot in ipairs(slots) do
        if slot.reagentType == basic and type(slot.reagents) == "table" then
            local required = type(slot.quantityRequired) == "number" and slot.quantityRequired >= 1
                and math.floor(slot.quantityRequired) or 1
            for tier, reagent in ipairs(slot.reagents) do
                local itemID = reagent.itemID
                local count = tier == 1 and required * amount or nil
                if type(itemID) == "number" then
                    if seen[itemID] then
                        if count then
                            seen[itemID].count = (seen[itemID].count or 0) + count
                        end
                    else
                        local name = itemName and itemName(itemID) or nil
                        local item = { itemID = itemID, name = name or ("item:" .. itemID), count = count }
                        seen[itemID] = item
                        items[#items + 1] = item
                    end
                end
            end
        end
    end
    return items
end

-- Returns the list name and the items of a recipe info, or nil when the recipe has no ID.
function RecipeSearch.Collect(recipeInfo, getSchematic, itemName, amount)
    if type(recipeInfo) ~= "table" or type(recipeInfo.recipeID) ~= "number" then
        return nil
    end
    local schematic = getSchematic(recipeInfo.recipeID, recipeInfo.isRecraft == true)
    local name = LIST_PREFIX .. tostring(recipeInfo.name or recipeInfo.recipeID)
    return name, RecipeSearch.Reagents(schematic, itemName, amount)
end

local function defaultItemName(itemID)
    local info = ns.itemCache and ns.itemCache:Get(itemID)
    if info and info.name then
        return info.name
    end
    return C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID) or nil
end

local function defaultDeps()
    return {
        bus = ns.bus,
        getPage = function()
            return ProfessionsFrame and ProfessionsFrame.CraftingPage or nil
        end,
        getSchematic = function(recipeID, isRecraft)
            return C_TradeSkillUI.GetRecipeSchematic(recipeID, isRecraft)
        end,
        itemName = defaultItemName,
        -- The craft amount of the profession window (the box next to Create All). 1 if the page gives none.
        craftAmount = function(page)
            local box = page and page.CreateMultipleInputBox
            local ok, value = pcall(function()
                return box and box:GetValue()
            end)
            return ok and type(value) == "number" and value >= 1 and value or 1
        end,
        buyingTab = function()
            return ns.auctionTabs and ns.auctionTabs.buying or nil
        end,
        isAuctionHouseOpen = function()
            return ns.IsAuctionHouseOpen and ns.IsAuctionHouseOpen() or false
        end,
        openEvent = ns.AuctionClient and ns.AuctionClient.OpenEvent() or nil,
        closeEvent = ns.AuctionClient and ns.AuctionClient.CloseEvent() or nil,
        say = function(text)
            if ns.ReportError then
                ns.ReportError(text)
            end
        end,
        hook = hooksecurefunc,
        createFrame = CreateFrame,
        tooltip = GameTooltip,
    }
end

-- Open the list of the selected recipe, unsaved. Returns true, or nil.
local function search(deps, recipeInfo, amount)
    local name, items = RecipeSearch.Collect(recipeInfo, deps.getSchematic, deps.itemName, amount)
    if not name then
        return nil
    end
    if #items == 0 then
        deps.say("this recipe has no reagent to search for")
        return nil
    end
    deps.bus:Emit(TEMP_EVENT, name, items, true)
    if deps.isAuctionHouseOpen() then
        local tab = deps.buyingTab()
        if tab and tab.Select then
            tab:Select()
        end
    end
    return true
end

local function build(deps, page)
    local form = page.SchematicForm
    local button = deps.createFrame("Button", nil, page, BUTTON_TEMPLATE)
    button:SetSize(LAYOUT.width, LAYOUT.height)
    button:SetText("Search AH")
    local anchor = page.CreateAllButton
    if anchor then
        button:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", LAYOUT.x, LAYOUT.y)
    else
        button:SetPoint("BOTTOMRIGHT", form or page, "BOTTOMRIGHT", -LAYOUT.x, LAYOUT.y)
    end

    local function recipeInfo()
        return form and form:GetRecipeInfo() or nil
    end
    local function refresh()
        local info = recipeInfo()
        -- The button shows only while the Auction House is open.
        button:SetShown(info ~= nil and type(info.recipeID) == "number" and deps.isAuctionHouseOpen() == true)
    end
    button:SetScript("OnClick", function()
        local ok, err = pcall(search, deps, recipeInfo(), deps.craftAmount and deps.craftAmount(page) or 1)
        if not ok then
            deps.say("recipe search failed: " .. tostring(err))
        end
    end)
    button:SetScript("OnEnter", function(self)
        local tip = deps.tooltip
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:SetText(TEXT)
        tip:Show()
    end)
    button:SetScript("OnLeave", function()
        deps.tooltip:Hide()
    end)

    -- The form runs Init for each selection and for no selection (Blizzard_ProfessionsRecipeSchematicForm.lua:353).
    if form then
        deps.hook(form, "Init", refresh)
    end
    if deps.openEvent then
        deps.bus:Subscribe(deps.openEvent, OWNER, refresh)
    end
    if deps.closeEvent then
        deps.bus:Subscribe(deps.closeEvent, OWNER, refresh)
    end
    refresh()
    return button
end

-- Add the button now if the profession frame exists, or when its addon loads. Returns the deps used.
-- The function build runs once.
function RecipeSearch.Attach(overrides)
    local deps = defaultDeps()
    for key, value in pairs(overrides or {}) do
        deps[key] = value
    end
    if not deps.bus or not deps.hook or not deps.createFrame then
        return deps
    end
    local built = false
    local function tryBuild()
        local page = deps.getPage()
        if built or not page then
            return
        end
        built = true
        deps.bus:Unsubscribe("ADDON_LOADED", OWNER)
        local ok, err = pcall(build, deps, page)
        if not ok then
            deps.say("the Search AH button is not available: " .. tostring(err))
        end
    end
    deps.bus:Subscribe("ADDON_LOADED", OWNER, function(_, name)
        if name == ADDON then
            tryBuild()
        end
    end)
    tryBuild()
    return deps
end
