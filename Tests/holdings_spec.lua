local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("ItemString")))("Flipside", ns)
assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
assert(loadfile(manifest.path("Holdings")))("Flipside", ns)

local now = 100
local function Clock()
    return now
end

local function Open(saved, character)
    local db = ns.SettingsDB.New(saved, { character = character or "Alice-Realm", schemaVersion = 1 })
    return db, ns.Holdings.New(db, { character = character or "Alice-Realm", clock = Clock })
end

describe("Holdings", function()
    before_each(function()
        now = 100
    end)

    it("stores a location with the seen time and skips zero counts", function()
        local saved = {}
        local _, h = Open(saved)
        assert.is_true(h:SetLocation("bags", { ["10"] = 5, ["11"] = 0, ["bad key"] = 3 }))
        local stored = saved["c/Alice-Realm/holdings"]
        assert.are.same({ version = 1, locations = { bags = { seen = 100, items = { ["10"] = 5 } } } }, stored)
    end)

    it("replaces a location and keeps the others", function()
        local _, h = Open({})
        h:SetLocation("bags", { ["10"] = 5 })
        h:SetLocation("bank", { ["10"] = 2 })
        now = 200
        h:SetLocation("bags", { ["10"] = 1 })
        local entry = h:Count("10").characters[1]
        assert.are.equal(1, entry.bags)
        assert.are.equal(2, entry.bank)
        assert.are.equal(3, entry.total)
        assert.are.same({ bags = 200, bank = 100 }, entry.seen)
    end)

    it("rejects an unknown location", function()
        local _, h = Open({})
        assert.has_error(function() h:SetLocation("void", {}) end)
    end)

    it("counts exact keys exactly and base keys over all variants", function()
        local _, h = Open({})
        h:SetLocation("bags", { ["10"] = 1, ["10#b1,2"] = 2, ["10#b3"] = 4, ["10#s-5"] = 8 })
        assert.are.equal(2, h:Count("10#b1,2").total)
        assert.are.equal(15, h:Count("10").total)
        assert.are.equal(0, h:Count("10#b9").total)
        assert.are.equal(0, h:Count("junk").total)
    end)

    it("counts every character on every realm, sorted", function()
        local saved = {}
        local _, a = Open(saved, "Alice-Realm")
        local _, b = Open(saved, "Bob-Other")
        local _, c = Open(saved, "Cy-Third")
        local _, d = Open(saved, "Al-Third")
        a:SetLocation("bags", { ["10"] = 3 })
        b:SetLocation("mail", { ["10"] = 7 })
        c:SetLocation("auctions", { ["10"] = 3 })
        d:SetLocation("bank", { ["11"] = 9 })
        local result = a:Count("10")
        assert.are.equal(13, result.total)
        local names = {}
        for i, e in ipairs(result.characters) do
            names[i] = e.name
        end
        assert.are.same({ "Bob-Other", "Alice-Realm", "Cy-Third" }, names)
        assert.are.equal(7, result.characters[1].mail)
        assert.are.equal(0, a:Count("12").total)
    end)

    it("counts bags of the current character only", function()
        local saved = {}
        local _, a = Open(saved, "Alice-Realm")
        local _, b = Open(saved, "Bob-Other")
        a:SetLocation("bags", { ["10"] = 3, ["10#b1"] = 2 })
        a:SetLocation("bank", { ["10"] = 10 })
        b:SetLocation("bags", { ["10"] = 50 })
        assert.are.equal(5, a:CountInBags("10"))
        assert.are.equal(2, a:CountInBags("10#b1"))
        assert.are.equal(0, a:CountInBags("99"))
    end)

    it("forgets holdings but keeps the profile map entry and other keys", function()
        local saved = {}
        local db, a = Open(saved, "Alice-Realm")
        local _, b = Open(saved, "Bob-Other")
        b:SetLocation("bags", { ["10"] = 4 })
        db:SetFor("Bob-Other", "other", 1)
        assert.are.equal(4, a:Count("10").total)
        a:Forget("Bob-Other")
        assert.are.equal(0, a:Count("10").total)
        assert.is_nil(saved["c/Bob-Other/holdings"])
        assert.are.equal(1, saved["c/Bob-Other/other"])
        assert.are.equal("Default", saved["a/profiles.map"]["Bob-Other"])
        assert.are.same({ "Alice-Realm", "Bob-Other" }, a:Characters())
    end)

    it("does not save when the DB is read-only", function()
        local saved = { _schema = 9 }
        local _, h = Open(saved)
        assert.is_false(h:SetLocation("bags", { ["10"] = 1 }))
        assert.are.equal(0, h:Count("10").total)
        assert.is_nil(saved["c/Alice-Realm/holdings"])
    end)

    it("reloads from the saved table", function()
        local saved = {}
        local _, h = Open(saved)
        h:SetLocation("bags", { ["10"] = 6 })
        local _, again = Open(saved)
        assert.are.equal(6, again:Count("10").total)
        assert.are.equal(6, again:CountInBags("10"))
    end)

    it("rebuilds the index after a change", function()
        local _, h = Open({})
        h:SetLocation("bags", { ["10"] = 1 })
        assert.are.equal(1, h:Count("10").total)
        h:SetLocation("bags", { ["10"] = 4, ["11"] = 2 })
        assert.are.equal(4, h:Count("10").total)
        assert.are.equal(2, h:Count("11").total)
        h:SetLocation("bags", {})
        assert.are.equal(0, h:Count("10").total)
    end)

    it("validates the constructor arguments", function()
        local db = Open({})
        assert.has_error(function() ns.Holdings.New(db, { clock = Clock }) end)
        assert.has_error(function() ns.Holdings.New(db, { character = "A-B" }) end)
    end)
end)
