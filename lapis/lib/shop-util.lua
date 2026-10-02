--[[
    Shop shared helpers (tokens, hashing, JSON, HTTP envelope)
    ===========================================================
    Used by queries/Shop*Queries.lua and routes/shop-*.lua.
]]

local cjson = require("cjson")
local bit = require("bit")

local ShopUtil = {}

-- Private cjson instance: other modules flip encode_empty_table_as_object(false)
-- on the SHARED instance, which would turn empty JSON objects ({} specs,
-- selections, customer) into []. This one encodes {} as an object and decodes
-- arrays with cjson.array_mt so empty arrays round-trip as [].
local J = require("cjson").new()
J.encode_empty_table_as_object(true)
J.decode_array_with_array_mt(true)
J.encode_escape_forward_slash(false)
ShopUtil.json = J

ShopUtil.null = cjson.null

-- ---------------------------------------------------------------------------
-- crypto
-- ---------------------------------------------------------------------------

--- `n` cryptographically secure random bytes (resty.random strong mode,
-- falling back to OpenSSL RAND via lua-resty-openssl). Raises if neither is
-- available — we never fall back to math.random for capability tokens.
function ShopUtil.random_bytes(n)
    local ok, rr = pcall(require, "resty.random")
    if ok and rr then
        local b = rr.bytes(n, true)
        if b and #b == n then return b end
    end
    local ok2, rand = pcall(require, "resty.openssl.rand")
    if ok2 and rand then
        local b = rand.bytes(n)
        if b and #b == n then return b end
    end
    error("no cryptographically secure random source available")
end

