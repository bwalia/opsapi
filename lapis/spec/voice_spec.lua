--[[
    Spec: voice routes (routes/voice.lua) — workspace members only, rate-limited
    per user (one LAN voice server is shared by everyone), audio streamed on to
    the voice server without copying it into one big Lua string, and the voice
    server's own error text never returned.

    Run from the repo root (what CI does):
        luajit lapis/spec/voice_spec.lua
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

-- The request being served.
local req = {}
ngx = { log = function() end, ERR = 3, header = {}, now = os.time, md5 = function(s) return ("%032x"):format(#s) end, -- luacheck: ignore 111
    var = setmetatable({}, { __index = function(_, k) return req[k] end }),
    req = {
        read_body = function() req.reads = (req.reads or 0) + 1 end,
        get_body_data = function() return req.data end,
        get_body_file = function() return req.file end,
    } }

-- Middleware stand-ins: what they let through is what the real ones would.
package.loaded["middleware.auth"] = { requireAuth = function(h)
    return function(self) return h(self) end
end }
package.loaded["middleware.namespace"] = { requireNamespace = function(h)
    return function(self)
        if not self.namespace then return { status = 400, json = { error = "X-Namespace-Id required" } } end
        return h(self)
    end
end }
local counts = {}
package.loaded["middleware.rate-limit"] = { check = function(key, rate)
    counts[key] = (counts[key] or 0) + 1
    return counts[key] <= rate, 0, 42
end }

-- The voice server.
local sent, answer = nil, nil
package.loaded["resty.http"] = { new = function()
    return { set_timeout = function() end, request_uri = function(_, url, params)
        sent = { url = url, params = params, body_type = type(params.body) }
        local body = params.body
        if type(body) == "function" then
            local parts = {}
            for chunk in body do parts[#parts + 1] = chunk end
            body = table.concat(parts)
        elseif type(body) == "table" then
            body = table.concat(body)
        end
        sent.body = body
        return answer()
    end }
end }

local real_getenv = os.getenv
os.getenv = function(k) if k == "VOICE_URL" then return "http://speaches:8000" end return real_getenv(k) end -- luacheck: ignore 122

local routes = {}
local app = {
    get = function(_, path, h) routes["GET " .. path] = h end,
    post = function(_, path, h) routes["POST " .. path] = h end,
}
require("routes.voice")(app)

local function call(route, user, opts)
    req = { content_type = opts and opts.ctype or "audio/webm", content_length = opts and opts.len or 0,
        data = opts and opts.data, file = opts and opts.file }
    ngx.header = {}
    local ns = not (opts and opts.no_ns) and { id = 7 } or nil
    return routes[route]({ current_user = { uuid = user or "user-1" }, namespace = ns })
end

print("workspace members only:")
for _, r in ipairs({ "GET /api/v2/voice/status", "POST /api/v2/voice/transcribe", "POST /api/v2/voice/speak" }) do
    local res = call(r, "user-1", { no_ns = true, data = "clip", len = 4 })
    check(r .. ": no workspace -> 400", res.status == 400 and res.json.error == "X-Namespace-Id required")
end

print("audio is streamed, not copied:")
answer = function() return { status = 200, body = '{"text":"  hello there "}' } end
local audio = ("\0\1\2voice"):rep(40000) -- ~280 KB: bigger than client_body_buffer_size, so nginx spooled it
local path = os.tmpname()
local f = assert(io.open(path, "wb"))
f:write(audio)
f:close()
local res = call("POST /api/v2/voice/transcribe", "user-1", { file = path, len = #audio })
check("transcribed", res.status == 200 and res.json.data.text == "hello there", res.status)
check("the temp file goes out in chunks (no full copy in Lua)", sent.body_type == "function")
check("the audio arrives byte for byte inside the multipart body", sent.body:find(audio, 1, true) ~= nil)
check("Content-Length matches what is sent", tonumber(sent.params.headers["Content-Length"]) == #sent.body,
    tostring(sent.params.headers["Content-Length"]) .. " vs " .. #sent.body)
check("multipart is well formed", sent.body:find('name="model"', 1, true) and sent.body:find('filename="speech.webm"', 1, true)
    and sent.body:match("%-%-\r\n$") ~= nil)
res = call("POST /api/v2/voice/transcribe", "user-2", { data = "smallclip", len = 9 })
check("a small in-memory body is sent as parts, not concatenated", res.status == 200 and sent.body_type == "table"
    and sent.body:find("smallclip", 1, true))
os.remove(path)
check("too long: refused before reading the body", call("POST /api/v2/voice/transcribe", "user-3",
    { len = 11 * 1024 * 1024 }).status == 413 and req.reads == nil)

print("rate limits per user:")
counts = {}
local last
for _ = 1, 21 do last = call("POST /api/v2/voice/transcribe", "user-9", { data = "clip", len = 4 }) end
check("transcribe: the 21st request in a minute -> 429", last.status == 429 and ngx.header["Retry-After"] == "42")
check("...refused before the body is read", req.reads == nil)
check("another user has their own allowance", call("POST /api/v2/voice/transcribe", "user-10",
    { data = "clip", len = 4 }).status == 200)
req.data = nil
for _ = 1, 31 do
    req = {}
    last = routes["POST /api/v2/voice/speak"]({ current_user = { uuid = "user-9" }, namespace = { id = 7 } })
end
check("speak: 30 a minute", last.status == 429)
check("status isn't limited", call("GET /api/v2/voice/status", "user-9").status == 200)

print("errors stay generic:")
counts = {}
answer = function() return { status = 500, body = "Traceback: /models/secret-path CUDA OOM" } end
res = call("POST /api/v2/voice/transcribe", "user-1", { data = "clip", len = 4 })
check("the voice server's own text is not returned", res.status == 502 and not res.json.error:find("CUDA", 1, true))

os.getenv = real_getenv -- luacheck: ignore 122
print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
