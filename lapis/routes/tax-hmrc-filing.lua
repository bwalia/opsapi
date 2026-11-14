--[[
    HMRC MTD Filing Routes (Phase 1 — PREVIEW ONLY, NO final declaration)

    GET  /api/v2/tax/hmrc/aggregate-preview?tax_year=2025-26
         Roll classified transactions into the HMRC cumulative MTD body for review.
         Pure aggregation — makes NO call to HMRC.

    POST /api/v2/tax/hmrc/calculate-preview { tax_year, nino?, business_id? }
         Submit the cumulative period to HMRC, trigger an *in-year* (non-binding)
         calculation and return HMRC's calculated figures. Does NOT file the return.

    POST /api/v2/tax/hmrc/sandbox/provision { tax_year, nino?, business_id? }
         Sandbox only: create a stateful test business (self-employment, or UK property
         for a landlord) + set MTD ITSA status so cumulative submissions/calculations
         work for the tax year.

    Which business is filed comes from the File My Tax profile (filingKind): a landlord
    with only UK property files the UK property cumulative summary
    (lib/hmrc-property-aggregator.lua); everyone else files self-employment.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local Global = require("helper.global")
local NamespaceResolver = require("helper.namespace-resolver")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

local function getUserUuid(user)
    return user.uuid or user.id
end

-- Load the tax profile row (NINO + default business) for a user_id.
local function getProfile(user_id)
    local ok, rows = pcall(db.select,
        "nino_encrypted, nino_last4, default_business_id, default_property_business_id "
        .. "FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id)
    if not ok then
        rows = db.select(
            "nino_encrypted, nino_last4, default_business_id FROM tax_user_profiles WHERE user_id = ? LIMIT 1",
            user_id)
    end
    return rows and rows[1]
end

local PROPERTY = "uk-property"
local SELF_EMPLOYMENT = "self-employment"

-- What File My Tax files for this user and year, from the income types they gave the
-- assistant: "uk-property" (landlord only), "self-employment", or "mixed" (both, which
-- one HMRC submission from one set of bank totals can't split).
local function filingKind(user_id, tax_year)
    local ok, TaxTools = pcall(require, "lib.agent.tax-tools")
    if not ok then return SELF_EMPLOYMENT, {} end
    local profile = TaxTools.profile_for(user_id, tax_year) or {}
    local se, prop = false, false
    for _, t in ipairs(profile.income_types or {}) do
        if t == "self_employment" then se = true end
        if t == "uk_property" then prop = true end
    end
    if prop and se then return "mixed", profile end
    if prop then return PROPERTY, profile end
    return SELF_EMPLOYMENT, profile
end

-- The stored filing business for a kind.
local function storedBusiness(profile, kind)
    if not profile then return nil end
    local id = (kind == PROPERTY) and profile.default_property_business_id or profile.default_business_id
    if id == nil or id == "" or id == ngx.null then return nil end
    return id
end

-- Remember the filing business on the user's profile, creating the profile if this is
-- the first thing ever stored for them (user_uuid and namespace_id are NOT NULL).
local function saveDefaultBusiness(user_id, business_id, kind)
    local col = (kind == PROPERTY) and "default_property_business_id" or "default_business_id"
    local existing = db.select("id FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id)
    if existing and #existing > 0 then
        db.update("tax_user_profiles",
            { [col] = business_id, updated_at = db.raw("NOW()") },
            { user_id = user_id })
        return
    end
    local urows = db.query("SELECT uuid FROM users WHERE id = ? LIMIT 1", user_id)
    local user_uuid = urows and urows[1] and urows[1].uuid
    db.insert("tax_user_profiles", {
        uuid = Global.generateStaticUUID(),
        user_id = user_id,
        user_uuid = user_uuid,
        namespace_id = NamespaceResolver.getByUuid(user_uuid) or 0,
        [col] = business_id,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    })
end

-- Resolve the NINO for HMRC calls. Precedence: explicit request param → the user's
-- stored (encrypted) NINO. Returns nil + reason when unavailable.
local function resolveNino(requested, profile)
    if requested and requested ~= "" then
        return requested:upper():gsub("%s", "")
    end
    if profile and profile.nino_encrypted and profile.nino_encrypted ~= "" then
        local ok, nino = pcall(Global.decryptSecret, profile.nino_encrypted)
        if ok and nino and nino ~= "" then return nino:upper():gsub("%s", "") end
    end
    return nil
end

-- Provision a STATEFUL sandbox self-employment business + MTD ITSA status for a tax
-- year, and remember it as the user's default filing business. Returns the new
-- business id, or nil + error. Sandbox-only — the stateful self-employment cumulative
-- endpoint only accepts a business created this way; the ones from the Business Details
-- list / obligations (e.g. XBIS12345678901) are not fileable. Used by the
-- calculate-preview self-heal (mirrors the explicit /sandbox/provision route).
local function provisionSandboxBusiness(Client, Aggregator, token, nino, tax_year, user_id, kind)
    local start_date, end_date = Aggregator.tax_year_bounds(tax_year)
    if not start_date then return nil, "Invalid tax year" end

    local params
    if kind == PROPERTY then
        params = {
            typeOfBusiness = PROPERTY,
            firstAccountingPeriodStartDate = start_date,
            firstAccountingPeriodEndDate = end_date,
            accountingType = "CASH",
            commencementDate = start_date,
        }
    else
        params = {
            typeOfBusiness = SELF_EMPLOYMENT,
            tradingName = "OpsAPI Test SE",
            -- HMRC Test Support now rejects a self-employment business without it
            -- (RULE_MISSING_TRADING_TYPE).
            tradingType = "Plastering",
            firstAccountingPeriodStartDate = start_date,
            firstAccountingPeriodEndDate = end_date,
            accountingType = "ACCRUALS",
            commencementDate = start_date,
            businessAddressLineOne = "1 Test Street",
            businessAddressTownOrCity = "London",
            businessAddressPostcode = "SW1A 1AA",
            businessAddressCountryCode = "GB",
        }
    end
    local biz, berr, bbody = Client.create_test_business(token, nino, params)
    if not biz and kind == PROPERTY and bbody and bbody.code == "RULE_PROPERTY_BUSINESS_ADDED" then
        -- HMRC allows one UK property business per NINO: it was created before (e.g. by
        -- another user of the same sandbox test NINO). Use that one.
        local list = Client.list_businesses(token, nino, { test_scenario = "STATEFUL" })
        biz = list and Client.first_uk_property(list)
    end
    if not biz then return nil, berr or "Failed to create sandbox business", bbody end

    -- Set MTD ITSA status for the year so calculations are allowed.
    local submitted_on = os.date("!%Y-%m-%dT%H:%M:%S") .. ".000Z"
    local itsa_ok, itsa_err = Client.set_itsa_status(token, nino, tax_year, {
        {
            submittedOn = submitted_on,
            status = "MTD Mandated",
            statusReason = "Sign up - return available",
            businessIncome2YearsPrior = 35000.00,
        },
    })

    -- Remember it as the default filing business for this kind.
    pcall(saveDefaultBusiness, user_id, biz, kind)

    return biz, nil, nil, itsa_ok, itsa_err
end

-- Shared prep for the calculate-preview and final-declaration routes: resolve the HMRC
-- token + NINO, aggregate the user's classified transactions into the MTD body, resolve
-- the filing business, and submit (PUT, idempotent) the cumulative period — including the
-- sandbox self-heal that provisions a stateful business if HMRC has none. Returns
-- (ctx, nil) on success, or (nil, response) where `response` is a ready-to-return
-- { status, json } error envelope. `ctx` carries everything the calc/declaration steps need.
-- opts.require_reviewed: refuse (before anything is sent to HMRC) while any transaction
-- for the year is still PENDING/NEEDS_REVIEW — they are left out of the body, so a
-- binding return would silently under-report them.
local function buildAndSubmitCumulative(self, HMRC, Client, Aggregator, opts)
    opts = opts or {}
    local tax_year = self.params.tax_year
    if not tax_year then
        return nil, { status = 400, json = { error = "tax_year is required (e.g. 2025-26)" } }
    end
    local user_id = getUserId(self.current_user)
    if not user_id then return nil, { status = 401, json = { error = "User not found" } } end
    local user_uuid = getUserUuid(self.current_user)

    -- Valid HMRC token (refreshes if needed).
    local token, terr = HMRC.get_valid_token(user_uuid)
    if not token then
        return nil, { status = 400, json = { error = "Not connected to HMRC", detail = terr } }
    end

    -- NINO (request param or the user's stored, encrypted NINO).
    local profile = getProfile(user_id)
    local nino = resolveNino(self.params.nino, profile)
    if not nino then
        return nil, { status = 400, json = {
            error = "No NINO available — create/connect a sandbox test user first" } }
    end

    local kind, fprofile = filingKind(user_id, tax_year)
    if kind == "mixed" then
        return nil, { status = 422, json = { code = "MIXED_INCOME_NOT_SUPPORTED",
            error = "You have both self-employment and rental income. Filing both from one set of bank "
                .. "statements isn't supported here yet, so choose \"Our accountant files it\"." } }
    end
    local is_property = (kind == PROPERTY)

    -- Aggregate classified transactions into the MTD body.
    local agg, aerr
    if is_property then
        agg, aerr = require("lib.hmrc-property-aggregator").build_cumulative_body({
            user_id = user_id, tax_year = tax_year, profile = fprofile })
    else
        agg, aerr = Aggregator.build_cumulative_body({ user_id = user_id, tax_year = tax_year })
    end
    if not agg then return nil, { status = 400, json = { error = aerr } } end
    if #agg.negative_fields > 0 then
        if is_property then
            return nil, { status = 422, json = {
                error = "Your rental income comes out negative, which HMRC rejects. Check refunds or money "
                    .. "paid back to tenants are categorised correctly.",
                negative_fields = agg.negative_fields } }
        end
        local neg_fields = {}
        for _, nf in ipairs(agg.negative_fields) do
            table.insert(neg_fields, (nf.field:gsub("Disallowable$", "")))
        end
        return nil, { status = 422, json = {
            error = "Aggregated body has negative values — HMRC would reject it. Fix the "
                .. "miscategorised credit/refund before submitting.",
            negative_fields = agg.negative_fields,
            offending_transactions = Aggregator.credit_offenders(
                { user_id = user_id, tax_year = tax_year }, neg_fields) } }
    end
    if agg.empty then
        return nil, { status = 422, json = { error = "No income or expenses to submit for this tax year" } }
    end
    local unreviewed = tonumber(agg.stats and agg.stats.excluded_unreviewed) or 0
    if opts.require_reviewed and unreviewed > 0 then
        return nil, { status = 422, json = {
            code = "UNREVIEWED_TRANSACTIONS",
            unreviewed = unreviewed,
            error = unreviewed .. " transaction(s) for " .. tax_year .. " still need review. They are "
                .. "left out of the figures, so filing now would under-report them — review them first." } }
    end

    -- Resolve the business id: param → stored default → the right business from HMRC.
    local business_id = self.params.business_id
    if not business_id or business_id == "" then business_id = storedBusiness(profile, kind) end
    if not business_id or business_id == "" then
        -- Sandbox: STATEFUL lists the test-support businesses, the only fileable ones.
        local list = Client.list_businesses(token, nino,
            { test_scenario = Client.is_sandbox() and "STATEFUL" or nil })
        if list then
            business_id = is_property and Client.first_uk_property(list) or Client.first_self_employment(list)
        end
    end
    if (not business_id or business_id == "") and Client.is_sandbox() then
        business_id = provisionSandboxBusiness(Client, Aggregator, token, nino, tax_year, user_id, kind)
    end
    if not business_id or business_id == "" then
        return nil, { status = 422, json = {
            error = "No HMRC " .. (is_property and "UK property" or "self-employment")
                .. " business found for this National Insurance number." } }
    end

    -- Build the body (self-employment needs the period dates added; property has them).
    local body = agg.body
    if not is_property then
        body.periodDates = { periodStartDate = agg.tax_year_start, periodEndDate = agg.tax_year_end }
    end
    local submit = is_property and Client.submit_property_cumulative or Client.submit_cumulative

    -- Submit the cumulative period. In the sandbox the only fileable business is one
    -- created via the test-support API; the businesses from the Business Details list /
    -- obligations (e.g. XBIS12345678901) are NOT stateful, so submitting against them
    -- returns MATCHING_RESOURCE_NOT_FOUND. Self-heal: provision a stateful business for
    -- this NINO + tax year and retry once, so the user never has to know about provisioning.
    local sres, serr, sbody = submit(token, nino, business_id, tax_year, body)
    if not sres and Client.is_sandbox()
        and sbody and sbody.code == "MATCHING_RESOURCE_NOT_FOUND" then
        local new_biz, perr = provisionSandboxBusiness(Client, Aggregator, token, nino, tax_year, user_id, kind)
        if new_biz then
            business_id = new_biz
            sres, serr, sbody = submit(token, nino, business_id, tax_year, body)
        else
            serr = perr or serr
        end
    end
    if not sres then
        local hint = ""
        if sbody and sbody.code == "MATCHING_RESOURCE_NOT_FOUND" then
            hint = " HMRC has no " .. (is_property and "UK property" or "self-employment")
                .. " record for this combination of NINO, business (" .. tostring(business_id)
                .. ") and tax year (" .. tax_year .. "). File for a tax year HMRC shows as open for "
                .. "this business — use the open obligation rather than a typed year."
        end
        return nil, { status = 502, json = {
            error = "HMRC rejected the period submission." .. hint,
            detail = serr, hmrc = sbody,
            business_id = business_id, tax_year = tax_year } }
    end

    return {
        tax_year = tax_year, user_id = user_id, user_uuid = user_uuid, kind = kind,
        token = token, nino = nino, business_id = business_id, agg = agg, body = body,
    }, nil
end

return function(app)

    -- GET /api/v2/tax/hmrc/aggregate-preview — review the MTD body before any HMRC call
    app:get("/api/v2/tax/hmrc/aggregate-preview",
        AuthMiddleware.requireAuth(function(self)
            local tax_year = self.params.tax_year
            if not tax_year then
                return { status = 400, json = { error = "tax_year is required (e.g. 2025-26)" } }
            end

            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local ok_agg, Aggregator = pcall(require, "lib.hmrc-aggregator")
            if not ok_agg then
                return { status = 500, json = { error = "Aggregator not available" } }
            end

            local kind, fprofile = filingKind(user_id, tax_year)
            local result, err
            if kind == PROPERTY then
                result, err = require("lib.hmrc-property-aggregator").build_cumulative_body({
                    user_id = user_id, tax_year = tax_year, profile = fprofile })
            else
                result, err = Aggregator.build_cumulative_body({
                    user_id = user_id,
                    tax_year = tax_year,
                })
            end
            if not result then
                return { status = 400, json = { error = err or "Aggregation failed" } }
            end

            -- Surface review-worthy conditions so the UI can warn before filing.
            -- `blocking` means the body would be rejected by HMRC and must NOT be submitted.
            local warnings = {}
            local blocking = false
            local offending_transactions = {}
            if kind == "mixed" then
                blocking = true
                table.insert(warnings, "You have both self-employment and rental income. Filing both from "
                    .. "one set of bank statements isn't supported here yet, so choose \"Our accountant files it\".")
            end
            if kind == PROPERTY and #result.negative_fields > 0 then
                blocking = true
                table.insert(warnings, "Your rental income comes out negative, which HMRC rejects. Check "
                    .. "refunds or money paid back to tenants are categorised correctly.")
            elseif #result.negative_fields > 0 then
                blocking = true
                local fields = {}
                for _, nf in ipairs(result.negative_fields) do
                    table.insert(warnings, string.format(
                        "'%s' is negative (%.2f) — HMRC rejects negative values; a credit/refund is likely "
                        .. "miscategorised into an expense. Fix before filing.", nf.field, nf.value))
                    -- Disallowable mirrors share the same source field name (minus the suffix).
                    table.insert(fields, (nf.field:gsub("Disallowable$", "")))
                end
                offending_transactions = Aggregator.credit_offenders(
                    { user_id = user_id, tax_year = tax_year }, fields)
            end
            if result.stats.excluded_unreviewed > 0 then
                table.insert(warnings, string.format(
                    "%d transaction(s) are still PENDING/NEEDS_REVIEW and were excluded — review them first",
                    result.stats.excluded_unreviewed))
            end
            if result.stats.excluded_no_mtd_field > 0 then
                table.insert(warnings, string.format(
                    "%d transaction(s) (e.g. capital allowances / use of home) are not part of the period summary",
                    result.stats.excluded_no_mtd_field))
            end
            if result.empty then
                table.insert(warnings, "No income or expenses to submit for this tax year")
            end

            return {
                status = 200,
                json = {
                    success = true,
                    data = {
                        tax_year = tax_year,
                        filing_kind = kind,
                        period = { from = result.tax_year_start, to = result.tax_year_end },
                        body = result.body,
                        stats = result.stats,
                        warnings = warnings,
                        blocking = blocking,
                        offending_transactions = offending_transactions,
                    },
                },
            }
        end)
    )

    -- POST /api/v2/tax/hmrc/calculate-preview — submit cumulative + trigger an in-year
    -- (non-binding) calculation and return HMRC's figures. This does NOT file the return.
    app:post("/api/v2/tax/hmrc/calculate-preview",
        AuthMiddleware.requireAuth(function(self)
            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            local ok_cli, Client = pcall(require, "lib.hmrc-mtd-client")
            local ok_agg, Aggregator = pcall(require, "lib.hmrc-aggregator")
            if not (ok_hmrc and ok_cli and ok_agg) then
                return { status = 500, json = { error = "HMRC modules not available" } }
            end

            -- Resolve + submit the cumulative period (shared with final declaration).
            local ctx, errResp = buildAndSubmitCumulative(self, HMRC, Client, Aggregator)
            if not ctx then return errResp end

            -- Trigger an in-year (non-binding) calculation, then poll until it's ready.
            local calc_id, cterr, ctbody = Client.trigger_calculation(ctx.token, ctx.nino, ctx.tax_year, "in-year")
            if not calc_id then
                return { status = 502, json = {
                    error = "HMRC calculation trigger failed", detail = cterr, hmrc = ctbody } }
            end
            local cres, cerr, cbody, attempts = Client.poll_calculation(ctx.token, ctx.nino, ctx.tax_year, calc_id)
            if not cres then
                return { status = 502, json = {
                    error = "Calculation did not complete in time", detail = cerr, hmrc = cbody,
                    calculation_id = calc_id } }
            end

            local figures = Client.parse_figures(cres.data)

            -- Persist the calculation (best-effort audit trail).
            pcall(function()
                db.insert("hmrc_calculations", {
                    uuid = Global.generateStaticUUID(),
                    user_uuid = ctx.user_uuid,
                    business_id = ctx.business_id,
                    tax_year = ctx.tax_year,
                    calculation_id = calc_id,
                    calculation_type = "in-year",
                    status = "retrieved",
                    correlation_id = cres.correlation_id,
                    period_start = ctx.agg.tax_year_start,
                    period_end = ctx.agg.tax_year_end,
                    total_income_tax_and_nics_due = figures.total_income_tax_and_nics_due,
                    total_taxable_income = figures.total_taxable_income,
                    income_tax_charged = figures.income_tax_charged,
                    class2_nics = figures.class2_nics,
                    class4_nics = figures.class4_nics,
                    personal_allowance = figures.personal_allowance,
                    tx_total = ctx.agg.stats.rows,
                    tx_applied = ctx.agg.stats.applied,
                    tx_excluded_no_mtd = ctx.agg.stats.excluded_no_mtd_field,
                    poll_attempts = attempts,
                    request_payload = cjson.encode(ctx.body),
                    raw_response = cjson.encode(cres.data),
                    triggered_at = db.raw("NOW()"),
                    retrieved_at = db.raw("NOW()"),
                    created_at = db.raw("NOW()"),
                    updated_at = db.raw("NOW()"),
                })
            end)

            return { status = 200, json = { success = true, data = {
                tax_year = ctx.tax_year,
                filing_kind = ctx.kind,
                business_id = ctx.business_id,
                calculation_id = calc_id,
                figures = figures,
                sandbox_placeholder = figures.is_sandbox_placeholder or false,
                body = ctx.body,
                stats = ctx.agg.stats,
            } } }
        end)
    )

    -- POST /api/v2/tax/hmrc/submit-final-declaration { tax_year, business_id?, nino?,
    --                                                  declaration_accepted }
    -- The BINDING final declaration (crystallisation) — THIS FILES THE RETURN with HMRC.
    -- Re-submits the cumulative period so HMRC holds the final figures, triggers an
    -- intent-to-finalise calculation, then submits the final declaration against it.
    -- Requires an explicit declaration_accepted=true (it is legally binding).
    app:post("/api/v2/tax/hmrc/submit-final-declaration",
        AuthMiddleware.requireAuth(function(self)
            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            local ok_cli, Client = pcall(require, "lib.hmrc-mtd-client")
            local ok_agg, Aggregator = pcall(require, "lib.hmrc-aggregator")
            if not (ok_hmrc and ok_cli and ok_agg) then
                return { status = 500, json = { error = "HMRC modules not available" } }
            end

            -- Hard gate: the user must confirm the declaration — this is binding.
            local accepted = self.params.declaration_accepted
            if accepted ~= "true" and accepted ~= true then
                return { status = 400, json = {
                    code = "DECLARATION_REQUIRED",
                    error = "You must confirm the declaration before filing your return." } }
            end

            -- Idempotency (as diy-tax-return-uk): never file the same year twice, and refuse
            -- while another submission for it is in flight (double-click, retried request).
            local guard_year = tostring(self.params.tax_year or "")
            local guard_uuid = getUserUuid(self.current_user)
            local guard_uid = getUserId(self.current_user)
            local prior = db.query([[
                SELECT status, calculation_id, business_id, correlation_id, updated_at,
                       updated_at > NOW() - INTERVAL '10 minutes' AS recent
                FROM hmrc_calculations
                WHERE user_uuid = ? AND tax_year = ? AND calculation_type = 'final-declaration'
                  AND status IN ('filed', 'submitting')
                ORDER BY (status = 'filed') DESC, updated_at DESC LIMIT 1]], guard_uuid, guard_year)
            local filed_return = guard_uid and db.query([[SELECT hmrc_submission_id, hmrc_filed_at
                FROM tax_returns WHERE user_id = ? AND tax_year = ? AND status = 'FILED' LIMIT 1]],
                guard_uid, guard_year)[1]
            local p = prior and prior[1]
            if (p and p.status == "filed") or filed_return then
                return { status = 200, json = { success = true, data = {
                    already_filed = true, filed = true, tax_year = guard_year,
                    business_id = p and p.business_id or nil,
                    sandbox = Client.is_sandbox(),
                    calculation_id = (p and p.calculation_id) or (filed_return and filed_return.hmrc_submission_id),
                    message = "Your return for " .. guard_year .. " has already been filed.",
                } } }
            end
            if p and p.status == "submitting" and p.recent then
                return { status = 409, json = { code = "FILING_IN_PROGRESS",
                    error = "A filing for " .. guard_year .. " is already in progress. Wait a minute, then "
                        .. "refresh to see whether it went through." } }
            end

            -- Resolve + submit the cumulative period (shared with calculate-preview).
            local ctx, errResp = buildAndSubmitCumulative(self, HMRC, Client, Aggregator,
                { require_reviewed = true })
            if not ctx then return errResp end

            -- 1) Trigger the intent-to-finalise calculation. The final declaration MUST
            -- reference a calculation produced by this type (HMRC rejects an in-year one).
            local calc_id, cterr, ctbody =
                Client.trigger_calculation(ctx.token, ctx.nino, ctx.tax_year, "intent-to-finalise")
            if not calc_id then
                return { status = 502, json = {
                    error = "HMRC could not start the final calculation", detail = cterr, hmrc = ctbody } }
            end

            -- 2) Poll until that calculation is ready (surfaces validation errors HMRC
            -- would otherwise reject the declaration for).
            local cres, cerr, cbody, attempts = Client.poll_calculation(ctx.token, ctx.nino, ctx.tax_year, calc_id)
            if not cres then
                return { status = 502, json = {
                    error = "Final calculation did not complete in time", detail = cerr, hmrc = cbody,
                    calculation_id = calc_id } }
            end
            local figures = Client.parse_figures(cres.data)

            -- 3) Write the audit row BEFORE the binding call (as diy does): a filed return
            -- must always leave a record. If we can't write it, we don't file.
            local audit_uuid = Global.generateUUID()
            local ok_audit, audit_err = pcall(db.insert, "hmrc_calculations", {
                uuid = audit_uuid,
                user_uuid = ctx.user_uuid,
                business_id = ctx.business_id,
                tax_year = ctx.tax_year,
                calculation_id = calc_id,
                calculation_type = "final-declaration",
                status = "submitting",
                correlation_id = cres.correlation_id,
                period_start = ctx.agg.tax_year_start,
                period_end = ctx.agg.tax_year_end,
                total_income_tax_and_nics_due = figures.total_income_tax_and_nics_due,
                total_taxable_income = figures.total_taxable_income,
                income_tax_charged = figures.income_tax_charged,
                class2_nics = figures.class2_nics,
                class4_nics = figures.class4_nics,
                personal_allowance = figures.personal_allowance,
                tx_total = ctx.agg.stats.rows,
                tx_applied = ctx.agg.stats.applied,
                tx_excluded_no_mtd = ctx.agg.stats.excluded_no_mtd_field,
                poll_attempts = attempts,
                request_payload = cjson.encode(ctx.body),
                raw_response = cjson.encode(cres.data),
                triggered_at = db.raw("NOW()"),
                retrieved_at = db.raw("NOW()"),
                created_at = db.raw("NOW()"),
                updated_at = db.raw("NOW()"),
            })
            if not ok_audit then
                ngx.log(ngx.ERR, "[hmrc] final declaration NOT sent — audit row failed: ", tostring(audit_err))
                return { status = 500, json = {
                    error = "Couldn't record the filing, so it was not sent to HMRC. Please try again." } }
            end

            -- 4) Submit the BINDING final declaration against that calculation.
            local fres, ferr, fbody = Client.submit_final_declaration(ctx.token, ctx.nino, ctx.tax_year, calc_id)
            if not fres then
                pcall(db.update, "hmrc_calculations", {
                    status = "failed",
                    error_message = tostring(ferr) .. " " .. cjson.encode(fbody or {}),
                    updated_at = db.raw("NOW()"),
                }, { uuid = audit_uuid })
                return { status = 502, json = {
                    error = "HMRC rejected the final declaration.",
                    detail = ferr, hmrc = fbody,
                    code = fbody and fbody.code or nil,
                    calculation_id = calc_id, tax_year = ctx.tax_year } }
            end

            -- 5) Filed. Mark the audit row and the year's return (tax_returns is what
            -- diy-tax-return-uk's already-filed checks read). Logged loudly on failure:
            -- the return IS filed with HMRC at this point.
            local ok_mark, mark_err = pcall(function()
                db.update("hmrc_calculations", {
                    status = "filed",
                    correlation_id = fres.correlation_id or cres.correlation_id,
                    updated_at = db.raw("NOW()"),
                }, { uuid = audit_uuid })
                local updated = db.query([[UPDATE tax_returns
                    SET status = 'FILED', hmrc_submission_id = ?, hmrc_filed_at = NOW(), updated_at = NOW()
                    WHERE user_id = ? AND tax_year = ?]], calc_id, ctx.user_id, ctx.tax_year)
                if (updated.affected_rows or 0) == 0 then
                    db.insert("tax_returns", {
                        uuid = Global.generateUUID(),
                        user_id = ctx.user_id,
                        tax_year = ctx.tax_year,
                        status = "FILED",
                        hmrc_submission_id = calc_id,
                        hmrc_filed_at = db.raw("NOW()"),
                        total_tax_due = figures.total_income_tax_and_nics_due,
                        created_at = db.raw("NOW()"),
                        updated_at = db.raw("NOW()"),
                    })
                end
            end)
            if not ok_mark then
                ngx.log(ngx.ERR, "[hmrc] return FILED with HMRC (calc ", calc_id, ", user ", ctx.user_uuid,
                    ", ", ctx.tax_year, ") but marking it failed: ", tostring(mark_err))
            end

            return { status = 200, json = { success = true, data = {
                filed = true,
                tax_year = ctx.tax_year,
                business_id = ctx.business_id,
                calculation_id = calc_id,
                figures = figures,
                sandbox = Client.is_sandbox(),
            } } }
        end)
    )

    -- GET /api/v2/tax/hmrc/business/default — the business id we'll file against (the
    -- stored default). In sandbox this is the test-support *stateful* business, which the
    -- Business Details list API does NOT return — so the UI needs it explicitly.
    app:get("/api/v2/tax/hmrc/business/default",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then return { status = 200, json = { business_id = nil } } end
            local kind = SELF_EMPLOYMENT
            if self.params.tax_year and self.params.tax_year ~= "" then
                kind = filingKind(user_id, self.params.tax_year)
            end
            local profile = getProfile(user_id)
            return { status = 200, json = {
                business_id = storedBusiness(profile, kind == PROPERTY and PROPERTY or SELF_EMPLOYMENT),
                -- "uk-property" | "self-employment" | "mixed": which HMRC business File My Tax files.
                filing_kind = kind } }
        end)
    )

    -- POST /api/v2/tax/hmrc/business/select { business_id } — persist the user's chosen
    -- default self-employment business so the filing flow (calculate-preview) uses it.
    app:post("/api/v2/tax/hmrc/business/select",
        AuthMiddleware.requireAuth(function(self)
            local business_id = self.params.business_id
            if not business_id or business_id == "" then
                return { status = 400, json = { error = "business_id is required" } }
            end
            local user_id = getUserId(self.current_user)
            if not user_id then return { status = 401, json = { error = "User not found" } } end

            local kind = self.params.kind
            if kind ~= PROPERTY and self.params.tax_year and self.params.tax_year ~= "" then
                kind = filingKind(user_id, self.params.tax_year)
            end
            kind = (kind == PROPERTY) and PROPERTY or SELF_EMPLOYMENT
            saveDefaultBusiness(user_id, business_id, kind)
            return { status = 200, json = { success = true, data = { business_id = business_id, kind = kind } } }
        end)
    )

    -- POST /api/v2/tax/hmrc/sandbox/provision — sandbox only. Create a stateful test
    -- self-employment business and set MTD ITSA status so the current tax year accepts
    -- cumulative submissions/calculations. Stores the business id on the user's profile.
    app:post("/api/v2/tax/hmrc/sandbox/provision",
        AuthMiddleware.requireAuth(function(self)
            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            local ok_cli, Client = pcall(require, "lib.hmrc-mtd-client")
            local ok_agg, Aggregator = pcall(require, "lib.hmrc-aggregator")
            if not (ok_hmrc and ok_cli and ok_agg) then
                return { status = 500, json = { error = "HMRC modules not available" } }
            end
            if not Client.is_sandbox() then
                return { status = 400, json = { error = "Provisioning is sandbox-only" } }
            end

            local tax_year = self.params.tax_year
            if not tax_year then
                return { status = 400, json = { error = "tax_year is required (e.g. 2025-26)" } }
            end
            local start_date, _, yerr = Aggregator.tax_year_bounds(tax_year)
            if not start_date then return { status = 400, json = { error = yerr } } end

            local user_id = getUserId(self.current_user)
            if not user_id then return { status = 401, json = { error = "User not found" } } end
            local user_uuid = getUserUuid(self.current_user)

            local token, terr = HMRC.get_valid_token(user_uuid)
            if not token then
                return { status = 400, json = { error = "Not connected to HMRC", detail = terr } }
            end
            local profile = getProfile(user_id)
            local nino = resolveNino(self.params.nino, profile)
            if not nino then
                return { status = 400, json = { error = "No NINO available — connect a sandbox test user first" } }
            end

            local kind = filingKind(user_id, tax_year)
            local biz, berr, bbody, itsa_ok, iterr =
                provisionSandboxBusiness(Client, Aggregator, token, nino, tax_year, user_id, kind)
            if not biz then
                return { status = 502, json = {
                    error = "Failed to create sandbox business", detail = berr, hmrc = bbody } }
            end

            return { status = 200, json = { success = true, data = {
                business_id = biz,
                kind = (kind == PROPERTY) and PROPERTY or SELF_EMPLOYMENT,
                itsa_status = itsa_ok and "MTD Mandated" or nil,
                itsa_error = (not itsa_ok) and iterr or nil,
            } } }
        end)
    )

end
