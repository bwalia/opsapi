-- Outbound HTTP for connectors: the same SSRF rule as AI providers (public
-- https hosts only, unless OPSAPI_AI_ALLOW_PRIVATE=true), JSON in and out.
-- The host is resolved once and the connection goes to the address that was
-- checked (lib/outbound-webhooks), so DNS can't be swapped in between.
-- Errors are short and safe to show ("HTTP 401", "could not reach the server");
-- what the provider said goes to the log only.
local H = {}

--- request_uri-like call through the IP-pinning client. @return res | nil, error (raw: log it, don't show it)
function H.request(url, params, timeout_ms)
    return require("lib.outbound-webhooks").request(url, params, {
        allow_private = os.getenv("OPSAPI_AI_ALLOW_PRIVATE") == "true", timeout_ms = timeout_ms or 20000 })
end

--- @return decoded body (table) | nil, error, status
function H.json(url, opts)
    opts = opts or {}
    local headers = { Accept = "application/json" }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    local host = tostring(url):match("^%a+://([^/?#]+)") or "?"
    local res, rerr = H.request(url, { method = opts.method or "GET", headers = headers, body = opts.body,
        ssl_verify = opts.ssl_verify }, opts.timeout_ms)
    if not res then
        ngx.log(ngx.WARN, "[property_deals] ", host, ": ", tostring(rerr))
        return nil, "could not reach the server"
    end
    local data = require("cjson.safe").decode(res.body or "")
    if res.status >= 300 then
        ngx.log(ngx.WARN, "[property_deals] ", host, " answered HTTP ", res.status, ": ",
            tostring(res.body):sub(1, 300))
        return nil, "HTTP " .. res.status, res.status
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