function ShopUtil.base64url(bytes)
    return (ngx.encode_base64(bytes):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

--- Opaque random token (default 32 bytes → 43 base64url chars).
function ShopUtil.token(nbytes)
    return ShopUtil.base64url(ShopUtil.random_bytes(nbytes or 32))
end

function ShopUtil.sha256_hex(s)
    local sha256 = require("resty.sha256")
    local str = require("resty.string")
    local h = sha256:new()
    h:update(s or "")
    return str.to_hex(h:final())
end

--- Constant-time string comparison. Both sides are hashed first so the
-- comparison runs over equal-length digests regardless of input length.
function ShopUtil.secure_equals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return false end
    local ha, hb = ShopUtil.sha256_hex(a), ShopUtil.sha256_hex(b)
    local diff = 0
    for i = 1, #ha do
        diff = bit.bor(diff, bit.bxor(ha:byte(i), hb:byte(i)))
    end
    return diff == 0
end

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

--- Mark a Lua table as a JSON array (so {} encodes as [] not {}).
function ShopUtil.arr(t)
    t = t or {}
    if cjson.array_mt then setmetatable(t, cjson.array_mt) end
    return t
end

--- Decode a json/jsonb column value (pgmoon may hand us a string or a table).
function ShopUtil.dec(v, default)
    if v == nil or v == cjson.null then return default end
    if type(v) == "table" then return v end
    if type(v) == "string" then
        if v == "" then return default end
        local ok, out = pcall(J.decode, v)
        if ok and out ~= nil and out ~= cjson.null then return out end
    end
    return default
end

function ShopUtil.enc(v)
    return J.encode(v == nil and {} or v)
end

--- nil for JSON null / empty string.
function ShopUtil.nz(v)
    if v == nil or v == cjson.null or v == "" then return nil end
    return v
end

function ShopUtil.bool(v, default)
    if v == nil or v == cjson.null then return default end
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    local s = tostring(v):lower()
    if s == "true" or s == "t" or s == "1" or s == "yes" or s == "on" then return true end
    if s == "false" or s == "f" or s == "0" or s == "no" or s == "off" then return false end
    return default
end

function ShopUtil.int(v, default)
    local n = tonumber(v)
    if not n or n ~= n then return default end
    return math.floor(n)
end

function ShopUtil.clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

function ShopUtil.slugify(s)
    s = tostring(s or ""):lower()
    s = s:gsub("[^%w%s%-]", ""):gsub("[%s_]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if #s > 120 then s = s:sub(1, 120) end
    return s
end

--- Format minor units as "£1,234.56" (for notes / CRM, never for maths).
function ShopUtil.money(minor, currency)
    minor = tonumber(minor) or 0
    local neg = minor < 0
    if neg then minor = -minor end
    local whole = math.floor(minor / 100)
    local frac = minor % 100
    local s = tostring(whole):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    local sym = (currency == nil or currency:upper() == "GBP") and "£" or (currency:upper() .. " ")
    return (neg and "-" or "") .. sym .. s .. string.format(".%02d", frac)
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

--- Parse a JSON request body (cjson). Reads spilled temp files for big bodies.
-- Returns (table) or (nil, "invalid JSON").
function ShopUtil.read_json()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local path = ngx.req.get_body_file()
        if path then
            local f = io.open(path, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end
    if not body or body == "" then return {} end
    local ok, decoded = pcall(J.decode, body)
    if not ok or type(decoded) ~= "table" then return nil, "invalid JSON body" end
    return decoded
end

--- Lapis response with a body encoded by the private instance.
function ShopUtil.respond(status, payload)
    return { status = status, layout = false, content_type = "application/json", J.encode(payload) }
end

function ShopUtil.ok(data, status, meta)
    local json = { success = true, data = data }
    if meta then json.meta = meta end
    return ShopUtil.respond(status or 200, json)
end

function ShopUtil.fail(status, code, message, extra)
    local json = { success = false, error = message or code, code = code }
    if extra then
        for k, v in pairs(extra) do json[k] = v end
    end
    return ShopUtil.respond(status, json)
end

--- Turn a service error table {status, code, message, ...} into a response.
function ShopUtil.from_err(e)
    if type(e) == "table" then
        local extra = {}
        for k, v in pairs(e) do
            if k ~= "status" and k ~= "code" and k ~= "message" then extra[k] = v end
        end
        return ShopUtil.fail(e.status or 400, e.code or "BAD_REQUEST", e.message, extra)
    end
    return ShopUtil.fail(400, "BAD_REQUEST", tostring(e))
end

--- Build a service error.
function ShopUtil.err(status, code, message, extra)
    local e = { status = status, code = code, message = message }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    return e
end

--- Wrap a handler: catch Lua errors and return the house 500 envelope.
function ShopUtil.safe(handler)
    return function(self)
        local ok, res = xpcall(function() return handler(self) end, debug.traceback)
        if ok then return res end
        ngx.log(ngx.ERR, "[shop] handler error: ", tostring(res))
        return ShopUtil.fail(500, "INTERNAL_ERROR", "Internal server error")
    end
end

-- ---------------------------------------------------------------------------
-- DB transactions
-- ---------------------------------------------------------------------------

--- Run fn() inside BEGIN/COMMIT. fn returns (result, err); a returned err or a
-- raised error rolls back. Returns (result, err).
function ShopUtil.tx(fn)
    local db = require("lapis.db")
    db.query("BEGIN")
    local ok, res, err = pcall(fn)
    if not ok then
        pcall(db.query, "ROLLBACK")
        error(res, 0)
    end
    if err ~= nil then
        pcall(db.query, "ROLLBACK")
        return nil, err
    end
    db.query("COMMIT")
    return res
end

-- ---------------------------------------------------------------------------
-- env
-- ---------------------------------------------------------------------------

function ShopUtil.env(name)
    local v = os.getenv(name)
    if v == nil then return nil end
    v = v:match("^%s*(.-)%s*$")
    if v == "" then return nil end
    return v
end

--- Allowed redirect origins for checkout success/cancel URLs.
function ShopUtil.allowed_origins()
    local raw = ShopUtil.env("SHOP_ALLOWED_ORIGINS") or ""
    local out = {}
    for part in raw:gmatch("[^,]+") do
        local o = part:match("^%s*(.-)%s*$"):gsub("/+$", "")
        if o ~= "" then out[#out + 1] = o end
    end
    return out
end

--- True when url starts with an allowed origin followed by end, "/", "?" or "#".
function ShopUtil.url_allowed(url)
    if type(url) ~= "string" or url == "" then return false end
    for _, origin in ipairs(ShopUtil.allowed_origins()) do
        if url:sub(1, #origin) == origin then
            local nxt = url:sub(#origin + 1, #origin + 1)
            if nxt == "" or nxt == "/" or nxt == "?" or nxt == "#" then return true end
        end
    end
    return false
end

return ShopUtil
