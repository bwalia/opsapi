--[[
    HMRC Data Routes

    Fetch and cache HMRC businesses and obligations.

    GET  /api/v2/hmrc/status                      — Token validity check
    POST /api/v2/hmrc/businesses/fetch             — Fetch from HMRC API
    GET  /api/v2/hmrc/businesses                   — Get cached businesses
    POST /api/v2/hmrc/obligations/fetch             — Fetch from HMRC API
    GET  /api/v2/hmrc/obligations                  — Get cached obligations
    POST /api/v2/hmrc/sandbox/create-test-user      — Sandbox helper
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local Global = require("helper.global")
local NamespaceResolver = require("helper.namespace-resolver")
local IdentityLock = require("lib.identity_lock")
local respond_to = require("lapis.application").respond_to

-- Resolve the numeric user id (tax_user_profiles is keyed on it) from the JWT uuid.
local function getUserId(user_uuid)
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

-- Resolve the NINO for HMRC calls: explicit request param → the user's stored,
-- encrypted NINO (captured when a sandbox test user is created, or saved manually).
local function resolveNino(user_id, requested)
    if requested and requested ~= "" then
        return (requested:upper():gsub("%s", ""))
    end
    if not user_id then return nil end
    local rows = db.select(
        "nino_encrypted FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id)
    local enc = rows and rows[1] and rows[1].nino_encrypted
    if enc and enc ~= "" then
        local ok, nino = pcall(Global.decryptSecret, enc)
        if ok and nino and nino ~= "" then return (nino:upper():gsub("%s", "")) end
    end
    return nil
end

-- Derive the UK tax year ("YYYY-YY") a date falls in (year boundary 6 April).
local function tax_year_of(date_str)
    local y, m = tostring(date_str or ""):match("^(%d%d%d%d)%-(%d%d)")
    if not y then return "" end
    y, m = tonumber(y), tonumber(m)
    local start = (m >= 4) and y or (y - 1)
    return string.format("%04d-%02d", start, (start + 1) % 100)
end

return function(app)

    -- GET /api/v2/hmrc/status
    app:get("/api/v2/hmrc/status",
        AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id

            local rows = db.select(
                "access_token, expires_at, scope, created_at FROM hmrc_tokens WHERE user_uuid = ? LIMIT 1",
                user_uuid
            )

            if not rows or #rows == 0 then
                return { status = 200, json = { connected = false, message = "No HMRC connection" } }
            end

            local token = rows[1]
            local exp_rows = db.query(
                "SELECT expires_at > NOW() as is_valid, expires_at FROM hmrc_tokens WHERE user_uuid = ? LIMIT 1",
                user_uuid
            )
            local is_valid = exp_rows and exp_rows[1] and exp_rows[1].is_valid

            return {
                status = 200,
                json = {
                    connected = true,
                    is_valid = is_valid,
                    expires_at = token.expires_at,
                    scope = token.scope,
                }
            }
        end)
    )

    -- POST /api/v2/hmrc/businesses/fetch
    -- Pull the taxpayer's businesses from the HMRC Business Details (MTD) API. That
    -- endpoint is NINO-scoped (/individuals/business/details/{nino}/list) — without the
    -- NINO HMRC returns 404 MATCHING_RESOURCE_NOT_FOUND, so we resolve it first.
    app:post("/api/v2/hmrc/businesses/fetch",
        AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id

            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            local ok_cli, Client = pcall(require, "lib.hmrc-mtd-client")
            if not (ok_hmrc and ok_cli) then
                return { status = 500, json = { error = "HMRC modules not available" } }
            end

            local access_token, token_err = HMRC.get_valid_token(user_uuid)
            if not access_token then
                return { status = 401, json = { error = token_err or "Not connected to HMRC" } }
            end

            local user_id = getUserId(user_uuid)
            local nino = resolveNino(user_id, self.params.nino)
            if not nino then
                return { status = 400, json = {
                    code = "NINO_REQUIRED",
                    error = "No National Insurance number on file. In the HMRC sandbox, create a "
                        .. "test user (it stores a NINO automatically); otherwise add your NINO first." } }
            end

            local data, err, hmrc_body = Client.list_businesses(access_token, nino)
            if not data then
                -- Surface the real HMRC reason instead of a silent failure.
                local code = hmrc_body and hmrc_body.code
                local detail = hmrc_body and hmrc_body.message
                local msg
                if code == "CLIENT_OR_AGENT_NOT_AUTHORISED" or tostring(err):find("403") then
                    -- The connected HMRC login is not authorised for this NINO. In the
                    -- sandbox the NINO must belong to the test user you signed in as.
                    msg = "The HMRC account you signed in with isn't authorised for the National "
                        .. "Insurance number on file (ending " .. nino:sub(-4) .. "). In the sandbox "
                        .. "the NINO must belong to the test user you log in as — create a test user "
                        .. "in HMRC settings, reconnect signing in with those exact credentials, then "
                        .. "load businesses. If the NINO is wrong, change it to match your login."
                else
                    msg = "HMRC could not return your businesses for NINO ending "
                        .. nino:sub(-4) .. " (" .. tostring(err) .. ")."
                        .. (detail and (" " .. detail) or "")
                end
                return { status = 502, json = { error = msg, code = code, hmrc = hmrc_body } }
            end

            -- The MTD list response nests under listOfBusinesses; older shapes vary.
            local businesses = data.listOfBusinesses or data.businesses
                or data.businessDetails or data.selfEmployment or {}
            -- hmrc_businesses.namespace_id is NOT NULL — resolve once per request.
            local namespace_id = NamespaceResolver.getByUuid(user_uuid)
            for _, biz in ipairs(businesses) do
                db.query([[
                    INSERT INTO hmrc_businesses (user_uuid, namespace_id, business_id, type_of_business, trading_name, raw_response, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, NOW())
                    ON CONFLICT (user_uuid, business_id) DO UPDATE SET
                        type_of_business = EXCLUDED.type_of_business,
                        trading_name = EXCLUDED.trading_name,
                        raw_response = EXCLUDED.raw_response,
                        fetched_at = NOW()
                ]], user_uuid, namespace_id, biz.businessId or biz.id, biz.typeOfBusiness or "",
                    biz.tradingName or "", cjson.encode(biz))
            end

            return { status = 200, json = { data = businesses, count = #businesses } }
        end)
    )

    -- GET /api/v2/hmrc/businesses
    app:get("/api/v2/hmrc/businesses",
        AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id
            local businesses = db.select(
                "* FROM hmrc_businesses WHERE user_uuid = ? ORDER BY fetched_at DESC",
                user_uuid
            )
            return { status = 200, json = { data = businesses or {} } }
        end)
    )

    -- POST /api/v2/hmrc/obligations/fetch
    -- Pull income-tax obligations from the Obligations (MTD) API (NINO-scoped). Caches
    -- each period with its tax year + due date so we can later remind the user a return
    -- is due. `business_id` (optional) filters the cached/returned rows to one business.
    app:post("/api/v2/hmrc/obligations/fetch",
        AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id
            local business_id = self.params.business_id
            local from_date = self.params.from_date or os.date("%Y") .. "-04-06"
            local to_date = self.params.to_date or (tonumber(os.date("%Y")) + 1) .. "-04-05"

            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            local ok_cli, Client = pcall(require, "lib.hmrc-mtd-client")
            if not (ok_hmrc and ok_cli) then
                return { status = 500, json = { error = "HMRC modules not available" } }
            end

            local access_token, token_err = HMRC.get_valid_token(user_uuid)
            if not access_token then
                return { status = 401, json = { error = token_err or "Not connected to HMRC" } }
            end

            local user_id = getUserId(user_uuid)
            local nino = resolveNino(user_id, self.params.nino)
            if not nino then
                return { status = 400, json = {
                    code = "NINO_REQUIRED",
                    error = "No National Insurance number on file — add your NINO (or create a "
                        .. "sandbox test user) before fetching obligations." } }
            end

            -- Sandbox only: with no Gov-Test-Scenario the HMRC sandbox returns a fixed
            -- historical sample (2017-18/2018-19) and ignores our dates — which is why
            -- testers see ancient obligations. DYNAMIC makes HMRC echo periods matching
            -- the from/to we send, giving current-tax-year obligations for real testing.
            -- The header is automatically dropped outside the sandbox (see headers()).
            local data, err, hmrc_body = Client.list_obligations(access_token, nino, {
                from = from_date, to = to_date,
                test_scenario = Client.is_sandbox() and "DYNAMIC" or nil,
            })
            if not data then
                local detail = hmrc_body and hmrc_body.message
                return { status = 502, json = {
                    error = "HMRC could not return your obligations (" .. tostring(err) .. ")."
                        .. (detail and (" " .. detail) or ""),
                    code = hmrc_body and hmrc_body.code or nil,
                    hmrc = hmrc_body } }
            end

            -- Cache obligations, flattening + filtering to one business.
            -- In the sandbox, DYNAMIC returns the SAME period windows for three synthetic
            -- businesses (self-employment XBIS…, UK property XPIS…, foreign property XFIS…).
            -- Keeping all three makes every period show up three times. We file
            -- self-employment, so keep only that one, and store it under the user's real
            -- filing business id so the rows map to the business they actually selected.
            -- Production returns the real business's obligations and is filtered by id.
            local is_sandbox = Client.is_sandbox()
            local obligations = data.obligations or {}
            local returned = {}
            for _, ob in ipairs(obligations) do
                local include
                if is_sandbox then
                    include = (ob.typeOfBusiness == "self-employment")
                else
                    include = (not business_id) or (ob.businessId == business_id)
                end
                if include then
                    -- Sandbox: persist under the selected/real business id (or the synthetic
                    -- one if we have nothing better) so obligations link to the filing business.
                    local ob_business = is_sandbox and (business_id or ob.businessId)
                        or (ob.businessId or business_id)
                    ob.businessId = ob_business
                    table.insert(returned, ob)
                    -- hmrc_obligations.namespace_id is NOT NULL — resolve per ob batch.
                    local ob_namespace_id = NamespaceResolver.getByUuid(user_uuid)
                    for _, period in ipairs(ob.obligationDetails or {}) do
                        -- Conflict target is the UNIQUE INDEX idx_hmrc_obligations_period
                        -- (user_uuid, business_id, period_start, period_end) — there is no
                        -- named constraint, so use the column-list form.
                        db.query([[
                            INSERT INTO hmrc_obligations (user_uuid, namespace_id, business_id, period_start, period_end, due_date, status, period_key, tax_year, fetched_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
                            ON CONFLICT (user_uuid, business_id, period_start, period_end)
                            DO UPDATE SET
                                status = EXCLUDED.status,
                                due_date = EXCLUDED.due_date,
                                tax_year = EXCLUDED.tax_year,
                                fetched_at = NOW()
                        ]], user_uuid, ob_namespace_id, ob_business or "",
                            period.periodStartDate, period.periodEndDate,
                            period.dueDate, period.status or "Open",
                            period.periodKey or "", tax_year_of(period.periodStartDate))
                    end
                end
            end

            return { status = 200, json = { data = returned } }
        end)
    )

    -- GET /api/v2/hmrc/obligations
    app:get("/api/v2/hmrc/obligations",
        AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id
            local business_id = self.params.business_id

            local where = "user_uuid = " .. db.escape_literal(user_uuid)
            if business_id then
                where = where .. " AND business_id = " .. db.escape_literal(business_id)
            end

            local obligations = db.select(
                "* FROM hmrc_obligations WHERE " .. where .. " ORDER BY period_start ASC"
            )
            return { status = 200, json = { data = obligations or {} } }
        end)
    )

    -- /api/v2/hmrc/nino — GET reports whether a NINO is on file (last 4 only);
    -- POST stores the user's NINO (encrypted) for filing. Both methods live on one
    -- route via respond_to — registering app:get and app:post on the same path
    -- separately makes Lapis keep only one (the other 404s).
    app:match("/api/v2/hmrc/nino", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user.uuid or self.current_user.id)
            if not user_id then return { status = 200, json = { has_nino = false } } end
            local rows = db.select(
                "nino_last4, has_nino FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id)
            local row = rows and rows[1]
            local has = row and (row.has_nino == true or row.has_nino == "t"
                or (row.nino_last4 and row.nino_last4 ~= "")) or false
            return { status = 200, json = { has_nino = has, last4 = row and row.nino_last4 or nil } }
        end),
        POST = AuthMiddleware.requireAuth(function(self)
            local raw = self.params.nino
            if not raw or raw == "" then
                return { status = 400, json = { error = "nino is required" } }
            end
            local nino = (raw:upper():gsub("%s", ""))
            -- UK NINO format: two letters, six digits, one suffix letter.
            if not nino:match("^%a%a%d%d%d%d%d%d%a$") then
                return { status = 400, json = {
                    error = "That doesn't look like a valid National Insurance number (e.g. QQ123456C)." } }
            end
            -- Explicit consent is required before we store this personal data (GDPR).
            local consent = self.params.consent
            consent = (consent == true or consent == "true" or consent == "1")
            if not consent then
                return { status = 400, json = { code = "CONSENT_REQUIRED",
                    error = "Please confirm you consent to us securely storing your National "
                        .. "Insurance number so we can file with HMRC." } }
            end
            local user_uuid = self.current_user.uuid or self.current_user.id
            local user_id = getUserId(user_uuid)
            if not user_id then return { status = 401, json = { error = "User not found" } } end
            local namespace_id = NamespaceResolver.getByUuid(user_uuid) or 0

            -- ─── Anti-fraud guard (see lib/identity_lock.lua) ─────────────
            -- Blocks re-write once the lock timestamp is set. Errors.raise
            -- from inside surfaces as a catalog 403 with support_url etc.
            IdentityLock.assertNotLocked(user_uuid, namespace_id, "nino")

            local enc = Global.encryptSecret(nino)
            local last4 = nino:sub(-4)

            -- Uniqueness check + write in one txn so the advisory lock
            -- covers the CAS.
            db.query("BEGIN")
            local ok, txn_err = pcall(function()
                IdentityLock.assertNinoUniqueInNamespace(user_id, namespace_id, nino, Global)

                local existing = db.select("id FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id)
                if existing and #existing > 0 then
                    db.update("tax_user_profiles",
                        { nino_encrypted = enc, nino_last4 = last4, has_nino = true,
                          nino_consent_at = db.raw("NOW()"), updated_at = db.raw("NOW()") },
                        { user_id = user_id })
                else
                    db.insert("tax_user_profiles", {
                        uuid = Global.generateStaticUUID(),
                        user_id = user_id,
                        namespace_id = namespace_id,
                        nino_encrypted = enc,
                        nino_last4 = last4,
                        has_nino = true,
                        nino_consent_at = db.raw("NOW()"),
                        created_at = db.raw("NOW()"),
                        updated_at = db.raw("NOW()"),
                    })
                end
                -- Stamp lock in the SAME txn so a successful save is ALWAYS
                -- accompanied by a lock stamp.
                IdentityLock.stampLock(user_uuid, namespace_id, "nino")
            end)
            if not ok then
                db.query("ROLLBACK")
                error(txn_err)
            end
            db.query("COMMIT")

            IdentityLock.emitAuditRow({
                user_id      = user_id,
                namespace_id = namespace_id,
                action       = "NINO_SAVED_AND_LOCKED",
                new_values   = { nino_last4 = last4, path = "/api/v2/hmrc/nino" },
            })

            return { status = 200, json = { success = true, data = { has_nino = true, last4 = last4 } } }
        end),

        -- DELETE — erase the stored NINO (GDPR right to erasure / user request).
        -- BLOCKED when nino_locked_at IS NOT NULL: sneaky delete-then-re-save
        -- would defeat the anti-fraud lock. Admin unlock is the only route
        -- to remove a locked NINO — see POST /api/v2/admin/tax-user-profiles/
        -- {uuid}/unlock.
        DELETE = AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id
            local user_id = getUserId(user_uuid)
            if not user_id then return { status = 401, json = { error = "User not found" } } end
            local namespace_id = NamespaceResolver.getByUuid(user_uuid) or 0

            IdentityLock.assertNotLocked(user_uuid, namespace_id, "nino")

            db.update("tax_user_profiles",
                { nino_encrypted = db.NULL, nino_last4 = db.NULL, has_nino = false,
                  nino_consent_at = db.NULL, updated_at = db.raw("NOW()") },
                { user_id = user_id })

            IdentityLock.emitAuditRow({
                user_id      = user_id,
                namespace_id = namespace_id,
                action       = "NINO_REMOVED",
                old_values   = { path = "/api/v2/hmrc/nino" },
            })

            return { status = 200, json = { success = true, data = { has_nino = false } } }
        end),
    }))

    -- POST /api/v2/hmrc/sandbox/create-test-user
    app:post("/api/v2/hmrc/sandbox/create-test-user",
        AuthMiddleware.requireAuth(function(self)
            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            if not ok_hmrc then
                return { status = 500, json = { error = "HMRC module not available" } }
            end

            local data, err = HMRC.create_sandbox_test_user()
            if not data then
                return { status = 422, json = { error = err } }
            end

            -- Persist the test user's NINO (encrypted) on the current user's tax profile
            -- so HMRC filing calls can use it without asking the user to re-enter it.
            --
            -- Also respects the identity-lock: if the user's NINO is already
            -- locked (they filed a real return earlier and now switched to
            -- sandbox testing), we DO NOT overwrite. Sandbox users regenerate
            -- test-users regularly, and silently swapping their real NINO for
            -- a fake HMRC-issued one would defeat the anti-fraud lock's whole
            -- purpose. The catalog error surfaces cleanly to the FE.
            if data.nino and data.nino ~= "" then
                local user_uuid = self.current_user.uuid or self.current_user.id
                local urows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
                local uid = urows and urows[1] and urows[1].id
                if uid then
                    local namespace_id = NamespaceResolver.getByUuid(user_uuid) or 0

                    -- Same guard the regular /nino POST uses.
                    IdentityLock.assertNotLocked(user_uuid, namespace_id, "nino")

                    local enc = Global.encryptSecret(data.nino)
                    local last4 = data.nino:sub(-4)

                    db.query("BEGIN")
                    local ok, txn_err = pcall(function()
                        IdentityLock.assertNinoUniqueInNamespace(uid, namespace_id, data.nino, Global)
                        local existing = db.select("id FROM tax_user_profiles WHERE user_id = ? LIMIT 1", uid)
                        if existing and #existing > 0 then
                            db.update("tax_user_profiles",
                                { nino_encrypted = enc, nino_last4 = last4, has_nino = true,
                                  updated_at = db.raw("NOW()") },
                                { user_id = uid })
                        else
                            db.insert("tax_user_profiles", {
                                uuid = Global.generateStaticUUID(),
                                user_id = uid,
                                namespace_id = namespace_id,
                                nino_encrypted = enc,
                                nino_last4 = last4,
                                has_nino = true,
                                created_at = db.raw("NOW()"),
                                updated_at = db.raw("NOW()"),
                            })
                        end
                        IdentityLock.stampLock(user_uuid, namespace_id, "nino")
                    end)
                    if not ok then
                        db.query("ROLLBACK")
                        error(txn_err)
                    end
                    db.query("COMMIT")

                    IdentityLock.emitAuditRow({
                        user_id      = uid,
                        namespace_id = namespace_id,
                        action       = "NINO_SAVED_AND_LOCKED",
                        new_values   = { nino_last4 = last4, path = "/api/v2/hmrc/sandbox/create-test-user" },
                    })
                end
            end

            return { status = 201, json = { data = data } }
        end)
    )
end
