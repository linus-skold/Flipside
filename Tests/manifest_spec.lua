local manifest = require("Tests.manifest")

local TOC = table.concat({
    "## Interface: 16001",
    "# a comment",
    "",
    "Core\\One.lua",
    "  Services\\Two.lua  ",
    "Layout.xml",
    "UI/Kit/Three.lua",
    "# Core\\Hidden.lua",
}, "\n")

describe("manifest", function()
    it("keeps only the lua paths, in order, with / separators", function()
        assert.are.same({ "Core/One.lua", "Services/Two.lua", "UI/Kit/Three.lua" }, manifest.parse(TOC))
    end)

    it("handles CRLF line ends", function()
        assert.are.same({ "A/B.lua", "C/D.lua" }, manifest.parse("A\\B.lua\r\n# x\r\nC\\D.lua\r\n"))
    end)

    it("finds a module by name, by partial path or by path", function()
        local files = manifest.parse(TOC)
        assert.are.equal(2, manifest.indexOf(files, "Two"))
        assert.are.equal(2, manifest.indexOf(files, "Services/Two"))
        assert.are.equal(3, manifest.indexOf(files, "UI/Kit/Three.lua"))
        assert.is_nil(manifest.indexOf(files, "Missing"))
    end)

    it("returns the TOC path of a module", function()
        assert.are.equal("Shared/Services/ScanEngine.lua", manifest.path("ScanEngine"))
        assert.are.equal("Shared/Services/ScanEngine.lua", manifest.path("Shared/Services/ScanEngine.lua"))
    end)

    it("raises an error for a module that is not in the TOC", function()
        assert.has_error(function()
            manifest.path("NoSuchModule")
        end)
    end)

    it("returns the files up to and including a module", function()
        local list = manifest.upTo("ItemString")
        assert.are.equal("Shared/Core/ItemString.lua", list[#list])
        assert.are.equal(manifest.files()[1], list[1])
        assert.are.equal(manifest.indexOf(manifest.files(), "ItemString"), #list)
    end)

    it("lists only files that exist on disk", function()
        local files = manifest.files()
        assert.is_true(#files > 0)
        for _, path in ipairs(files) do
            local handle = io.open(path, "rb")
            assert.is_truthy(handle, "missing file: " .. path)
            if handle then
                handle:close()
            end
        end
    end)
end)
