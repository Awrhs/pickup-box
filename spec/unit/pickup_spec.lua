-- Unit tests for pure pickup-box helpers. Run: resty spec/run.lua spec/unit
describe("pickup.config parsers", function()
    local pc = require "pickup.config"
    it("parses sizes", function()
        assert.equal(2 * 1024 ^ 3, pc.parse_size("2G"))
        assert.equal(500 * 1024 ^ 2, pc.parse_size("500m"))
        assert.equal(1024, pc.parse_size("1KiB"))
        assert.equal(1536, pc.parse_size("1.5k"))
        assert.equal(42, pc.parse_size("42"))
        assert.is_nil(pc.parse_size("lots"))
        assert.is_nil(pc.parse_size(""))
    end)
    it("parses durations", function()
        assert.equal(604800, pc.parse_duration("7d"))
        assert.equal(5400, pc.parse_duration("90m"))
        assert.equal(36, pc.parse_duration("36"))
        assert.equal(1209600, pc.parse_duration("2w"))
        assert.is_nil(pc.parse_duration("soon"))
    end)
end)

describe("pickup.shares names", function()
    local shares
    setup(function()
        package.loaded["image.metadata"] = {}
        shares = require "pickup.shares"
    end)
    it("keeps only the base name and strips dangerous characters", function()
        assert.equal("passwd", shares.clean_name("../../etc/passwd"))
        assert.equal("a_b_.txt", shares.clean_name("a<b>.txt"))
        assert.equal("报告.pdf", shares.clean_name("C:\\Users\\me\\报告.pdf"))
        assert.equal("_hidden", shares.clean_name(".hidden"))
        assert.equal("file-3", shares.clean_name("   ", 3))
        assert.equal("x.txt", shares.clean_name("x.txt\0\1"))
    end)
    it("replaces invalid UTF-8", function()
        assert.equal("a?b", shares.valid_utf8("a\255b"))
        assert.equal("你好", shares.valid_utf8("你好"))
        assert.equal("??", shares.valid_utf8("\228\189"))  -- truncated sequence
    end)
    it("truncates long names on character boundaries", function()
        local n = shares.clean_name(string.rep("中", 100) .. ".txt")
        assert.is_true(#n <= 180)
        assert.equal(n, shares.valid_utf8(n))
    end)
    it("dedupes names case-insensitively", function()
        assert.same({ "a.jpg", "A (2).jpg", "a (3).jpg", "b" },
            shares.dedupe_names({ "a.jpg", "A.jpg", "a.jpg", "b" }))
    end)
end)

describe("common.digest", function()
    local digest = require "common.digest"
    it("computes the standard CRC-32 check value", function()
        assert.equal(0xCBF43926, digest.crc32("123456789"))
        assert.equal(0, digest.crc32(""))
        assert.equal(digest.crc32("hello world"), digest.crc32(" world", digest.crc32("hello")))
    end)
end)

describe("pickup.sniff", function()
    local sniff = require "pickup.sniff"
    local function kind(head) return (sniff.classify(head)) end
    it("classifies by magic bytes", function()
        assert.equal("image", kind("\255\216\255\224\0\16JFIF"))
        assert.equal("image", kind("\137PNG\r\n\26\n\0\0\0\13IHDR"))
        assert.equal("video", kind("\0\0\0\24ftypisom\0\0\2\0"))
        assert.equal("video", kind("\0\0\0\20ftypqt  \0\0\0\0"))
        assert.equal("image", kind("\0\0\0\24ftypheic\0\0\0\0"))
        assert.equal("audio", kind("ID3\4\0\0\0\0\0\0"))
        assert.equal("audio", kind("\255\251\144\100"))
        assert.equal("other", kind("\255\254h\0i\0"))           -- UTF-16 BOM, not MP3
        assert.equal("other", kind("<html><script>alert(1)</script>"))
        assert.equal("other", kind("<svg xmlns='http://www.w3.org/2000/svg'>"))
        assert.equal("other", kind("%PDF-1.7"))
        assert.equal("other", kind(""))
    end)
    it("derives MIME types for downloads from the name", function()
        assert.equal("application/pdf", sniff.mime_for_name("a.PDF"))
        assert.equal("application/octet-stream", sniff.mime_for_name("evil.html"))
    end)
end)

describe("pickup.zip", function()
    local zip = require "pickup.zip"
    local digest = require "common.digest"

    local function u16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
    local function u32(s, i) return u16(s, i) + u16(s, i + 2) * 65536 end

    local function build(files, opts)
        local entries = {}
        for i, f in ipairs(files) do
            entries[i] = { name = f[1], size = #f[2], crc32 = digest.crc32(f[2]) }
        end
        local plan = zip.plan(entries, opts)
        local parts = {}
        for i, e in ipairs(plan.entries) do
            parts[#parts + 1] = e.header
            parts[#parts + 1] = files[i][2]
        end
        parts[#parts + 1] = plan.trailer
        return table.concat(parts), plan
    end

    it("produces an archive of exactly the planned size", function()
        local data, plan = build({ { "a.txt", "hello" }, { "图片.jpg", string.rep("x", 1000) } })
        assert.equal(plan.total, #data)
        assert.equal(0x04034b50, u32(data, 1))
        -- End of central directory: 2 entries, pointing at the central dir.
        local eocd = #data - 21
        assert.equal(0x06054b50, u32(data, eocd))
        assert.equal(2, u16(data, eocd + 10))
        local cd_size, cd_off = u32(data, eocd + 12), u32(data, eocd + 16)
        assert.equal(0x02014b50, u32(data, cd_off + 1))
        assert.equal(eocd - 1, cd_off + cd_size)
    end)
    it("sets the UTF-8 flag and stores CRCs", function()
        local data = build({ { "名字.txt", "abc" } })
        assert.equal(0x0800, u16(data, 7))
        assert.equal(digest.crc32("abc"), u32(data, 15))
    end)
    it("writes ZIP64 records when forced", function()
        local data, plan = build({ { "a", "1" }, { "b", "22" } }, { force_zip64 = true })
        assert.equal(plan.total, #data)
        assert.equal(0xFFFFFFFF, u32(data, 19))          -- local compressed size
        local eocd = #data - 21
        assert.equal(0xFFFF, u16(data, eocd + 10))
        local loc = eocd - 20
        assert.equal(0x07064b50, u32(data, loc))
        local z64 = u32(data, loc + 8)
        assert.equal(0x06064b50, u32(data, z64 + 1))
    end)
    it("handles an empty file", function()
        local data, plan = build({ { "empty", "" } })
        assert.equal(plan.total, #data)
    end)
end)
