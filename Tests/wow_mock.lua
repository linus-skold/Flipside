-- Small mocked WoW API for busted specs. Call mock.reset() before each test.

local M = {}

local GLOBAL_NAMES = {
    "ACCEPT", "CANCEL", "CLOSE", "SAVE", "GetCursorPosition",
    "C_AuctionHouse", "C_Container", "C_Item", "C_Timer", "CreateFrame", "DEFAULT_CHAT_FRAME",
    "C_GameRules", "FlipsideDB", "FlipsideScanDB", "GetBuildInfo", "GetCurrentRegionName", "GetNormalizedRealmName",
    "GetServerTime", "GetTime", "GetCurrentRegion", "IsTestBuild", "IsBetaBuild", "IsPublicTestClient",
    "SLASH_FLIPSIDE1", "SLASH_FLIPSIDE2",
    "SLASH_SCANTEST1", "ScanTestDB", "SlashCmdList",
    "StaticPopupDialogs", "StaticPopup_Show", "UnitName", "WOW_PROJECT_ID", "date", "debugprofilestop", "time",
    "UISpecialFrames", "UIParent", "GameTooltip", "GetMoneyString", "GetMoney", "issecretvalue",
    "PanelTemplates_SetNumTabs", "PlaySound", "SOUNDKIT",
    "PanelTemplates_SetTab", "PanelTemplates_TabResize", "InCombatLockdown", "ScrollUtil", "CreateDataProvider",
    "CreateScrollBoxListLinearView", "CreateTreeDataProvider", "CreateScrollBoxListTreeListView", "MenuUtil",
    "Enum", "TooltipDataProcessor", "IsAltKeyDown", "GetInboxNumItems", "GetInboxItemLink", "GetInboxItem",
    "FlipsideDB_TBC", "FlipsideScanDB_TBC", "FlipsideLedgerDB", "FlipsideLedgerDB_TBC", "C_AddOns", "LoadAddOn",
    "C_ChatInfo", "IsInGuild", "FlipsideLogDB", "NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS", "BANK_CONTAINER",
    "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxText", "hooksecurefunc",
    "AUCTION_SOLD_MAIL_SUBJECT", "AUCTION_EXPIRED_MAIL_SUBJECT", "AUCTION_REMOVED_MAIL_SUBJECT",
    "AUCTION_OUTBID_MAIL_SUBJECT", "AUCTION_WON_MAIL_SUBJECT",
}

local frameMethods = {}
frameMethods.__index = frameMethods

function frameMethods:RegisterEvent(event)
    if M.invalidEvents[event] then
        error("unknown event: " .. tostring(event), 2)
    end
    self.events[event] = true
end

function frameMethods:UnregisterEvent(event)
    self.events[event] = nil
end

function frameMethods:Show()
    self.shown = true
end

function frameMethods:Hide()
    local wasShown = self.shown
    self.shown = false
    if wasShown and self.scripts.OnHide then
        self.scripts.OnHide(self)
    end
end

function frameMethods:SetFrameStrata(strata)
    self.strata = strata
end

function frameMethods:SetToplevel(toplevel)
    self.toplevel = toplevel
end

function frameMethods:Raise()
    self.raised = (self.raised or 0) + 1
end

function frameMethods:SetFrameLevel(level)
    self.level = level
end

function frameMethods:GetFrameLevel()
    return self.level or 1
end

function frameMethods:RegisterForClicks(...)
    self.clickButtons = { ... }
end

function frameMethods:GetEffectiveScale()
    return self.scale or 1
end

-- Set f.mouseOver = true in a test to place the cursor over a frame.
function frameMethods:IsMouseOver()
    return self.mouseOver == true
end

function frameMethods:SetFocus()
    self.focused = true
    if self.scripts.OnEditFocusGained then
        self.scripts.OnEditFocusGained(self)
    end
end

function frameMethods:HighlightText()
    self.highlighted = true
end

function frameMethods:IsShown()
    return self.shown
end

function frameMethods:SetScript(name, fn)
    self.scripts[name] = fn
end

function frameMethods:GetScript(name)
    return self.scripts[name]
end

function frameMethods:GetName()
    return self.name
end

function frameMethods:GetParent()
    return self.parent
end

