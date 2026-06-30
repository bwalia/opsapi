--[[
    Payout / Ledger Queries
    =======================
    The academy_payments table is the earnings ledger. Each successful sale
    records gross / platform_cut / creator_net using the creator's effective fee
    %, with payout_status 'owed'. The super admin pays creators manually (bank
    transfer) and marks the owed balance paid, which records a creator_payouts
    row and flips the ledger rows to 'paid'.
]]

local Global = require "helper.global"
local db = require("lapis.db")
local CreatorQueries = require "queries.CreatorQueries"
local AcademyPaymentModel = require "models.AcademyPaymentModel"

local PayoutQueries = {}

--- Record a successful sale in the ledger (computes cut + net from the fee).
--- p: { user_uuid, namespace_id, course_id?, kind, stripe_ref, amount, currency }
function PayoutQueries.recordSale(p)
    local fee_pct = CreatorQueries.effectiveFeePct(p.namespace_id)
    local gross = math.floor(tonumber(p.amount) or 0)
    local cut = math.floor(gross * fee_pct / 100)
    local net = gross - cut
    local row = {
        uuid = Global.generateUUID(),
        user_uuid = p.user_uuid,
        namespace_id = p.namespace_id,
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
    -- course_id is NULL for subscription sales; omit so the model writes NULL.
    if p.course_id then row.course_id = p.course_id end
    AcademyPaymentModel:create(row, { returning = "*" })
end

--- Owed balance per creator (for the super-admin payouts list).
function PayoutQueries.owedByCreator()
    return db.query([[
        SELECT n.id AS namespace_id, n.name AS namespace_name, n.slug AS namespace_slug,
               COALESCE(SUM(p.creator_net), 0) AS owed,
               COALESCE(MAX(p.currency), 'usd') AS currency,
               COUNT(p.id) AS sales
        FROM academy_payments p JOIN namespaces n ON n.id = p.namespace_id
        WHERE p.payout_status = 'owed' AND p.status = 'succeeded'
        GROUP BY n.id, n.name, n.slug
        HAVING SUM(p.creator_net) > 0
        ORDER BY owed DESC
    ]]) or {}
end

function PayoutQueries.owedForCreator(namespace_id)
    local rows = db.query([[
        SELECT COALESCE(SUM(creator_net), 0) AS owed, COALESCE(MAX(currency), 'usd') AS currency
        FROM academy_payments WHERE namespace_id = ? AND payout_status = 'owed' AND status = 'succeeded'
    ]], namespace_id)
    return rows and rows[1] or { owed = 0, currency = "usd" }
end

--- Mark a creator's owed earnings as paid: record a payout + flip the rows.
function PayoutQueries.markPaid(namespace_id, reference, paid_by_uuid)
    local owed = PayoutQueries.owedForCreator(namespace_id)
    local amount = math.floor(tonumber(owed.owed) or 0)
    if amount <= 0 then return nil, "Nothing owed" end
    local payout = db.query([[
        INSERT INTO creator_payouts (uuid, namespace_id, amount, currency, status, reference, paid_by_uuid, paid_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'paid', ?, ?, NOW(), NOW(), NOW()) RETURNING *
    ]], Global.generateUUID(), namespace_id, amount, owed.currency, reference, paid_by_uuid)
    local payout_id = payout and payout[1] and payout[1].id
    db.query([[
        UPDATE academy_payments SET payout_status = 'paid', payout_id = ?, updated_at = NOW()
        WHERE namespace_id = ? AND payout_status = 'owed' AND status = 'succeeded'
    ]], payout_id, namespace_id)
    return payout and payout[1] or nil
end

--- A creator's own earnings summary (for their dashboard).
function PayoutQueries.earningsForCreator(namespace_id)
    local rows = db.query([[
        SELECT
            COALESCE(SUM(creator_net), 0) AS total_net,
            COALESCE(SUM(CASE WHEN payout_status = 'owed' THEN creator_net ELSE 0 END), 0) AS owed,
            COALESCE(SUM(CASE WHEN payout_status = 'paid' THEN creator_net ELSE 0 END), 0) AS paid,
            COALESCE(MAX(currency), 'usd') AS currency,
            COUNT(*) AS sales
        FROM academy_payments WHERE namespace_id = ? AND status = 'succeeded'
    ]], namespace_id)
    return rows and rows[1] or { total_net = 0, owed = 0, paid = 0, currency = "usd", sales = 0 }
end

return PayoutQueries
