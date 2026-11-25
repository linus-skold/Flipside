local _, ns = ...

-- The item tooltip of a list row (Buying tab and Selling tab). One helper for both tabs.
-- It sets only the OnEnter and OnLeave scripts of the row. The hover glow of the Kit is a HIGHLIGHT texture,
-- so it needs no script and stays.
local RowTooltip = {}
ns.RowTooltip = RowTooltip

-- The hyperlink payload ("item:100:...") of an item link, or nil.
local function linkPayload(link)
    return type(link) == "string" and link:match("|H(item:.-)|h") or nil
end

-- The item string of an item key (D20: "100", "100#s5", "100#b1,2"), or nil. The fields are the client order:
-- item, enchant, 4 gems, suffix, unique, link level, spec, modifiers, context, bonus count, bonus ids.
local function keyPayload(key)
    local parsed = ns.ItemString and type(key) == "string" and ns.ItemString.ParseKey(key)
    if not parsed then
        return nil
    end
    local text = "item:" .. parsed.itemID
    if parsed.suffixID ~= 0 or #parsed.bonusIDs > 0 then
        text = text .. ":::::" .. ":" .. parsed.suffixID
    end
    if #parsed.bonusIDs > 0 then
        text = text .. ":::::" .. ":" .. #parsed.bonusIDs .. ":" .. table.concat(parsed.bonusIDs, ":")
    end
    return text
end

-- The hyperlink payload of one item. source: { link, key, itemID }. The link of an auction comes first: it keeps the
-- suffix and the item level of that auction. Then the item key, then the plain item id. Returns nil if there is none.
function RowTooltip.Payload(source)
    if type(source) ~= "table" then
        return nil
    end
    local payload = linkPayload(source.link) or keyPayload(source.key)
    if not payload and type(source.itemID) == "number" and source.itemID > 0 then
        payload = "item:" .. math.floor(source.itemID)
    end
    return payload
end

-- Make a row show the tooltip of an item on mouse-over. source is as in RowTooltip.Payload. With a nil source (a
-- group row, a header) or a source without an item, the row loses a tooltip of an earlier use.
-- opts.chatLink (an item link): a shift-click on the row puts it in the chat box. A row that uses the shift-click
-- for another action sets none. Call this after the row sets its OnClick script.
function RowTooltip.Link(row, source, opts)
    local payload = RowTooltip.Payload(source)
    if not payload then
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        return false
    end
    row:SetScript("OnEnter", function(frame)
        local tip = _G.GameTooltip
        if not (tip and tip.SetOwner and tip.SetHyperlink) then
            return
        end
        tip:SetOwner(frame, "ANCHOR_RIGHT")
        tip:SetHyperlink(payload)
        tip:Show()
    end)
    row:SetScript("OnLeave", function()
        local tip = _G.GameTooltip
        if tip and tip.Hide then
            tip:Hide()
        end
    end)
    local link = opts and opts.chatLink
    if type(link) == "string" and link:find("|H", 1, true) then
        local onSelect = row:GetScript("OnClick")
        row:SetScript("OnClick", function(frame, button, ...)
            local insert, modified = _G.ChatEdit_InsertLink, _G.IsModifiedClick
            if button ~= "RightButton" and insert and modified and modified("CHATLINK") and insert(link) then
                return
            end
            if onSelect then
                onSelect(frame, button, ...)
            end
        end)
    end
    return true
end
