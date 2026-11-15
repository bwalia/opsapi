--[[
    Spec: VAT filing kill switch (queries/VatFilingQueries.lua). In production a VAT
    return is only sent when VAT_FILING_ENABLED=true; the sandbox always files.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-filing-switch_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local sandbox, env = true, {}
local queried = false
package.loaded["lapis.db"] = { query = function() queried = true; return {} end }
package.loaded["helper.hmrc"] = {}
package.loaded["lib.hmrc-vat-client"] = { is_sandbox = function() return sandbox end }
package.loaded["lib.vat-return"] = {}
package.loaded["queries.VatReturnQueries"] = {}
package.loaded["lib.prometheus_metrics"] = { get_metric_vat_submissions = function() return nil end }
local real_getenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] end return real_getenv(k) end -- luacheck: ignore 122

local Q = require("queries.VatFilingQueries")

check("sandbox: always on", Q.filing_enabled() == true)
sandbox = false
check("production: off unless switched on", Q.filing_enabled() == false)
env.VAT_FILING_ENABLED = "yes"
check("production: only the exact value \"true\" switches it on", Q.filing_enabled() == false)
env.VAT_FILING_ENABLED = "true"
check("production: on when VAT_FILING_ENABLED=true", Q.filing_enabled() == true)
env.VAT_FILING_ENABLED = "false"
local row, resp = Q.submit({ id = 1, vrn = "980780684" }, "u", 1, "uuid", { declaration_accepted = true,
    period_key = "18A1" })
check("switched off: refused with 503 before anything else", row == nil and resp.status == 503
    and resp.json.code == "VAT_FILING_OFF" and not queried)

os.getenv = real_getenv -- luacheck: ignore 122
print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