function frameMethods:SetShown(shown)
    self.shown = shown and true or false
end

function frameMethods:HookScript(name, fn)
    local old = self.scripts[name]
    self.scripts[name] = old and function(...)
        old(...)
        fn(...)
    end or fn
end

function frameMethods:SetSize(w, h)
    self.width, self.height = w, h
end

function frameMethods:SetWidth(w)
    self.width = w
end

function frameMethods:SetHeight(h)
    self.height = h
end

function frameMethods:SetPoint(...)
    table.insert(self.points, { ... })
end

function frameMethods:GetNumPoints()
    return #self.points
end

function frameMethods:GetPoint(index)
    return unpack(self.points[index or 1], 1, 5)
end

function frameMethods:ClearAllPoints()
    self.points = {}
end

function frameMethods:SetText(text)
    self.text = text
end

function frameMethods:GetText()
    return self.text
end

function frameMethods:SetID(id)
    self.id = id
end

function frameMethods:GetID()
    return self.id
end

function frameMethods:SetAttribute(name, value)
    self.attributes = self.attributes or {}
    self.attributes[name] = value
end

function frameMethods:GetAttribute(name)
    return self.attributes and self.attributes[name]
end

function frameMethods:SetEnabled(enabled)
    self.enabled = enabled and true or false
end

function frameMethods:IsEnabled()
    return self.enabled ~= false
end

function frameMethods:Enable()
    self.enabled = true
end

function frameMethods:Disable()
    self.enabled = false
end

function frameMethods:SetChecked(checked)
    self.checked = checked and true or false
end

function frameMethods:GetChecked()
    return self.checked
end

function frameMethods:SetMovable(movable)
    self.movable = movable
end

function frameMethods:EnableMouse(enabled)
    self.mouse = enabled
end

function frameMethods:RegisterForDrag(...)
    self.dragButtons = { ... }
end

function frameMethods:StartMoving()
    self.moving = true
end

function frameMethods:StopMovingOrSizing()
    self.moving = false
    self.sizing = nil
end

function frameMethods:SetResizable(resizable)
    self.resizable = resizable
end

-- Models the newer client. A test removes it to model an older client (SetMinResize and SetMaxResize).
function frameMethods:SetResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
    self.resizeBounds = { minWidth, minHeight, maxWidth, maxHeight }
end

function frameMethods:StartSizing(point)
    self.sizing = point
end

function frameMethods:SetNormalTexture(texture)
    self.normalTexture = texture
end

function frameMethods:SetPushedTexture(texture)
    self.pushedTexture = texture
end

function frameMethods:SetClampedToScreen(clamped)
    self.clamped = clamped
end

function frameMethods:SetAutoFocus(autoFocus)
    self.autoFocus = autoFocus
end

function frameMethods:ClearFocus()
    self.focusCleared = (self.focusCleared or 0) + 1
end

-- Text width of the mock: 6 per character.
function frameMethods:GetTextWidth()
    return #(self.text or "") * 6
end

function frameMethods:GetStringWidth()
    return #(self.text or "") * 6
end

function frameMethods:SetJustifyH(justify)
    self.justifyH = justify
end

function frameMethods:SetJustifyV(justify)
    self.justifyV = justify
end

function frameMethods:SetFontObject(font)
    self.fontObject = font
end

function frameMethods:SetTexture(texture)
    self.texture = texture
end

function frameMethods:SetAtlas(atlas)
    self.atlas = atlas
end

function frameMethods:SetHighlightTexture(texture, mode)
    self.highlightTexture, self.highlightMode = texture, mode
end

function frameMethods:SetDataProvider(provider, retainScrollPosition)
    self.dataProvider, self.retainScroll = provider, retainScrollPosition
end

function frameMethods:SetNumeric(numeric)
    self.numeric = numeric
end

function frameMethods:SetMaxLetters(count)
    self.maxLetters = count
end

-- GetWidth and GetHeight are set per object in newObject; UIParent has none, as specs for the window rely on it.
local function getWidth(self)
    return self.width or 0
end

local function getHeight(self)
    return self.height or 0
end

-- Set f.left in a test to place the frame on the screen.
function frameMethods:GetLeft()
    return self.left or 0
end

