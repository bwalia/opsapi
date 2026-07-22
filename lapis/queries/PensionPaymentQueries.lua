--[[
    Pension Payment Queries — pension_payment_items + pension_payment_categories.

    Payment rows are the user's "Relief: Pension payments" entries (provider +
    description, amount, relief-at-source / one-off flags), grouped by an
    admin-managed section catalogue and scoped per tax year. No parent entity —
    unlike property/business lines these hang straight off the user.

    Ownership: every row is scoped to the authenticated user. Category keys
    are stored as plain varchar (no FK) so retiring a section never breaks
    history; updates grandfather an unchanged key the same way property lines
    grandfather a retired category. Totals only count ACTIVE sections (a
    deactivated section's rows stay listed and deletable but drop out of the
    summary), matching the business-values convention.
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local PensionPaymentQueries = {}

-- numeric(15,2) tops out at 9,999,999,999,999.99 — reject beyond-range
-- amounts up front instead of surfacing a numeric-overflow 500.
local MAX_AMOUNT = 9999999999999.99
PensionPaymentQueries.MAX_AMOUNT = MAX_AMOUNT

local function resolveUserId(user)
    if not user then return nil, "User not authenticated" end
    local user_uuid = user.uuid or user.id
    local rows
    if user.uuid then
        rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        rows = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not rows or #rows == 0 then return nil, "User not found" end
    return rows[1].id
end

local function present(row)
    row.id = row.uuid
    row.user_id = nil
    return row
end

-- ────────────────────────────────────────────────────────────────────────────
-- Catalogue
-- ────────────────────────────────────────────────────────────────────────────
function PensionPaymentQueries.categories()
    local rows = db.query([[
        SELECT uuid, category_key, label, description, hmrc_mapping,
               supports_relief_flag, supports_one_off_flag, display_order
        FROM pension_payment_categories
        WHERE is_active = true
        ORDER BY display_order ASC, label ASC
    ]]) or {}
    return rows
end

-- key → catalogue row for active sections — validation helper for routes
-- (both existence and which flags the section supports).
function PensionPaymentQueries.active_categories()
    local map = {}
    for _, r in ipairs(PensionPaymentQueries.categories()) do
        map[r.category_key] = r
    end
    return map
end

-- ────────────────────────────────────────────────────────────────────────────
-- List
-- ────────────────────────────────────────────────────────────────────────────
-- params: { tax_year?, category_key?, include_archived? }
function PensionPaymentQueries.all(params, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local where = { "user_id = ?" }
    local args = { internal_user_id }
    -- type() guards: a repeated query-string key arrives as a Lua table,
    -- which passes `~= ""` and would blow up in SQL interpolation.
    if type(params.tax_year) == "string" and params.tax_year ~= "" then
        table.insert(where, "tax_year = ?"); table.insert(args, params.tax_year)
    end
    if type(params.category_key) == "string" and params.category_key ~= "" then
        table.insert(where, "category_key = ?"); table.insert(args, params.category_key)
    end
    if params.include_archived ~= "true" and params.include_archived ~= true then
        table.insert(where, "is_archived = false")
    end

    local rows = db.query(
        "SELECT * FROM pension_payment_items WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY created_at ASC",
        unpack(args)) or {}
    for _, r in ipairs(rows) do present(r) end
    return { data = rows, total = #rows }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Create — route layer validates category/amount/tax_year/flags; the amount
-- and category checks are re-run defensively here.
-- ────────────────────────────────────────────────────────────────────────────
function PensionPaymentQueries.create(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local n = tonumber(data.amount)
    if not n or n ~= n or n <= 0 or n > MAX_AMOUNT then
        return nil, "amount must be a positive number"
    end
    if not data.category_key or data.category_key == "" then
        return nil, "category_key is required"
    end
    if not data.tax_year or data.tax_year == "" then
        return nil, "tax_year is required"
    end

    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO pension_payment_items
            (uuid, user_id, namespace_id, tax_year, category_key, description,
             amount, relief_at_source, one_off, is_archived, created_at, updated_at)
        VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, false, NOW(), NOW())
    ]],
        uuid,
        internal_user_id,
        data.tax_year,
        data.category_key,
        (data.description and data.description ~= "") and data.description or db.NULL,
        n,
        data.relief_at_source == true,
        data.one_off == true
    )
    local row = db.query("SELECT * FROM pension_payment_items WHERE uuid = ? LIMIT 1", uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PENSION_PAYMENT",
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present(row)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Show / Update / Archive — addressed by row uuid, always ownership-scoped.
-- ────────────────────────────────────────────────────────────────────────────
-- Archived rows are readable history via all(include_archived=true) but are
-- immutable: show/update/archive all 404 on them (same convention Business
-- entities adopted), so a stale tab can't edit or double-archive a row and
-- scramble the audit trail.
function PensionPaymentQueries.show(item_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT * FROM pension_payment_items
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], item_uuid, internal_user_id)
    if not rows or #rows == 0 then return nil end
    return present(rows[1])
