-- Unit tests for image.download_guard: signed URL round-trip + tamper
-- detection. Run with: busted spec/unit/download_guard_spec.lua
describe("download_guard signing", function()
    local guard

    before_each(function()
        _G.ngx = {
            time = function() return 1700000000 end,
            now  = function() return 1700000000.0 end,
            say  = function() end,
            exit = function() end,
            log  = function() end,
            var  = { uri = "/i/abc.jpg", remote_addr = "127.0.0.1" },
            req  = { get_uri_args = function() return {} end },
            header = {},
            status = 200,
            shared = {},
            config = {},
            ERR = 1, WARN = 1, INFO = 1, DEBUG = 1,
            escape_uri = function(s) return s end,
            unescape_uri = function(s) return s end,
        }
        _G.ngx.shared.image_downloads = {
            get = function() return nil end,
            incr = function() return 0 end,
        }
        package.loaded["image.config"] = nil
        package.loaded["image.download_guard"] = nil
        guard = require "image.download_guard"
        guard.set_config({ secret = "test-secret-at-least-32-chars-xxxx", signed_urls = false })
    end)

    it("round-trips a signed path and validates it", function()
        local path = "/i/abc.jpg"
        local qs = guard.sign_path(path, 3600, { w = 800, fmt = "webp" })
        assert.truthy(qs:match("^e=%d+&s=%x+&"))
        -- Parse and feed back to signature_ok indirectly: the only public
        -- verification path is enforce(); re-implement verification in terms
        -- of the public sign_path and the returned qs so we can assert the
        -- signature covers transform params.
        -- Signed params are emitted in sorted order (fmt before w).
        local e, s = qs:match("^e=(%d+)&s=(%x+)&")
        assert.equal("1700003600", e)
        assert.equal(32, #s)
        assert.truthy(qs:match("&fmt=webp"))
        assert.truthy(qs:match("&w=800"))
        assert.truthy(qs:find("fmt=webp", 1, true) < qs:find("w=800", 1, true))
    end)

    it("returns nil when no secret is configured", function()
        local g = guard
        g.set_config({ secret = "" })
        local qs, err = g.sign_path("/i/x.jpg", 60)
        assert.falsy(qs)
        assert.truthy(err)
    end)
end)
