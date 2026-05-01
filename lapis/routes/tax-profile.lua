--[[
    Tax Profile Routes (HMRC Profile Management)

    User profile endpoints for HMRC integration:
      - Save/verify NINO (stored as bcrypt hash, only last 4 visible)
      - View HMRC connection status
      - Manage default business & tax year

    All endpoints require JWT authentication.
    Users can only access their own profile.
]]

local cjson = require("cjson")
local TaxUserProfileQueries = require("queries.TaxUserProfileQueries")
local HMRCBusinessQueries = require("queries.HMRCBusinessQueries")
local HMRCObligationQueries = require("queries.HMRCObligationQueries")
local HMRCTokenQueries = require("queries.HMRCTokenQueries")

-- Helper: parse JSON body into params
local function parseJsonBody(self)
    local params = self.params or {}
    local ct = ngx.req.get_headers()["content-type"]
    if ct and ct:find("application/json") then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body then
            local ok, parsed = pcall(cjson.decode, body)
            if ok and parsed then
                for k, v in pairs(parsed) do params[k] = v end
            end
        end
    end
    return params
end

return function(app)

    -- =========================================================================
    -- GET /api/v2/tax/profile
    -- Get the user's HMRC tax profile (masked NINO, connection status, etc.)
    -- =========================================================================
    app:get("/api/v2/tax/profile", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id

        -- Get or create profile (pcall to catch DB errors)
        local ok, profile, err = pcall(TaxUserProfileQueries.getOrCreate, user_uuid)
        if not ok then
            ngx.log(ngx.ERR, "[Tax Profile] getOrCreate failed: ", tostring(profile))
            return { status = 500, json = { error = "Failed to load profile: " .. tostring(profile) } }
        end
        if not profile then
            return { status = 500, json = { error = err or "Failed to create profile" } }
        end

        -- Check HMRC token status (pcall — hmrc_tokens table may not exist)
        local hmrc_connected = false
        local hmrc_token = nil
        local tok_ok, tok_result = pcall(HMRCTokenQueries.getValid, user_uuid)
        if tok_ok and tok_result then
            hmrc_token = tok_result
            hmrc_connected = true
        end
        if profile.hmrc_connected ~= hmrc_connected then
            pcall(TaxUserProfileQueries.setHmrcConnected, user_uuid, hmrc_connected)
        end

        -- Get cached businesses (pcall — table may be empty/new)
        local business_list = {}
        local biz_ok, businesses = pcall(HMRCBusinessQueries.allForUser, user_uuid)
        if biz_ok and businesses then
            for _, b in ipairs(businesses) do
                table.insert(business_list, {
                    business_id = b.business_id,
                    trading_name = b.trading_name,
                    type_of_business = b.type_of_business,
                    fetched_at = b.fetched_at,
                })
            end
        end

        -- Get open obligations count (pcall)
        local open_count = 0
        local ob_ok, open_obligations = pcall(HMRCObligationQueries.openForUser, user_uuid)
        if ob_ok and open_obligations then
            open_count = #open_obligations
        end

        -- Build masked NINO display
        local nino_display = nil
        if profile.has_nino and profile.nino_last4 then
            nino_display = "****" .. profile.nino_last4
        end

        return {
            status = 200,
            json = {
                uuid = profile.uuid,
                has_nino = profile.has_nino,
                nino_masked = nino_display,
                hmrc_connected = hmrc_connected,
                hmrc_token_expires_at = hmrc_token and hmrc_token.expires_at or nil,
                default_business_id = profile.default_business_id,
                default_tax_year = profile.default_tax_year,
                businesses = business_list,
                open_obligations_count = open_count,
                created_at = profile.created_at,
                updated_at = profile.updated_at,
            }
        }
    end)

    -- =========================================================================
    -- POST /api/v2/tax/profile/nino
    -- Save user's NINO (hashed with bcrypt, last 4 chars stored for display)
    -- Body: { "nino": "QQ123456C" }
    -- =========================================================================
    app:post("/api/v2/tax/profile/nino", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local nino = params.nino

        if not nino or nino == "" then
            return { status = 400, json = { error = "NINO is required" } }
        end

        local user_uuid = user.uuid or user.id
        local ok_save, result, err = pcall(TaxUserProfileQueries.saveNino, user_uuid, nino)

        if not ok_save then
            ngx.log(ngx.ERR, "[Tax Profile] saveNino error: ", tostring(result))
            return { status = 500, json = { error = "Failed to save NINO" } }
        end

        if not result then
            return { status = 400, json = { error = err or "Failed to save NINO" } }
        end

        ngx.log(ngx.NOTICE, "[Tax Profile] NINO saved for user=", user_uuid,
                " last4=", result.nino_last4)

        return {
            status = 200,
            json = {
                message = "NINO saved securely",
                nino_masked = "****" .. result.nino_last4,
                has_nino = true,
            }
        }
    end)

    -- =========================================================================
    -- POST /api/v2/tax/profile/nino/verify
    -- Verify user's NINO (e.g. before HMRC API calls)
    -- Body: { "nino": "QQ123456C" }
    -- Returns: { verified: true/false }
    -- =========================================================================
    app:post("/api/v2/tax/profile/nino/verify", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local nino = params.nino

        if not nino or nino == "" then
            return { status = 400, json = { error = "NINO is required" } }
        end

        local user_uuid = user.uuid or user.id
        local ok_verify, verified = pcall(TaxUserProfileQueries.verifyNino, user_uuid, nino)

        if not ok_verify then
            ngx.log(ngx.ERR, "[Tax Profile] verifyNino error: ", tostring(verified))
            return { status = 500, json = { error = "Failed to verify NINO" } }
        end

        return {
            status = 200,
            json = { verified = verified or false }
        }
    end)

    -- =========================================================================
    -- DELETE /api/v2/tax/profile/nino
    -- Remove stored NINO from profile
    -- =========================================================================
    app:delete("/api/v2/tax/profile/nino", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local ok_rm, rm_err = pcall(TaxUserProfileQueries.removeNino, user_uuid)
        if not ok_rm then
            ngx.log(ngx.ERR, "[Tax Profile] removeNino error: ", tostring(rm_err))
            return { status = 500, json = { error = "Failed to remove NINO" } }
        end

        return {
            status = 200,
            json = { message = "NINO removed", has_nino = false }
        }
    end)

    -- =========================================================================
    -- PUT /api/v2/tax/profile/preferences
    -- Update profile preferences (default_business_id, default_tax_year)
    -- Body: { "default_business_id": "...", "default_tax_year": "2024-25" }
    -- =========================================================================
    app:put("/api/v2/tax/profile/preferences", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local user_uuid = user.uuid or user.id

        -- Ensure profile exists
        local ok_gc, gc_err = pcall(TaxUserProfileQueries.getOrCreate, user_uuid)
        if not ok_gc then
            ngx.log(ngx.ERR, "[Tax Profile] getOrCreate failed in preferences: ", tostring(gc_err))
            return { status = 500, json = { error = "Failed to load profile" } }
        end

        if params.default_business_id then
            local ok_biz, biz_err = pcall(TaxUserProfileQueries.setDefaultBusiness, user_uuid, params.default_business_id)
            if not ok_biz then
                ngx.log(ngx.ERR, "[Tax Profile] setDefaultBusiness error: ", tostring(biz_err))
                return { status = 500, json = { error = "Failed to update default business" } }
            end
        end

        if params.default_tax_year then
            -- Validate format: YYYY-YY
            if not params.default_tax_year:match("^%d%d%d%d%-%d%d$") then
                return { status = 400, json = { error = "Invalid tax year format. Expected: YYYY-YY (e.g. 2024-25)" } }
            end
            local ok_ty, ty_err = pcall(TaxUserProfileQueries.setDefaultTaxYear, user_uuid, params.default_tax_year)
            if not ok_ty then
                ngx.log(ngx.ERR, "[Tax Profile] setDefaultTaxYear error: ", tostring(ty_err))
                return { status = 500, json = { error = "Failed to update default tax year" } }
            end
        end

        return {
            status = 200,
            json = { message = "Preferences updated" }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/profile/obligations
    -- Get cached HMRC obligations for the user
    -- Query params: ?tax_year=2024-25&business_id=...
    -- =========================================================================
    app:get("/api/v2/tax/profile/obligations", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local tax_year = self.params.tax_year
        local business_id = self.params.business_id

        local obligations
        local ob_ok, ob_result
        if tax_year and business_id then
            ob_ok, ob_result = pcall(HMRCObligationQueries.forTaxYear, user_uuid, business_id, tax_year)
        else
            ob_ok, ob_result = pcall(HMRCObligationQueries.allForUser, user_uuid)
        end
        if not ob_ok then
            ngx.log(ngx.ERR, "[Tax Profile] obligations query error: ", tostring(ob_result))
            return { status = 500, json = { error = "Failed to load obligations" } }
        end
        obligations = ob_result

        -- Clean up for API response
        local result = {}
        for _, ob in ipairs(obligations or {}) do
            table.insert(result, {
                uuid = ob.uuid,
                business_id = ob.business_id,
                tax_year = ob.tax_year,
                period_start = ob.period_start,
                period_end = ob.period_end,
                due_date = ob.due_date,
                status = ob.status,
                period_key = ob.period_key,
                fetched_at = ob.fetched_at,
            })
        end

        return {
            status = 200,
            json = { obligations = result, total = #result }
        }
    end)

end
