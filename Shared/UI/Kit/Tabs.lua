local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

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

-- Add page tabs along the bottom edge of a window.
-- pages: array of { key, title, build(contentFrame) }.
function Kit.CreatePageTabs(window, pages)
    local self = setmetatable({ window = window, pages = pages, contents = {}, buttons = {} }, Tabs)
    window.Tabs = self.buttons
    local name = window:GetName()
    local padding = Kit.Theme.padding
    for index, page in ipairs(pages) do
        local tab = CreateFrame("Button", name and (name .. "Tab" .. index) or nil, window, "PanelTabButtonTemplate")
        tab:SetID(index)
        tab:SetText(page.title)
        if index == 1 then
            tab:SetPoint("TOPLEFT", window, "BOTTOMLEFT", padding, 2)
        else
            tab:SetPoint("TOPLEFT", self.buttons[index - 1], "TOPRIGHT", 3, 0)
        end
        tab:SetScript("OnClick", function()
            self:Select(page.key)
        end)
        self.buttons[index] = tab

        local content = CreateFrame("Frame", nil, window)
        content:SetPoint("TOPLEFT", window, "TOPLEFT", padding, -60)
        content:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -padding, padding)
        content:Hide()
        self.contents[index] = content
    end
    PanelTemplates_SetNumTabs(window, #pages)
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
-- options: onSelect(key), selected (start key, default the first tab).
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
    for index, page in ipairs(tabs) do
        local key, title = page.key or page[1], page.title or page[2]
        local tab = CreateFrame("Button", nil, holder, "PanelTopTabButtonTemplate")
        tab:SetID(index)
        tab:SetText(title)
        if index == 1 then
            tab:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        else
            tab:SetPoint("TOPLEFT", self.buttons[index - 1], "TOPRIGHT", 3, 0)
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