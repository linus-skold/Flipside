local _, ns = ...

-- Thin adapter between the profession window of the client and the craft panel.
-- Two paths. The "tradeskill" path is the old TradeSkill API (TBC Anniversary). The "professions" path is the
-- Professions window API (WoW: Forever). The path follows from the API that exists, not from the flavour.
-- api is the table that holds the client globals (_G by default). Each call is guarded with pcall.
-- Client source: Gethe/wow-ui-source, branch classic_anniversary (Blizzard_TradeSkillUI/TBC) and branch forever
-- (Blizzard_Professions, Blizzard_APIDocumentationGenerated).
local CraftClient = {}
ns.CraftClient = CraftClient

CraftClient.UNSUPPORTED = "Not supported on this client"

local BASIC_REAGENT = 1 -- Enum.CraftingReagentType.Basic

local EVENTS = {
    -- No known path: the panel still opens and says that the client is not supported.
    none = { "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE" },
    tradeskill = { "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE" },
    professions = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
        "TRADE_SKILL_CLOSE" },
}

local Client = {}
Client.__index = Client

-- Call fn and return its results, or nothing if it fails.
local function guarded(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then
        return a, b, c, d
    end
    return nil
end

local function itemIDOfLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("|Hitem:(%d+)"))
end

function CraftClient.New(api)
    return setmetatable({ api = api or _G }, Client)
end

-- Return "professions", "tradeskill" or nil.
function Client:Path()
    local api = self.api
    local ui = api.C_TradeSkillUI
    if type(ui) == "table" and type(ui.GetRecipeSchematic) == "function" then
        return "professions"
    end
    if type(api.GetTradeSkillSelectionIndex) == "function" and type(api.GetTradeSkillInfo) == "function"
        and type(api.GetTradeSkillNumReagents) == "function" and type(api.GetTradeSkillReagentInfo) == "function" then
        return "tradeskill"
    end
    return nil
end

function Client:Supported()
    return self:Path() ~= nil
end

-- Return the game events that make the panel refresh.
function Client:Events()
    return EVENTS[self:Path() or "none"]
end

-- Return the Blizzard profession frame, or nil if it does not exist yet.
function Client:Host()
    local path = self:Path()
    if path == "professions" then
        return self.api.ProfessionsFrame
    elseif path == "tradeskill" then
        return self.api.TradeSkillFrame
    end
    return nil
end

-- The "professions" path: the recipe ID of the recipe on the crafting page, or nil.
function Client:_RecipeID()
    local page = self.api.ProfessionsFrame and self.api.ProfessionsFrame.CraftingPage
    local form = page and page.SchematicForm
    if not (form and type(form.GetRecipeInfo) == "function") then
        return nil
    end
    local info = guarded(form.GetRecipeInfo, form)
    return type(info) == "table" and type(info.recipeID) == "number" and info.recipeID or nil
end

-- The "tradeskill" path: the index of a selected recipe row, or nil (no row, or a header row).
function Client:_Index()
    local api = self.api
    local index = guarded(api.GetTradeSkillSelectionIndex)
    if type(index) ~= "number" or index < 1 then
        return nil
    end
    local _, skillType = guarded(api.GetTradeSkillInfo, index)
    if skillType == nil or skillType == "header" then
        return nil
    end
    return index
end

-- Return a cheap key for the selected recipe, or nil. The panel compares keys to see a change of the selection.
function Client:SelectionKey()
    local path = self:Path()
    if path == "professions" then
        return self:_RecipeID()
    elseif path == "tradeskill" then
        return self:_Index()
    end
    return nil
end

local function itemName(api, itemID)
    local items = api.C_Item
    return type(items) == "table" and guarded(items.GetItemNameByID, itemID) or nil
end

local function itemIcon(api, itemID)
    local items = api.C_Item
    return type(items) == "table" and guarded(items.GetItemIconByID, itemID) or nil
end

function Client:_ReadProfessions()
    local api = self.api
    local recipeID = self:_RecipeID()
    if not recipeID then
        return nil
    end
    local schematic = guarded(api.C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if type(schematic) ~= "table" then
        return nil
    end
    local basic = type(api.Enum) == "table" and api.Enum.CraftingReagentType
        and api.Enum.CraftingReagentType.Basic or BASIC_REAGENT
    local reagents = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        -- Only basic slots count. A slot with quality tiers gives its first (lowest) item.
        local first = slot.reagentType == basic and slot.reagents and slot.reagents[1] or nil
        if first and type(first.itemID) == "number" then
            reagents[#reagents + 1] = {
                itemID = first.itemID,
                count = slot.quantityRequired or 0,
                name = itemName(api, first.itemID),
                icon = itemIcon(api, first.itemID),
            }
        end
    end
    return {
        key = recipeID,
        name = schematic.name,
        icon = schematic.icon,
        itemID = type(schematic.outputItemID) == "number" and schematic.outputItemID or nil,
        madeMin = schematic.quantityMin,
        madeMax = schematic.quantityMax,
        reagents = reagents,
    }
end

function Client:_ReadTradeSkill()
    local api = self.api
    local index = self:_Index()
    if not index then
        return nil
    end
    local name = guarded(api.GetTradeSkillInfo, index)
    local madeMin, madeMax = guarded(api.GetTradeSkillNumMade, index)
    local reagents = {}
    local count = guarded(api.GetTradeSkillNumReagents, index) or 0
    for position = 1, count do
        local reagentName, icon, needed = guarded(api.GetTradeSkillReagentInfo, index, position)
        local itemID = itemIDOfLink(guarded(api.GetTradeSkillReagentItemLink, index, position))
        if itemID then
            reagents[#reagents + 1] = { itemID = itemID, count = needed or 0, name = reagentName, icon = icon }
        end
    end
    -- An enchant has a link that is not an item link, so it has no item.
    local itemID = itemIDOfLink(guarded(api.GetTradeSkillItemLink, index))
    return {
        key = index,
        name = name,
        icon = guarded(api.GetTradeSkillIcon, index),
        itemID = itemID,
        madeMin = madeMin,
        madeMax = madeMax,
        reagents = reagents,
    }
end

-- Return the selected recipe: { key, name, icon, itemID, madeMin, madeMax, reagents }, or nil if nothing is selected.
-- reagents is a list of { itemID, count, name, icon }. itemID is nil if the recipe makes no item.
function Client:Read()
    local path = self:Path()
    if path == "professions" then
        return self:_ReadProfessions()
    elseif path == "tradeskill" then
        return self:_ReadTradeSkill()
    end
    return nil
end
