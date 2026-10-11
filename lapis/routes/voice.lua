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
]]

local cjson = require("cjson.safe")
local AuthMiddleware = require("middleware.auth")

local MAX_AUDIO = 10 * 1024 * 1024
local MAX_TEXT = 2000
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

local function read_body()
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if data then return data end
    local file = ngx.req.get_body_file()
    if not file then return nil end
    local f = io.open(file, "rb")
    if not f then return nil end
    data = f:read("*a")
    f:close()
    return data
end

local function fail(status, message)
    return { status = status, json = { success = false, error = message } }
end

return function(app)
    app:get("/api/v2/voice/status", AuthMiddleware.requireAuth(function()
        local on = base() ~= nil
        return { status = 200, json = { success = true, data = { stt = on, tts = on,
            voice = on and env("VOICE_TTS_VOICE", "bf_emma") or nil } } }
    end))

    app:post("/api/v2/voice/transcribe", AuthMiddleware.requireAuth(function()
        local url = base()
        if not url then return fail(501, "Speech-to-text isn't set up on this server (VOICE_URL)") end
        local ctype = tostring(ngx.var.content_type or ""):lower():match("^([%w/%-]+)") or ""
        local ext = AUDIO_TYPES[ctype]
        if not ext then return fail(415, "Send audio (webm, ogg, wav, mp4, mp3 or aac)") end
        local len = tonumber(ngx.var.content_length or 0) or 0
        if len > MAX_AUDIO then return fail(413, "Audio is too long (max 10 MB)") end
        local audio = read_body()
        if not audio or #audio == 0 then return fail(400, "No audio received") end
        if #audio > MAX_AUDIO then return fail(413, "Audio is too long (max 10 MB)") end

        local boundary = "----opsapi" .. ngx.md5(tostring(ngx.now()) .. tostring(math.random()))
        local function field(name, value)
            return "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"" .. name .. "\"\r\n\r\n" .. value .. "\r\n"
        end
        local body = table.concat({
            field("model", env("VOICE_STT_MODEL", "Systran/faster-whisper-small")),
            field("language", env("VOICE_LANGUAGE", "en")),
            field("response_format", "json"),
            "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech." .. ext
                .. "\"\r\nContent-Type: " .. ctype .. "\r\n\r\n", audio, "\r\n",
            "--" .. boundary .. "--\r\n",
        })
        local res, err = http(url .. "/v1/audio/transcriptions", { timeout = 120000, body = body,
            headers = headers({ ["Content-Type"] = "multipart/form-data; boundary=" .. boundary }) })
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

    app:post("/api/v2/voice/speak", AuthMiddleware.requireAuth(function()
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
