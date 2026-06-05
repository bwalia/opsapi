-- Tax Transaction Classification Pipeline
-- Five-layer pipeline: merchant cleaner → profile narrowing → LLM → RAG → confidence adjustment

local cjson = require("cjson")
local db = require("lapis.db")

local Classifier = {}

-- Phase 2 feature flag. Guidance-aware classification (per-profile persona/rules +
-- dynamic snake_case HMRC box map) is ON by default; a consumer can opt out by
-- setting TAX_CLASSIFIER_GUIDANCE to a falsy value, which reverts to the legacy prompt.
local function guidance_enabled()
    local v = os.getenv("TAX_CLASSIFIER_GUIDANCE")
    if v == nil or v == "" then return true end
    v = v:lower()
    return not (v == "0" or v == "false" or v == "off" or v == "no")
end

-- Decode a JSON-text array column (category_affinity / excluded_categories) to a Lua
-- list; returns {} on nil/empty/malformed.
local function decode_json_array(s)
    if type(s) ~= "string" or s == "" then return {} end
    local ok, t = pcall(cjson.decode, s)
    if ok and type(t) == "table" then return t end
    return {}
end

--- Load opsApi-owned per-profile guidance (Phase 0 table). Returns the row or nil.
function Classifier.get_profile_guidance(profile_type)
    if not profile_type then return nil end
    local ok, rows = pcall(db.select,
        "* FROM tax_profile_guidance WHERE profile_key = ? AND is_active = true LIMIT 1",
        profile_type)
    if ok and rows and rows[1] then return rows[1] end
    return nil
end

--- Load the HMRC box catalogue (snake_case keys) the LLM must map into. Returns a list.
function Classifier.get_hmrc_box_map()
    local ok, rows = pcall(db.select,
        "key, box, label, mtd_field_name, is_tax_deductible "
        .. "FROM tax_hmrc_categories WHERE is_active = true ORDER BY id")
    if ok and rows then return rows end
    return {}
end

-- ---------------------------------------------------------------------------
-- Layer 1: Merchant Cleaner
-- ---------------------------------------------------------------------------

local STRIP_PATTERNS = {
    -- Card/payment method prefixes
    "^CARD PAYMENT TO%s+",
    "^CONTACTLESS PAYMENT TO%s+",
    "^DIRECT DEBIT TO%s+",
    "^STANDING ORDER TO%s+",
    "^FASTER PAYMENT TO%s+",
    "^FASTER PAYMENT FROM%s+",
    "^BACS PAYMENT TO%s+",
    "^BACS CREDIT FROM%s+",
    "^BANK TRANSFER TO%s+",
    "^BANK TRANSFER FROM%s+",
    "^INTERNET TRANSFER TO%s+",
    "^POS%s+",
    "^VIS%s+",
    "^MC%s+",
    -- Reference numbers
    "%s+REF[:%s]+[A-Z0-9]+",
    "%s+REFERENCE[:%s]+[A-Z0-9]+",
    "%s+MANDATE NO[:%s]+[A-Z0-9]+",
    -- Card numbers
    "%s+%*+%d%d%d%d",
    "%s+CARD%s+%d+",
    -- Dates embedded in descriptions
    "%s+%d%d[/%-]%d%d[/%-]%d%d%d?%d?",
    "%s+%d%d%s+%a%a%a%s+%d%d%d?%d?",
    -- Location/branch codes
    "%s+%d%d%d%d%d%d+$",
    "%s+[A-Z][A-Z]%d%d%s+%d[A-Z][A-Z]$",
    -- Currency markers
    "GBP%s*",
    "£%s*",
    -- Extra whitespace
    "%s+",
}

--- Clean a transaction description to extract the core merchant name
function Classifier.clean_merchant(description)
    if not description then return "" end
    local cleaned = description:upper()

    for _, pattern in ipairs(STRIP_PATTERNS) do
        cleaned = cleaned:gsub(pattern, " ")
    end

    -- Remove duplicate words
    local words = {}
    local seen = {}
    for word in cleaned:gmatch("%S+") do
        if not seen[word] then
            seen[word] = true
            table.insert(words, word)
        end
    end

    cleaned = table.concat(words, " ")
    return cleaned:match("^%s*(.-)%s*$") or ""
