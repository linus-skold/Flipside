local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("ItemInfoCache")))("Flipside", ns)
local IIC = ns.ItemInfoCache

describe("ItemInfoCache", function()
    local client, requests, errors, cache

    before_each(function()
        client = {}
        requests = {}
        errors = {}
        cache = IIC.New({
            getInfo = function(id)
                return client[id]
            end,
            requestLoad = function(id)
                requests[#requests + 1] = id
            end,
            onError = function(message)
                errors[#errors + 1] = message
            end,
        })
    end)

    it("maps all 17 values in FromItemInfo", function()
        local info = IIC.FromItemInfo("n", "l", 2, 3, 4, "t", "st", 5, "eq", 6, 7, 8, 9, 10, 11, 12, true)
        assert.same({
            name = "n", link = "l", quality = 2, itemLevel = 3, minLevel = 4, itemType = "t",
            itemSubType = "st", stackCount = 5, equipLoc = "eq", icon = 6, sellPrice = 7,
            classID = 8, subclassID = 9, bindType = 10, expansionID = 11, setID = 12,
            isCraftingReagent = true,
        }, info)
    end)

    it("returns nil from FromItemInfo for no data", function()
        assert.is_nil(IIC.FromItemInfo())
        assert.is_nil(IIC.FromItemInfo(nil, "l"))
    end)

    it("requires getInfo and requestLoad", function()
        assert.has_error(function() IIC.New({ requestLoad = function() end }) end)
        assert.has_error(function() IIC.New({ getInfo = function() end }) end)
    end)

    it("Get loads data that the client already has", function()
        client[10] = { name = "a" }
        local info, state = cache:Get(10)
        assert.equals(client[10], info)
        assert.equals("loaded", state)
        assert.equals("loaded", cache:GetState(10))
        assert.equals(0, #requests)
    end)

    it("Get without data does not request", function()
        local info, state = cache:Get(10)
        assert.is_nil(info)
        assert.equals("unknown", state)
        assert.equals(0, #requests)
    end)

    it("Request calls requestLoad once and runs all callbacks", function()
        local got = {}
        for i = 1, 3 do
            cache:Request(10, function(id, info, state)
                got[i] = { id, info, state }
            end)
        end
        assert.same({ 10 }, requests)
        assert.equals("requested", cache:GetState(10))
        client[10] = { name = "a" }
        cache:OnLoadResult(10, true)
        for i = 1, 3 do
            assert.same({ 10, client[10], "loaded" }, got[i])
        end
        assert.equals("loaded", cache:GetState(10))
    end)

    it("calls the callback at once for a loaded item", function()
        client[10] = { name = "a" }
        local called
        cache:Request(10, function(id, info, state) called = { id, info, state } end)
        assert.same({ 10, client[10], "loaded" }, called)
        assert.equals(0, #requests)
    end)

    it("calls the callback at once for a failed item", function()
        cache:Request(10)
        cache:OnLoadResult(10, false)
        local called
        cache:Request(10, function(id, info, state) called = { id, info, state } end)
        assert.same({ 10, nil, "failed" }, called)
        assert.equals(1, #requests)
    end)

    it("sets failed on success without data", function()
        local state
        cache:Request(10, function(_, _, s) state = s end)
        cache:OnLoadResult(10, true)
        assert.equals("failed", state)
        assert.equals("failed", cache:GetState(10))
    end)

    it("sets failed on success false", function()
        cache:Request(10)
        client[10] = { name = "a" }
        cache:OnLoadResult(10, false)
        assert.equals("failed", cache:GetState(10))
    end)

    it("isolates a failing callback and reports it", function()
        local second = false
        cache:Request(10, function() error("boom") end)
        cache:Request(10, function() second = true end)
        client[10] = { name = "a" }
        cache:OnLoadResult(10, true)
        assert.is_true(second)
        assert.equals(1, #errors)
        assert.truthy(errors[1]:find("boom", 1, true))
    end)

    it("runs callbacks only one time", function()
        local count = 0
        cache:Request(10, function() count = count + 1 end)
        client[10] = { name = "a" }
        cache:OnLoadResult(10, true)
        cache:OnLoadResult(10, true)
        assert.equals(1, count)
    end)

    it("ResetFailed allows a new load request", function()
        cache:Request(10)
        cache:OnLoadResult(10, false)
        assert.equals(1, cache:ResetFailed())
        assert.equals("unknown", cache:GetState(10))
        assert.equals(0, cache:ResetFailed())
        cache:Request(10)
        assert.same({ 10, 10 }, requests)
    end)

    it("Get runs the callbacks of a requested item when the client has the data", function()
        local count = 0
        cache:Request(10, function() count = count + 1 end)
        client[10] = { name = "a" }
        cache:Get(10)
        assert.equals(1, count)
        assert.equals("loaded", cache:GetState(10))
        cache:OnLoadResult(10, true)
        assert.equals(1, count)
    end)

    it("Get runs the callbacks on a later frame when after is set", function()
        local queue, count = {}, 0
        cache = IIC.New({
            getInfo = function(id) return client[id] end,
            requestLoad = function() end,
            after = function(fn) queue[#queue + 1] = fn end,
        })
        cache:Request(10, function() count = count + 1 end)
        client[10] = { name = "a" }
        cache:Get(10)
        assert.equals(0, count)
        assert.equals(1, #queue)
        cache:OnLoadResult(10, true)
        assert.equals(0, count)
        queue[1]()
        assert.equals(1, count)
    end)

    it("Request on a pending item keeps both callbacks and sends one request", function()
        local calls = {}
        cache:Request(10, function() calls[#calls + 1] = "a" end)
        cache:Request(10, function() calls[#calls + 1] = "b" end)
        assert.same({ 10 }, requests)
        client[10] = { name = "a" }
        cache:OnLoadResult(10, true)
        assert.same({ "a", "b" }, calls)
    end)

    it("Resend sends the request again and keeps the callback", function()
        local count = 0
        cache:Request(10, function() count = count + 1 end)
        assert.is_true(cache:Resend(10))
        assert.same({ 10, 10 }, requests)
        client[10] = { name = "a" }
        cache:OnLoadResult(10, true)
        assert.equals(1, count)
    end)

    it("Resend returns false for an item that is not requested", function()
        assert.is_false(cache:Resend(10))
        assert.same({}, requests)
    end)

    it("Reload sends a real request for a loaded item and runs the callback once on the result", function()
        client[10] = { name = "a" }
        cache:Request(10)
        assert.equals("loaded", cache:GetState(10))
        local count = 0
        local function callback() count = count + 1 end
        cache:Reload(10, callback)
        cache:Reload(10, callback)
        assert.same({ 10, 10 }, requests)
        assert.equals("requested", cache:GetState(10))
        cache:OnLoadResult(10, true)
        assert.equals(1, count)
        assert.equals("loaded", cache:GetState(10))
    end)

    it("Reload marks the item failed when the request raises an error", function()
        local called
        local failing = IIC.New({
            getInfo = function() end,
            requestLoad = function() error("boom") end,
        })
        failing:Reload(10, function(_, _, state) called = state end)
        assert.equals("failed", failing:GetState(10))
        assert.equals("failed", called)
    end)

    it("counts pending items", function()
        cache:Request(1)
        cache:Request(2)
        cache:Request(2)
        assert.equals(2, cache:GetPendingCount())
        client[1] = { name = "a" }
        cache:OnLoadResult(1, true)
        assert.equals(1, cache:GetPendingCount())
    end)

    it("Wipe removes items and drops callbacks", function()
        local called = false
        cache:Request(10, function() called = true end)
        cache:Wipe()
        assert.equals(0, cache:GetPendingCount())
        assert.equals("unknown", cache:GetState(10))
        client[10] = { name = "a" }
        cache:OnLoadResult(10, true)
        assert.is_false(called)
    end)

    it("raises an error for invalid ids", function()
        for _, bad in ipairs({ 0, -1, 1.5, "7" }) do
            assert.has_error(function() cache:Get(bad) end)
            assert.has_error(function() cache:Request(bad) end)
            assert.has_error(function() cache:GetState(bad) end)
        end
        assert.has_error(function() cache:Get(nil) end)
        assert.has_no.errors(function() cache:OnLoadResult("x", true) end)
        assert.has_no.errors(function() cache:OnLoadResult(-5, true) end)
    end)

    it("marks failed and reports when requestLoad fails", function()
        local c = IIC.New({
            getInfo = function() end,
            requestLoad = function() error("no") end,
            onError = function(m) errors[#errors + 1] = m end,
        })
        local state
        c:Request(10, function(_, _, s) state = s end)
        assert.equals("failed", c:GetState(10))
        assert.equals("failed", state)
        assert.equals(1, #errors)
    end)

    it("keeps state when getInfo fails in Get", function()
        local c = IIC.New({
            getInfo = function() error("bad") end,
            requestLoad = function() end,
            onError = function(m) errors[#errors + 1] = m end,
        })
        local info, state = c:Get(10)
        assert.is_nil(info)
        assert.equals("unknown", state)
        assert.equals(1, #errors)
    end)

    it("stores a success result for an item that was never requested", function()
        client[10] = { name = "a" }
        cache:OnLoadResult(10, true)
        assert.equals("loaded", cache:GetState(10))
    end)

    it("ignores a failed result for an item that was never requested", function()
        cache:OnLoadResult(10, false)
        cache:OnLoadResult(11, true)
        assert.equals("unknown", cache:GetState(10))
        assert.equals("unknown", cache:GetState(11))
    end)
end)