-- Set f.bottom in a test to place the frame on the screen. Without it the frame has no layout (nil), as in the client.
function frameMethods:GetBottom()
    return self.bottom
end

function frameMethods:SetColorTexture(r, g, b, a)
    self.colorTexture = { r, g, b, a }
end

function frameMethods:SetVertexColor(r, g, b, a)
    self.vertexColor = { r, g, b, a }
end

function frameMethods:SetThickness(thickness)
    self.thickness = thickness
end

function frameMethods:SetStartPoint(point, relativeTo, x, y)
    self.startPoint = { point, relativeTo, x, y }
end

function frameMethods:SetEndPoint(point, relativeTo, x, y)
    self.endPoint = { point, relativeTo, x, y }
end

function frameMethods:SetAllPoints(target)
    self.allPoints = target
end

function frameMethods:SetTextColor(r, g, b, a)
    self.color = { r, g, b, a }
end

function frameMethods:SetHyperlinksEnabled(enabled)
    self.hyperlinksEnabled = enabled
end

function frameMethods.GetStringHeight()
    return 14
end

function frameMethods:SetAlpha(alpha)
    self.alpha = alpha
end

function frameMethods:SetBlendMode(mode)
    self.blendMode = mode
end

-- Menu stub: SetupMenu keeps the generator. GenerateMenu runs it against a recording root.
-- Each entry of self.menuItems has text, value, isSelected(), pick().
function frameMethods:SetupMenu(generator)
    self.menuGenerator = generator
    self:GenerateMenu()
end

function frameMethods:GenerateMenu()
    local items = {}
    self.menuItems = items
    local root = {}
    function root.CreateRadio(_, text, isSelected, setSelected, value)
        table.insert(items, {
            text = text, value = value,
            isSelected = function()
                return isSelected(value)
            end,
            pick = function()
                setSelected(value)
            end,
        })
    end
    self.menuGenerator(self, root)
end

-- Model of the drop-down click path (Menu.lua AcquireMenu). The client asserts and crashes when it
-- gets a non-table owner or a description with a non-string text. The mock raises a Lua error.
function frameMethods:OpenMenu()
    assert(type(self) == "table", "owner region must be a table")
    self:GenerateMenu()
    for _, item in ipairs(self.menuItems) do
        assert(type(item.text) == "string", "menu text must be a string")
        assert(item.value ~= nil, "menu value must not be nil")
        assert(type(item.isSelected()) == "boolean", "isSelected must give a boolean")
    end
    self.menuOpen = true
end

local function newTreeNode(parent, data)
    local node = { parent = parent, data = data, nodes = {}, collapsed = false }
    node.depth = (parent.depth or 0) + 1
    function node:Insert(childData)
        local child = newTreeNode(self, childData)
        table.insert(self.nodes, child)
        return child
    end
    function node:GetData()
        return self.data
    end
    function node:GetDepth()
        return self.depth
    end
    function node:GetNodes()
        return self.nodes
    end
    function node:IsCollapsed()
        return self.collapsed
    end
    function node:SetCollapsed(collapsed)
        self.collapsed = collapsed
    end
    return node
end

local function newObject(kind, name, parent, template)
    local f = setmetatable({
        events = {}, scripts = {}, shown = true, points = {},
        kind = kind, name = name, parent = parent, template = template,
    }, frameMethods)
    if M.objects then
        table.insert(M.objects, f)
    end
    if name ~= "UIParent" then
        f.GetWidth, f.GetHeight = getWidth, getHeight
    end
    f.CreateFontString = function(self, fsName, layer, font)
        local fs = newObject("FontString", fsName, self)
        fs.layer, fs.fontObject = layer, font
        return fs
    end
    f.CreateTexture = function(self, texName, layer)
        local tex = newObject("Texture", texName, self)
        tex.layer = layer
        return tex
    end
    -- A flag in a test (mock.noLines = true) removes CreateLine, as on a client without it.
    if not M.noLines then
        f.CreateLine = function(self, lineName, layer)
            local line = newObject("Line", lineName, self)
            line.layer = layer
            return line
        end
    end
    return f
