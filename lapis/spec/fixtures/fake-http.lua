--[[
    resty.http stand-in for specs. respond(url, req) answers with
    { status, body } or nil, err, for both request_uri and the connect +
    request + body_reader flow (lib/outbound-webhooks fetch, used by
    lib/agent/llm). req.connect = what was connected to (host = the address,
    ssl_server_name, ssl_verify).
]]
return function(respond)
    return {
        new = function()
            local c, conn = {}, nil
            function c.set_timeout() end
            function c.set_timeouts() end
            function c.set_keepalive() end
            function c.close() end
            function c.request_uri(_, url, req) return respond(url, req) end
            function c.connect(_, o)
                conn = o
                return true
            end
            function c.request(_, req)
                local default = conn.port == (conn.scheme == "https" and 443 or 80)
                req.connect = conn
                local r, err = respond(conn.scheme .. "://" .. conn.ssl_server_name
                    .. (default and "" or (":" .. conn.port)) .. req.path, req)
                if not r then return nil, err end
                local body = r.body
                return { status = r.status or 200, headers = r.headers or {}, body_reader = function()
                    local b = body
                    body = nil
                    return b
                end }
            end
            return c
        end,
    }
end
