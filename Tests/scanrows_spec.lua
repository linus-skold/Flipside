local manifest = require("Tests.manifest")
describe("ScanRows", function()
    local ScanRows
    local PET = "|cff0070dd|Hbattlepet:1:1:1:1:1:1:1|h[Pet]|h|r"
    local ITEM = "|cff0070dd|Hitem:100::::::::70:::::|h[Item]|h|r"

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("ItemString")))("Flipside", ns)
        assert(loadfile(manifest.path("ScanKey")))("Flipside", ns)
        assert(loadfile(manifest.path("ScanRows")))("Flipside", ns)
        ScanRows = ns.ScanRows
    end)

    local function newJob(cancelAfterChecks)
        local job = { checkpoints = {}, progress = {}, cancelled = false, checks = 0 }
        function job:Checkpoint(units) self.checkpoints[#self.checkpoints + 1] = units end
        function job:SetProgress(done, total) self.progress[#self.progress + 1] = { done, total } end
        function job:IsCancelled()
            self.checks = self.checks + 1
            if cancelAfterChecks and self.checks > cancelAfterChecks then
                self.cancelled = true
            end
            return self.cancelled
        end
        return job
    end

    -- A row: { item, count, buyout, all, link, pet, fail }.
    local function newApi(rows)
        local api = { infoCalls = {} }
        function api.getNum() return #rows end
        function api.getInfo(i)
            api.infoCalls[#api.infoCalls + 1] = i
            local r = rows[i + 1]
            if r.fail then error("boom") end
            return "n", 1, r.count, 1, true, 1, 0, 0, 0, r.buyout, 0, false, "", "", "", 0, r.item, r.all
        end
        function api.getLink(i) return rows[i + 1].link end
        function api.getPetInfo(i)
            if rows[i + 1].pet then return "pet" end
        end
        return api
    end

    local function good(item, count, buyout)
        return { item = item, count = count or 1, buyout = buyout or 100, all = true, link = ITEM }
    end

    describe("Read", function()
        it("reads index 0 to n-1 for n = 0, 1 and 2500", function()
            for _, n in ipairs({ 0, 1, 2500 }) do
                local rows = {}
                for i = 1, n do rows[i] = good(i) end
                local api = newApi(rows)
                local result = ScanRows.Read(newJob(), api)
                assert.are.equal(n, #api.infoCalls)
                if n > 0 then
                    assert.are.equal(0, api.infoCalls[1])
                    assert.are.equal(n - 1, api.infoCalls[n])
                end
                assert.are.equal(n, result.stats.rows)
                assert.are.equal(n, result.stats.kept)
                assert.are.equal(n, result.stats.items)
            end
        end)

        it("calls Checkpoint(1) once per row", function()
            local rows = { good(1), good(2), { item = nil }, good(3) }
            local job = newJob()
            ScanRows.Read(job, newApi(rows))
            assert.are.same({ 1, 1, 1, 1 }, job.checkpoints)
        end)

        it("skips and counts each reason", function()
            local rows = {
                { item = nil, count = 1, buyout = 100 },
                { item = 1, count = 1, buyout = nil, all = true, link = ITEM },
                { item = 1, count = 1, buyout = 0, all = true, link = ITEM },
                { item = 2, count = 1, buyout = 100, all = true, link = ITEM, pet = true },
                { item = 3, count = 1, buyout = 100, all = true, link = PET },
                { item = 4, count = 0, buyout = 100, all = true, link = ITEM },
                { item = 4, count = 1.5, buyout = 100, all = true, link = ITEM },
                { item = 4, count = nil, buyout = 100, all = true, link = ITEM },
                good(5),
            }
            local s = ScanRows.Read(newJob(), newApi(rows)).stats
            assert.are.equal(9, s.rows)
            assert.are.equal(1, s.empty)
            assert.are.equal(2, s.bidOnly)
            assert.are.equal(2, s.pet)
            assert.are.equal(3, s.badCount)
            assert.are.equal(1, s.kept)
            assert.are.equal(1, s.items)
        end)

        it("uses total buyout / count as unit price (not verified in game)", function()
            local result = ScanRows.Read(newJob(), newApi({ good(7, 4, 1000) }))
            local row = result.byItem[7][1]
            assert.are.equal(250, row.unitPrice)
            assert.are.equal(4, row.count)
            assert.are.equal(0, row.index)
            assert.are.equal(ITEM, row.link)
        end)

        it("groups rows by item id", function()
            local result = ScanRows.Read(newJob(), newApi({ good(1), good(2), good(1) }))
            assert.are.equal(2, #result.byItem[1])
            assert.are.equal(2, result.byItem[1][2].index + 0)
            assert.are.equal(1, #result.byItem[2])
            assert.are.equal(2, result.stats.items)
        end)

        it("marks pending for hasAllInfo false and for nil link", function()
            local rows = {
                { item = 1, count = 1, buyout = 10, all = false, link = ITEM },
                { item = 2, count = 1, buyout = 10, all = true, link = nil },
                good(3),
            }
            local result = ScanRows.Read(newJob(), newApi(rows))
            assert.is_true(result.pending[1])
            assert.is_true(result.pending[2])
            assert.is_nil(result.pending[3])
            assert.are.equal(2, result.stats.pendingItems)
            assert.is_nil(result.byItem[2][1].link)
        end)

        it("stops and returns nil when cancelled", function()
            local rows = {}
            for i = 1, 3500 do rows[i] = good(i) end
            local api = newApi(rows)
            local job = newJob(1)
            assert.is_nil(ScanRows.Read(job, api))
            assert.are.equal(1000, #api.infoCalls)
        end)

        it("returns nil when already cancelled", function()
            local job = newJob()
            job.cancelled = true
            local api = newApi({ good(1) })
            assert.is_nil(ScanRows.Read(job, api))
            assert.are.equal(0, #api.infoCalls)
        end)

        it("counts a failing call as empty and stores the first error", function()
            local rows = { good(1), { fail = true }, good(2), { fail = true } }
            local result = ScanRows.Read(newJob(), newApi(rows))
            assert.are.equal(2, result.stats.empty)
            assert.are.equal(2, result.stats.kept)
            assert.is_truthy(result.stats.firstError:find("boom", 1, true))
        end)

        it("counts a failing getLink as empty", function()
            local api = newApi({ good(1), good(2) })
            api.getLink = function(i)
                if i == 0 then error("linkfail") end
                return ITEM
            end
            local result = ScanRows.Read(newJob(), api)
            assert.are.equal(1, result.stats.empty)
            assert.are.equal(1, result.stats.kept)
            assert.is_truthy(result.stats.firstError:find("linkfail", 1, true))
        end)

        it("reports progress every 1000 rows and at the end", function()
            local rows = {}
            for i = 1, 2500 do rows[i] = good(i) end
            local job = newJob()
            ScanRows.Read(job, newApi(rows))
            assert.are.same({ { 1000, 2500 }, { 2000, 2500 }, { 2500, 2500 } }, job.progress)
        end)

        it("reports progress once when n is a multiple of 1000", function()
            local rows = {}
            for i = 1, 1000 do rows[i] = good(i) end
            local job = newJob()
            ScanRows.Read(job, newApi(rows))
            assert.are.same({ { 1000, 1000 } }, job.progress)
        end)

        it("reports progress for n = 0", function()
            local job = newJob()
            ScanRows.Read(job, newApi({}))
            assert.are.same({ { 0, 0 } }, job.progress)
        end)
    end)

    describe("RereadLinks", function()
        it("stores new links and clears pending", function()
            local rows = {
                { item = 1, count = 1, buyout = 10, all = false, link = nil },
                { item = 1, count = 1, buyout = 10, all = false, link = nil },
            }
            local api = newApi(rows)
            local job = newJob()
            local result = ScanRows.Read(job, api)
            assert.is_true(result.pending[1])
            rows[1].link, rows[2].link = ITEM, ITEM
            local job2 = newJob()
            ScanRows.RereadLinks(job2, api, result, { 1 })
            assert.is_nil(result.pending[1])
            assert.are.equal(ITEM, result.byItem[1][1].link)
            assert.are.same({ 1, 1 }, job2.checkpoints)
            assert.are.equal(0, result.stats.pendingItems)
        end)

        it("keeps pending while a row has no link", function()
            local rows = {
                { item = 1, count = 1, buyout = 10, all = false, link = nil },
                { item = 1, count = 1, buyout = 10, all = false, link = nil },
            }
            local api = newApi(rows)
            local result = ScanRows.Read(newJob(), api)
            rows[1].link = ITEM
            ScanRows.RereadLinks(newJob(), api, result, { 1 })
            assert.is_true(result.pending[1])
            assert.are.equal(1, result.stats.pendingItems)
        end)

        it("removes rows that are now battle pets", function()
            local rows = {
                { item = 1, count = 1, buyout = 10, all = false, link = nil },
                { item = 2, count = 1, buyout = 10, all = false, link = nil },
                { item = 2, count = 1, buyout = 10, all = false, link = nil },
            }
            local api = newApi(rows)
            local result = ScanRows.Read(newJob(), api)
            rows[1].link = PET
            rows[2].link, rows[3].link = ITEM, PET
            ScanRows.RereadLinks(newJob(), api, result, { 1, 2 })
            assert.is_nil(result.byItem[1])
            assert.is_nil(result.pending[1])
            assert.are.equal(1, #result.byItem[2])
            assert.is_nil(result.pending[2])
            assert.are.equal(2, result.stats.pet)
            assert.are.equal(1, result.stats.kept)
            assert.are.equal(1, result.stats.items)
        end)

        it("records an error and keeps the row when getLink fails", function()
            local rows = { { item = 1, count = 1, buyout = 10, all = false, link = nil } }
            local api = newApi(rows)
            local result = ScanRows.Read(newJob(), api)
            api.getLink = function() error("again") end
            ScanRows.RereadLinks(newJob(), api, result, { 1 })
            assert.is_true(result.pending[1])
            assert.is_truthy(result.stats.firstError:find("again", 1, true))
        end)
    end)

    it("merges page results and counts the items", function()
        local into = ScanRows.NewResult()
        local one = { byItem = { [1] = { { index = 0 } } }, pending = { [1] = true },
            stats = { rows = 2, kept = 1, empty = 1, bidOnly = 0, pet = 0, badCount = 0, items = 1, pendingItems = 1 } }
        local two = { byItem = { [1] = { { index = 0 } }, [2] = { { index = 1 } } }, pending = {},
            stats = { rows = 3, kept = 2, empty = 1, bidOnly = 0, pet = 0, badCount = 0, items = 2, pendingItems = 0 } }
        ScanRows.Merge(into, one)
        ScanRows.Merge(into, two)
        assert.are.equal(5, into.stats.rows)
        assert.are.equal(3, into.stats.kept)
        assert.are.equal(2, #into.byItem[1])
        assert.are.equal(2, into.stats.items)
        assert.are.equal(1, into.stats.pendingItems)
    end)

    it("reads only rows without a link when onlyMissing is set", function()
        local calls = {}
        local api = { getLink = function(i) calls[#calls + 1] = i return ITEM end }
        local result = { byItem = { [100] = { { index = 0, link = ITEM }, { index = 1 } } }, pending = { [100] = true },
            stats = { kept = 2, pet = 0, items = 1, pendingItems = 1 } }
        ScanRows.RereadLinks(newJob(), api, result, { 100 }, true)
        assert.are.same({ 1 }, calls)
        assert.is_nil(result.pending[100])
    end)
end)
