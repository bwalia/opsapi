--[[
    Spec: helper/idempotency.lua (Idempotency-Key on creates).
      - the request hash covers the body also when nginx spooled it to a temp
        file (bigger than client_body_buffer_size), so a different large body
        is a 422, not a replay of someone else's response
      - a claim whose worker died mid-handler (no response) is taken over by a
        retry after the 2-minute lease, once (atomically), instead of 409 for 24 h

    Run from the repo root (what CI does):
        luajit lapis/spec/idempotency_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local b64 = require("spec.fixtures.openssl")
package.loaded["resty.string"] = { to_hex = b64.encode_base64 } -- the real one needs nginx's ngx_hex_dump

-- The request: headers, and a body in memory or in a temp file.
local req = {}
ngx = { header = {}, var = { uri = "/api/v2/crm/leads" }, req = { -- luacheck: ignore 111
    get_headers = function() return { ["Idempotency-Key"] = req.key } end,
    read_body = function() end,
    get_body_data = function() return req.data end,
    get_body_file = function() return req.file end,
    get_method = function() return "POST" end,
} }

-- idempotency_keys in memory; `now` in seconds.
local now, seq, rows, lease_arg = 1000, 0, {}, nil
local function by_id(id)
    for _, r in pairs(rows) do if r.id == id then return r end end
end
package.loaded["lapis.db"] = {
    NULL = setmetatable({}, {}),
    query = function(sql, a, b, c, _, _, f)
        if sql:find("INSERT INTO idempotency_keys", 1, true) then
            local k = a .. "|" .. b .. "|" .. c
            if rows[k] then return {} end
            seq = seq + 1
            rows[k] = { id = seq, request_sha256 = f, created_at = now }
            return { { id = seq } }
        elseif sql:find("SELECT * FROM idempotency_keys", 1, true) then
            return { rows[a .. "|" .. b .. "|" .. c] }
        elseif sql:find("UPDATE idempotency_keys SET created_at = NOW()", 1, true) then
            lease_arg = b
            local r = by_id(a)
            if r and r.status == nil and r.created_at < now - 120 then
                r.created_at = now
                return { { id = r.id } }
            end
            return {}
        elseif sql:find("UPDATE idempotency_keys SET status", 1, true) then
            local r = by_id(c)
            r.status, r.response = a, b
        elseif sql:find("DELETE FROM idempotency_keys WHERE id", 1, true) then
            for k, r in pairs(rows) do if r.id == a then rows[k] = nil end end
        end
        return {}
    end,
}
local Idempotency = require("helper.idempotency")

local runs = 0
local function create()
    runs = runs + 1
    return { status = 201, json = { id = runs } }
end
local function post(key, body)
    ngx.header = {}
    req.key, req.data, req.file = key, body, nil
    return Idempotency.run({}, 7, "user-1", create)
end
local function post_spooled(key, body)
    local path = os.tmpname()
    local f = assert(io.open(path, "wb"))
    f:write(body)
    f:close()
    ngx.header = {}
    req.key, req.data, req.file = key, nil, path
    local res = Idempotency.run({}, 7, "user-1", create)
    os.remove(path)
    return res
end

print("request hash covers the whole body:")
local first = post("k1", '{"name":"Ada"}')
local again = post("k1", '{"name":"Ada"}')
check("same key + body: replayed, created once", first.status == 201 and again.json.id == first.json.id and runs == 1
    and ngx.header["Idempotent-Replayed"] == "true")
check("same key, different body: 422", post("k1", '{"name":"Bob"}').status == 422)
local big = '{"notes":"' .. ("x"):rep(200000) .. '"}'
local spooled = post_spooled("k2", big)
check("a body nginx spooled to a file still runs", spooled.status == 201 and runs == 2)
check("same spooled body again: replayed", post_spooled("k2", big).json.id == spooled.json.id and runs == 2)
local other = big:sub(1, -4) .. 'y"}'
check("a different spooled body: 422 (not someone else's response)", post_spooled("k2", other).status == 422)
check("in memory or spooled: the same hash", post("k2", big).json.id == spooled.json.id and runs == 2)

print("a claim whose worker died:")
-- The first attempt claimed the key and never finished (worker killed mid-handler).
seq = seq + 1
rows["7|user-1|k3"] = { id = seq, request_sha256 = nil, created_at = now }
req.key, req.data = "k3", '{"name":"Cy"}'
post("k3-probe", '{"name":"Cy"}') -- learn the hash this body gets
rows["7|user-1|k3"].request_sha256 = rows["7|user-1|k3-probe"].request_sha256
runs = 0
check("still inside the lease: 409 (it may be running)", post("k3", '{"name":"Cy"}').status == 409 and runs == 0)
now = now + 121
local retried = post("k3", '{"name":"Cy"}')
check("past the 2-minute lease: a retry takes it over and runs", retried.status == 201 and runs == 1, retried.status)
check("lease is 2 minutes", lease_arg == "2 minutes", lease_arg)
check("...and its response is what later retries get", post("k3", '{"name":"Cy"}').json.id == retried.json.id
    and runs == 1)
seq = seq + 1
rows["7|user-1|k4"] = { id = seq, request_sha256 = rows["7|user-1|k3"].request_sha256, created_at = now - 500 }
local winner = rows["7|user-1|k4"]
check("only one retry wins the takeover", (function()
    local r1 = post("k4", '{"name":"Cy"}')
    winner.status = nil -- as if the winner were still running when the second retry arrives
    local r2 = post("k4", '{"name":"Cy"}')
    return r1.status == 201 and r2.status == 409
end)())

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
