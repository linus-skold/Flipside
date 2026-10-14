-- Checks the D23 folder layout against the root TOC files.
local function listLua(dir)
    local files = {}
    local cmd = package.config:sub(1, 1) == "\\" and ('dir /b /s /a-d "' .. dir .. '" 2>nul')
        or ('find "' .. dir .. '" -type f 2>/dev/null')
    local p = io.popen(cmd)
    for line in p:lines() do
        line = line:gsub("\\", "/")
        if line:lower():match("%.lua$") then
            table.insert(files, line)
        end
    end
    p:close()
    return files
end

local function listDirs()
    local dirs = {}
    local cmd = package.config:sub(1, 1) == "\\" and "dir /b /ad ." or "ls -1 -d */"
    local p = io.popen(cmd)
    for line in p:lines() do
        table.insert(dirs, (line:gsub("[/\\]$", "")))
    end
    p:close()
    return dirs
end

local function tocFiles()
    local manifest = dofile("Tests/manifest.lua")
    local out, listed = {}, {}
    local p = io.popen(package.config:sub(1, 1) == "\\" and "dir /b Flipside*.toc" or "ls -1 Flipside*.toc")
    for name in p:lines() do
        table.insert(out, name)
    end
    p:close()
    for _, toc in ipairs(out) do
        for _, f in ipairs(manifest.files(toc)) do
            listed[f] = true
        end
    end
    return listed
end

local function flavourDirs()
    local result = {}
    for _, d in ipairs(listDirs()) do
        if d == "Shared" or d:match("^Core_") or d:match("^AH_") then
            table.insert(result, d)
        end
    end
    return result
end

local function addonFiles()
    local files = {}
    for _, d in ipairs(flavourDirs()) do
        for _, path in ipairs(listLua(d)) do
            local s = path:find("/" .. d .. "/", 1, true)
            table.insert(files, s and path:sub(s + 1) or path)
        end
    end
    return files
end

describe("D23 layout", function()
    it("lists every addon Lua file in a root TOC", function()
        local listed = tocFiles()
        for _, path in ipairs(addonFiles()) do
            assert.is_true(listed[path] == true, path .. " is not in a TOC")
        end
    end)

    it("has every TOC entry on disk", function()
        for path in pairs(tocFiles()) do
            local handle = io.open(path, "rb")
            assert.is_not_nil(handle, path .. " is missing")
            handle:close()
        end
    end)

    it("leaves no Lua file in the old folders", function()
        for _, d in ipairs({ "Core", "Services", "Features", "UI" }) do
            assert.are.same({}, listLua(d))
        end
    end)

    pending("D23: AH calls move to AH_<Flavour> in a later pull request", function()
        local banned = { "C_AuctionHouse", "AuctionHouseFrame", "QueryAuctionItems", "GetAuctionItem" }
        for _, path in ipairs(addonFiles()) do
            if path:match("^Shared/") then
                local handle = io.open(path, "rb")
                local text = handle:read("*a")
                handle:close()
                for _, word in ipairs(banned) do
                    assert.is_nil(text:find(word, 1, true), path .. " has " .. word)
                end
            end
        end
    end)
end)