end

-- ---------------------------------------------------------------------------
-- Layer 2: Profile-Driven Category Narrowing
-- ---------------------------------------------------------------------------

local PROFILE_CATEGORIES = {
    amazon_seller = {
        preferred = { "inventory_stock", "shipping_and_delivery", "cost_of_sales", "sales_income",
                      "marketing_advertising", "software_subscriptions", "bank_charges", "accountancy_fees" },
    },
    it_contractor = {
        preferred = { "consulting_income", "software_subscriptions", "equipment_purchase", "home_office",
                      "training_courses", "professional_memberships", "accountancy_fees", "travel_transport" },
    },
    construction = {
        preferred = { "materials_supplies", "subcontractors", "equipment_purchase", "vehicle_fuel",
                      "vehicle_maintenance", "salaries_wages", "business_insurance", "rent_business" },
    },
    landlord = {
        preferred = { "rental_income", "repairs_property", "premises_insurance", "rent_business",
                      "utilities", "accountancy_fees", "legal_fees", "business_rates" },
    },
    freelance_developer = {
        preferred = { "consulting_income", "software_subscriptions", "equipment_purchase", "home_office",
                      "internet", "training_courses", "travel_transport", "accountancy_fees" },
    },
    sole_trader = {
        preferred = { "sales_income", "consulting_income", "office_supplies", "software_subscriptions",
                      "accountancy_fees", "bank_charges", "travel_transport", "marketing_advertising" },
    },
}

--- Narrow categories for a profile: drop excluded keys, mark affinity keys preferred.
-- @param all_categories list of {name=...} (or plain strings)
-- @param affinity list of preferred category keys
-- @param excluded list of category keys to drop entirely
function Classifier.narrow_categories(all_categories, affinity, excluded)
    local preferred_set, excluded_set = {}, {}
    for _, name in ipairs(affinity or {}) do preferred_set[name] = true end
    for _, name in ipairs(excluded or {}) do excluded_set[name] = true end

    local narrowed = {}
    for _, cat in ipairs(all_categories) do
        local name = cat.name or cat
        if not excluded_set[name] then
            if type(cat) == "table" then
                cat.is_preferred = preferred_set[name] or false
            end
            table.insert(narrowed, cat)
        end
    end

    return narrowed
end

-- ---------------------------------------------------------------------------
-- Layer 4: RAG Similarity Search
-- ---------------------------------------------------------------------------

--- Query pgvector for similar transactions
function Classifier.rag_lookup(embedding, limit, threshold)
    limit = limit or 5
    threshold = threshold or 0.7

    if not embedding or #embedding == 0 then
        return {}
    end

    -- Format embedding as pgvector literal
    local vec_parts = {}
    for _, v in ipairs(embedding) do
        table.insert(vec_parts, tostring(v))
    end
    local vec_literal = "[" .. table.concat(vec_parts, ",") .. "]"

    -- Search both training and reference data with UNION ALL
    local sql = string.format([[
        (SELECT original_description as description, category, hmrc_category,
                confidence, is_tax_deductible, source,
                1 - (embedding <=> '%s'::vector) as similarity,
                CASE WHEN source = 'accountant_correction' THEN 1.25 ELSE 1.1 END as weight
         FROM classification_training_data
         WHERE embedding IS NOT NULL
         ORDER BY embedding <=> '%s'::vector
         LIMIT %d)
        UNION ALL
        (SELECT description, category, hmrc_category,
                confidence, is_tax_deductible, 'reference' as source,
                1 - (embedding <=> '%s'::vector) as similarity,
                1.15 as weight
         FROM classification_reference_data
         WHERE embedding IS NOT NULL
         ORDER BY embedding <=> '%s'::vector
         LIMIT %d)
        ORDER BY similarity DESC
        LIMIT %d
    ]], vec_literal, vec_literal, limit, vec_literal, vec_literal, limit, limit)

    local ok, results = pcall(db.query, "SELECT * FROM (" .. sql .. ") combined")
    if not ok or not results then
        return {}
    end

    -- Filter by threshold
    local filtered = {}
    for _, row in ipairs(results) do
        if tonumber(row.similarity) >= threshold then
            table.insert(filtered, row)
        end
    end

    return filtered
