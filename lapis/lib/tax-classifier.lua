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
        "key, box, label, mtd_field_name, mtd_section, is_tax_deductible "
        .. "FROM tax_hmrc_categories WHERE is_active = true ORDER BY id")
    if ok and rows then return rows end
    return {}
end

--- Per-category metadata: whether it is INCOME (vs expense), its catalogue HMRC key,
-- and deductibility. Used to (a) offer the model only same-direction categories and
-- (b) trust the catalogue — not the model — for the HMRC box + deductibility. Keyed by
-- category key. income = maps to an income box (turnover/other_income) or type='income'.
function Classifier.category_meta()
    local ok, rows = pcall(db.query, [[SELECT c.key, c.type, c.is_tax_deductible, h.key AS hmrc_key
        FROM tax_categories c LEFT JOIN tax_hmrc_categories h ON h.id = c.hmrc_category_id
        WHERE c.is_active = true]])
    local by_key = {}
    if ok then
        for _, r in ipairs(rows or {}) do
            local ded = r.is_tax_deductible
            if ded == "f" or ded == 0 then ded = false elseif ded == "t" or ded == 1 then ded = true end
            by_key[r.key] = {
                hmrc_key = r.hmrc_key,
                deductible = ded and true or false,
                income = (r.hmrc_key == "turnover" or r.hmrc_key == "other_income" or r.type == "income"),
            }
        end
    end
    return by_key
end

-- ---------------------------------------------------------------------------
-- Layer 1: Merchant Cleaner (shared with admin CSV upload / Python classify)
-- ---------------------------------------------------------------------------

local MerchantCleaner = require("lib.merchant-cleaner")

--- Clean a transaction description to extract the core merchant name.
-- Delegates to lib/merchant-cleaner.lua so OpsAPI upload and FastAPI classify
-- agree on the same cleaned merchant string.
function Classifier.clean_merchant(description)
    return MerchantCleaner.clean_merchant_name(description)
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

-- Rule engine: unambiguous UK merchants, matched as a lowercase substring of the
-- cleaned description. Direction-aware — income rules apply to credits, expense rules
-- to debits. Keep these HIGH-confidence only; ambiguous names fall through to the LLM.
local INCOME_RULES = {
    { "stripe", "sales_income" }, { "paypal", "sales_income" }, { "gocardless", "sales_income" },
    { "sumup", "sales_income" }, { "square", "sales_income" }, { "worldpay", "sales_income" },
    { "takepayments", "sales_income" }, { "zettle", "sales_income" }, { "teya", "sales_income" },
}
local EXPENSE_RULES = {
    -- fuel
    { "shell", "vehicle_fuel" }, { "esso", "vehicle_fuel" }, { "texaco", "vehicle_fuel" },
    { "petrol", "vehicle_fuel" }, { "fuel", "vehicle_fuel" },
    -- transport
    { "uber", "travel_transport" }, { "trainline", "travel_transport" }, { "tfl ", "travel_transport" },
    { "tfl.gov", "travel_transport" }, { "national rail", "travel_transport" }, { "addison lee", "travel_transport" },
    { "railway", "travel_transport" }, { "ryanair", "travel_transport" }, { "easyjet", "travel_transport" },
    -- software / subscriptions
    { "amazon web services", "software_subscriptions" }, { "aws ", "software_subscriptions" },
    { "microsoft", "software_subscriptions" }, { "adobe", "software_subscriptions" },
    { "google cloud", "software_subscriptions" }, { "dropbox", "software_subscriptions" },
    { "zoom", "software_subscriptions" }, { "slack", "software_subscriptions" },
    { "github", "software_subscriptions" }, { "godaddy", "software_subscriptions" },
    { "notion", "software_subscriptions" }, { "atlassian", "software_subscriptions" },
    { "openai", "software_subscriptions" }, { "mailchimp", "software_subscriptions" },
    { "canva", "software_subscriptions" }, { "xero", "software_subscriptions" }, { "quickbooks", "software_subscriptions" },
    -- telephone / internet
    { "vodafone", "telephone" }, { "o2.co", "telephone" }, { "three.co", "telephone" },
    { "plusnet", "telephone" }, { "virgin media", "internet" }, { "ee.co", "telephone" },
    -- utilities
    { "british gas", "utilities" }, { "edf energy", "utilities" }, { "octopus energy", "utilities" },
    { "scottish power", "utilities" }, { "thames water", "utilities" }, { "npower", "utilities" },
    { "eon next", "utilities" }, { "ovo energy", "utilities" },
    -- clearly personal
    { "tesco", "personal_expense" }, { "sainsbury", "personal_expense" }, { "asda", "personal_expense" },
    { "aldi", "personal_expense" }, { "lidl", "personal_expense" }, { "waitrose", "personal_expense" },
    { "costa", "personal_expense" }, { "starbucks", "personal_expense" }, { "greggs", "personal_expense" },
    { "mcdonald", "personal_expense" }, { "kfc", "personal_expense" }, { "pret a manger", "personal_expense" },
    { "nando", "personal_expense" }, { "deliveroo", "personal_expense" }, { "just eat", "personal_expense" },
    { "netflix", "personal_expense" }, { "spotify", "personal_expense" }, { "puregym", "personal_expense" },
    { "disney+", "personal_expense" },
    -- office / materials
    { "screwfix", "materials_supplies" }, { "staples", "office_supplies" }, { "rymans", "office_supplies" },
}

