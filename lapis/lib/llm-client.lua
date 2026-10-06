-- LLM client for the tax / bookkeeping features
-- Text classification, bank-statement extraction (images/PDFs) and plain chat go
-- through lib/agent/llm, so they use the platform's one model setting
-- (AI_PROVIDER / AI_MODEL / AI_API_KEY / AI_BASE_URL — see that file); vision
-- uses Llm.vision (AI_VISION_PROVIDER / AI_VISION_MODEL). Embeddings stay on
-- their own model: the stored RAG vectors are 384-dim all-MiniLM, and switching
-- the chat model must never change that space.
-- Includes retry with exponential backoff and Langfuse tracing.

local cjson = require("cjson")
local Llm = require("lib.agent.llm")

local LLMClient = {}

-- ---------------------------------------------------------------------------
-- Configuration (embeddings only — every other call follows lib/agent/llm)
-- ---------------------------------------------------------------------------

local OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
local VOYAGE_API_KEY = os.getenv("VOYAGE_API_KEY")
local OLLAMA_URL = os.getenv("OLLAMA_URL") or "http://ollama:11434"
-- Dedicated embedding model. MUST be an embedder (NOT the chat model): the RAG
-- corpus is stored as vector(384) from all-MiniLM-L6-v2, so query embeddings must
-- land in that same 384-dim space. Ollama's `all-minilm` is that model.
local OLLAMA_EMBED_MODEL = os.getenv("OLLAMA_EMBED_MODEL") or "all-minilm"
local DEFAULT_EMBED_PROVIDER = os.getenv("DEFAULT_LLM_PROVIDER") or "ollama"

local MAX_RETRIES = 3
local REQUEST_TIMEOUT = 60000 -- 60s for LLM calls

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
-- One completion through the configured model (lib/agent/llm)
-- ---------------------------------------------------------------------------

-- @param messages table agent-format messages (system/user, optional attachments)
-- @param opts table { cfg?, json?, temperature?, max_tokens?, trace_id?, trace_name?, feature? }
-- @return { content, model, input_tokens, output_tokens, latency_ms } | nil, err
local function complete(messages, opts)
    opts = opts or {}
    local start_time = ngx.now()
    local msg, err = Llm.chat(messages, nil, {
        cfg = opts.cfg,
        json = opts.json,
        temperature = opts.temperature or 0.1,
        max_tokens = opts.max_tokens or 2048,
        timeout_ms = REQUEST_TIMEOUT,
        usage = { feature = opts.feature or "tax_chat" }, -- metered to the request's user (lib/agent/llm)
    })
    if not msg then return nil, err end
    local latency_ms = (ngx.now() - start_time) * 1000
    local result = {
        content = msg.content or "",
        model = msg.model,
        input_tokens = msg.usage and msg.usage.input or 0,
        output_tokens = msg.usage and msg.usage.output or 0,
        latency_ms = latency_ms,
    }

    local langfuse = get_langfuse()
    if langfuse and opts.trace_id then
        langfuse.trace_generation(opts.trace_id, {
            name = opts.trace_name or "llm",
            model = result.model,
            prompt = messages,
            completion = result.content,
            input_tokens = result.input_tokens,
            output_tokens = result.output_tokens,
            metadata = { latency_ms = latency_ms, provider = (opts.cfg or Llm.default).provider },
        })
    end
    return result, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- The model these features use (one, from the env — see lib/agent/llm).
-- @return table Array of { id, name, models, is_default, available }
function LLMClient.get_providers()
    return { {
        id = Llm.default.provider,
        name = Llm.default.label,
        models = { Llm.default.model },
        is_default = true,
        available = Llm.configured(),
    } }
end

