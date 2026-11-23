-- Unit tests for API key entry parsing (IMAGE_API_KEYS / key file format).
describe("image.config key parsing", function()
    local parse

    setup(function()
        package.loaded["image.config"] = nil
        parse = require("image.config")._parse_key_entry
    end)

    it("accepts a bare secret", function()
        local name, secret, role = parse("just-a-long-secret-value")
        assert.equal("default", name)
        assert.equal("just-a-long-secret-value", secret)
        assert.equal("upload", role)
    end)
    it("accepts name:secret", function()
        local name, secret, role = parse("alice:s3cret-0123456789")
        assert.same({ "alice", "s3cret-0123456789", "upload" }, { name, secret, role })
    end)
    it("accepts name:secret:role (three fields)", function()
        local name, secret, role = parse("bob:admin-secret-0123456789:admin")
        assert.same({ "bob", "admin-secret-0123456789", "admin" }, { name, secret, role })
    end)
    it("accepts quota and expiry", function()
        local name, secret, role, quota, expires = parse("c:sec-0123456789abcdef:upload:1024:1700000000")
        assert.same({ "c", "sec-0123456789abcdef", "upload", "1024", "1700000000" },
                    { name, secret, role, quota, expires })
    end)
    it("defaults an empty role and drops a non-numeric quota", function()
        local _, _, role, quota = parse("d:sec-0123456789abcdef::lots")
        assert.equal("upload", role)
        assert.is_nil(quota)
    end)
    it("rejects an empty secret", function()
        assert.is_nil(parse("e::admin"))
    end)
end)