--- Deterministic classification for known merchants. Returns a category key or nil.
-- @param cleaned string  the cleaned merchant description
-- @param is_credit boolean
function Classifier.classify_by_rules(cleaned, is_credit)
    local text = tostring(cleaned or ""):lower()
    if text == "" then return nil end
    for _, rule in ipairs(is_credit and INCOME_RULES or EXPENSE_RULES) do
        if text:find(rule[1], 1, true) then return rule[2] end
    end
    return nil
end

--- Classify a single transaction through the five-layer pipeline
-- @param transaction table { description, amount, transaction_type, ... }
-- @param opts table { profile_type, llm_provider, categories, trace_id }
-- @return table Classification result
function Classifier.classify_transaction(transaction, opts)
    opts = opts or {}

    local ok_llm, LLMClient = pcall(require, "lib.llm-client")
    if not ok_llm then
        -- Graceful degradation: never silently guess. Flag for human review
        -- explicitly (not just via the confidence gate) so model-down transactions
        -- are always surfaced to the user, never auto-filed.
        return {
            category = "uncategorised_expense",
            hmrc_category = "otherExpenses",
            confidence = 0,
            needs_review = true,
            reasoning = "Couldn't auto-classify (the AI model is unavailable) — flagged for your review.",
            is_tax_deductible = false,
            classified_by = "fallback",
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

    -- Direction (CREDIT = money in = income; DEBIT = money out = expense). The model
    -- otherwise reads only the description and files income as an expense (and vice
    -- versa), so we both tell it the direction AND offer only same-direction categories.
    local cat_meta = opts.cat_meta or Classifier.category_meta()
    local is_credit = tostring(transaction.transaction_type):upper() == "CREDIT"

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

    -- Offer only same-direction categories: income for a credit, expense/non-business
    -- for a debit. `transfer` is allowed either way. Falls back to the full list if the
    -- filter would leave nothing (e.g. metadata missing).
    do
        local directed = {}
        for _, c in ipairs(categories) do
            local k = c.name or c
            local inc = cat_meta[k] and cat_meta[k].income
            if (is_credit and (inc or k == "transfer")) or (not is_credit and not inc) then
                directed[#directed + 1] = c
            end
        end
        if #directed > 0 then categories = directed end
    end

    -- Layer 2.5: rule engine — obvious merchants are classified deterministically (no
    -- LLM): faster, and the same merchant always gets the same category. Only
    -- high-confidence, direction-aware matches; everything else falls through to the LLM.
    local classification, err
    local rag_results = {}
    local rule_cat = Classifier.classify_by_rules(cleaned, is_credit)
    if rule_cat then
        classification = { category = rule_cat, confidence = 0.95,
            reasoning = "Matched a known-merchant rule.", classified_by = "rule_engine" }
    else
        -- Layer 4 (run before LLM to get few-shot examples): RAG lookup
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
        classification, err = LLMClient.classify({
            description = cleaned,
            amount = transaction.amount,
            transaction_type = transaction.transaction_type,
            categories = categories,
            profile_type = opts.profile_type,
            provider = opts.llm_provider,
            trace_id = opts.trace_id,
            few_shot_examples = few_shot,
            is_credit = is_credit,
            -- Phase 2 guidance: persona + per-profile rules + dynamic snake_case box map
            persona = guidance and guidance.persona or nil,
            rules_markdown = guidance and guidance.rules_markdown or nil,
            hmrc_box_map = box_map,
        })
    end

    if not classification then
        -- Model down / refused: flag for review explicitly so it is never
        -- auto-filed, regardless of the downstream confidence threshold. Direction-aware:
        -- a credit defaults to income (other income), a debit to uncategorised expense.
        ngx.log(ngx.WARN, "[tax-classifier] classify failed, flagging for review: ", tostring(err))
        return {
            category = is_credit and "income_other" or "uncategorised_expense",
            hmrc_category = is_credit and "other_income" or "other_expenses",
            confidence = 0,
            needs_review = true,
            reasoning = "Couldn't auto-classify (the AI model did not respond) — flagged for your review.",
            is_tax_deductible = false,
            classified_by = "fallback",
        }
    end

    -- The catalogue — not the model — is authoritative for the HMRC box + deductibility.
    -- Mapping the chosen category key to its catalogue hmrc_category stops a model that
    -- picked a valid category but a wrong/invalid box key from being needlessly flagged.
    local meta = classification.category and cat_meta[classification.category]
    if meta then
        if meta.hmrc_key then classification.hmrc_category = meta.hmrc_key end
        classification.is_tax_deductible = meta.deductible
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

            -- A CREDIT (money in) classified into an expense box is almost always income
            -- or a refund mis-filed as a cost. Left as-is the aggregator treats it as a
            -- NEGATIVE period expense, which HMRC rejects outright (the "negative values"
            -- filing blocker). Never auto-file it: force human review so the user confirms
            -- whether it is income (→ turnover/other income) or a genuine refund.
            if box.mtd_section == "periodExpenses"
                and tostring(transaction.transaction_type):upper() == "CREDIT" then
                table.insert(review_reasons,
                    "credit (money in) classified as the expense '" .. tostring(hk)
                    .. "' — confirm whether this is income or a refund")
                classification.confidence = math.min(tonumber(classification.confidence) or 0.5, 0.4)
                classification.credit_in_expense = true
            end
        end
    end

    -- Non-business categories can never be claimed as a deduction, whatever HMRC box
    -- the model paired them with. personal_expense/drawings have NO hmrc box, so the
    -- box-authority check above can't catch them — force non-deductible here.
    local NON_DEDUCTIBLE_CATEGORIES = {
        personal_expense = true,
        drawings = true,
        uncategorised_expense = true,
        transfer = true,
    }
    if classification.category and NON_DEDUCTIBLE_CATEGORIES[classification.category] then
        classification.is_tax_deductible = false
    end

    -- "uncategorised_expense" means the model couldn't place the transaction. It must
    -- never auto-file and must not be silently claimed — force human review and cap
    -- confidence so the route routes it to NEEDS_REVIEW regardless of the LLM's number.
    if classification.category == "uncategorised_expense" or classification.category == nil then
        table.insert(review_reasons, "model could not categorise — assign a category")
        classification.confidence = math.min(tonumber(classification.confidence) or 0.5, 0.4)
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

    -- Keep "rule_engine" if the rule engine answered; otherwise it was the LLM.
    classification.classified_by = classification.classified_by or "ai"
    classification.cleaned_description = cleaned

    return classification
end

--- Classify multiple transactions in parallel
-- @param transactions table Array of transaction records
-- @param opts table { profile_type, llm_provider, max_concurrent, trace_id }
-- @return table Array of classification results (parallel indices)
function Classifier.classify_batch(transactions, opts)
    opts = opts or {}
    -- AI_CLASSIFY_CONCURRENCY: model calls in flight at once. A single self-hosted
    -- model serves them one by one, so a lower number stops queued calls timing out.
    local max_concurrent = opts.max_concurrent or tonumber(os.getenv("AI_CLASSIFY_CONCURRENCY") or "") or 5
    local results = {}

    -- Pre-fetch categories once for all transactions (see classify_transaction:
    -- the machine identity is `key`, aliased to name for the pipeline).
    local categories = db.select("key as name, hmrc_category_id FROM tax_categories WHERE is_active = true ORDER BY key")
    opts.categories = categories
    -- Direction + catalogue-hmrc metadata, once for the batch (per-txn fallback exists).
    opts.cat_meta = Classifier.category_meta()

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
