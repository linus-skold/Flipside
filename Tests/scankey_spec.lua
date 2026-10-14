local manifest = require("Tests.manifest")
describe("ScanKey", function()
    local ScanKey

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("ItemString")))("Flipside", ns)
        assert(loadfile(manifest.path("ScanKey")))("Flipside", ns)
        ScanKey = ns.ScanKey
    end)

    local function make(client, stack)
        return ScanKey.New({
            clientIsCommodity = function() return client end,
            maxStack = function() return stack end,
        })
    end

    describe("IsCommodity", function()
        it("uses the client answer", function()
            for _, stack in ipairs({ 1, 20 }) do
                local r = make(true, stack)
                assert.are.same({ true, "client" }, { r:IsCommodity(1) })
                r = make(false, stack)
                assert.are.same({ false, "client" }, { r:IsCommodity(1) })
            end
        end)

        it("uses the client answer when stack size is nil", function()
            assert.are.same({ true, "client" }, { make(true, nil):IsCommodity(1) })
            assert.are.same({ false, "client" }, { make(false, nil):IsCommodity(1) })
        end)

        it("falls back to the stack size", function()
            assert.are.same({ true, "stack" }, { make(nil, 20):IsCommodity(1) })
            assert.are.same({ false, "stack" }, { make(nil, 1):IsCommodity(1) })
        end)

        it("is unknown with no data", function()
            assert.are.same({ nil, "unknown" }, { make(nil, nil):IsCommodity(1) })
            assert.are.same({ nil, "unknown" }, { ScanKey.New():IsCommodity(1) })
        end)

        it("counts a mismatch once and the client wins", function()
            local r = make(false, 20)
            assert.are.same({ false, "client" }, { r:IsCommodity(1) })
            r:IsCommodity(1)
            assert.are.equal(1, r:GetStats().mismatch)
            r:IsCommodity(2)
            assert.are.equal(2, r:GetStats().mismatch)
        end)

        it("does not count a match as a mismatch", function()
            local r = make(true, 20)
            r:IsCommodity(1)
            assert.are.equal(0, r:GetStats().mismatch)
        end)

        it("does not cache unknown", function()
            local client
            local r = ScanKey.New({ clientIsCommodity = function() return client end })
            assert.is_nil((r:IsCommodity(1)))
            client = true
            assert.are.same({ true, "client" }, { r:IsCommodity(1) })
            client = false
            assert.are.same({ true, "client" }, { r:IsCommodity(1) })
        end)

        it("treats a lookup error as nil", function()
            local r = ScanKey.New({
                clientIsCommodity = function() error("boom") end,
                maxStack = function() return 5 end,
            })
            assert.are.same({ true, "stack" }, { r:IsCommodity(1) })
            r = ScanKey.New({
                clientIsCommodity = function() error("boom") end,
                maxStack = function() error("boom") end,
            })
            assert.are.same({ nil, "unknown" }, { r:IsCommodity(1) })
        end)
    end)

    describe("KeyFor", function()
        it("returns a base key for a commodity without a link", function()
            local r = make(true, 200)
            assert.are.same({ "190", true }, { r:KeyFor(190) })
            assert.are.same({ "190", true }, { r:KeyFor(190, "garbage") })
        end)

        it("returns an exact key for gear", function()
            local r = make(false, 1)
            local link = "|cff0070dd|Hitem:100::::::-37::::::3:4786:1520:6652|h[Sword]|h|r"
            assert.are.same({ "100#s-37#b1520,4786,6652", false }, { r:KeyFor(100, link) })
        end)

        it("returns no-link for a missing or bad link", function()
            local r = make(false, 1)
            assert.are.same({ nil, "no-link" }, { r:KeyFor(100) })
            assert.are.same({ nil, "no-link" }, { r:KeyFor(100, "nothing") })
        end)

        it("returns link-mismatch for another item", function()
            local r = make(false, 1)
            assert.are.same({ nil, "link-mismatch" }, { r:KeyFor(100, "item:101") })
        end)

        it("returns unknown when undecided and the link is missing", function()
            assert.are.same({ nil, "unknown" }, { make(nil, nil):KeyFor(100) })
            assert.are.same({ nil, "unknown" }, { make(nil, nil):KeyFor(100, "nothing") })
        end)

        it("uses the exact key of the link when undecided, and counts the item once", function()
            local r = make(nil, nil)
            assert.are.same({ "100", nil }, { r:KeyFor(100, "item:100") })
            assert.are.same({ "100", nil }, { r:KeyFor(100, "item:100") })
            assert.are.same({ "100#s-34", nil }, { r:KeyFor(100, "item:100::::::-34") })
            assert.are.equal(1, r:GetStats().linkFallback)
            assert.are.equal(1, r:GetStats().unknown)
        end)

        it("returns link-mismatch for another item when undecided", function()
            assert.are.same({ nil, "link-mismatch" }, { make(nil, nil):KeyFor(100, "item:101") })
        end)
    end)

    describe("GetStats", function()
        it("counts every item once", function()
            local lookups = { client = {}, stack = {} }
            lookups.client[1] = true
            lookups.stack[2] = 5
            local r = ScanKey.New({
                clientIsCommodity = function(id) return lookups.client[id] end,
                maxStack = function(id) return lookups.stack[id] end,
            })
            r:IsCommodity(1)
            r:IsCommodity(1)
            r:IsCommodity(2)
            r:IsCommodity(2)
            r:IsCommodity(3)
            r:IsCommodity(3)
            assert.are.same({ client = 1, stack = 1, unknown = 1, mismatch = 0, linkFallback = 0 }, r:GetStats())
        end)

        it("returns a new table", function()
            local r = make(true, 1)
            local a = r:GetStats()
            a.client = 99
            assert.are.equal(0, r:GetStats().client)
        end)
    end)

    describe("IsBattlePet", function()
        it("detects a battle pet link", function()
            assert.is_true(ScanKey.IsBattlePet("|cff0070dd|Hbattlepet:1234:1:3:100:10:10:0|h[Pet]|h|r"))
        end)

        it("is false for other input", function()
            assert.is_false(ScanKey.IsBattlePet("|Hitem:100|h[Sword]|h"))
            assert.is_false(ScanKey.IsBattlePet(nil))
            assert.is_false(ScanKey.IsBattlePet(5))
        end)
    end)

    it("does not change caller tables", function()
        local lookups = {
            clientIsCommodity = function() return false end,
            maxStack = function() return 1 end,
        }
        local c, m = lookups.clientIsCommodity, lookups.maxStack
        local r = ScanKey.New(lookups)
        r:KeyFor(100, "item:100")
        assert.are.equal(c, lookups.clientIsCommodity)
        assert.are.equal(m, lookups.maxStack)
    end)
end)
