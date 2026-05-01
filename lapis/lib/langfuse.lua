-- Langfuse LLM Observability Tracer
-- Fire-and-forget trace emission via ngx.timer.at for non-blocking HTTP calls.
-- Gracefully degrades (no-op) when LANGFUSE_PUBLIC_KEY is not set.

local cjson = require("cjson")

local Langfuse = {}

local PUBLIC_KEY = os.getenv("LANGFUSE_PUBLIC_KEY")
local SECRET_KEY = os.getenv("LANGFUSE_SECRET_KEY")
local BASE_URL = os.getenv("LANGFUSE_BASE_URL") or "https://cloud.langfuse.com"
local ENABLED = PUBLIC_KEY and SECRET_KEY and #PUBLIC_KEY > 0 and #SECRET_KEY > 0

-- ---------------------------------------------------------------------------
-- Internal
-- ---------------------------------------------------------------------------

local function generate_id()
    local random = math.random
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and random(0, 15) or random(8, 11)
        return string.format("%x", v)
    end)
end

local function send_event(event)
    if not ENABLED then return end

    local ok, err = ngx.timer.at(0, function(premature)
        if premature then return end

        local http_ok, http = pcall(require, "resty.http")
        if not http_ok then return end

        local httpc = http.new()
        httpc:set_timeout(5000)

        local body = cjson.encode({ batch = { event } })
        local auth = ngx.encode_base64(PUBLIC_KEY .. ":" .. SECRET_KEY)

        local res, req_err = httpc:request_uri(BASE_URL .. "/api/public/ingestion", {
            method = "POST",
            body = body,
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. auth,
            },
            ssl_verify = false,
        })

        if not res then
            ngx.log(ngx.WARN, "[Langfuse] Failed to send trace: ", tostring(req_err))
        elseif res.status >= 400 then
            ngx.log(ngx.WARN, "[Langfuse] HTTP ", res.status, ": ", tostring(res.body))
        end
    end)

    if not ok then
        ngx.log(ngx.WARN, "[Langfuse] Failed to schedule timer: ", tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function Langfuse.is_enabled()
    return ENABLED
end

--- Start a new trace
-- @param name string Trace name (e.g. "classify_transaction")
-- @param metadata table Optional metadata
-- @return string trace_id
function Langfuse.trace_start(name, metadata)
    local trace_id = generate_id()

    send_event({
        type = "trace-create",
        id = generate_id(),
        timestamp = ngx.utctime(),
        body = {
            id = trace_id,
            name = name,
            metadata = metadata or {},
        },
    })

    return trace_id
end

--- Record an LLM generation span
-- @param trace_id string Parent trace ID
-- @param opts table { name, model, prompt, completion, input_tokens, output_tokens, latency_ms, cost, metadata }
function Langfuse.trace_generation(trace_id, opts)
    if not ENABLED then return end

    opts = opts or {}
    send_event({
        type = "generation-create",
        id = generate_id(),
        timestamp = ngx.utctime(),
        body = {
            traceId = trace_id,
            name = opts.name or "llm-call",
            model = opts.model,
            input = opts.prompt,
            output = opts.completion,
            usage = {
                input = opts.input_tokens,
                output = opts.output_tokens,
                total = (opts.input_tokens or 0) + (opts.output_tokens or 0),
            },
            metadata = opts.metadata or {},
            startTime = opts.start_time,
            endTime = opts.end_time,
            completionStartTime = opts.start_time,
        },
    })
end

--- Record a generic span
-- @param trace_id string Parent trace ID
-- @param opts table { name, input, output, metadata }
function Langfuse.trace_span(trace_id, opts)
    if not ENABLED then return end

    opts = opts or {}
    send_event({
        type = "span-create",
        id = generate_id(),
        timestamp = ngx.utctime(),
        body = {
            traceId = trace_id,
            name = opts.name or "span",
            input = opts.input,
            output = opts.output,
            metadata = opts.metadata or {},
        },
    })
end

return Langfuse
