--[[
    Academy Admin Routes (platform super-admin only)
    ================================================
    Requires the platform "administrative" role.

      GET  /api/v2/academy/admin/settings                       -> default cut %
      PUT  /api/v2/academy/admin/settings                       -> set default cut %
      PUT  /api/v2/academy/admin/creators/:namespace_id/fee     -> per-creator override
      GET  /api/v2/academy/admin/payouts                        -> owed per creator (+ bank)
      POST /api/v2/academy/admin/payouts/:namespace_id/mark-paid -> record manual payout
]]

local cJson = require("cjson")
local CreatorQueries = require("queries.CreatorQueries")
local PayoutQueries = require("queries.PayoutQueries")
local AuthMiddleware = require("middleware.auth")

return function(app)
    local function parse_body()
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then return post_args end
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, decoded = pcall(cJson.decode, body)
        if ok and type(decoded) == "table" then return decoded end
        local args = ngx.decode_args(body)
        return type(args) == "table" and args or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    -- Global default cut %
    app:get("/api/v2/academy/admin/settings", AuthMiddleware.requireRole("administrative", function()
        return { status = 200, json = { default_fee_pct = CreatorQueries.getDefaultFeePct() } }
    end))

    app:put("/api/v2/academy/admin/settings", AuthMiddleware.requireRole("administrative", function(self)
        local body = parse_body()
        local pct = tonumber(body.default_fee_pct)
        if not pct or pct < 0 or pct > 100 then
            return api_response(400, nil, "default_fee_pct must be 0-100")
        end
        CreatorQueries.setDefaultFeePct(pct)
        return { status = 200, json = { default_fee_pct = pct } }
    end))

    -- Per-creator fee override (empty/null clears it -> falls back to default)
    app:put("/api/v2/academy/admin/creators/:namespace_id/fee", AuthMiddleware.requireRole("administrative", function(self)
        local ns_id = tonumber(self.params.namespace_id)
        if not ns_id then return api_response(400, nil, "Invalid namespace id") end
        local body = parse_body()
        local raw = body.fee_pct
        if raw == nil or raw == "" or raw == cJson.null then
            CreatorQueries.setFeeOverride(ns_id, nil)
            return { status = 200, json = { fee_pct_override = nil } }
        end
        local pct = tonumber(raw)
        if not pct or pct < 0 or pct > 100 then
            return api_response(400, nil, "fee_pct must be 0-100")
        end
        CreatorQueries.setFeeOverride(ns_id, pct)
        return { status = 200, json = { fee_pct_override = pct } }
    end))

    -- Owed balance per creator, with bank details for the transfer
    app:get("/api/v2/academy/admin/payouts", AuthMiddleware.requireRole("administrative", function()
        local rows = PayoutQueries.owedByCreator()
        for _, r in ipairs(rows) do
            local acc = CreatorQueries.getAccount(r.namespace_id)
            r.bank = acc and {
                account_holder_name = acc.account_holder_name,
                bank_name = acc.bank_name,
                account_number = acc.account_number,
                sort_code = acc.sort_code,
                routing_number = acc.routing_number,
                iban = acc.iban,
                swift_bic = acc.swift_bic,
                bank_country = acc.bank_country,
                payout_email = acc.payout_email,
                complete = acc.bank_details_complete or false,
            } or nil
        end
        return { status = 200, json = { payouts = rows } }
    end))

    -- Record a manual payout (marks the creator's owed earnings paid)
    app:post("/api/v2/academy/admin/payouts/:namespace_id/mark-paid", AuthMiddleware.requireRole("administrative", function(self)
        local ns_id = tonumber(self.params.namespace_id)
        if not ns_id then return api_response(400, nil, "Invalid namespace id") end
        local body = parse_body()
        local payout, err = PayoutQueries.markPaid(ns_id, body.reference, self.current_user and self.current_user.uuid)
        if not payout then return api_response(400, nil, err or "Nothing to pay out") end
        return { status = 200, json = { paid = true, amount = payout.amount, currency = payout.currency } }
    end))
end
