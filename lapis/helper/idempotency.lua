--[[
    Idempotency-Key for creates (core). A client that retries a POST after a
    lost response sends the same `Idempotency-Key: <uuid>`; the first response
    (status + body) is replayed and nothing is created twice. Keys are per
    workspace + user and live 24 h (idempotency_keys, migrations/ai-providers.lua).

      return Idempotency.run(self, namespace_id, user_uuid, function() ... return { status, json } end)

    - No header: the handler just runs.
    - Same key, same request: the stored response, with `Idempotent-Replayed: true`.
    - Same key, different body or path: 422 (a client bug; nothing runs).
    - Same key while the first is still running: 409, try again shortly.
    - The first attempt failed with 5xx (or raised): the key is released so a retry runs.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local Idempotency = {}

local TTL = "24 hours"

local function sha256_hex(s)
    local h = require("resty.sha256"):new()
    h:update(s)
    return require("resty.string").to_hex(h:final())
end

local function header_key()
    local v = ngx.req.get_headers()["Idempotency-Key"]
    if type(v) == "table" then v = v[1] end
    if type(v) ~= "string" or v == "" then return nil end
    return v
end

function Idempotency.run(self, ns, user_uuid, handler)
    local key = header_key()
    if not key or not ns or not user_uuid then return handler() end
    if #key > 255 then
        return { status = 400, json = { success = false, error = "Idempotency-Key is too long (255 characters at most)" } }
    end
    ngx.req.read_body()
    local method, path = ngx.req.get_method(), ngx.var.uri
    local request = sha256_hex(method .. " " .. path .. "\n" .. (ngx.req.get_body_data() or ""))

    db.query("DELETE FROM idempotency_keys WHERE namespace_id = ? AND user_uuid = ? AND idem_key = ? AND created_at < NOW() - ?::interval",
        ns, user_uuid, key, TTL)
    if math.random() < 0.01 then
        pcall(db.query, "DELETE FROM idempotency_keys WHERE created_at < NOW() - ?::interval", TTL)
    end
    local claimed = db.query([[
        INSERT INTO idempotency_keys (namespace_id, user_uuid, idem_key, method, path, request_sha256)
        VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (namespace_id, user_uuid, idem_key) DO NOTHING RETURNING id
    ]], ns, user_uuid, key, method, path, request)[1]

    if not claimed then
        local row = db.query("SELECT * FROM idempotency_keys WHERE namespace_id = ? AND user_uuid = ? AND idem_key = ?",
            ns, user_uuid, key)[1]
        if not row then return handler() end
        if row.request_sha256 ~= request then
            return { status = 422, json = { success = false,
                error = "This Idempotency-Key was already used for a different request" } }
        end
        if row.status == nil or row.status == db.NULL then
            return { status = 409, json = { success = false, error = "The first request with this Idempotency-Key is still running" } }
        end
        ngx.header["Idempotent-Replayed"] = "true"
        local body = type(row.response) == "string" and cjson.decode(row.response) or row.response
        return { status = tonumber(row.status), json = body }
    end

    local ok, res = pcall(handler)
    if not ok or type(res) ~= "table" or (tonumber(res.status) or 200) >= 500 then
        db.query("DELETE FROM idempotency_keys WHERE id = ?", claimed.id)
        if not ok then error(res, 0) end
        return res
    end
    db.query("UPDATE idempotency_keys SET status = ?, response = ?::jsonb WHERE id = ?",
        tonumber(res.status) or 200, cjson.encode(res.json == nil and cjson.null or res.json), claimed.id)
    return res
end

return Idempotency
