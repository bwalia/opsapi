-- luacheck: max line length 140
--[[
    Payment methods ("Getting paid"), namespace level
    ==================================================
    Storage for namespace_payment_methods (migrations/payment-methods.lua). Rules (validation, document
    order, public fields) live in lib/payment-methods.lua so they can be specced without a database.

      PaymentMethodQueries.list(ns_id, { include_inactive? })  -> rows (admin shape)
      PaymentMethodQueries.create(ns_id, body, actor)          -> row | nil, message
      PaymentMethodQueries.update(ns_id, uuid, body)           -> row | nil, message
      PaymentMethodQueries.remove(ns_id, uuid)                 -> { deleted | deactivated } | nil, message
      PaymentMethodQueries.forDocuments(ns_id)                 -> public shapes, default first ([] when none / no table)
      PaymentMethodQueries.resolve(ns_id, uuid?)               -> one public shape for an invoice (uuid, else default)
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")
local PM = require("lib.payment-methods")

local Q = {}

local COLS = [[id, uuid, namespace_id, kind, label, account_name, bank_name, sort_code, account_number, iban, swift_bic,
    currency, instructions, is_default, show_on_documents, is_active, sort_order, created_at, updated_at]]

local function nn(v)
    if v == nil then return cjson.null end
    return v
end

--- Admin JSON shape (the contract's PaymentMethod).
function Q.shape(r)
    return {
        uuid = r.uuid, kind = r.kind, label = r.label, account_name = nn(r.account_name), bank_name = nn(r.bank_name),
        sort_code = nn(r.sort_code), account_number = nn(r.account_number), iban = nn(r.iban),
        swift_bic = nn(r.swift_bic), currency = r.currency, instructions = nn(r.instructions),
        is_default = r.is_default == true, show_on_documents = r.show_on_documents ~= false,
        is_active = r.is_active ~= false, sort_order = tonumber(r.sort_order) or 0,
        created_at = r.created_at, updated_at = r.updated_at,
    }
end

local function rows_for(ns_id, include_inactive)
    local sql = "SELECT " .. COLS .. " FROM namespace_payment_methods WHERE namespace_id = ?"
    if not include_inactive then sql = sql .. " AND is_active" end
    return db.query(sql .. " ORDER BY is_default DESC, sort_order, id", ns_id)
end

function Q.list(ns_id, opts)
    local out = {}
    for _, r in ipairs(rows_for(ns_id, opts and opts.include_inactive)) do out[#out + 1] = Q.shape(r) end
    return out
end

local function get_row(ns_id, uuid)
    if type(uuid) ~= "string" or uuid == "" then return nil end
    return db.query("SELECT " .. COLS .. " FROM namespace_payment_methods WHERE namespace_id = ? AND uuid = ?",
        ns_id, uuid)[1]
end
Q.getRow = get_row

local function null_or(v) if v == nil then return db.NULL end return v end

local function write(ns_id, f, id)
    local values = {
        kind = f.kind, label = f.label, account_name = null_or(f.account_name), bank_name = null_or(f.bank_name),
        sort_code = null_or(f.sort_code), account_number = null_or(f.account_number), iban = null_or(f.iban),
        swift_bic = null_or(f.swift_bic), currency = f.currency, instructions = null_or(f.instructions),
        is_default = f.is_default, show_on_documents = f.show_on_documents, is_active = f.is_active,
        sort_order = f.sort_order, updated_at = db.raw("NOW()"),
    }
    db.query("BEGIN")
    local ok, err = pcall(function()
        if f.is_default then
            -- One default per namespace (also a partial unique index).
            db.query("UPDATE namespace_payment_methods SET is_default = false, updated_at = NOW() WHERE namespace_id = ?"
                .. " AND is_default AND id <> ?", ns_id, id or 0)
        end
        if id then
            db.update("namespace_payment_methods", values, { id = id })
        else
            values.uuid = Global.generateUUID()
            values.namespace_id = ns_id
            values.created_by = f.created_by and f.created_by or db.NULL
            values.created_at = db.raw("NOW()")
            local r = db.insert("namespace_payment_methods", values, "id")
            id = r and r[1] and r[1].id or (r and r.id)
        end
        -- The first active method becomes the default, so documents always have one.
        if f.is_active then
            db.query([[UPDATE namespace_payment_methods SET is_default = true WHERE id = ? AND NOT EXISTS (
                         SELECT 1 FROM namespace_payment_methods WHERE namespace_id = ? AND is_default)]], id, ns_id)
        end
    end)
    if not ok then
        pcall(db.query, "ROLLBACK")
        ngx.log(ngx.ERR, "[payment-methods] save failed: ", tostring(err))
        return nil, "Could not save the payment method"
    end
    db.query("COMMIT")
    return Q.shape(db.query("SELECT " .. COLS .. " FROM namespace_payment_methods WHERE id = ?", id)[1])
end

function Q.create(ns_id, body, actor)
    local f, err = PM.clean(body)
    if not f then return nil, err end
    f.created_by = actor
    return write(ns_id, f)
end

function Q.update(ns_id, uuid, body)
    local row = get_row(ns_id, uuid)
    if not row then return nil, "Payment method not found" end
    local f, err = PM.clean(body, row)
    if not f then return nil, err end
    return write(ns_id, f, row.id)
end

--- Referenced by an invoice → deactivated (kept for that invoice's history); otherwise deleted.
function Q.remove(ns_id, uuid)
    local row = get_row(ns_id, uuid)
    if not row then return nil, "Payment method not found" end
    local ok, used = pcall(db.query, "SELECT 1 FROM invoices WHERE namespace_id = ? AND payment_method_uuid = ? LIMIT 1",
        ns_id, uuid)
    local referenced = ok and used and #used > 0
    if referenced then
        db.query([[UPDATE namespace_payment_methods SET is_active = false, is_default = false, updated_at = NOW()
                    WHERE id = ?]], row.id)
    else
        db.query("DELETE FROM namespace_payment_methods WHERE id = ?", row.id)
    end
    if row.is_default then
        -- Hand the default to the next active method.
        db.query([[UPDATE namespace_payment_methods SET is_default = true, updated_at = NOW() WHERE id = (
                     SELECT id FROM namespace_payment_methods WHERE namespace_id = ? AND is_active
                      ORDER BY (kind = 'bank_transfer') DESC, sort_order, id LIMIT 1)]], ns_id)
    end
    return referenced and { deactivated = true, uuid = uuid } or { deleted = true, uuid = uuid }
end

--- What customers see on documents: active + show_on_documents, default first. Never fails (a workspace
-- without the table yet, or a DB hiccup, just shows no "How to pay" block).
function Q.forDocuments(ns_id)
    local ok, rows = pcall(rows_for, ns_id, false)
    if not ok then return setmetatable({}, cjson.array_mt) end
    local out = {}
    for _, r in ipairs(PM.forDocuments(rows)) do out[#out + 1] = PM.publicShape(r, cjson.null) end
    return setmetatable(out, cjson.array_mt)
end

--- The method an invoice prints: its own (active or not — it was chosen when the invoice was made),
-- else the namespace default bank account, else the first bank account on documents. Public shape + uuid.
function Q.resolve(ns_id, uuid)
    local ok, row = pcall(get_row, ns_id, uuid)
    row = ok and row or nil
    if not row then
        local okd, rows = pcall(rows_for, ns_id, false)
        local docs = okd and PM.forDocuments(rows) or {}
        for _, r in ipairs(docs) do
            if r.kind == "bank_transfer" then row = r break end
        end
        row = row or docs[1]
    end
    if not row then return nil end
    local out = PM.publicShape(row, cjson.null)
    out.uuid = row.uuid
    return out
end

return Q
