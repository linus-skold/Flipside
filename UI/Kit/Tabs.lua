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
