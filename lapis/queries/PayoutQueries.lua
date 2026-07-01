--[[
    Payout / Ledger Queries  (per-instructor marketplace)
    =====================================================
    academy_payments is the earnings ledger. Each successful sale records
    gross / platform_cut / creator_net using the SELLER's effective fee %, with
    payout_status 'owed'. The seller is the course owner (an instructor); sales
    with no seller (e.g. an academy-wide community subscription) are platform
    revenue (creator_net = 0). The super admin pays each instructor manually and
    marks their owed balance paid, which records a creator_payouts row and flips
    that instructor's ledger rows to 'paid'.
]]

local Global = require "helper.global"
local db = require("lapis.db")
local CreatorQueries = require "queries.CreatorQueries"
local AcademyPaymentModel = require "models.AcademyPaymentModel"

local PayoutQueries = {}

--- Record a successful sale in the ledger (computes cut + net from the fee).
--- p: { user_uuid (buyer), namespace_id, seller_user_uuid?, course_id?, kind,
---      stripe_ref, amount, currency }
--- When seller_user_uuid is present the instructor earns net at their effective
--- fee; otherwise the platform keeps the whole amount (net = 0).
function PayoutQueries.recordSale(p)
    local gross = math.floor(tonumber(p.amount) or 0)
    local seller = p.seller_user_uuid
    local fee_pct, cut, net
    if seller and seller ~= "" then
        fee_pct = CreatorQueries.effectiveFeePct(seller)
        cut = math.floor(gross * fee_pct / 100)
        net = gross - cut
    else
        -- Platform-owned revenue (no single instructor): platform keeps all.
        fee_pct = 100
        cut = gross
        net = 0
    end
    local row = {
        uuid = Global.generateUUID(),
        user_uuid = p.user_uuid,
        namespace_id = p.namespace_id,
        seller_user_uuid = seller,
        kind = p.kind,
        stripe_ref = p.stripe_ref,
        amount = gross,
        platform_cut = cut,
        creator_net = net,
        fee_pct = fee_pct,
        currency = p.currency or "usd",
        status = "succeeded",
        payout_status = "owed",
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }
    -- course_id / seller_user_uuid are NULL for platform subscriptions; omit so
    -- the model writes NULL rather than the string "nil".
    if p.course_id then row.course_id = p.course_id end
    if not (seller and seller ~= "") then row.seller_user_uuid = nil end
    AcademyPaymentModel:create(row, { returning = "*" })
end

--- Owed balance per instructor (for the super-admin payouts list).
function PayoutQueries.owedByInstructor()
    return db.query([[
        SELECT p.seller_user_uuid AS user_uuid,
               COALESCE(NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), ''), u.username, u.email) AS instructor_name,
               u.email AS instructor_email,
               COALESCE(SUM(p.creator_net), 0) AS owed,
               COALESCE(MAX(p.currency), 'usd') AS currency,
               COUNT(p.id) AS sales
        FROM academy_payments p
        JOIN users u ON u.uuid = p.seller_user_uuid
        WHERE p.payout_status = 'owed' AND p.status = 'succeeded'
          AND p.seller_user_uuid IS NOT NULL
        GROUP BY p.seller_user_uuid, u.first_name, u.last_name, u.username, u.email
        HAVING SUM(p.creator_net) > 0
        ORDER BY owed DESC
    ]]) or {}
end

function PayoutQueries.owedForInstructor(user_uuid)
    local rows = db.query([[
        SELECT COALESCE(SUM(creator_net), 0) AS owed, COALESCE(MAX(currency), 'usd') AS currency
        FROM academy_payments
        WHERE seller_user_uuid = ? AND payout_status = 'owed' AND status = 'succeeded'
    ]], user_uuid)
    return rows and rows[1] or { owed = 0, currency = "usd" }
end

--- Mark an instructor's owed earnings as paid: record a payout + flip the rows.
function PayoutQueries.markPaid(user_uuid, reference, paid_by_uuid)
    local owed = PayoutQueries.owedForInstructor(user_uuid)
    local amount = math.floor(tonumber(owed.owed) or 0)
    if amount <= 0 then return nil, "Nothing owed" end
    local payout = db.query([[
        INSERT INTO creator_payouts (uuid, user_uuid, amount, currency, status, reference, paid_by_uuid, paid_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'paid', ?, ?, NOW(), NOW(), NOW()) RETURNING *
    ]], Global.generateUUID(), user_uuid, amount, owed.currency, reference, paid_by_uuid)
    local payout_id = payout and payout[1] and payout[1].id
    db.query([[
        UPDATE academy_payments SET payout_status = 'paid', payout_id = ?, updated_at = NOW()
        WHERE seller_user_uuid = ? AND payout_status = 'owed' AND status = 'succeeded'
    ]], payout_id, user_uuid)
    return payout and payout[1] or nil
end

--- An instructor's own earnings summary (for their dashboard).
function PayoutQueries.earningsForInstructor(user_uuid)
    local rows = db.query([[
        SELECT
            COALESCE(SUM(creator_net), 0) AS total_net,
            COALESCE(SUM(CASE WHEN payout_status = 'owed' THEN creator_net ELSE 0 END), 0) AS owed,
            COALESCE(SUM(CASE WHEN payout_status = 'paid' THEN creator_net ELSE 0 END), 0) AS paid,
            COALESCE(MAX(currency), 'usd') AS currency,
            COUNT(*) AS sales
        FROM academy_payments WHERE seller_user_uuid = ? AND status = 'succeeded'
    ]], user_uuid)
    return rows and rows[1] or { total_net = 0, owed = 0, paid = 0, currency = "usd", sales = 0 }
end

return PayoutQueries
