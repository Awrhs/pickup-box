-- Unit tests for image.util (format detection, transform arg parsing).
-- Run with: busted spec/unit/image_util_spec.lua
describe("image.util", function()
    local util

    before_each(function()
        _G.ngx = {
            time = function() return 1000 end,
            now  = function() return 1000.0 end,
            req  = { get_uri_args = function() return {} end },
            say  = function() end,
            exit = function() end,
            header = {},
            status = 200,
            log = function() end,
            ERR = 1,
        }
        package.loaded["image.config"] = nil
        package.loaded["image.util"] = nil
        util = require "image.util"
    end)

    it("detects JPEG by FFD8FF", function()
        local f = util.detect_format("\255\216\255\000\000\000\000\000\000\000\000\000")
        assert.equal("jpeg", f)
    end)
    it("detects PNG by 8-byte signature", function()
        local f = util.detect_format("\137\080\078\071\013\010\026\010rest")
        assert.equal("png", f)
    end)
    it("detects GIF89a", function()
        local f = util.detect_format("GIF89a" .. string.rep("\0", 12))
        assert.equal("gif", f)
    end)
    it("detects WebP (RIFF....WEBP)", function()
        local data = "RIFF" .. string.rep("\0", 4) .. "WEBP" .. string.rep("\0", 20)
        local f = util.detect_format(data)
        assert.equal("webp", f)
    end)
    it("rejects garbage", function()
        assert.falsy(util.detect_format(string.rep("x", 32)))
    end)
    it("canonicalizes jpg to jpeg", function()
        assert.equal("jpeg", util.canonical_format("jpg"))
        assert.equal("jpeg", util.canonical_format("JPEG"))
        assert.equal("webp", util.canonical_format("webp"))
        assert.falsy(util.canonical_format("bmp"))
    end)
    it("parses safe transform args", function()
        _G.ngx.req.get_uri_args = function()
            return { w = "800", h = "600", fit = "cover", q = "70",
                     fmt = "webp", wm = "1", gray = "1", blur = "2" }
        end
        local p, err = util.parse_transform_args()
        assert.truthy(p)
        assert.equal(800, p.width)
        assert.equal(600, p.height)
        assert.is_true(p.crop)
        assert.equal(70, p.quality)
        assert.equal("webp", p.format)
        assert.is_true(p.watermark)
        assert.is_true(p.grayscale)
        assert.equal(2, p.blur)
        assert.falsy(err)
    end)
    it("rejects out-of-range width", function()
        _G.ngx.req.get_uri_args = function() return { w = "999999" } end
        local p, err = util.parse_transform_args()
        assert.falsy(p)
        assert.truthy(err)
    end)
    it("rejects unknown format", function()
        _G.ngx.req.get_uri_args = function() return { fmt = "bmp" } end
        local p, err = util.parse_transform_args()
        assert.falsy(p)
        assert.truthy(err)
    end)
end)
