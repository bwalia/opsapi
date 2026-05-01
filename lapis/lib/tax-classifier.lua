-- Tax Transaction Classification Pipeline
-- Five-layer pipeline: merchant cleaner → profile narrowing → LLM → RAG → confidence adjustment

local cjson = require("cjson")
local db = require("lapis.db")

local Classifier = {}

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

--- Narrow categories based on business profile, returning all but marking preferred
function Classifier.narrow_categories(all_categories, profile_type)
    if not profile_type or not PROFILE_CATEGORIES[profile_type] then
        return all_categories
    end

    local preferred_set = {}
    for _, name in ipairs(PROFILE_CATEGORIES[profile_type].preferred) do
        preferred_set[name] = true
    end

    local narrowed = {}
    for _, cat in ipairs(all_categories) do
        local name = cat.name or cat
        cat.is_preferred = preferred_set[name] or false
        table.insert(narrowed, cat)
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
function Classifier.adjust_confidence(llm_result, rag_results, profile_type, transaction)
    local confidence = tonumber(llm_result.confidence) or 0.5

    if rag_results and #rag_results > 0 then
        local top = rag_results[1]
        local similarity = tonumber(top.similarity) or 0

        if top.category == llm_result.category and similarity > 0.85 then
            -- RAG agrees with LLM — boost confidence
            confidence = math.min(0.99, confidence + 0.10)
        elseif top.category ~= llm_result.category and similarity > 0.90 then
            -- RAG disagrees with high confidence — prefer RAG
            llm_result.category = top.category
            llm_result.hmrc_category = top.hmrc_category
            llm_result.is_tax_deductible = top.is_tax_deductible
            confidence = similarity
            llm_result.reasoning = (llm_result.reasoning or "") ..
                " [Overridden by RAG match: " .. top.description .. " (similarity=" ..
                string.format("%.2f", similarity) .. ")]"
        end
    end

    -- Profile fit boost
    if profile_type and PROFILE_CATEGORIES[profile_type] then
        local preferred = {}
        for _, name in ipairs(PROFILE_CATEGORIES[profile_type].preferred) do
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

    -- Layer 2: Get and narrow categories
    local categories = opts.categories
    if not categories then
        categories = db.select("name, hmrc_category_id FROM tax_categories WHERE is_active = true ORDER BY name")
    end
    categories = Classifier.narrow_categories(categories, opts.profile_type)

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
    })

    if not classification then
        return {
            category = "uncategorised_expense",
            hmrc_category = "otherExpenses",
            confidence = 0,
            reasoning = "Classification failed: " .. tostring(err),
            is_tax_deductible = false,
            classified_by = "error",
        }
    end

    -- Layer 5: Confidence adjustment
    classification = Classifier.adjust_confidence(classification, rag_results, opts.profile_type, transaction)
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

    -- Pre-fetch categories once for all transactions
    local categories = db.select("name, hmrc_category_id FROM tax_categories WHERE is_active = true ORDER BY name")
    opts.categories = categories

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