end
-- options.flavour = "tbc" removes the Forever-only globals and sets the TBC bag constants.
function M.reset(options)
    M.clock = 0 -- seconds since reset
    M.serverBase = 1000000
    M.timers = {}
    M.frames = {}
    M.objects = {} -- every frame, font string, texture and line that was made
    M.invalidEvents = {} -- event names that RegisterEvent rejects
    M.messages = {}
    M.popup = nil -- last popup: { which, text, dialog }
    M.popupFrame = nil -- frame that StaticPopup_Show gives back
    M.qualityColors = { [4] = { 0.64, 0.21, 0.93, "ffa335ee" } } -- quality -> r, g, b, hex
    M.menu = nil -- last context menu: { owner, title, items = { { text, onClick, enabled } } }
    M.replicateCalls = 0
    M.rows = {} -- each row: itemID, count, buyout, hasAll, link
    M.region = "EU" -- result of GetCurrentRegionName()
    M.regionId = nil -- result of GetCurrentRegion(); nil removes the function
    M.testBuild = false -- result of IsTestBuild()
    M.standard = true -- result of C_GameRules.IsStandard()
    M.commodity = {} -- itemID -> isCommodity from GetItemKeyInfo; a missing id gives no info
    M.stackSizes = {} -- itemID -> max stack size
    M.playerName = nil -- result of UnitName("player")
    M.money = 0 -- result of GetMoney()
    M.noLines = false -- true removes CreateLine from the frames that are made after it
    M.realmName = nil -- result of GetNormalizedRealmName()
    M.itemInfo = {} -- itemID -> array of GetItemInfo return values
    M.loadRequests = {} -- itemIDs passed to RequestLoadItemDataByID
    M.commodityResults = {} -- itemID -> rows of the commodity search result
    M.itemResults = {} -- itemID -> rows of the item search result
    M.searchFull = true -- result of the HasFull...SearchResults calls
    M.browseQueries = {} -- queries passed to SendBrowseQuery
    M.browseRows = {} -- rows that GetBrowseResults gives; each has itemKey
    M.itemNames = {} -- itemID -> itemName that GetItemKeyInfo gives
    M.altDown = false -- result of IsAltKeyDown()
    M.postCalls = {} -- AddTooltipPostCall registrations: { type, fn }
    M.guidLinks = {} -- item guid -> link that GetItemLinkByGUID gives
    M.mail = {} -- inbox rows; each has attachments = array of { link, count }, and optional header and invoice
    M.hookCalls = {} -- names passed to hooksecurefunc
    M.inboxTextCalls = 0 -- number of GetInboxText calls (the real call marks the mail as read)
    M.ownedAuctions = {} -- rows that GetOwnedAuctions gives
    M.bags = {} -- bag index -> array of slot tables (as GetContainerItemInfo gives); a missing bag has no slots
    M.inGuild = false -- result of IsInGuild()
    M.addonPrefixes = {} -- prefixes passed to C_ChatInfo.RegisterAddonMessagePrefix
    M.addonSent = {} -- calls of C_ChatInfo.SendAddonMessage: { prefix, text, chatType, target }
    M.addonResult = 0 -- result of C_ChatInfo.SendAddonMessage (0 is Success, 3 is AddonMessageThrottle)

    _G.ACCEPT = "Accept"
    _G.CANCEL = "Cancel"
    _G.CLOSE = "Close"
    _G.SAVE = "Save"
    M.cursor = { 0, 0 } -- result of GetCursorPosition()
    _G.GetCursorPosition = function()
        return M.cursor[1], M.cursor[2]
    end
    _G.WOW_PROJECT_ID = 99
    _G.date = os.date
    _G.time = os.time
    _G.ScanTestDB = nil
    _G.FlipsideDB = nil
    _G.FlipsideDB_TBC = nil
    _G.FlipsideScanDB_TBC = nil
    _G.FlipsideScanDB = nil
    _G.FlipsideLogDB = nil
    _G.SLASH_FLIPSIDE1 = nil
    _G.SLASH_FLIPSIDE2 = nil
    _G.SLASH_SCANTEST1 = nil
    _G.SlashCmdList = {}
    _G.StaticPopupDialogs = {}

    _G.CreateFrame = function(kind, name, parent, template)
        if template and M.missingTemplates[template] then
            error("CreateFrame: unknown template " .. template, 2)
        end
        local f = newObject(kind, name, parent, template)
        if template == "PortraitFrameTemplate" or template == "ButtonFrameTemplate" then
            f.TitleContainer = newObject("Frame", nil, f)
            f.TitleContainer:SetFrameLevel(510)
            f.SetTitle = function(self, title)
                self.title = title
            end
            f.SetPortraitTextureRaw = function(self, texture)
                self.portrait = texture
            end
            f.SetPortraitShown = function(self, shown)
                self.portraitShown = shown
            end
        elseif template == "UICheckButtonTemplate" then
            f.Text = newObject("FontString", nil, f)
        elseif template == "InputScrollFrameTemplate" then
            f.EditBox = newObject("EditBox", nil, f)
            f.CharCount = newObject("FontString", nil, f)
        elseif template == "WowScrollBoxList" then
            f.rowFrames = {} -- test sets the row frames that the box shows
            f.ForEachFrame = function(self, fn)
                for _, row in ipairs(self.rowFrames) do
                    fn(row)
                end
            end
        end
        table.insert(M.frames, f)
        return f
    end

    M.missingTemplates = {} -- template names that CreateFrame rejects
    M.inCombat = false -- result of InCombatLockdown()
    M.sounds = {} -- keys that PlaySound was called with
    _G.SOUNDKIT = { IG_CHARACTER_INFO_TAB = 841, IG_CHARACTER_INFO_OPEN = 839, IG_CHARACTER_INFO_CLOSE = 840 }
    _G.PlaySound = function(key)
        M.sounds[#M.sounds + 1] = key
    end
    M.tabCalls = {} -- PanelTemplates_SetNumTabs and PanelTemplates_SetTab calls
    M.tooltip = { shown = false, title = nil, lines = {} }
    M.scrollInit = nil -- last ScrollUtil.InitScrollBoxListWithScrollBar call

    M.addOnLoads = {} -- names that C_AddOns.LoadAddOn was called with
    M.addOnLoadResult = { true } -- loaded, reason
    _G.C_AddOns = {
        LoadAddOn = function(name)
            M.addOnLoads[#M.addOnLoads + 1] = name
            return M.addOnLoadResult[1], M.addOnLoadResult[2]
        end,
    }

    _G.UISpecialFrames = {}
    _G.UIParent = newObject("Frame", "UIParent")
    _G.InCombatLockdown = function()
        return M.inCombat
    end
    -- With one argument: plain copper text. With separateThousands: the client letter format
    -- (Colorblind Mode on), as ns.TooltipLines.FormatMoney calls it.
    _G.GetMoneyString = function(copper, separate)
        if not separate then
            return copper .. "c"
        end
        local g, s, c = math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
        local gold = tostring(g)
        local prev
        repeat
            prev = gold
            gold = gold:gsub("^(%d+)(%d%d%d)", "%1,%2")
        until gold == prev
        local out = {}
        if g > 0 then out[#out + 1] = gold .. "g" end
        if s > 0 then out[#out + 1] = s .. "s" end
        if c > 0 or #out == 0 then out[#out + 1] = c .. "c" end
        return table.concat(out, " ")
    end
    _G.PanelTemplates_SetNumTabs = function(frame, num)
        table.insert(M.tabCalls, { "num", frame, num })
    end
    _G.PanelTemplates_SetTab = function(frame, id)
        table.insert(M.tabCalls, { "tab", frame, id })
    end
    -- Client helper: the tab is text + padding + 32 for the sides (at least minWidth), or absoluteSize.
    M.tabResizes = {}
    _G.PanelTemplates_TabResize = function(tab, padding, absoluteSize, minWidth)
        table.insert(M.tabResizes, { tab, padding, absoluteSize, minWidth })
        if absoluteSize then
            tab:SetWidth(absoluteSize)
        else
            local width = tab:GetTextWidth() + (padding or 0)
            if minWidth and width < minWidth then
                width = minWidth
            end
            tab:SetWidth(width + 32)
        end
    end
    _G.GameTooltip = {
        SetOwner = function(_, owner)
            M.tooltip.owner = owner
        end,
        SetText = function(_, text)
            M.tooltip.title = text
        end,
        SetHyperlink = function(_, link)
            M.tooltip.hyperlink = link
        end,
        AddLine = function(_, text)
            table.insert(M.tooltip.lines, text)
        end,
        AddDoubleLine = function(_, left, right)
            table.insert(M.tooltip.lines, { left, right })
        end,
        Show = function()
            M.tooltip.shown = true
        end,
        Hide = function()
            M.tooltip.shown = false
        end,
    }
    _G.CreateDataProvider = function(tbl)
        return { data = tbl }
    end
    _G.CreateScrollBoxListLinearView = function()
        local view = {}
        function view:SetElementExtent(extent)
            self.extent = extent
        end
        function view:SetElementExtentCalculator(calculator)
            self.calculator = calculator
        end
        function view:SetElementInitializer(template, fn)
            self.template, self.initializer = template, fn
        end
        return view
    end
    _G.CreateTreeDataProvider = function()
        local provider = { nodes = {} }
        function provider:Insert(data)
            local node = newTreeNode(self, data)
            table.insert(self.nodes, node)
            return node
        end
        -- Test helper: the nodes that a view shows, in order, without collapsed children.
        function provider:GetVisible()
            local out = {}
            local function walk(nodes)
                for _, node in ipairs(nodes) do
                    table.insert(out, node)
                    if not node.collapsed then
                        walk(node.nodes)
                    end
                end
            end
            walk(self.nodes)
            return out
        end
        return provider
    end
    _G.CreateScrollBoxListTreeListView = function(indent)
        local view = { indent = indent }
        function view:SetElementExtent(extent)
            self.extent = extent
        end
        function view:SetElementInitializer(template, fn)
            self.template, self.initializer = template, fn
        end
        return view
    end
    _G.ScrollUtil = {
        InitScrollBoxListWithScrollBar = function(box, bar, view)
            M.scrollInit = { box = box, bar = bar, view = view }
        end,
    }

    _G.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, msg)
            table.insert(M.messages, msg)
        end,
    }

    _G.GetBuildInfo = function()
        return "1.60.1", "70009", "Oct 1 2026", 16001, "1.60.1", {}
    end
    _G.GetServerTime = function()
        return M.serverBase + math.floor(M.clock)
    end
    _G.GetTime = function()
        return M.clock
    end
    _G.GetMoney = function()
        return M.money
    end
    _G.GetCurrentRegionName = function()
        return M.region
    end
    _G.IsTestBuild = function()
        return M.testBuild
    end
    _G.IsBetaBuild = function()
        return false
    end
    _G.IsPublicTestClient = function()
        return false
    end
    _G.GetCurrentRegion = function()
        return M.regionId
    end
    _G.C_GameRules = {
        IsStandard = function()
            return M.standard
        end,
    }
    _G.debugprofilestop = function()
        return M.clock * 1000
    end

    _G.C_Timer = {
        After = function(seconds, fn)
            table.insert(M.timers, { at = M.clock + seconds, fn = fn })
        end,
    }

    _G.IsInGuild = function()
        return M.inGuild
    end
    _G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix)
            table.insert(M.addonPrefixes, prefix)
            return 0
        end,
        SendAddonMessage = function(prefix, text, chatType, target)
            table.insert(M.addonSent, { prefix = prefix, text = text, chatType = chatType, target = target })
            return M.addonResult
        end,
    }
    _G.UnitName = function()
        return M.playerName, nil
    end
    _G.GetNormalizedRealmName = function()
        return M.realmName
    end

    _G.C_Item = {
        GetItemInfo = function(itemID)
            local values = M.itemInfo[itemID]
            if values then
                return unpack(values, 1, 17)
            end
        end,
        RequestLoadItemDataByID = function(itemID)
            table.insert(M.loadRequests, itemID)
        end,
        GetItemMaxStackSizeByID = function(itemID)
            return M.stackSizes[itemID]
        end,
        -- Quality colours: M.qualityColors[quality] = { r, g, b, hex }.
        GetItemQualityColor = function(quality)
            local color = M.qualityColors[quality]
            if color then
                return color[1], color[2], color[3], color[4]
            end
        end,
    }

    _G.C_AuctionHouse = {
        ReplicateItems = function()
            M.replicateCalls = M.replicateCalls + 1
        end,
        GetNumReplicateItems = function()
            return #M.rows
        end,
        -- Index base is 0 to n-1, like the addon assumes.
        GetReplicateItemInfo = function(index)
            local r = M.rows[index + 1]
            if not r then
                return
            end
            return "name", 0, r.count, 1, true, 1, 0, 0, 0, r.buyout, 0, false, "", "", "", 0,
                r.itemID, r.hasAll
        end,
    }

    _G.C_AuctionHouse.GetOwnedAuctions = function()
        return M.ownedAuctions
    end
    _G.C_AuctionHouse.MakeItemKey = function(itemID)
        return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    end
    _G.C_AuctionHouse.GetItemKeyInfo = function(itemKey)
        local isCommodity = M.commodity[itemKey.itemID]
        local itemName = M.itemNames[itemKey.itemID]
        if isCommodity ~= nil or itemName ~= nil then
            return { isCommodity = isCommodity, itemName = itemName }
        end
    end
    _G.C_AuctionHouse.SendBrowseQuery = function(query)
        table.insert(M.browseQueries, query)
    end
    _G.C_AuctionHouse.GetBrowseResults = function()
        return M.browseRows
    end
    _G.C_AuctionHouse.GetReplicateItemLink = function(index)
        local r = M.rows[index + 1]
        return r and r.link
    end
    _G.C_AuctionHouse.GetReplicateItemBattlePetInfo = function() end

    -- Search results: M.commodityResults[itemID] and M.itemResults[itemID] are lists of rows.
    -- A commodity row has unitPrice and quantity. An item row has link, buyout and quantity.
    local ah = _G.C_AuctionHouse
    ah.GetNumCommoditySearchResults = function(itemID)
        return #(M.commodityResults[itemID] or {})
    end
    ah.GetCommoditySearchResultInfo = function(itemID, index)
        local r = (M.commodityResults[itemID] or {})[index]
        return r and { itemID = itemID, unitPrice = r.unitPrice, quantity = r.quantity, auctionID = r.auctionID,
            containsOwnerItem = r.owner, timeLeftSeconds = r.timeLeftSeconds }
    end
    ah.HasFullCommoditySearchResults = function()
        return M.searchFull
    end
    ah.GetNumItemSearchResults = function(itemKey)
        return #(M.itemResults[itemKey.itemID] or {})
    end
    ah.GetItemSearchResultInfo = function(itemKey, index)
        local r = (M.itemResults[itemKey.itemID] or {})[index]
        return r and { itemKey = itemKey, itemLink = r.link, buyoutAmount = r.buyout, quantity = r.quantity,
            auctionID = r.auctionID, containsOwnerItem = r.owner, timeLeft = r.timeLeft }
    end
    ah.HasFullItemSearchResults = function()
        return M.searchFull
    end
    -- Live search: M.searchQueries records SendSearchQuery calls; M.throttleReady is the ready flag.
    M.searchQueries = {}
    M.ownedQueries = {}
    M.throttleReady = true
    ah.SendSearchQuery = function(itemKey, sorts, separate)
        table.insert(M.searchQueries, { itemKey = itemKey, sorts = sorts, separate = separate })
    end
    ah.IsThrottledMessageSystemReady = function()
        return M.throttleReady
    end
    ah.QueryOwnedAuctions = function(sorts)
        table.insert(M.ownedQueries, sorts)
    end

    _G.C_Container = {
        GetContainerNumSlots = function(bag)
            return #(M.bags[bag] or {})
        end,
        GetContainerItemInfo = function(bag, slot)
            return (M.bags[bag] or {})[slot]
        end,
    }

    _G.IsAltKeyDown = function()
        return M.altDown
    end
    _G.Enum = { TooltipDataType = { Item = 0 } }
    _G.TooltipDataProcessor = {
        AddTooltipPostCall = function(tooltipType, fn)
            table.insert(M.postCalls, { type = tooltipType, fn = fn })
        end,
    }
    _G.C_Item.GetItemLinkByGUID = function(guid)
        return M.guidLinks[guid]
    end
    _G.GetInboxNumItems = function()
        return #M.mail
    end
    _G.GetInboxItemLink = function(index, attachment)
        local a = M.mail[index] and M.mail[index].attachments[attachment]
        return a and a.link
    end
    _G.AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
    _G.AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
    _G.AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
    _G.AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"
    _G.AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"
    _G.hooksecurefunc = function(name)
        table.insert(M.hookCalls, tostring(name))
    end
    -- header = { sender, subject, money, itemCount, quantity, link }; same order as the client values.
    _G.GetInboxHeaderInfo = function(index)
        local h = M.mail[index] and M.mail[index].header
        if h then
            return "pkg", "stat", h.sender, h.subject, h.money, 0, 3, h.itemCount, false, false, false, true, false,
                h.quantity, h.link
        end
    end
    -- invoice = { type, itemName, player, bid, buyout, deposit, consignment, count }
    _G.GetInboxInvoiceInfo = function(index)
        local v = M.mail[index] and M.mail[index].invoice
        if v then
            return v.type, v.itemName, v.player, v.bid, v.buyout, v.deposit, v.consignment, 0, 0, 0, v.count, false
        end
    end
    _G.GetInboxText = function()
        M.inboxTextCalls = M.inboxTextCalls + 1
    end
    _G.GetInboxItem = function(index, attachment)
        local a = M.mail[index] and M.mail[index].attachments[attachment]
        if a then
            return "name", 0, "icon", a.count
        end
    end

    _G.StaticPopup_Show = function(which, arg1, arg2)
        local d = _G.StaticPopupDialogs[which]
        M.popup = { which = which, dialog = d, text = string.format(d.text, arg1 or "", arg2 or "") }
        return M.popupFrame
    end

    -- Context menu stub: records the owner, the title and the entries that the generator creates.
    _G.MenuUtil = {
        CreateContextMenu = function(owner, generator)
            local menu = { owner = owner, items = {} }
            local root = {}
            function root.CreateTitle(_, text)
                menu.title = text
            end
            function root.CreateButton(_, text, onClick)
                local item = { text = text, onClick = onClick, enabled = true }
                table.insert(menu.items, item)
                local description = {}
                function description.SetEnabled(_, enabled)
                    item.enabled = enabled
                end
                return description
            end
            generator(owner, root)
            M.menu = menu
            return menu
        end,
    }

    if options and options.flavour == "tbc" then
        _G.C_AuctionHouse = nil
        _G.TooltipDataProcessor = nil
        _G.NUM_BAG_SLOTS = 4
        _G.NUM_BANKBAGSLOTS = 7
        _G.BANK_CONTAINER = -1
    end
