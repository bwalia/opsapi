--[[
    Spec: a File My Tax reply that asks for bank statements always carries the upload
    button (TaxTools.upload_prompt_for_reply), even when the model only asked in words.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/tax-agent-upload-button_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

package.loaded["lapis.db"] = { query = function() return {} end, select = function() return {} end }
package.loaded["resty.http"] = { new = function() error("no http in spec") end }

local TaxTools = require("lib.agent.tax-tools")
local f = TaxTools.upload_prompt_for_reply

local asks = {
    "I've saved your finance costs. To build your estimate I'll need your figures — "
        .. "could you upload your bank statements for 2025-26?",
    "Now go ahead and upload your bank statement using the button above.",
    "Please upload your bank statement (PDF or CSV).",
}
for _, r in ipairs(asks) do
    local p = f(r)
    check("button for: " .. r:sub(1, 50),
        p and p.kind == "bank_statement" and p.button_label == "Upload bank statement")
end
local not_asks = {
    "Your estimate for 2025-26 is £375,142.83.",
    "You've uploaded 12 statements; they are being read now.",
    "No need to upload a statement again.",
    "",
}
for _, r in ipairs(not_asks) do
    check("no button for: " .. (r == "" and "(empty)" or r:sub(1, 50)), f(r) == nil)
end
check("nil reply is safe", f(nil) == nil)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