end

function PensionPaymentQueries.update(item_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM pension_payment_items
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], item_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    local updates, args = {}, {}
    if data.amount ~= nil then
        local n = tonumber(data.amount)
        if not n or n ~= n or n <= 0 or n > MAX_AMOUNT then
            return nil, "amount must be a positive number"
        end
        table.insert(updates, "amount = ?"); table.insert(args, n)
    end
    if data.category_key then
        table.insert(updates, "category_key = ?"); table.insert(args, data.category_key)
    end
    if data.tax_year then
        table.insert(updates, "tax_year = ?"); table.insert(args, data.tax_year)
    end
    if data.description ~= nil then
        -- "" clears the description (stored as NULL, matching create) —
        -- JSON null can't express "clear" because body parsing strips
        -- cjson.null before it reaches the SQL layer.
        table.insert(updates, "description = ?")
        table.insert(args, data.description ~= "" and data.description or db.NULL)
    end
    if data.relief_at_source ~= nil then
        table.insert(updates, "relief_at_source = ?")
        table.insert(args, data.relief_at_source == true)
    end
    if data.one_off ~= nil then
        table.insert(updates, "one_off = ?")
        table.insert(args, data.one_off == true)
    end
    if #updates == 0 then return present(old) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, item_uuid)
    table.insert(args, internal_user_id)
    db.query("UPDATE pension_payment_items SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM pension_payment_items WHERE uuid = ? LIMIT 1", item_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PENSION_PAYMENT",
        entity_id = item_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present(refreshed)
end

function PensionPaymentQueries.archive(item_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM pension_payment_items
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], item_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE pension_payment_items
           SET is_archived = true, archived_at = NOW(), archived_by = ?, updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], internal_user_id, item_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PENSION_PAYMENT",
        entity_id = item_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- Summary — per-section totals for the hub, derived and read-only. Only
-- ACTIVE sections count (same convention as business totals); rows in a
-- retired section stay listed via all() but drop out of these numbers.
-- ────────────────────────────────────────────────────────────────────────────
function PensionPaymentQueries.summary(tax_year, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local totals = db.query([[
        SELECT category_key,
               COALESCE(SUM(amount), 0) AS total,
               COUNT(*)                 AS row_count
        FROM pension_payment_items
        WHERE user_id = ? AND tax_year = ? AND is_archived = false
        GROUP BY category_key
    ]], internal_user_id, tax_year) or {}
    local by_key = {}
    for _, t in ipairs(totals) do by_key[t.category_key] = t end

    local sections = {}
    local grand_total = 0
    for _, c in ipairs(PensionPaymentQueries.categories()) do
        local t = by_key[c.category_key]
        local total = t and tonumber(t.total) or 0
        sections[#sections + 1] = {
            key = c.category_key,
            label = c.label,
            total = total,
            row_count = t and tonumber(t.row_count) or 0,
        }
        grand_total = grand_total + total
    end

    return {
        tax_year = tax_year,
        total = grand_total,
        sections = sections,
    }
end

return PensionPaymentQueries
