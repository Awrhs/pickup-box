-- Luacheck configuration for the gateway.
-- Run with: luacheck lua/
std = "min+busted"

-- Allow OpenResty globals that appear across the codebase.
read_globals = {
    "ngx", "ndk", "ffi",
    "describe", "it", "before_each", "after_each", "spy", "mock", "stub",
}

-- Per-directory overrides
files = {
    "lua/**/*.lua",
    "spec/**/*.lua",
}

-- Reasonable style limits; silence noise on long lines.
max_line_length = 110
ignore = {
    "631",  -- line is too long
    "411",  -- variable was previously defined as an argument
}

-- Don't enforce unused warnings on ngx.ctx fields or module tables.
globals = { "ngx" }
