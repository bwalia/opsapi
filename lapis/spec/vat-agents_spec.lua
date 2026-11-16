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
ngx = { null = {}, log = function() end, WARN = 4 } -- luacheck: ignore 111
local last_sql, last_args
local sqls, answer = {}, function() return {} end
package.loaded["lapis.db"] = {
    NULL = {},
    query = function(sql, ...)
        last_sql, last_args = sql, { ... }
        sqls[#sqls + 1] = sql
        return answer(sql, { ... })
    end,
}
package.loaded["lib.hmrc-agent-client"] = Client
local Q = require("queries.VatAgentQueries")
check("no link -> no client registration", Q.active_registration(7, 42, "link-uuid", "agent-uuid") == nil)
check("only 'active' links (HMRC-confirmed) count", last_sql:find("status = 'active'", 1, true) ~= nil)
check("only this accountant's links in this workspace", last_args[2] == "link-uuid" and last_args[3] == 7
    and last_args[4] == 42, cjson.encode(last_args))

-- An active link whose last HMRC check is `stale`, and the client's registration.
local link = { id = 5, registration_id = 9, arn = "AARN1234567", client_vrn = "980780684",
    known_fact = "2007-05-18" }
local function with_link(stale)
    sqls = {}
    answer = function(sql)
        if sql:find("FROM vat_agent_clients WHERE uuid", 1, true) then
            local l = {}; for k, v in pairs(link) do l[k] = v end
            l.stale = stale
            return { l }
        end
        if sql:find("FROM vat_registrations WHERE id", 1, true) then return { { id = 9, vrn = "980780684" } } end
        if sql:find("FROM hmrc_tokens", 1, true) then
            return { { scope = "write:sent-invitations read:check-relationship" } }
        end
        return {}
    end
end
local function ran(fragment)
    for _, s in ipairs(sqls) do if s:find(fragment, 1, true) then return true end end
    return false
end
local before = #calls
with_link(false)
check("checked within a day: no HMRC call", Q.active_registration(7, 42, "l", "agent-uuid").id == 9
    and #calls == before)
with_link(true)
replies = { { status = 204, body = "" } }
check("stale: HMRC still says yes -> allowed, check time saved", (Q.active_registration(7, 42, "l", "a") or {}).id == 9
    and ran("SET last_checked_at = NOW()") and calls[#calls].url:find("/relationships$") ~= nil)
with_link(true)
replies = { { status = 404, body = cjson.encode({ code = "RELATIONSHIP_NOT_FOUND" }) } }
local r, msg, st = Q.active_registration(7, 42, "l", "a")
check("stale: HMRC says no -> refused and the link is revoked", r == nil and st == 403
    and msg:find("no longer") ~= nil and ran("status = 'revoked'"))
with_link(true)
replies = { { status = 503, body = "{}" } }
r, msg, st = Q.active_registration(7, 42, "l", "a")
check("stale: HMRC can't answer -> refused, link kept", r == nil and st == 409 and not ran("revoked"), msg)

print("== the client sees and stops their accountants")
answer = function() return { { id = 1 } } end
check("revoke only on this registration's live links", Q.revoke_for_registration({ id = 9, namespace_id = 7 }, "u")
    and last_sql:find("registration_id = ?", 1, true) and last_args[2] == 9 and last_args[3] == 7)
answer = function() return {} end
check("someone else's link: not found", select(3, Q.revoke_for_registration({ id = 9, namespace_id = 7 }, "u")) == 404)
Q.for_registration({ id = 9, namespace_id = 7 })
check("list is this registration's links", last_sql:find("c.registration_id = ? AND c.namespace_id = ?", 1, true)
    and last_args[1] == 9 and last_args[2] == 7)

print("== invite: a VAT number two businesses here entered is never guessed")
answer = function(sql)
    if sql:find("FROM vat_agents", 1, true) then return { { arn = "AARN1234567" } } end
    if sql:find("FROM vat_registrations WHERE namespace_id", 1, true) then return { { id = 1 }, { id = 2 } } end
    return {}
end
local _, resp = Q.invite(7, 42, "a", { vrn = "980780684", vat_registration_date = "2007-05-18" })
check("two registrations with that VAT number -> 409", resp and resp.status == 409, resp and resp.status)
answer = function(sql)
    if sql:find("FROM vat_agents", 1, true) then return { { arn = "AARN1234567" } } end
    if sql:find("FROM vat_registrations WHERE namespace_id", 1, true) then return { { id = 1 } } end
    return {}
end
_, resp = Q.invite(7, 42, "a", { vrn = "980780684", vat_registration_date = "2007-02-30" })
check("impossible registration date -> 400", resp and resp.status == 400, resp and resp.status)

print("== HMRC errors don't echo our own error text")
answer = function(sql)
    if sql:find("FROM vat_agents", 1, true) then return { { arn = "AARN1234567" } } end
    if sql:find("FROM vat_registrations WHERE namespace_id", 1, true) then return { { id = 1 } } end
    if sql:find("FROM hmrc_tokens", 1, true) then return { { scope = "write:sent-invitations" } } end
    return {}
end
Client._http = { request_uri = function() return nil, "connection refused to 10.0.0.1" end }
_, resp = Q.invite(7, 42, "a", { vrn = "980780684", vat_registration_date = "2007-05-18" })
check("unreachable: 502 with a plain message, no detail", resp and resp.status == 502 and resp.json.detail == nil
    and not cjson.encode(resp.json):find("10.0.0.1", 1, true), resp and cjson.encode(resp.json))

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
