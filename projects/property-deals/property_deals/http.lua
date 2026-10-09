-- Outbound HTTP for connectors: the same SSRF rule as AI providers (public
-- https hosts only, unless OPSAPI_AI_ALLOW_PRIVATE=true), JSON in and out.
local H = {}

--- @return decoded body (table) | nil, error, status
function H.json(url, opts)
    opts = opts or {}
    local ok, err = require("lib.ai-providers").url_ok(url)
    if not ok then return nil, err end
    local httpc = require("resty.http").new()
    httpc:set_timeout(opts.timeout_ms or 20000)
    local headers = { Accept = "application/json" }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    local res, rerr = httpc:request_uri(url, { method = opts.method or "GET", headers = headers, body = opts.body,
        ssl_verify = true })
    if not res then return nil, "request failed: " .. tostring(rerr) end
    local data = require("cjson.safe").decode(res.body or "")
    if res.status >= 300 then
        local msg = type(data) == "table" and (data.error_description or data.error or data.message) or res.body
        if type(msg) == "table" then msg = msg.message or require("cjson").encode(msg) end
        return nil, "HTTP " .. res.status .. ": " .. tostring(msg):sub(1, 200), res.status
    end
    return data or {}, nil, res.status
end

function H.basic(user, pass)
    return "Basic " .. ngx.encode_base64(tostring(user or "") .. ":" .. tostring(pass or ""))
end

function H.query(t)
    local out = {}
    for k, v in pairs(t) do
        if v ~= nil then out[#out + 1] = ngx.escape_uri(k) .. "=" .. ngx.escape_uri(tostring(v)) end
    end
    table.sort(out)
    return table.concat(out, "&")
end

return H