end

-- ---------------------------------------------------------------------------
-- Layer 5: Confidence Adjustment
-- ---------------------------------------------------------------------------

--- Adjust confidence based on RAG agreement, profile fit, and anomalies
-- @param affinity list of preferred category keys for the profile (may be empty)
-- @param valid_hmrc set (key->true) of catalogue HMRC keys; guards RAG overrides
function Classifier.adjust_confidence(llm_result, rag_results, affinity, transaction, valid_hmrc)
    local confidence = tonumber(llm_result.confidence) or 0.5

    if rag_results and #rag_results > 0 then
        local top = rag_results[1]
        local similarity = tonumber(top.similarity) or 0

        if top.category == llm_result.category and similarity > 0.85 then
            -- RAG agrees with LLM — boost confidence
            confidence = math.min(0.99, confidence + 0.10)
        elseif top.category ~= llm_result.category and similarity > 0.90 then
            -- RAG disagrees with high confidence. The reference corpus may carry a
            -- STALE/camelCase hmrc_category (pre-Phase-2 data); only override when its
            -- hmrc_category is a valid snake_case catalogue key, otherwise keep the
            -- LLM's category/hmrc_category and just nudge confidence. This prevents RAG
            -- from re-injecting the vocabulary Phase 2 fixed.
            local rag_hmrc_ok = (not valid_hmrc) or (top.hmrc_category and valid_hmrc[top.hmrc_category])
            if rag_hmrc_ok then
                llm_result.category = top.category
                llm_result.hmrc_category = top.hmrc_category
                llm_result.is_tax_deductible = top.is_tax_deductible
                confidence = similarity
                llm_result.reasoning = (llm_result.reasoning or "") ..
                    " [Overridden by RAG match: " .. tostring(top.description) .. " (similarity=" ..
                    string.format("%.2f", similarity) .. ")]"
            else
                -- Strong neighbour but unusable label: flag for review, don't override.
                confidence = math.min(confidence, 0.6)
                llm_result.reasoning = (llm_result.reasoning or "") ..
                    " [RAG neighbour '" .. tostring(top.description) .. "' had a non-catalogue " ..
                    "hmrc_category; not applied — review]"
            end
        end
    end

    -- Profile fit boost
    if affinity and #affinity > 0 then
        local preferred = {}
        for _, name in ipairs(affinity) do
            preferred[name] = true
        end
        if preferred[llm_result.category] then
            confidence = math.min(0.99, confidence + 0.05)
        end
    end

    -- Anomaly: very large transactions get reduced confidence
    local amount = tonumber(transaction.amount) or 0
    if amount > 10000 then
        confidence = math.max(0.10, confidence - 0.15)
    end

    -- Floor
    confidence = math.max(0.10, confidence)

    llm_result.confidence = confidence
    return llm_result
end

-- ---------------------------------------------------------------------------
-- Main Pipeline
-- ---------------------------------------------------------------------------

