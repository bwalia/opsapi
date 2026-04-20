-- Multi-Provider LLM Client
-- Supports Anthropic Claude, OpenAI, and Ollama for text classification,
-- image extraction (Claude Vision), and embedding generation.
-- Includes retry with exponential backoff and Langfuse tracing.

local cjson = require("cjson")

local LLMClient = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
local OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
local VOYAGE_API_KEY = os.getenv("VOYAGE_API_KEY")
local OLLAMA_URL = os.getenv("OLLAMA_URL") or "http://ollama:11434"
local OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or "mistral"
local DEFAULT_PROVIDER = os.getenv("DEFAULT_LLM_PROVIDER") or "ollama"

local MAX_RETRIES = 3
local REQUEST_TIMEOUT = 60000 -- 60s for LLM calls

-- Provider defaults
local CLAUDE_MODEL = "claude-sonnet-4-20250514"
local CLAUDE_VISION_MODEL = "claude-sonnet-4-20250514"
local OPENAI_MODEL = "gpt-4o-mini"
local OPENAI_EMBEDDING_MODEL = "text-embedding-3-small"
local VOYAGE_EMBEDDING_MODEL = "voyage-3-lite"

-- ---------------------------------------------------------------------------
-- Internal Helpers
-- ---------------------------------------------------------------------------

local function create_http_client()
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(REQUEST_TIMEOUT)
    return httpc, nil
end

local function safe_json_decode(str)
    if not str or str == "" then return nil, "empty response" end
    local ok, result = pcall(cjson.decode, str)
    if not ok then return nil, "JSON decode error: " .. tostring(result) end
    return result, nil
end

local function get_langfuse()
    local ok, langfuse = pcall(require, "lib.langfuse")
    if ok then return langfuse end
    return nil
end

--- Retry a function with exponential backoff
local function with_retry(fn, max_retries)
    max_retries = max_retries or MAX_RETRIES
    local last_err
    for attempt = 1, max_retries do
        local result, err = fn()
        if result then return result, nil end
        last_err = err
        if attempt < max_retries then
            local delay = math.pow(2, attempt - 1) -- 1s, 2s, 4s
            ngx.sleep(delay)
        end
    end
    return nil, "Failed after " .. max_retries .. " attempts: " .. tostring(last_err)
end

-- ---------------------------------------------------------------------------
-- Claude (Anthropic)
-- ---------------------------------------------------------------------------

local function _call_claude(messages, opts)
    opts = opts or {}
    local api_key = opts.api_key or ANTHROPIC_API_KEY
    if not api_key then return nil, "ANTHROPIC_API_KEY not set" end

    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local model = opts.model or CLAUDE_MODEL
    local body = {
        model = model,
        max_tokens = opts.max_tokens or 2048,
        temperature = opts.temperature or 0.1,
        messages = messages,
    }
    if opts.system then
        body.system = opts.system
    end

    local start_time = ngx.now()
    local res, req_err = httpc:request_uri("https://api.anthropic.com/v1/messages", {
        method = "POST",
        body = cjson.encode(body),
        headers = {
            ["Content-Type"] = "application/json",
            ["x-api-key"] = api_key,
            ["anthropic-version"] = "2023-06-01",
        },
        ssl_verify = false,
    })
    local latency_ms = (ngx.now() - start_time) * 1000

    if not res then return nil, "Claude request failed: " .. tostring(req_err) end
    if res.status >= 400 then
        return nil, "Claude HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local data, decode_err = safe_json_decode(res.body)
    if not data then return nil, decode_err end

    local content = ""
    if data.content and #data.content > 0 then
        content = data.content[1].text or ""
    end

    -- Langfuse trace
    local langfuse = get_langfuse()
    if langfuse and opts.trace_id then
        langfuse.trace_generation(opts.trace_id, {
            name = opts.trace_name or "claude",
            model = model,
            prompt = messages,
            completion = content,
            input_tokens = data.usage and data.usage.input_tokens,
            output_tokens = data.usage and data.usage.output_tokens,
            metadata = { latency_ms = latency_ms, provider = "anthropic" },
        })
    end

    return {
        content = content,
        model = model,
        input_tokens = data.usage and data.usage.input_tokens or 0,
        output_tokens = data.usage and data.usage.output_tokens or 0,
        latency_ms = latency_ms,
    }, nil
end

-- ---------------------------------------------------------------------------
-- OpenAI
-- ---------------------------------------------------------------------------

