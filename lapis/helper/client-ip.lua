--[[
    The real client IP behind reverse proxies
    =========================================

    X-Forwarded-For is written by the client first, so anyone can put a fake
    address at its start. The trustworthy part is the right-hand end — the hops
    our own proxies appended. So: if the direct peer is one of our proxies,
    walk X-Forwarded-For from the RIGHT, skipping our proxies, and the first
    address that isn't ours is the client. If the peer is not a trusted proxy,
    the headers are ignored (a client talking to us directly can't spoof).

    Trusted = private / loopback / link-local / CGNAT ranges (cluster, ingress,
    docker), plus OPSAPI_TRUSTED_PROXIES: comma-separated IPv4 CIDRs of public
    proxies in front of us (CDN / edge), e.g. "203.0.113.0/24,198.51.100.7/32".
    Without it an edge proxy's own address is reported — never a spoofed one.
]]

local ClientIP = {}

local PRIVATE = { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16" }

local function ipv4_number(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function parse_cidr(cidr)
    local ip, bits = cidr:match("^%s*([%d%.]+)/(%d+)%s*$")
    if not ip then
        ip, bits = cidr:match("^%s*([%d%.]+)%s*$"), 32
    end
    local n = ip and ipv4_number(ip)
    bits = tonumber(bits)
    if not n or not bits or bits > 32 then return nil end
    local size = 2 ^ (32 - bits)
    return { first = math.floor(n / size) * size, size = size }
end

local ranges
local function trusted_ranges()
    if ranges then return ranges end
    ranges = {}
    local list = { unpack(PRIVATE) }
    for cidr in (os.getenv("OPSAPI_TRUSTED_PROXIES") or ""):gmatch("[^,]+") do
        list[#list + 1] = cidr
    end
    for _, cidr in ipairs(list) do
        local r = parse_cidr(cidr)
        if r then
            ranges[#ranges + 1] = r
        elseif cidr:match("%S") and ngx then
            ngx.log(ngx.WARN, "[client-ip] ignoring invalid OPSAPI_TRUSTED_PROXIES entry: ", cidr)
        end
    end
    return ranges
end

--- Is this address one of our own proxies (or internal)?
function ClientIP.isTrusted(ip)
    if type(ip) ~= "string" then return false end
    local n = ipv4_number(ip)
    if not n then
        -- IPv6: loopback, unique-local (fc00::/7), link-local (fe80::/10)
        local v6 = ip:lower()
        return v6 == "::1" or v6:match("^f[cd]") ~= nil or v6:match("^fe[89ab]") ~= nil
    end
    for _, r in ipairs(trusted_ranges()) do
        if n >= r.first and n < r.first + r.size then return true end
    end
    return false
end

-- "1.2.3.4:5678" → "1.2.3.4" (some proxies append ports); IPv6 left as is.
local function strip_port(hop)
    return hop:match("^(%d+%.%d+%.%d+%.%d+):%d+$") or hop:match("^%[(.-)%]") or hop
end

--- Client IP for the current request.
-- @param peer string|nil remote address (defaults to ngx.var.remote_addr)
-- @param xff string|nil X-Forwarded-For (defaults to the request header)
-- @param real_ip string|nil X-Real-IP (defaults to the request header)
function ClientIP.get(peer, xff, real_ip)
    peer = peer or (ngx and ngx.var.remote_addr)
    if not ClientIP.isTrusted(peer) then return peer end
    xff = xff or (ngx and ngx.var.http_x_forwarded_for)
    if xff and xff ~= "" then
        local hops = {}
        for hop in xff:gmatch("[^,%s]+") do hops[#hops + 1] = strip_port(hop) end
        for i = #hops, 1, -1 do
            if not ClientIP.isTrusted(hops[i]) then return hops[i] end
        end
        if hops[1] then return hops[1] end -- every hop internal: an in-cluster caller
    end
    real_ip = real_ip or (ngx and ngx.var.http_x_real_ip)
    if real_ip and real_ip ~= "" then return real_ip end
    return peer
end

--- Test hook: forget the parsed ranges (e.g. after changing the env).
function ClientIP._reset()
    ranges = nil
end

return ClientIP
