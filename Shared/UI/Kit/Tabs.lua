local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local DEFAULT_PAGE_TEMPLATE = "PanelTabButtonTemplate"
local DEFAULT_TOP_TEMPLATE = "PanelTopTabButtonTemplate"
local MIN_FIT_WIDTH = 40
local TAB_GAP = 3

-- Width of a tab from its text width: text + padding, at least minWidth.
function Kit.TabWidth(textWidth, padding, minWidth)
    local width = textWidth + (padding or 0)
    if minWidth and width < minWidth then
        width = minWidth
    end
    return width
end

-- Shrink tab widths so that the tabs and the gaps fit in maxTotal. Each tab keeps its share of the total.
-- Returns a new list. A tab never gets narrower than minWidth (default 40).
function Kit.FitTabWidths(widths, maxTotal, gap, minWidth)
    gap = gap or TAB_GAP
    minWidth = minWidth or MIN_FIT_WIDTH
    local sum = 0
    for _, width in ipairs(widths) do
        sum = sum + width
    end
    local available = maxTotal - gap * math.max(#widths - 1, 0)
    local out = {}
    for index, width in ipairs(widths) do
        if sum <= available or sum <= 0 then
            out[index] = width
        else
            out[index] = math.min(width, math.max(minWidth, math.floor(width * available / sum)))
        end
    end
    return out
end

-- Size a tab to its text with the client helper. Without the helper, set the width from the text width.
local function sizeTab(tab, padding, minWidth, absoluteSize)
    if PanelTemplates_TabResize then
        PanelTemplates_TabResize(tab, padding, absoluteSize, minWidth)
    elseif absoluteSize then
        tab:SetWidth(absoluteSize)
    else
        tab:SetWidth(Kit.TabWidth(tab:GetTextWidth(), padding, minWidth))
    end
end

local tabCounter = 0
local Tabs = {}
Tabs.__index = Tabs

-- Show the page with this key. The page builds on its first show.
function Tabs:Select(key)
    for index, page in ipairs(self.pages) do
        if page.key == key then
            if not self.contents[index].built then
                self.contents[index].built = true
                if page.build then
                    page.build(self.contents[index])
                end
            end
            for i, content in ipairs(self.contents) do
                content:SetShown(i == index)
            end
            self.selected = key
            PanelTemplates_SetTab(self.window, index)
            return
        end
    end
end

function Tabs:GetSelected()
    return self.selected
end

-- Size every tab to its text. If the tabs are wider than the window, shrink them evenly and cut the text.
function Tabs:Layout()
    if self.layingOut then
        return
    end
    local maxTotal = self.window:GetWidth() - 2 * self.edge
    if maxTotal <= 0 then
        return
    end
    self.layingOut = true
    local natural = {}
    for index, tab in ipairs(self.buttons) do
        sizeTab(tab, self.tabPadding, self.minTabWidth)
        natural[index] = tab:GetWidth()
    end
    local fitted = Kit.FitTabWidths(natural, maxTotal, TAB_GAP)
    for index, tab in ipairs(self.buttons) do
        if fitted[index] < natural[index] then
            sizeTab(tab, self.tabPadding, self.minTabWidth, fitted[index])
        end
    end
    self.layingOut = false
end
-- Add page tabs along the bottom edge of a window.
-- pages: array of { key, title, build(contentFrame) }.
-- options: template (default PanelTabButtonTemplate), tabPadding, minTabWidth (for the client resize helper).
-- The tabs size to their text and shrink evenly if they are wider than the window.
function Kit.CreatePageTabs(window, pages, options)
    options = options or {}
    local self = setmetatable({
        window = window, pages = pages, contents = {}, buttons = {},
        tabPadding = options.tabPadding, minTabWidth = options.minTabWidth,
        edge = Kit.Theme.padding,
    }, Tabs)
    window.Tabs = self.buttons
    -- The client resize helper reads these fields from the parent. Some templates cut the text at maxTabWidth.
    window.tabPadding, window.minTabWidth, window.maxTabWidth = options.tabPadding, options.minTabWidth, 1000
    local template = options.template or DEFAULT_PAGE_TEMPLATE
    local name = window:GetName()
    local padding = Kit.Theme.padding
    tabCounter = tabCounter + 1
    for index, page in ipairs(pages) do
        -- Some templates need a name for their texture names.
        local tab = CreateFrame("Button", (name or ("PageTabs" .. tabCounter)) .. "Tab" .. index, window, template)
        tab:SetID(index)
        tab:SetText(page.title)
        if index == 1 then
            tab:SetPoint("TOPLEFT", window, "BOTTOMLEFT", padding, 2)
        else
            tab:SetPoint("TOPLEFT", self.buttons[index - 1], "TOPRIGHT", TAB_GAP, 0)
        end
        tab:SetScript("OnClick", function()
            self:Select(page.key)
        end)
        -- Run after the client OnShow resize.
        tab:HookScript("OnShow", function()
            self:Layout()
        end)
        self.buttons[index] = tab

        local content = CreateFrame("Frame", nil, window)
        content:SetPoint("TOPLEFT", window, "TOPLEFT", padding, -60)
        content:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -padding, padding)
        content:Hide()
        self.contents[index] = content
    end
    PanelTemplates_SetNumTabs(window, #pages)
    window:HookScript("OnSizeChanged", function()
        self:Layout()
    end)
    self:Layout()
    if pages[1] then
        self:Select(pages[1].key)
    end
    return self
end
local TopTabs = {}
TopTabs.__index = TopTabs

local TOP_TAB_HEIGHT = 30

local function apply(self, key, notify)
    local index = self.indexByKey[key]
    if not index or self.selected == key then
        return
    end
    for i, content in ipairs(self.contents) do
        content:SetShown(i == index)
    end
    self.selected = key
    PanelTemplates_SetTab(self.holder, index)
    if notify and self.onSelect then
        self.onSelect(key)
    end
end

-- Show the content of this tab. An unknown key does nothing. onSelect(key) runs when the tab changes.
function TopTabs:Select(key)
    apply(self, key, true)
end

function TopTabs:GetSelected()
    return self.selected
end

-- Return the content frame of a tab, or nil.
function TopTabs:GetContent(key)
    return self.contents[self.indexByKey[key]]
end

-- Add tabs along the top edge of any frame. tabs: array of { key = k, title = t } (or { k, t }).
-- options: onSelect(key), selected (start key, default the first tab), template (default PanelTopTabButtonTemplate),
-- tabPadding and minTabWidth (each tab is as wide as its text + tabPadding, at least minTabWidth).
-- The tabs use their own holder frame, so the parent can also have page tabs.
function Kit.CreateTopTabs(parent, tabs, options)
    options = options or {}
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetAllPoints(parent)
    local self = setmetatable({
        parent = parent, holder = holder, onSelect = options.onSelect,
        contents = {}, buttons = {}, indexByKey = {},
    }, TopTabs)
    holder.Tabs = self.buttons
    -- The client OnShow resize of some templates reads these fields from the parent.
    holder.tabPadding, holder.minTabWidth = options.tabPadding, options.minTabWidth
    for index, page in ipairs(tabs) do
        local key, title = page.key or page[1], page.title or page[2]
        local tab = CreateFrame("Button", nil, holder, options.template or DEFAULT_TOP_TEMPLATE)
        tab:SetID(index)
        tab:SetText(title)
        sizeTab(tab, options.tabPadding, options.minTabWidth)
        if index == 1 then
            tab:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        else
            tab:SetPoint("TOPLEFT", self.buttons[index - 1], "TOPRIGHT", TAB_GAP, 0)
        end
        tab:SetScript("OnClick", function()
            self:Select(key)
        end)
        self.buttons[index] = tab
        self.indexByKey[key] = index

        local content = CreateFrame("Frame", nil, parent)
        content:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -TOP_TAB_HEIGHT)
        content:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        content:Hide()
        self.contents[index] = content
    end
    PanelTemplates_SetNumTabs(holder, #tabs)
    local first = options.selected or (tabs[1] and (tabs[1].key or tabs[1][1]))
    if first then
        apply(self, first, false)
    end
    return self
end