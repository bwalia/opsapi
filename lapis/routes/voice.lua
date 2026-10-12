--[[
    Voice for the assistant: speech-to-text and text-to-speech
    ==========================================================
    So operators and QA testers can talk to the assistant (and hear it) in
    natural language. Audio only goes to the deployment's OWN voice server —
    an OpenAI-compatible one such as Speaches (faster-whisper for speech-to-
    text, Kokoro / Piper for text-to-speech), running on our machines. Never a
    public cloud speech API (GDPR). Off until VOICE_URL is set.

      GET  /api/v2/voice/status       { stt, tts, voice }  (the dashboard hides what's off)
      POST /api/v2/voice/transcribe   raw audio body (audio/webm, audio/ogg, audio/wav, audio/mp4; max 10 MB)
                                      -> { text }
      POST /api/v2/voice/speak        { text, voice? } (max 2000 chars) -> audio/mpeg

    Env: VOICE_URL or PA_STT_URL (base, e.g. http://speaches:8000; PA_STT_URL wins), VOICE_API_KEY (optional),
    VOICE_STT_MODEL (default Systran/faster-whisper-small), VOICE_TTS_MODEL
    (default speaches-ai/Kokoro-82M-v1.0-ONNX), VOICE_TTS_VOICE (default bf_emma,
    a British voice), VOICE_LANGUAGE (default en). VOICE_URL is operator config,
    so it may be a private (LAN) address.

    Workspace members only (X-Namespace-Id), and rate-limited per user: one voice
    server is shared by everyone. Audio is streamed on from nginx's buffer, not
    copied into Lua memory.
]]

local cjson = require("cjson.safe")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RateLimit = require("middleware.rate-limit")

local MAX_AUDIO = 10 * 1024 * 1024
local MAX_TEXT = 2000
local PER_MINUTE = { transcribe = 20, speak = 30 } -- requests per user
local AUDIO_TYPES = { ["audio/webm"] = "webm", ["audio/ogg"] = "ogg", ["audio/wav"] = "wav", ["audio/x-wav"] = "wav",
    ["audio/mp4"] = "mp4", ["audio/mpeg"] = "mp3", ["audio/aac"] = "aac" }

local function env(name, default)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return default
end

-- VOICE_URL is deployment config set by operators (Helm values / env), not user input, so it may point at a
-- private address (the voice server on the LAN) without opening OPSAPI_AI_ALLOW_PRIVATE for user-entered URLs.
local function base()
    -- PA_STT_URL (Property PA naming, the private UK GPU's speech server) wins over VOICE_URL.
    local url = env("PA_STT_URL") or env("VOICE_URL")
    if not url or not url:match("^https?://[%w%.%-]+") then return nil end
    return (url:gsub("/+$", ""))
end

local function headers(extra)
    local h = extra or {}
    local key = env("VOICE_API_KEY")
    if key then h.Authorization = "Bearer " .. key end
    return h
end

local function http(url, opts)
    local httpc = require("resty.http").new()
    httpc:set_timeout(opts.timeout or 60000)
    return httpc:request_uri(url, { method = "POST", headers = opts.headers, body = opts.body,
        ssl_verify = url:match("^https://") ~= nil })
end

-- The request body without copying it: in memory, or nginx's temp file read in chunks.
-- @return string | chunk iterator, size in bytes | nil
local function body_source()
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if data then return data, #data end
    local path = ngx.req.get_body_file()
    local f = path and io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:seek("set")
    return function()
        local chunk = f:read(65536)
        if not chunk then f:close() end
        return chunk
    end, size
end

local function fail(status, message)
    return { status = status, json = { success = false, error = message } }
end

-- Signed in, a member of the workspace, and (for the voice server's work) under the per-user limit.
local function guard(name, handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
        local limit = PER_MINUTE[name]
        if limit then
            local allowed, _, retry = RateLimit.check("voice:" .. name .. ":" .. tostring(self.current_user.uuid),
                limit, 60)
            if not allowed then
                ngx.header["Retry-After"] = tostring(retry)
                return fail(429, "Too many voice requests. Please wait a moment and try again.")
            end
        end
        return handler(self)
    end))
end

return function(app)
    app:get("/api/v2/voice/status", guard("status", function()
        local on = base() ~= nil
        return { status = 200, json = { success = true, data = { stt = on, tts = on,
            voice = on and env("VOICE_TTS_VOICE", "bf_emma") or nil } } }
    end))

    app:post("/api/v2/voice/transcribe", guard("transcribe", function()
        local url = base()
        if not url then return fail(501, "Speech-to-text isn't set up on this server (VOICE_URL)") end
        local ctype = tostring(ngx.var.content_type or ""):lower():match("^([%w/%-]+)") or ""
        local ext = AUDIO_TYPES[ctype]
        if not ext then return fail(415, "Send audio (webm, ogg, wav, mp4, mp3 or aac)") end
        local len = tonumber(ngx.var.content_length or 0) or 0
        if len > MAX_AUDIO then return fail(413, "Audio is too long (max 10 MB)") end
        local audio, size = body_source()
        if not audio or size == 0 then return fail(400, "No audio received") end
        if size > MAX_AUDIO then return fail(413, "Audio is too long (max 10 MB)") end

        local boundary = "----opsapi" .. ngx.md5(tostring(ngx.now()) .. tostring(math.random()))
        local function field(name, value)
            return "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"" .. name .. "\"\r\n\r\n" .. value .. "\r\n"
        end
        local head = table.concat({
            field("model", env("VOICE_STT_MODEL", "Systran/faster-whisper-small")),
            field("language", env("VOICE_LANGUAGE", "en")),
            field("response_format", "json"),
            "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech." .. ext
                .. "\"\r\nContent-Type: " .. ctype .. "\r\n\r\n",
        })
        local tail = "\r\n--" .. boundary .. "--\r\n"
        -- The multipart body is sent in pieces: the audio is never copied into one big string.
        local body = { head, audio, tail }
        if type(audio) == "function" then
            local queue = body
            body = function()
                while queue[1] do
                    local part = queue[1]
                    if type(part) == "string" then return table.remove(queue, 1) end
                    local chunk = part()
                    if chunk then return chunk end
                    table.remove(queue, 1)
                end
            end
        end
        local res, err = http(url .. "/v1/audio/transcriptions", { timeout = 120000, body = body,
            headers = headers({ ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["Content-Length"] = #head + size + #tail }) })
        if not res then
            ngx.log(ngx.ERR, "[voice] transcribe: ", tostring(err))
            return fail(502, "The speech-to-text server didn't answer")
        end
        if res.status >= 300 then
            ngx.log(ngx.ERR, "[voice] transcribe HTTP ", res.status, ": ", tostring(res.body):sub(1, 300))
            return fail(502, "The speech-to-text server couldn't read that audio")
        end
        local data = cjson.decode(res.body or "") or {}
        local text = type(data.text) == "string" and data.text:gsub("^%s+", ""):gsub("%s+$", "") or ""
        return { status = 200, json = { success = true, data = { text = text } } }
    end))

    app:post("/api/v2/voice/speak", guard("speak", function()
        local url = base()
        if not url then return fail(501, "Text-to-speech isn't set up on this server (VOICE_URL)") end
        ngx.req.read_body()
        local b = cjson.decode(ngx.req.get_body_data() or "") or {}
        local text = type(b.text) == "string" and b.text:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if text == "" then return fail(400, "text is required") end
        if #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) end
        local voice = type(b.voice) == "string" and b.voice:match("^[%w_%-%.]+$") and b.voice
            or env("VOICE_TTS_VOICE", "bf_emma")
        local res, err = http(url .. "/v1/audio/speech", { timeout = 60000,
            headers = headers({ ["Content-Type"] = "application/json" }),
            body = cjson.encode({ model = env("VOICE_TTS_MODEL", "speaches-ai/Kokoro-82M-v1.0-ONNX"), input = text,
                voice = voice, response_format = "mp3" }) })
        if not res then
            ngx.log(ngx.ERR, "[voice] speak: ", tostring(err))
            return fail(502, "The text-to-speech server didn't answer")
        end
        if res.status >= 300 then
            ngx.log(ngx.ERR, "[voice] speak HTTP ", res.status, ": ", tostring(res.body):sub(1, 300))
            return fail(502, "The text-to-speech server couldn't speak that")
        end
        ngx.header["Cache-Control"] = "no-store"
        return { status = 200, layout = false, content_type = "audio/mpeg", res.body }
    end))
end
