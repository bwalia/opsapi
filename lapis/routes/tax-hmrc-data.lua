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
    app:post("/api/v2/hmrc/businesses/fetch",
        AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id

            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            if not ok_hmrc then
                return { status = 500, json = { error = "HMRC module not available" } }
            end

            local access_token, token_err = HMRC.get_valid_token(user_uuid)
            if not access_token then
                return { status = 401, json = { error = token_err } }
            end

            local data, err = HMRC.fetch_businesses(access_token)
            if not data then
                return { status = 422, json = { error = err } }
            end

            -- Cache businesses
            local businesses = data.businessDetails or data.selfEmployment or {}
            for _, biz in ipairs(businesses) do
                db.query([[
                    INSERT INTO hmrc_businesses (user_uuid, business_id, type_of_business, trading_name, raw_response, fetched_at)
                    VALUES (?, ?, ?, ?, ?, NOW())
                    ON CONFLICT (user_uuid, business_id) DO UPDATE SET
                        type_of_business = EXCLUDED.type_of_business,
                        trading_name = EXCLUDED.trading_name,
                        raw_response = EXCLUDED.raw_response,
                        fetched_at = NOW()
                ]], user_uuid, biz.businessId or biz.id, biz.typeOfBusiness or "",
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
    app:post("/api/v2/hmrc/obligations/fetch",
        AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid or self.current_user.id
            local business_id = self.params.business_id
            local from_date = self.params.from_date or os.date("%Y") .. "-04-06"
            local to_date = self.params.to_date or (tonumber(os.date("%Y")) + 1) .. "-04-05"

            if not business_id then
                return { status = 400, json = { error = "business_id is required" } }
            end

            local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
            if not ok_hmrc then
                return { status = 500, json = { error = "HMRC module not available" } }
            end

            local access_token, token_err = HMRC.get_valid_token(user_uuid)
            if not access_token then
                return { status = 401, json = { error = token_err } }
            end

            local data, err = HMRC.fetch_obligations(access_token, business_id, from_date, to_date)
            if not data then
                return { status = 422, json = { error = err } }
            end

            -- Cache obligations
            local obligations = data.obligations or {}
            for _, ob in ipairs(obligations) do
                for _, period in ipairs(ob.obligationDetails or {}) do
                    db.query([[
                        INSERT INTO hmrc_obligations (user_uuid, business_id, period_start, period_end, due_date, status, period_key, tax_year, fetched_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW())
                        ON CONFLICT ON CONSTRAINT hmrc_obligations_user_uuid_business_id_period_start_period_end_key
                        DO UPDATE SET
                            status = EXCLUDED.status,
                            due_date = EXCLUDED.due_date,
                            fetched_at = NOW()
                    ]], user_uuid, business_id,
                        period.periodStartDate, period.periodEndDate,
                        period.dueDate, period.status or "Open",
                        period.periodKey or "", "")
                end
            end

            return { status = 200, json = { data = obligations } }
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

            return { status = 201, json = { data = data } }
        end)
    )
end
