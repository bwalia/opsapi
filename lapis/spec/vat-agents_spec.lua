--[[
    Spec: accountants acting for clients' VAT (lib/hmrc-agent-client.lua,
    queries/VatAgentQueries.lua). HMRC is stubbed.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-agents_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local cjson = require("cjson")
local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

package.loaded["helper.hmrc"] = { build_fraud_headers = function() return {} end,
    get_valid_token = function() return "agent-token" end }

local Client = require("lib.hmrc-agent-client")
local calls, replies = {}, {}
Client._http = { request_uri = function(_, url, req)
    calls[#calls + 1] = { url = url, req = req }
    return table.remove(replies, 1) or { status = 500, body = "{}" }
end }

print("== HMRC agent API client")
check("ARN format", Client.valid_arn("AARN1234567") and not Client.valid_arn("ARN123") and not Client.valid_arn(nil))
replies = { { status = 204, body = "", headers = { Location = "/agents/AARN1234567/invitations/CS5AK7O8FPC43" } } }
local id = Client.create_invitation("t", "AARN1234567", "980780684", "2007-05-18")
local body = cjson.decode(calls[1].req.body)
check("invitation id from the Location header", id == "CS5AK7O8FPC43", id)
check("asks for MTD VAT by VRN with the VAT registration date", body.service[1] == "MTD-VAT"
    and body.clientIdType == "vrn" and body.clientId == "980780684" and body.knownFact == "2007-05-18"
    and body.clientType == "business")
check("POST to the agent's invitations", calls[1].req.method == "POST"
    and calls[1].url:find("/agents/AARN1234567/invitations$") ~= nil)
check("bad ARN refused before any call", Client.create_invitation("t", "nope", "980780684", "2007-05-18") == nil)
replies = { { status = 204, body = "" } }
check("relationship confirmed (204)", Client.check_relationship("t", "AARN1234567", "980780684", "2007-05-18") == true)
check("relationship body has no clientType", cjson.decode(calls[#calls].req.body).clientType == nil)
replies = { { status = 404, body = cjson.encode({ code = "RELATIONSHIP_NOT_FOUND" }) } }
check("not authorised (404)", Client.check_relationship("t", "AARN1234567", "980780684", "2007-05-18") == false)
replies = { { status = 403, body = cjson.encode({ code = "VAT_REG_DATE_DOES_NOT_MATCH" }) } }
local ok, _, b = Client.create_invitation("t", "AARN1234567", "980780684", "2001-01-01")
check("HMRC's refusal explained", ok == nil and Client.explain(b):find("registration date") ~= nil)

print("== access needs HMRC's confirmation")
local last_sql, last_args
package.loaded["lapis.db"] = {
    NULL = {},
    query = function(sql, ...)
        last_sql, last_args = sql, { ... }
        return {}
    end,
}
package.loaded["lib.hmrc-agent-client"] = Client
local Q = require("queries.VatAgentQueries")
check("no link -> no client registration", Q.active_registration(7, 42, "link-uuid") == nil)
check("only 'active' links (HMRC-confirmed) count", last_sql:find("status = 'active'", 1, true) ~= nil)
check("only this accountant's links in this workspace", last_args[1] == "link-uuid" and last_args[2] == 7
    and last_args[3] == 42, cjson.encode(last_args))

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
