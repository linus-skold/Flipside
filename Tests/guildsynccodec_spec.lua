local manifest = require("Tests.manifest")

describe("GuildSyncCodec", function()
    local Codec, now, drops

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("GuildSyncCodec")))("Flipside", ns)
        Codec = ns.GuildSyncCodec
        now = 1000
        drops = {}
    end)

    local SCOPE = Codec.ScopeKey("EU", nil, "standard")

    local function entries(count, base)
        local list = {}
        for i = 1, count do
            list[i] = { key = tostring(1000 + i) .. "::", min = 5000 + i, market = 5200 + i, qty = 40 + i,
                time = (base or 1760000000) - (i % 3) * 60 }
        end
        return list
    end

    local function assembler()
        return Codec.NewAssembler({
            clock = function()
                return now
            end,
            idleSeconds = 60,
            onDrop = function(sender, reason)
                drops[#drops + 1] = sender .. ":" .. reason
            end,
        })
    end

    local function parseAll(messages)
        local chunks = {}
        for i, text in ipairs(messages) do
            chunks[i] = assert(Codec.Parse(text))
        end
        return chunks
    end

    describe("scope key", function()
        it("joins region, realm and ruleset and keeps only safe characters", function()
            assert.are.equal("EU._.standard", SCOPE)
            assert.are.equal("US.Tarren_Mill.standard", Codec.ScopeKey("US", "Tarren Mill", "standard"))
            assert.is_nil(string.find(Codec.ScopeKey("EU", "Dunkelhain;|x", "s"), "[;|]"))
        end)
    end)

    describe("request", function()
        it("round trips", function()
            local parsed = assert(Codec.Parse(Codec.BuildRequest(SCOPE, 1760000000)))
            assert.are.same({ kind = "Q", scope = SCOPE, newest = 1760000000 }, parsed)
        end)
    end)

    describe("data set", function()
        it("round trips items through chunks", function()
            local list = entries(30)
            local messages = assert(Codec.BuildSet(SCOPE, 77, list))
            local asm = assembler()
            local set
            for _, chunk in ipairs(parseAll(messages)) do
                set = asm:Add("Bob-Realm", chunk) or set
            end
            assert.is_table(set)
            local back = {}
            for index = 1, set.total do
                local items, skipped = Codec.ParseItems(set.parts[index], set.time)
                assert.are.equal(0, skipped)
                for _, item in ipairs(items) do
                    back[item.key] = item
                end
            end
            for _, entry in ipairs(list) do
                assert.are.same(entry, back[entry.key])
            end
        end)

        it("keeps each message under the byte limit and makes more than one for many items", function()
            local messages = assert(Codec.BuildSet(SCOPE, 1, entries(200)))
            assert.is_true(#messages > 1)
            for _, text in ipairs(messages) do
                assert.is_true(#text <= Codec.MAX_BYTES)
                assert.is_true(Codec.MAX_BYTES < 255)
            end
        end)

        it("uses only the safe character set", function()
            for _, text in ipairs(assert(Codec.BuildSet(SCOPE, 1, entries(50)))) do
                assert.is_nil(string.find(text, "[^%w;,:/%._%-]"))
            end
            assert.is_nil(string.find(Codec.BuildRequest(SCOPE, 5), "[^%w;,:/%._%-]"))
        end)

        it("gives an empty list for no entries", function()
            assert.are.same({}, Codec.BuildSet(SCOPE, 1, {}))
        end)

        it("refuses an item that cannot fit in one message", function()
            local list = { { key = string.rep("1", 300), min = 1, market = 1, qty = 1, time = 5 } }
            local messages, problem = Codec.BuildSet(SCOPE, 1, list)
            assert.is_nil(messages)
            assert.is_string(problem)
        end)
    end)

    describe("Parse", function()
        it("rejects another protocol version", function()
            local text = Codec.BuildRequest(SCOPE, 5):gsub("^1;", "2;")
            local parsed, reason = Codec.Parse(text)
            assert.is_nil(parsed)
            assert.are.equal("version", reason)
        end)

        it("rejects text that is not a message", function()
            for _, text in ipairs({ "", "hello", "1;X;a;b", "1;Q;;5", "1;D;s;1;3;2;5;x", "1;D;s;1;0;2;5;x", 5 }) do
                local parsed, reason = Codec.Parse(text)
                assert.is_nil(parsed)
                assert.are.equal("malformed", reason)
            end
        end)

        it("skips invalid items and counts them", function()
            local items, skipped = Codec.ParseItems("12::,1,2,3,/bad key,1,2,3,/13::,1,2,3,99999/14::,x,2,3,", 100)
            assert.are.equal(1, #items)
            assert.are.equal(3, skipped)
            assert.are.equal(100, items[1].time)
        end)
    end)

    describe("assembler", function()
        it("joins chunks that arrive out of order", function()
            local chunks = parseAll(assert(Codec.BuildSet(SCOPE, 9, entries(60))))
            assert.is_true(#chunks >= 3)
            local asm = assembler()
            local set
            for i = #chunks, 1, -1 do
                set = asm:Add("Bob", chunks[i])
                if i > 1 then
                    assert.is_nil(set)
                end
            end
            assert.is_table(set)
            assert.are.equal(#chunks, set.total)
            assert.are.equal(0, asm:Pending())
        end)

        it("ignores a repeated chunk", function()
            local chunks = parseAll(assert(Codec.BuildSet(SCOPE, 9, entries(60))))
            local asm = assembler()
            asm:Add("Bob", chunks[1])
            asm:Add("Bob", chunks[1])
            assert.are.equal(1, asm:Pending())
            local set
            for i = 2, #chunks do
                set = asm:Add("Bob", chunks[i])
            end
            assert.is_table(set)
        end)

        it("gives no set when a chunk is missing, and drops the set after the idle time", function()
            local chunks = parseAll(assert(Codec.BuildSet(SCOPE, 9, entries(60))))
            local asm = assembler()
            for i = 1, #chunks - 1 do
                assert.is_nil(asm:Add("Bob", chunks[i]))
            end
            assert.are.equal(1, asm:Pending())
            now = now + 30
            assert.are.equal(0, asm:Sweep())
            now = now + 31
            assert.are.equal(1, asm:Sweep())
            assert.are.equal(0, asm:Pending())
            assert.are.same({ "Bob:incomplete" }, drops)
            assert.is_nil(asm:Add("Bob", chunks[#chunks]))
        end)

        it("replaces an old set of a sender when a new set starts", function()
            local a = parseAll(assert(Codec.BuildSet(SCOPE, 1, entries(60))))
            local b = parseAll(assert(Codec.BuildSet(SCOPE, 2, entries(60))))
            local asm = assembler()
            asm:Add("Bob", a[1])
            asm:Add("Bob", b[1])
            assert.are.same({ "Bob:replaced" }, drops)
            assert.are.equal(1, asm:Pending())
        end)

        it("keeps the sets of different senders apart", function()
            local chunks = parseAll(assert(Codec.BuildSet(SCOPE, 1, entries(60))))
            local asm = assembler()
            asm:Add("Bob", chunks[1])
            asm:Add("Ann", chunks[1])
            assert.are.equal(2, asm:Pending())
        end)

        it("limits the number of senders", function()
            local chunks = parseAll(assert(Codec.BuildSet(SCOPE, 1, entries(60))))
            local asm = Codec.NewAssembler({
                clock = function()
                    return now
                end,
                maxSenders = 1,
                onDrop = function(sender, reason)
                    drops[#drops + 1] = sender .. ":" .. reason
                end,
            })
            asm:Add("Bob", chunks[1])
            asm:Add("Ann", chunks[1])
            assert.are.equal(1, asm:Pending())
            assert.are.same({ "Ann:busy" }, drops)
        end)
    end)
end)
