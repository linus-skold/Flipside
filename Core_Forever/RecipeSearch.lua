local _, ns = ...

-- WoW: Forever profession helper. It adds a "Search AH" button to the Blizzard crafting page.
-- The click saves the basic reagents of the selected recipe as a search list and opens it in the Buying tab.
-- It only reads Blizzard frames (taint). The button is a child of the crafting page and anchors to it.
local RecipeSearch = {}
ns.RecipeSearch = RecipeSearch

local OWNER = "Flipside.RecipeSearch"
local ADDON = "Blizzard_Professions"
local LIST_PREFIX = "Recipe: "
local OPEN_EVENT = "Flipside.SearchListOpen"
local BUTTON_TEMPLATE = "UIPanelButtonTemplate"
local BASIC = 1 -- Enum.CraftingReagentType.Basic (ProfessionConstantsDocumentation.lua:203)
-- The button sits above the Create All button of the crafting page (Blizzard_ProfessionsCrafting.lua:268).
-- Change only this table to move it.
local LAYOUT = { width = 100, height = 22, x = 0, y = 4 }
local TEXT_OPEN = "Search the reagents of this recipe on the Auction House"
local TEXT_CLOSED = "Open the Auction House to search"

-- Returns the basic reagent items of a schematic as a list of { itemID, name }, without duplicates.
-- Modifying, finishing and automatic slots give none. A slot with quality tiers gives each tier.
-- itemName(itemID) is optional and returns the name or nil.
function RecipeSearch.Reagents(schematic, itemName)
    local items, seen = {}, {}
    local slots = type(schematic) == "table" and schematic.reagentSlotSchematics or nil
    if type(slots) ~= "table" then
        return items
    end
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or BASIC
    for _, slot in ipairs(slots) do
        if slot.reagentType == basic and type(slot.reagents) == "table" then
            for _, reagent in ipairs(slot.reagents) do
                local itemID = reagent.itemID
                if type(itemID) == "number" and not seen[itemID] then
                    seen[itemID] = true
                    local name = itemName and itemName(itemID) or nil
                    items[#items + 1] = { itemID = itemID, name = name or ("item:" .. itemID) }
                end
            end
        end
    end
    return items
end

-- Returns the list name and the items of a recipe info, or nil when the recipe has no ID.
function RecipeSearch.Collect(recipeInfo, getSchematic, itemName)
    if type(recipeInfo) ~= "table" or type(recipeInfo.recipeID) ~= "number" then
        return nil
    end
    local schematic = getSchematic(recipeInfo.recipeID, recipeInfo.isRecraft == true)
    local name = LIST_PREFIX .. tostring(recipeInfo.name or recipeInfo.recipeID)
    return name, RecipeSearch.Reagents(schematic, itemName)
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
        lists = function()
            return ns.searchLists
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

-- Save the list of the selected recipe and open it. Returns the list ID, or nil.
local function search(deps, recipeInfo)
    local name, items = RecipeSearch.Collect(recipeInfo, deps.getSchematic, deps.itemName)
    if not name then
        return nil
    end
    if #items == 0 then
        deps.say("this recipe has no reagent to search for")
        return nil
    end
    local lists = deps.lists()
    if not lists then
        deps.say("search lists are not available this session")
        return nil
    end
    local id = lists:Upsert(name, items)
    deps.bus:Emit(OPEN_EVENT, id, true)
    if deps.isAuctionHouseOpen() then
        local tab = deps.buyingTab()
        if tab and tab.Select then
            tab:Select()
        end
    end
    return id
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
        button:SetShown(info ~= nil and type(info.recipeID) == "number")
        button:SetAlpha(deps.isAuctionHouseOpen() and 1 or 0.6)
    end
    button:SetScript("OnClick", function()
        local ok, err = pcall(search, deps, recipeInfo())
        if not ok then
            deps.say("recipe search failed: " .. tostring(err))
        end
    end)
    button:SetScript("OnEnter", function(self)
        local tip = deps.tooltip
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:SetText(deps.isAuctionHouseOpen() and TEXT_OPEN or TEXT_CLOSED)
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
