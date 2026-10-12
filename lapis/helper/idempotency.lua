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
    - The first attempt never finished (its worker died): after LEASE a retry takes the key over.
    The request hash covers the whole body, also when nginx spooled a large one to a temp file.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local Idempotency = {}

local TTL = "24 hours"
-- A claim with no response after this long belongs to a worker that died mid-handler (creates take
-- seconds), so a retry may run instead of getting 409 for a day.
local LEASE = "2 minutes"

-- sha256 of method, path and body; a body bigger than client_body_buffer_size is in a temp file.
local function request_sha256(method, path)
    local h = require("resty.sha256"):new()
    h:update(method .. " " .. path .. "\n")
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if data then
        h:update(data)
    else
        local file = ngx.req.get_body_file()
        local f = file and io.open(file, "rb")
        if f then
            for chunk in function() return f:read(65536) end do h:update(chunk) end
            f:close()
        end
    end
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
    local method, path = ngx.req.get_method(), ngx.var.uri
    local request = request_sha256(method, path)

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
        if row.status ~= nil and row.status ~= db.NULL then
            ngx.header["Idempotent-Replayed"] = "true"
            local body = type(row.response) == "string" and cjson.decode(row.response) or row.response
            return { status = tonumber(row.status), json = body }
        end
        -- Still running, or abandoned: past the lease, one retry (atomically) takes the claim over.
        claimed = db.query([[
            UPDATE idempotency_keys SET created_at = NOW()
            WHERE id = ? AND status IS NULL AND created_at < NOW() - ?::interval RETURNING id
        ]], row.id, LEASE)[1]
        if not claimed then
            return { status = 409, json = { success = false, error = "The first request with this Idempotency-Key is still running" } }
        end
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
