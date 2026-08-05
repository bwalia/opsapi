--[[
    Business Value Queries — business_line_values + business_line_categories
    + the Capital Allowances grid (business_ca_pools/rows/values).

    The self-employment trade form is FIXED-BOX (one value per admin-managed
    category per business per tax year), so writes are batch UPSERTS keyed on
    (user, business, tax_year, category) rather than free rows — clearing a
    box deletes its row so summaries never count stale zeros.

    Ownership: the route layer 404s unknown/foreign businesses via
    BusinessQueries.show first; every statement here still scopes to the
    authenticated user defensively. Category/pool/row keys are stored as
    plain varchar (no FK) so retiring a catalogue entry never breaks history.
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local BusinessValueQueries = {}

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

-- The business must exist, belong to this user, and not be archived.
-- Returns the row (for namespace_id) or nil.
local function owned_business(business_uuid, internal_user_id)
    local rows = db.query([[
        SELECT uuid, namespace_id FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = 'business' AND is_archived = false
        LIMIT 1
    ]], business_uuid, internal_user_id)
    return rows and rows[1] or nil
end

-- numeric(15,2)-safe parse: nil/"" → nil, otherwise a finite number within
-- column bounds. The bound is the column's actual max (9999999999999.99),
-- not 1e13 — doubles just below 1e13 would pass a 1e13 check but round to
-- 14 integer digits in Postgres and overflow. Sign rules are per-kind and
-- enforced by the callers.
local MAX_AMOUNT = 9999999999999.99
local function parse_amount(v)
    if v == nil or v == "" then return nil, true end
    local n = tonumber(v)
    if not n or n ~= n or n > MAX_AMOUNT or n < -MAX_AMOUNT then return nil, false end
    return n, true
end

-- Only balance-sheet and adjustment boxes may go negative; SA103F income,
-- allowance, expense and capital-allowance boxes are non-negative, and a
-- sign typo in turnover would otherwise flow silently into hub totals.
local function kind_allows_negative(kind)
    return kind == "balance_sheet" or kind == "adjustment"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Catalogue
-- ────────────────────────────────────────────────────────────────────────────
function BusinessValueQueries.categories()
    return db.query([[
        SELECT uuid, kind, category_key, label, description, hmrc_mapping,
               supports_disallowable, display_order
        FROM business_line_categories
        WHERE is_active = true
        ORDER BY kind ASC, display_order ASC, label ASC
    ]]) or {}
end

-- key → { kind, supports_disallowable } for active categories (validation).
function BusinessValueQueries.active_categories()
    local rows = db.query([[
        SELECT category_key, kind, supports_disallowable
        FROM business_line_categories WHERE is_active = true
    ]]) or {}
    local map = {}
    for _, r in ipairs(rows) do
        map[r.category_key] = { kind = r.kind, supports_disallowable = r.supports_disallowable }
    end
    return map
end

-- ────────────────────────────────────────────────────────────────────────────
-- Fixed-box values
-- ────────────────────────────────────────────────────────────────────────────
function BusinessValueQueries.values_for(business_uuid, tax_year, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT category_key, kind, amount, disallowable_amount, updated_at
        FROM business_line_values
        WHERE user_id = ? AND business_uuid = ? AND tax_year = ?
        ORDER BY category_key ASC
    ]], internal_user_id, business_uuid, tax_year) or {}
    return { data = rows, total = #rows }
end

-- Batch upsert. values = array of { category_key, amount?, disallowable_amount? }.
-- A value with BOTH amounts empty clears the box (row deleted). Unknown or
-- retired categories are reported per-entry, valid ones still save.
function BusinessValueQueries.upsert_values(business_uuid, tax_year, values, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local biz = owned_business(business_uuid, internal_user_id)
    if not biz then return nil, "Business not found" end

    local catalogue = BusinessValueQueries.active_categories()
    local saved, deleted = 0, 0
    local errors = {}

    for i, v in ipairs(values) do
        local key = v and v.category_key
        local cat = key and catalogue[key] or nil
        local amount, ok_a = parse_amount(v and v.amount)
        local disallowable, ok_d = parse_amount(v and v.disallowable_amount)
        -- Clearing is allowed even for retired categories — otherwise a
        -- value whose category an admin deactivates becomes permanently
        -- stuck (no box renders it, and re-saving its key is rejected).
        if key and amount == nil and disallowable == nil and ok_a and ok_d then
            local res = db.query([[
                DELETE FROM business_line_values
                WHERE user_id = ? AND business_uuid = ? AND tax_year = ? AND category_key = ?
            ]], internal_user_id, business_uuid, tax_year, key)
            deleted = deleted + ((res and res.affected_rows) or 0)
        elseif not cat then
            table.insert(errors, { index = i, error = "Unknown or inactive category: " .. tostring(key) })
        else
            if not ok_a or not ok_d then
                table.insert(errors, { index = i, error = "Amount for " .. key .. " must be a number within range" })
            elseif disallowable ~= nil and not cat.supports_disallowable then
                table.insert(errors, { index = i, error = key .. " does not take a disallowable amount" })
            elseif not kind_allows_negative(cat.kind)
                and ((amount and amount < 0) or (disallowable and disallowable < 0)) then
                table.insert(errors, { index = i, error = key .. " cannot be negative" })
            else
                db.query([[
                    INSERT INTO business_line_values
                        (uuid, user_id, namespace_id, business_uuid, tax_year, kind, category_key, amount, disallowable_amount, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                    ON CONFLICT (user_id, business_uuid, tax_year, category_key)
                    DO UPDATE SET amount = EXCLUDED.amount,
                                  disallowable_amount = EXCLUDED.disallowable_amount,
                                  kind = EXCLUDED.kind,
                                  updated_at = NOW()
                ]],
                    Global.generateUUID(),
                    internal_user_id,
                    biz.namespace_id or db.NULL,
                    business_uuid,
                    tax_year,
                    cat.kind,
                    key,
                    amount ~= nil and amount or db.NULL,
                    disallowable ~= nil and disallowable or db.NULL
                )
                saved = saved + 1
            end
        end
    end

    -- One audit row per batch — per-box rows would flood the log on autosave.
    if saved > 0 or deleted > 0 then
        TaxAuditLogQueries.log({
            user_id = internal_user_id,
            user_email = user.email,
            entity_type = "BUSINESS_VALUES",
            entity_id = business_uuid,
            action = "UPDATE",
            new_values = cjson.encode({ tax_year = tax_year, saved = saved, deleted = deleted }),
        })
    end

    local refreshed = BusinessValueQueries.values_for(business_uuid, tax_year, user)
    return { saved = saved, deleted = deleted, errors = errors, data = refreshed and refreshed.data or {} }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Capital Allowances grid
-- ────────────────────────────────────────────────────────────────────────────
function BusinessValueQueries.ca_catalogue()
    local pools = db.query([[
        SELECT uuid, pool_key, label, display_order FROM business_ca_pools
        WHERE is_active = true ORDER BY display_order ASC, label ASC
    ]]) or {}
    local rows = db.query([[
        SELECT uuid, row_key, label, display_order FROM business_ca_rows
        WHERE is_active = true ORDER BY display_order ASC, label ASC
    ]]) or {}
    return { pools = pools, rows = rows }
end

function BusinessValueQueries.ca_values_for(business_uuid, tax_year, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT pool_key, row_key, amount, updated_at
        FROM business_ca_values
        WHERE user_id = ? AND business_uuid = ? AND tax_year = ?
    ]], internal_user_id, business_uuid, tax_year) or {}
    return { data = rows, total = #rows }
end

-- Save one pool's column of the grid (the per-pool Edit dialog).
-- cells = array of { row_key, amount? } — empty amount clears the cell.
function BusinessValueQueries.upsert_ca(business_uuid, tax_year, pool_key, cells, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local biz = owned_business(business_uuid, internal_user_id)
    if not biz then return nil, "Business not found" end

    local pool = db.query(
        "SELECT pool_key FROM business_ca_pools WHERE pool_key = ? AND is_active = true LIMIT 1",
        pool_key)
    if not pool or #pool == 0 then return nil, "Unknown or inactive pool: " .. tostring(pool_key) end

    local active_rows = {}
    for _, r in ipairs(db.query("SELECT row_key FROM business_ca_rows WHERE is_active = true") or {}) do
        active_rows[r.row_key] = true
    end

    local saved, deleted = 0, 0
    local errors = {}
    for i, c in ipairs(cells) do
        local row_key = c and c.row_key
        if not row_key or not active_rows[row_key] then
            table.insert(errors, { index = i, error = "Unknown or inactive row: " .. tostring(row_key) })
        else
            local amount, ok = parse_amount(c.amount)
            if not ok then
                table.insert(errors, { index = i, error = "Amount for " .. row_key .. " must be a number" })
            elseif amount == nil then
                local res = db.query([[
                    DELETE FROM business_ca_values
                    WHERE user_id = ? AND business_uuid = ? AND tax_year = ? AND pool_key = ? AND row_key = ?
                ]], internal_user_id, business_uuid, tax_year, pool_key, row_key)
                deleted = deleted + ((res and res.affected_rows) or 0)
            else
                db.query([[
                    INSERT INTO business_ca_values
                        (uuid, user_id, namespace_id, business_uuid, tax_year, pool_key, row_key, amount, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                    ON CONFLICT (user_id, business_uuid, tax_year, pool_key, row_key)
                    DO UPDATE SET amount = EXCLUDED.amount, updated_at = NOW()
                ]],
                    Global.generateUUID(),
                    internal_user_id,
                    biz.namespace_id or db.NULL,
                    business_uuid,
                    tax_year,
                    pool_key,
                    row_key,
                    amount
                )
                saved = saved + 1
            end
        end
    end

    if saved > 0 or deleted > 0 then
        TaxAuditLogQueries.log({
            user_id = internal_user_id,
            user_email = user.email,
            entity_type = "BUSINESS_CA",
            entity_id = business_uuid,
            action = "UPDATE",
            new_values = cjson.encode({ tax_year = tax_year, pool_key = pool_key, saved = saved, deleted = deleted }),
        })
    end

    local refreshed = BusinessValueQueries.ca_values_for(business_uuid, tax_year, user)
    return { saved = saved, deleted = deleted, errors = errors, data = refreshed and refreshed.data or {} }
end

return BusinessValueQueries