local function _call_openai(messages, opts)
    opts = opts or {}
    local api_key = opts.api_key or OPENAI_API_KEY
    if not api_key then return nil, "OPENAI_API_KEY not set" end

    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local model = opts.model or OPENAI_MODEL
    local body = {
        model = model,
        temperature = opts.temperature or 0.1,
        max_tokens = opts.max_tokens or 2048,
        messages = messages,
    }
    if opts.response_format then
        body.response_format = opts.response_format
    end

    local start_time = ngx.now()
    local res, req_err = httpc:request_uri("https://api.openai.com/v1/chat/completions", {
        method = "POST",
        body = cjson.encode(body),
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
        },
        ssl_verify = false,
    })
    local latency_ms = (ngx.now() - start_time) * 1000

    if not res then return nil, "OpenAI request failed: " .. tostring(req_err) end
    if res.status >= 400 then
        return nil, "OpenAI HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local data, decode_err = safe_json_decode(res.body)
    if not data then return nil, decode_err end

    local content = ""
    if data.choices and #data.choices > 0 then
        content = data.choices[1].message and data.choices[1].message.content or ""
    end

    local langfuse = get_langfuse()
    if langfuse and opts.trace_id then
        langfuse.trace_generation(opts.trace_id, {
            name = opts.trace_name or "openai",
            model = model,
            prompt = messages,
            completion = content,
            input_tokens = data.usage and data.usage.prompt_tokens,
            output_tokens = data.usage and data.usage.completion_tokens,
            metadata = { latency_ms = latency_ms, provider = "openai" },
        })
    end

    return {
        content = content,
        model = model,
        input_tokens = data.usage and data.usage.prompt_tokens or 0,
        output_tokens = data.usage and data.usage.completion_tokens or 0,
        latency_ms = latency_ms,
    }, nil
end

-- ---------------------------------------------------------------------------
-- Ollama
-- ---------------------------------------------------------------------------

local function _call_ollama(prompt, opts)
    opts = opts or {}
    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local model = opts.model or OLLAMA_MODEL
    local body = {
        model = model,
        prompt = prompt,
        stream = false,
        options = {
            temperature = opts.temperature or 0.1,
        },
    }
    if opts.format == "json" then
        body.format = "json"
    end

    local start_time = ngx.now()
    local res, req_err = httpc:request_uri(OLLAMA_URL .. "/api/generate", {
        method = "POST",
        body = cjson.encode(body),
        headers = { ["Content-Type"] = "application/json" },
        ssl_verify = false,
    })
    local latency_ms = (ngx.now() - start_time) * 1000

    if not res then return nil, "Ollama request failed: " .. tostring(req_err) end
    if res.status >= 400 then
        return nil, "Ollama HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local data, decode_err = safe_json_decode(res.body)
    if not data then return nil, decode_err end

    local content = data.response or ""

    local langfuse = get_langfuse()
    if langfuse and opts.trace_id then
        langfuse.trace_generation(opts.trace_id, {
            name = opts.trace_name or "ollama",
            model = model,
            prompt = prompt,
            completion = content,
            input_tokens = data.prompt_eval_count,
            output_tokens = data.eval_count,
            metadata = { latency_ms = latency_ms, provider = "ollama" },
        })
    end

    return {
        content = content,
        model = model,
        input_tokens = data.prompt_eval_count or 0,
        output_tokens = data.eval_count or 0,
        latency_ms = latency_ms,
    }, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Get available LLM providers based on env configuration
-- @return table Array of { id, name, models, is_default }
function LLMClient.get_providers()
    local providers = {}

    if ANTHROPIC_API_KEY and #ANTHROPIC_API_KEY > 0 then
        table.insert(providers, {
            id = "claude",
            name = "Anthropic Claude",
            models = { CLAUDE_MODEL },
            is_default = DEFAULT_PROVIDER == "claude",
        })
    end

    if OPENAI_API_KEY and #OPENAI_API_KEY > 0 then
        table.insert(providers, {
            id = "openai",
            name = "OpenAI",
            models = { OPENAI_MODEL },
            is_default = DEFAULT_PROVIDER == "openai",
        })
    end

    -- Ollama is always available (local)
    table.insert(providers, {
        id = "ollama",
        name = "Ollama (Local)",
        models = { OLLAMA_MODEL },
        is_default = DEFAULT_PROVIDER == "ollama",
    })

    return providers
end

