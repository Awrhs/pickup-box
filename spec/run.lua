-- Runs busted inside OpenResty's `resty` CLI so modules that depend on
-- OpenResty libraries (resty.sha256, resty.string, ...) load for real.
-- Usage (from repo root): resty spec/run.lua spec/unit
package.path = "lua/?.lua;" .. package.path
require("busted.runner")({ standalone = false })