--- Classify a single transaction through the five-layer pipeline
-- @param transaction table { description, amount, transaction_type, ... }
-- @param opts table { profile_type, llm_provider, categories, trace_id }
-- @return table Classification result
function Classifier.classify_transaction(transaction, opts)
    opts = opts or {}

    local ok_llm, LLMClient = pcall(require, "lib.llm-client")
    if not ok_llm then
        return {
            category = "uncategorised_expense",
            hmrc_category = "otherExpenses",
            confidence = 0,
            reasoning = "LLM client not available",
            is_tax_deductible = false,
        }
    end

    -- Layer 1: Clean merchant description
    local cleaned = Classifier.clean_merchant(transaction.description)

    -- Layer 2: Get categories + profile guidance, then narrow
    local categories = opts.categories
    if not categories then
        -- tax_categories has no `name` column: the machine identity is `key`
        -- (e.g. "sales_income"), which is what the affinity lists, the LLM prompt
        -- (via c.name) and the value written back to tax_transactions.category all
        -- use. Alias key->name so the whole pipeline stays consistent.
        categories = db.select("key as name, hmrc_category_id FROM tax_categories WHERE is_active = true ORDER BY key")
    end

    -- Phase 2: resolve per-profile guidance + the HMRC box map (preloaded by
    -- classify_batch, or looked up here for single-transaction calls). opts.guidance
    -- may be `false` to mean "looked up, none found".
    local guidance = opts.guidance
    if guidance == nil and guidance_enabled() then
        guidance = Classifier.get_profile_guidance(opts.profile_type)
    end
    if guidance == false then guidance = nil end

    local box_map = opts.box_map
    if box_map == nil and guidance_enabled() then
        box_map = Classifier.get_hmrc_box_map()
    end

    -- Affinity/exclusions come from guidance, falling back to the legacy hardcoded
    -- PROFILE_CATEGORIES when no guidance row exists.
    local affinity, excluded = {}, {}
    if guidance then
        affinity = decode_json_array(guidance.category_affinity)
        excluded = decode_json_array(guidance.excluded_categories)
    elseif opts.profile_type and PROFILE_CATEGORIES[opts.profile_type] then
        affinity = PROFILE_CATEGORIES[opts.profile_type].preferred
    end

    -- Capture the full set of valid category keys BEFORE narrowing. This is the
    -- vocabulary downstream filing keys on (tax_categories.key), so we validate the
    -- model's `category` against it in the Phase 4 gates.
    local all_category_keys = {}
    for _, c in ipairs(categories) do all_category_keys[c.name or c] = true end

    categories = Classifier.narrow_categories(categories, affinity, excluded)

    -- Layer 4 (run before LLM to get few-shot examples): RAG lookup
    local rag_results = {}
    local embedding_result = LLMClient.generate_embedding({
        text = cleaned,
        provider = opts.llm_provider,
        trace_id = opts.trace_id,
    })
    if embedding_result and embedding_result.embedding then
        rag_results = Classifier.rag_lookup(embedding_result.embedding, 5, 0.6)
    end

    -- Build few-shot examples from RAG
    local few_shot = {}
    for _, r in ipairs(rag_results) do
        table.insert(few_shot, {
            description = r.description,
            amount = 0,
            category = r.category,
            confidence = tonumber(r.similarity) or 0,
        })
    end

    -- Layer 3: LLM classification
    local classification, err = LLMClient.classify({
        description = cleaned,
        amount = transaction.amount,
        transaction_type = transaction.transaction_type,
        categories = categories,
        profile_type = opts.profile_type,
        provider = opts.llm_provider,
        trace_id = opts.trace_id,
        few_shot_examples = few_shot,
        -- Phase 2 guidance: persona + per-profile rules + dynamic snake_case box map
        persona = guidance and guidance.persona or nil,
        rules_markdown = guidance and guidance.rules_markdown or nil,
        hmrc_box_map = box_map,
    })

    if not classification then
        return {
            category = "uncategorised_expense",
            hmrc_category = "other_expenses",
            confidence = 0,
            reasoning = "Classification failed: " .. tostring(err),
            is_tax_deductible = false,
            classified_by = "error",
        }
    end

    -- Build the catalogue key-set once: used to guard RAG overrides and to validate
    -- the final hmrc_category.
    local valid = nil
    if box_map and #box_map > 0 then
        valid = {}
        for _, b in ipairs(box_map) do valid[b.key] = true end
    end

    -- Layer 5: Confidence adjustment (valid set guards RAG from re-injecting stale keys)
    classification = Classifier.adjust_confidence(classification, rag_results, affinity, transaction, valid)

    -- Phase 4: filing-safety gates. Anything that could produce a wrong/un-fileable
    -- return is forced to human review (regardless of confidence) so it never auto-files.
    local review_reasons = {}

    -- `category` is the key downstream filing aggregates on (tax_categories.key); an
    -- unknown value is silently dropped from the return, so it must be reviewed.
    if next(all_category_keys) ~= nil and classification.category
        and not all_category_keys[classification.category] then
        table.insert(review_reasons, "category '" .. tostring(classification.category)
            .. "' not in tax_categories — would be excluded from filing")
        classification.category_invalid = true
        classification.confidence = math.min(tonumber(classification.confidence) or 0.5, 0.4)
    end

    if valid then
        local box_by_key = {}
        for _, b in ipairs(box_map) do box_by_key[b.key] = b end
        local hk = classification.hmrc_category
        local box = hk and box_by_key[hk]

        if not box then
            -- Unknown/legacy-camelCase/hallucinated key: never persist as fileable.
            table.insert(review_reasons,
                "hmrc_category '" .. tostring(hk) .. "' not in HMRC catalogue")
            classification.confidence = math.min(tonumber(classification.confidence) or 0.5, 0.4)
            classification.hmrc_category_invalid = true
        else
            -- The catalogue box is authoritative for deductibility — the LLM cannot mark
            -- a non-deductible box (e.g. entertainment_costs) as deductible.
            local cat_ded = box.is_tax_deductible
            if cat_ded == "f" or cat_ded == 0 then cat_ded = false end
            if cat_ded == "t" or cat_ded == 1 then cat_ded = true end
            if type(cat_ded) == "boolean" and classification.is_tax_deductible ~= cat_ded then
                classification.is_tax_deductible = cat_ded
            end
            -- Capital purchases need a human AIA/capital-allowances decision.
            if hk == "capital_allowances" then
                table.insert(review_reasons, "capital item — confirm capital allowances/AIA")
            end
        end
    end

    -- Large/anomalous amounts get verified by a human.
    local amount = math.abs(tonumber(transaction.amount) or 0)
    if amount > 10000 then
        table.insert(review_reasons, string.format("large amount (£%.2f) — verify", amount))
    end

    -- A profile whose filing isn't supported yet (e.g. landlord/SA105) must NEVER
    -- auto-file: triage only.
    local fs = guidance and guidance.filing_supported
    if fs == false or fs == "f" or fs == 0 then
        table.insert(review_reasons,
            "profile filing not yet supported (" .. tostring(guidance.sa_form) .. ") — triage only")
    end

    if #review_reasons > 0 then
        classification.needs_review = true
        classification.review_reasons = review_reasons
        classification.reasoning = (classification.reasoning or "")
            .. " [REVIEW: " .. table.concat(review_reasons, "; ") .. "]"
    end

    classification.classified_by = "ai"
    classification.cleaned_description = cleaned

    return classification