--- Classify a transaction using the selected LLM provider
-- @param opts table { description, amount, transaction_type, categories, profile_type, provider, model, trace_id, few_shot_examples }
-- @return table { category, hmrc_category, confidence, reasoning, is_tax_deductible } | nil, error
function LLMClient.classify(opts)
    opts = opts or {}
    -- opts.provider is accepted for old callers but ignored: the model is the
    -- platform's one setting (lib/agent/llm).
    local provider = Llm.default.provider

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

    local system_prompt
    if opts.hmrc_box_map and #opts.hmrc_box_map > 0 then
        -- Guidance-aware prompt (Phase 2). The HMRC box map is built dynamically from
        -- tax_hmrc_categories, so `hmrc_category` is emitted as a **snake_case key**
        -- from that catalogue (e.g. "car_van_travel") — the vocabulary the rest of the
        -- system and downstream consumers expect. Persona + per-profile rules come from
        -- tax_profile_guidance.
        local persona = opts.persona
            or "You are a UK chartered accountant classifying a sole trader's bank "
            .. "transactions for Self Assessment (SA103). Apply the wholly-and-exclusively "
            .. "test and separate capital purchases from revenue expenses."

        local box_lines = {}
        for _, b in ipairs(opts.hmrc_box_map) do
            local ded = b.is_tax_deductible and "deductible" or "NOT deductible"
            table.insert(box_lines, string.format("- %s (Box %s): %s [%s]",
                tostring(b.key), tostring(b.box), b.label or "", ded))
        end

        local rules_text = ""
        if opts.rules_markdown and #opts.rules_markdown > 0 then
            rules_text = "\n\nProfile-specific HMRC guidance:\n" .. opts.rules_markdown
        end

        system_prompt = persona .. "\n\n"
            .. "Classify the transaction into one system category and map it to the "
            .. "correct HMRC box.\n\n"
            .. "Respond with VALID JSON ONLY, no other text:\n"
            .. '{"category": "category_name", "hmrc_category": "hmrc_key", '
            .. '"confidence": 0.95, "reasoning": "brief explanation", "is_tax_deductible": true}\n\n'
            .. "System categories: " .. cat_list .. "\n\n"
            .. "HMRC boxes — `hmrc_category` MUST be EXACTLY one of these snake_case keys, "
            .. "never anything else:\n" .. table.concat(box_lines, "\n") .. "\n\n"
            .. "Rules: capital purchases (computers, plant, vehicles) map to "
            .. "capital_allowances, never a revenue box. Business entertainment is "
            .. "entertainment_costs and is NOT deductible. Clearly personal or "
            .. "non-business spending (personal coffee/meals, supermarket groceries, ATM "
            .. "cash withdrawals) is personal_expense and is NOT deductible — prefer it "
            .. "over a business box whenever the transaction looks personal. Use "
            .. "uncategorised_expense ONLY as a last resort when nothing else fits, and "
            .. "lower the confidence when you do." .. rules_text
            .. "\n\nBusiness profile: " .. (opts.profile_type or "general") .. examples_text
    else
        -- Legacy prompt (feature flag off / no box map supplied). NOTE: emits camelCase
        -- HMRC keys — retained only for backward-compatible opt-out.
        system_prompt = [[You are a UK tax classification expert. Classify the following bank transaction into one of the given categories.

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
    end

    local user_prompt = string.format(
        'Classify this transaction:\nDescription: "%s"\nAmount: £%.2f\nType: %s',
        opts.description or "", opts.amount or 0, opts.transaction_type or "DEBIT"
    )

    local result, err = with_retry(function()
        return complete({
            { role = "system", content = system_prompt },
            { role = "user", content = user_prompt },
        }, { json = true, temperature = 0.1, trace_id = opts.trace_id, trace_name = "classify",
            feature = "tax_classify" })
    end)

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

--- Extract structured data from a statement image or PDF with the vision
-- model (Llm.vision: AI_VISION_PROVIDER/AI_VISION_MODEL, else the main model;
-- Claude by default while AI_PROVIDER is unset and an Anthropic key exists).
-- @param opts table { image_base64, mime_type, prompt, trace_id }
-- @return table { content, model, tokens } | nil, error
function LLMClient.extract_from_image(opts)
    opts = opts or {}
    if not Llm.configured(Llm.vision) then
        return nil, "No vision model is configured (set AI_VISION_PROVIDER / AI_VISION_MODEL or AI_PROVIDER)"
    end
    local prompt = opts.prompt or [[Extract all transactions from this bank statement.
Return a JSON array where each element has: {"date": "DD/MM/YYYY", "description": "text", "amount": number, "type": "DEBIT" or "CREDIT", "balance": number}
Also include: {"bank_name": "...", "account_number": "...", "sort_code": "...", "statement_period": "...", "opening_balance": number, "closing_balance": number}
Respond with valid JSON only.]]
    local messages = { {
        role = "user",
        content = prompt,
        attachments = { { mime = opts.mime_type or "image/png", data = opts.image_base64 } },
    } }
    return with_retry(function()
        return complete(messages, {
            cfg = Llm.vision,
            max_tokens = 4096,
            trace_id = opts.trace_id,
            trace_name = "vision_extract",
            feature = "statement_extract",
        })
    end)
end

--- Generate embedding vector for text
-- @param opts table { text, provider, trace_id }
-- @return table { embedding: number[] } | nil, error
function LLMClient.generate_embedding(opts)
    opts = opts or {}
    local provider = opts.provider or DEFAULT_EMBED_PROVIDER
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
                model = opts.model or OLLAMA_EMBED_MODEL,
                prompt = text,
            }),
            -- The workstation gateway needs its JWT here too (as for chat).
            headers = { ["Content-Type"] = "application/json", ["x-api-key"] = Llm.ollama_auth() },
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

--- Send a chat to the configured model
-- @param opts table { messages, system, temperature, max_tokens, json, trace_id, trace_name }
-- @return table { content, model, input_tokens, output_tokens, latency_ms } | nil, error
function LLMClient.chat(opts)
    opts = opts or {}
    local messages = {}
    if opts.system then messages[1] = { role = "system", content = opts.system } end
    for _, m in ipairs(opts.messages or {}) do messages[#messages + 1] = m end
    return with_retry(function()
        return complete(messages, opts)
    end)
end

return LLMClient