--- Classify a transaction using the selected LLM provider
-- @param opts table { description, amount, transaction_type, categories, profile_type, provider, model, trace_id, few_shot_examples }
-- @return table { category, hmrc_category, confidence, reasoning, is_tax_deductible } | nil, error
function LLMClient.classify(opts)
    opts = opts or {}
    local provider = opts.provider or DEFAULT_PROVIDER

    -- Build category list for the prompt
    local cat_list = ""
    if opts.categories and #opts.categories > 0 then
        local names = {}
        for _, c in ipairs(opts.categories) do
            table.insert(names, c.name or c)
        end
        cat_list = table.concat(names, ", ")
    end

    -- Build few-shot examples if provided (RAG)
    local examples_text = ""
    if opts.few_shot_examples and #opts.few_shot_examples > 0 then
        examples_text = "\n\nHere are similar transactions and their correct categories:\n"
        for _, ex in ipairs(opts.few_shot_examples) do
            examples_text = examples_text .. string.format(
                '- "%s" (£%.2f) → %s (confidence: %.2f)\n',
                ex.description or "", ex.amount or 0, ex.category or "unknown", ex.confidence or 0
            )
        end
    end

    local system_prompt = [[You are a UK tax classification expert. Classify the following bank transaction into one of the given categories.

You MUST respond with valid JSON only, no other text. Use this exact format:
{"category": "category_name", "hmrc_category": "hmrc_key", "confidence": 0.95, "reasoning": "brief explanation", "is_tax_deductible": true}

Categories: ]] .. cat_list .. [[

HMRC SA103F box mappings:
- costOfGoods (Box 17): Stock, inventory, materials
- staffCosts (Box 19): Salaries, wages, pensions, NIC
- premisesRunningCosts (Box 20): Rent, rates, utilities, insurance
- maintenanceCosts (Box 21): Repairs, maintenance
- adminCosts (Box 22): Phone, stationery, software, subscriptions
- travelCosts (Box 23): Fuel, train, taxi, mileage
- advertisingCosts (Box 24): Marketing, advertising
- businessEntertainmentCosts (Box 25): Client entertainment (NOT deductible)
- professionalFees (Box 29): Accountant, solicitor
- otherExpenses (Box 31): Bank charges, interest, depreciation

Business profile: ]] .. (opts.profile_type or "general") .. examples_text

    local user_prompt = string.format(
        'Classify this transaction:\nDescription: "%s"\nAmount: £%.2f\nType: %s',
        opts.description or "", opts.amount or 0, opts.transaction_type or "DEBIT"
    )

    local result, err

    if provider == "claude" then
        result, err = with_retry(function()
            return _call_claude(
                { { role = "user", content = user_prompt } },
                { system = system_prompt, trace_id = opts.trace_id, trace_name = "classify", temperature = 0.1 }
            )
        end)
    elseif provider == "openai" then
        result, err = with_retry(function()
            return _call_openai(
                {
                    { role = "system", content = system_prompt },
                    { role = "user", content = user_prompt },
                },
                { trace_id = opts.trace_id, trace_name = "classify", temperature = 0.1,
                  response_format = { type = "json_object" } }
            )
        end)
    else -- ollama
        result, err = with_retry(function()
            return _call_ollama(
                system_prompt .. "\n\n" .. user_prompt,
                { format = "json", trace_id = opts.trace_id, trace_name = "classify" }
            )
        end)
    end

    if not result then
        return nil, err
    end

    -- Parse JSON from LLM response
    local classification, parse_err = safe_json_decode(result.content)
    if not classification then
        -- Try to extract JSON from mixed text
        local json_str = result.content:match("{.-}")
        if json_str then
            classification, parse_err = safe_json_decode(json_str)
        end
        if not classification then
            return {
                category = "uncategorised_expense",
                hmrc_category = "otherExpenses",
                confidence = 0,
                reasoning = "Failed to parse LLM response",
                is_tax_deductible = false,
                raw_response = result.content,
                provider = provider,
                model = result.model,
            }, nil
        end
    end

    classification.provider = provider
    classification.model = result.model
    classification.input_tokens = result.input_tokens
    classification.output_tokens = result.output_tokens
    classification.latency_ms = result.latency_ms

    return classification, nil
end