end

--- Classify multiple transactions in parallel
-- @param transactions table Array of transaction records
-- @param opts table { profile_type, llm_provider, max_concurrent, trace_id }
-- @return table Array of classification results (parallel indices)
function Classifier.classify_batch(transactions, opts)
    opts = opts or {}
    local max_concurrent = opts.max_concurrent or 5
    local results = {}

    -- Pre-fetch categories once for all transactions (see classify_transaction:
    -- the machine identity is `key`, aliased to name for the pipeline).
    local categories = db.select("key as name, hmrc_category_id FROM tax_categories WHERE is_active = true ORDER BY key")
    opts.categories = categories

    -- Phase 2: preload the HMRC box map + per-profile guidance once for the whole batch
    -- (avoids a DB round-trip per transaction). `false` means "looked up, none found".
    if guidance_enabled() then
        opts.box_map = Classifier.get_hmrc_box_map()
        opts.guidance = Classifier.get_profile_guidance(opts.profile_type) or false
    end

    -- Process in batches of max_concurrent using ngx.thread.spawn
    for batch_start = 1, #transactions, max_concurrent do
        local batch_end = math.min(batch_start + max_concurrent - 1, #transactions)
        local threads = {}

        for i = batch_start, batch_end do
            local txn = transactions[i]
            local thread = ngx.thread.spawn(function()
                return Classifier.classify_transaction(txn, opts)
            end)
            table.insert(threads, { index = i, thread = thread })
        end

        -- Wait for all threads in this batch
        for _, t in ipairs(threads) do
            local ok, result = ngx.thread.wait(t.thread)
            if ok and result then
                results[t.index] = result
            else
                results[t.index] = {
                    category = "uncategorised_expense",
                    hmrc_category = "otherExpenses",
                    confidence = 0,
                    reasoning = "Thread execution failed",
                    is_tax_deductible = false,
                    classified_by = "error",
                }
            end
        end
    end

    return results
end

return Classifier
