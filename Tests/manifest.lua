-- Reads the TOC so that specs get addon file paths from one place.
local M = {}

-- Return the ordered .lua paths of a TOC text, with "/" separators.
function M.parse(text)
    local files = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" and line:lower():match("%.lua$") then
            table.insert(files, (line:gsub("\\", "/")))
        end
    end
    return files
end

-- Return the ordered .lua paths of a TOC file (default Flipside.toc).
function M.files(tocPath)
    local handle = assert(io.open(tocPath or "Flipside.toc", "rb"))
    local text = handle:read("*a")
    handle:close()
    return M.parse(text)
end

local function moduleName(name)
    return (name:match("([^/\\]+)$"):gsub("%.lua$", ""))
end

-- Return the index of a module in a file list. The name can be "ScanEngine", "Services/ScanEngine" or a path.
function M.indexOf(files, name)
    local wanted = moduleName(name)
    for i, path in ipairs(files) do
        if moduleName(path) == wanted then
            return i
        end
    end
end

-- Return the TOC path of a module, for example manifest.path("ScanEngine").
function M.path(name, tocPath)
    local files = M.files(tocPath)
    local index = M.indexOf(files, name)
    if not index then
        error("module not in the TOC: " .. tostring(name), 2)
    end
    return files[index]
end

-- Return the TOC paths up to and including a module.
function M.upTo(name, tocPath)
    local files = M.files(tocPath)
    local index = M.indexOf(files, name)
    if not index then
        error("module not in the TOC: " .. tostring(name), 2)
    end
    local list = {}
    for i = 1, index do
        list[i] = files[i]
    end
    return list
end

return M