--- Extract structured data from an image using Claude Vision
-- @param opts table { image_base64, mime_type, prompt, trace_id }
-- @return table { content, model, tokens } | nil, error
function LLMClient.extract_from_image(opts)
    opts = opts or {}
    if not ANTHROPIC_API_KEY then return nil, "ANTHROPIC_API_KEY required for Vision" end

    local messages = {
        {
            role = "user",
            content = {
                {
                    type = "image",
                    source = {
                        type = "base64",
                        media_type = opts.mime_type or "image/png",
                        data = opts.image_base64,
                    },
                },
                {
                    type = "text",
                    text = opts.prompt or [[Extract all transactions from this bank statement image.
Return a JSON array where each element has: {"date": "DD/MM/YYYY", "description": "text", "amount": number, "type": "DEBIT" or "CREDIT", "balance": number}
Also include: {"bank_name": "...", "account_number": "...", "sort_code": "...", "statement_period": "...", "opening_balance": number, "closing_balance": number}
Respond with valid JSON only.]],
                },
            },
        },
    }

    return with_retry(function()
        return _call_claude(messages, {
            model = opts.model or CLAUDE_VISION_MODEL,
            max_tokens = 4096,
            trace_id = opts.trace_id,
            trace_name = "vision_extract",
        })
    end)
end

--- Generate embedding vector for text
-- @param opts table { text, provider, trace_id }
-- @return table { embedding: number[] } | nil, error
function LLMClient.generate_embedding(opts)
    opts = opts or {}
    local provider = opts.provider or DEFAULT_PROVIDER
    local text = opts.text
    if not text or #text == 0 then return nil, "text is required" end

    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    if provider == "claude" or provider == "voyage" then
        -- Voyage AI embeddings (used with Claude ecosystem)
        local api_key = VOYAGE_API_KEY
        if not api_key then return nil, "VOYAGE_API_KEY not set" end

        local res, req_err = httpc:request_uri("https://api.voyageai.com/v1/embeddings", {
            method = "POST",
            body = cjson.encode({
                model = VOYAGE_EMBEDDING_MODEL,
                input = { text },
            }),
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. api_key,
            },
            ssl_verify = false,
        })

        if not res then return nil, "Voyage request failed: " .. tostring(req_err) end
        if res.status >= 400 then return nil, "Voyage HTTP " .. res.status end

        local data = safe_json_decode(res.body)
        if data and data.data and #data.data > 0 then
            return { embedding = data.data[1].embedding }, nil
        end
        return nil, "No embedding in Voyage response"

    elseif provider == "openai" then
        local api_key = OPENAI_API_KEY
        if not api_key then return nil, "OPENAI_API_KEY not set" end

        local res, req_err = httpc:request_uri("https://api.openai.com/v1/embeddings", {
            method = "POST",
            body = cjson.encode({
                model = OPENAI_EMBEDDING_MODEL,
                input = text,
            }),
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. api_key,
            },
            ssl_verify = false,
        })

        if not res then return nil, "OpenAI embedding failed: " .. tostring(req_err) end
        if res.status >= 400 then return nil, "OpenAI HTTP " .. res.status end

        local data = safe_json_decode(res.body)
        if data and data.data and #data.data > 0 then
            return { embedding = data.data[1].embedding }, nil
        end
        return nil, "No embedding in OpenAI response"

    else -- ollama
        local res, req_err = httpc:request_uri(OLLAMA_URL .. "/api/embeddings", {
            method = "POST",
            body = cjson.encode({
                model = opts.model or OLLAMA_MODEL,
                prompt = text,
            }),
            headers = { ["Content-Type"] = "application/json" },
            ssl_verify = false,
        })

        if not res then return nil, "Ollama embedding failed: " .. tostring(req_err) end
        if res.status >= 400 then return nil, "Ollama HTTP " .. res.status end

        local data = safe_json_decode(res.body)
        if data and data.embedding then
            return { embedding = data.embedding }, nil
        end
        return nil, "No embedding in Ollama response"
    end
end

--- Send a raw chat message to any provider
-- @param opts table { messages, system, provider, model, temperature, max_tokens, trace_id, trace_name }
-- @return table { content, model, input_tokens, output_tokens, latency_ms } | nil, error
function LLMClient.chat(opts)
    opts = opts or {}
    local provider = opts.provider or DEFAULT_PROVIDER

    if provider == "claude" then
        return with_retry(function()
            return _call_claude(opts.messages, opts)
        end)
    elseif provider == "openai" then
        local messages = opts.messages
        if opts.system then
            table.insert(messages, 1, { role = "system", content = opts.system })
        end
        return with_retry(function()
            return _call_openai(messages, opts)
        end)
    else
        local prompt = ""
        if opts.system then prompt = opts.system .. "\n\n" end
        for _, msg in ipairs(opts.messages or {}) do
            prompt = prompt .. (msg.content or "") .. "\n"
        end
        return with_retry(function()
            return _call_ollama(prompt, opts)
        end)
    end
end

return LLMClient
