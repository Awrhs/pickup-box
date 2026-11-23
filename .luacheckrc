-- Luacheck configuration. Run with: luacheck lua spec
std = "ngx_lua"

-- FFI-heavy modules and tests use these.
read_globals = { "ffi" }

files["spec/**/*.lua"] = {
    std = "+busted",
    globals = { "ngx", "os" },  -- specs stub ngx and os.getenv
}

max_line_length = 120

-- Enforced: undefined globals (113), setting globals (111/112), and syntax.
-- Not enforced yet (tech debt, tracked in PROGRESS.md): unused locals/args/
-- values (211/212/213/311) and shadowing (421/431).
ignore = {
    "631",                      -- line too long
    "211", "212", "213", "311", -- unused variable / argument / loop var / value
    "421", "431",               -- shadowing
}
