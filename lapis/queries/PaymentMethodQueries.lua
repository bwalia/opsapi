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

    Every create / change / delete is written to the workspace audit log (namespace_audit_logs, before and
    after) and emailed to the workspace owners: documents already sent show the current details, so a changed
    account number must never go unnoticed.
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

-- ---------------------------------------------------------------------------
-- audit trail + owner email
-- ---------------------------------------------------------------------------

local AUDITED = { "kind", "label", "account_name", "bank_name", "sort_code", "account_number", "iban", "swift_bic",
    "currency", "instructions", "is_default", "show_on_documents", "is_active" }
local LABELS = { kind = "Type", label = "Name", account_name = "Account name", bank_name = "Bank", sort_code = "Sort code",
    account_number = "Account number", iban = "IBAN", swift_bic = "SWIFT/BIC", currency = "Currency",
    instructions = "Instructions", is_default = "Default", show_on_documents = "Shown on documents", is_active = "Active" }
local MASKED = { sort_code = true, account_number = true, iban = true }

--- The audited fields that differ between two admin shapes (nil = none): (before, after).
function Q.diff(old, new)
    local before, after, any = {}, {}, false
    for _, k in ipairs(AUDITED) do
        local a, b = old and old[k], new and new[k]
        if a == cjson.null then a = nil end
        if b == cjson.null then b = nil end
        if a ~= b then before[k], after[k], any = a, b, true end
    end
    if not any then return nil end
    return before, after
end

local function esc(v)
    return (tostring(v):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function shown(k, v)
    if v == nil then return "(none)" end
    if type(v) == "boolean" then return v and "yes" or "no" end
    v = tostring(v)
    if MASKED[k] and #v > 4 then return "••••" .. v:sub(-4) end
    return v
end

--- The owners' email: what changed (bank numbers shown as their last digits only). Pure, for the spec.
function Q.changeEmail(ws_name, action, label, who, before, after)
    local verb = action == "created" and "added" or action == "deleted" and "deleted"
        or action == "deactivated" and "turned off" or "changed"
    local rows = {}
    for _, k in ipairs(AUDITED) do
        if (before and before[k] ~= nil) or (after and after[k] ~= nil) then
            local text = action == "created" and shown(k, after[k])
                or action == "updated" and (shown(k, before[k]) .. " → " .. shown(k, after[k]))
                or shown(k, before[k])
            rows[#rows + 1] = "<p><strong>" .. esc(LABELS[k]) .. ":</strong> " .. esc(text) .. "</p>"
        end
    end
    return {
        subject = "Bank details " .. verb .. " in " .. tostring(ws_name),
        title = "Payment details " .. verb .. ": " .. tostring(label),
        message = "The payment method \"" .. tostring(label) .. "\" in " .. tostring(ws_name) .. " was " .. verb .. " by "
            .. tostring(who) .. ". Invoices, Order Authorisations and bank-transfer orders that haven't been paid "
            .. "yet show the current details. If you didn't expect this, check it now in Workspace → Getting paid "
            .. "and change your password.",
        details = table.concat(rows, ""),
    }
end

-- Never fails the change itself.
local function record(ns_id, action, old, new)
    local ok, err = pcall(function()
        local before, after = Q.diff(old, new)
        if not before then return end
        local u = ngx.ctx and ngx.ctx.user
        local me = type(u) == "table" and u.uuid and db.query("SELECT id, email FROM users WHERE uuid = ?", u.uuid)[1]
        local okip, ip = pcall(function() return require("helper.client-ip").get() end)
        local subject = new or old
        require("queries.NamespaceAuditLogQueries").log({
            namespace_id = ns_id, user_id = me and me.id or nil, action = "payment_method." .. action,
            entity_type = "payment_method", entity_id = subject.uuid, old_values = before, new_values = after,
            ip_address = okip and type(ip) == "string" and ip or nil,
            user_agent = ngx.var and ngx.var.http_user_agent and ngx.var.http_user_agent:sub(1, 500) or nil,
        })
        local Mail = require("helper.mail")
        if not Mail.isConfigured() then return end
        local ws = db.query("SELECT name FROM namespaces WHERE id = ?", ns_id)[1]
        local owners = {}
        for _, r in ipairs(db.query([[
            SELECT DISTINCT u.email FROM users u
             WHERE u.email IS NOT NULL AND u.id IN (SELECT owner_user_id FROM namespaces WHERE id = ?
                                                   UNION SELECT user_id FROM namespace_members
                                                          WHERE namespace_id = ? AND is_owner AND status = 'active')
        ]], ns_id, ns_id)) do owners[#owners + 1] = r.email end
        if #owners == 0 then return end
        local e = Q.changeEmail(ws and ws.name or "your workspace", action, subject.label,
            me and me.email or "an API key", before, after)
        Mail.send({ to = owners, subject = e.subject, template = "notification",
            data = { title = e.title, message = e.message, details = e.details, app_name = ws and ws.name or nil } })
    end)
    if not ok then ngx.log(ngx.ERR, "[payment-methods] audit/notify failed: ", tostring(err)) end
end

function Q.create(ns_id, body, actor)
    local f, err = PM.clean(body)
    if not f then return nil, err end
    f.created_by = actor
    local saved, werr = write(ns_id, f)
    if saved then record(ns_id, "created", nil, saved) end
    return saved, werr
end

function Q.update(ns_id, uuid, body)
    local row = get_row(ns_id, uuid)
    if not row then return nil, "Payment method not found" end
    local f, err = PM.clean(body, row)
    if not f then return nil, err end
    local saved, werr = write(ns_id, f, row.id)
    if saved then record(ns_id, "updated", Q.shape(row), saved) end
    return saved, werr
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
    record(ns_id, referenced and "deactivated" or "deleted", Q.shape(row), nil)
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