end

-- Remove the globals that the mock sets.
function M.teardown()
    for _, name in ipairs(GLOBAL_NAMES) do
        _G[name] = nil
    end
end

-- Send an event to each frame that registered for it.
function M.fire(event, ...)
    local list = {}
    for _, f in ipairs(M.frames) do
        if f.events[event] and f.scripts.OnEvent then
            table.insert(list, f)
        end
    end
    for _, f in ipairs(list) do
        f.scripts.OnEvent(f, event, ...)
    end
end

function M.isRegistered(event)
    for _, f in ipairs(M.frames) do
        if f.events[event] then
            return true
        end
    end
    return false
end

-- Run one frame: call the OnUpdate script of each shown frame once.
function M.update()
    local list = {}
    for _, f in ipairs(M.frames) do
        if f.scripts.OnUpdate and f.shown then
            table.insert(list, f)
        end
    end
    for _, f in ipairs(list) do
        if f.scripts.OnUpdate and f.shown then
            f.scripts.OnUpdate(f, 0.016)
        end
    end
end

-- Move the clock forward and run the timers that are due.
function M.advance(seconds)
    M.clock = M.clock + seconds
    local due, rest = {}, {}
    for _, t in ipairs(M.timers) do
        if t.at <= M.clock then
            table.insert(due, t)
        else
            table.insert(rest, t)
        end
    end
    M.timers = rest
    table.sort(due, function(a, b)
        return a.at < b.at
    end)
    for _, t in ipairs(due) do
        t.fn()
    end
end

function M.runSlash(args)
    _G.SlashCmdList["SCANTEST"](args or "")
end

-- Run the logout event as the client does.
function M.logout()
    M.fire("PLAYER_LOGOUT")
end

function M.cancelPopup()
    local p = M.popup
    M.popup = nil
    if p.dialog.OnCancel then
        p.dialog.OnCancel()
    end
end

function M.acceptPopup()
    local p = M.popup
    M.popup = nil
    p.dialog.OnAccept()
end

return M
