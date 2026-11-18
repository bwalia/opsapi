-- luacheck: max line length 140
--[[
    Message templates: storage (shop)
    =================================
    A workspace's own templates for supplier messages (rules and placeholders: lib/message-templates.lua).

      list(ns_id, { kind? })            templates + the built-in default for each kind, for the Templates page
      get(ns_id, uuid)
      create(ns_id, body, user_id)      body { kind, name, subject, body, supplier_uuid?, is_default?, is_active? }
      update(ns_id, uuid, body, user_id)
      delete(ns_id, uuid)
      pick(ns_id, kind, { template_uuid?, supplier_id? })
            → the template to draft with: the one asked for, else this supplier's own, else the workspace default,
              else the built-in. Returns { uuid|nil, name, subject, body, builtin }.
      choices(ns_id, kind, supplier_id?) → what the send window offers: built-in + active templates for the kind
            (those for another supplier left out)
    Errors are (nil, { status, code, message }).
]]

local db = require("lapis.db")
local U = require("lib.shop-util")
local T = require("lib.message-templates")
local Global = require("helper.global")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143

local Q = {}

local COLS = [[t.uuid, t.kind, t.name, t.subject, t.body, t.is_default, t.is_active, t.created_at, t.updated_at,
    s.uuid AS supplier_uuid, s.name AS supplier_name, t.supplier_id]]
local FROM = " FROM shop_message_templates t LEFT JOIN shop_suppliers s ON s.id = t.supplier_id "

local function shape(r)
    if not r then return nil end
    return { uuid = r.uuid, kind = r.kind, kind_label = T.KINDS[r.kind], name = r.name, subject = r.subject, body = r.body,
             supplier_uuid = r.supplier_uuid or U.null, supplier_name = r.supplier_name or U.null,
             is_default = r.is_default == true, is_active = r.is_active ~= false, builtin = false,
             created_at = r.created_at, updated_at = r.updated_at }
end

local function builtin(kind)
    local d = T.DEFAULTS[kind]
    return { uuid = U.null, kind = kind, kind_label = T.KINDS[kind], name = d.name, subject = d.subject, body = d.body,
             supplier_uuid = U.null, supplier_name = U.null, is_default = false, is_active = true, builtin = true }
end

local function row(ns_id, uuid)
    if type(uuid) ~= "string" or uuid == "" then return nil end
    return db.query("SELECT t.id, " .. COLS .. FROM .. "WHERE t.namespace_id = ? AND t.uuid = ?", ns_id, uuid)[1]
end

function Q.placeholders()
    local out = {}
    for _, kind in ipairs(T.KIND_ORDER) do
        local list = {}
        for name, desc in pairs(T.PLACEHOLDERS[kind]) do list[#list + 1] = { name = name, description = desc } end
        table.sort(list, function(a, b) return a.name < b.name end)
        out[#out + 1] = { kind = kind, label = T.KINDS[kind], placeholders = U.arr(list), builtin = builtin(kind) }
    end
    return U.arr(out)
end

function Q.list(ns_id, opts)
    opts = type(opts) == "table" and opts or {}
    local where, vals = { "t.namespace_id = ?" }, { ns_id }
    if U.nz(opts.kind) then
        if not T.KINDS[opts.kind] then return nil, U.err(400, "VALIDATION_ERROR", "Unknown template kind") end
        where[#where + 1] = "t.kind = ?"; vals[#vals + 1] = opts.kind
    end
    local out = {}
    for i, r in ipairs(db.query("SELECT " .. COLS .. FROM .. "WHERE " .. table.concat(where, " AND ")
            .. " ORDER BY t.kind, t.is_default DESC, t.name", unpack(vals))) do
        out[i] = shape(r)
    end
    return U.arr(out)
end

function Q.get(ns_id, uuid)
    local r = row(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Template not found") end
    return shape(r)
end

local function fields(ns_id, body, current)
    local kind = body.kind ~= nil and body.kind or (current and current.kind)
    if not T.KINDS[kind] then return nil, U.err(400, "VALIDATION_ERROR", "Choose what the template is for") end
    if current and body.kind ~= nil and body.kind ~= current.kind then
        return nil, U.err(400, "VALIDATION_ERROR", "A template's kind can't change: make a new one")
    end
    local f = { kind = kind }
    local name = body.name ~= nil and body.name or (current and current.name)
    name = type(name) == "string" and name:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if name == "" or #name > 160 then return nil, U.err(400, "VALIDATION_ERROR", "Give the template a name (160 characters at most)") end
    f.name = name
    local subject = body.subject ~= nil and body.subject or (current and current.subject)
    local text = body.body ~= nil and body.body or (current and current.body)
    local ok, msg = T.validate(kind, subject, text)
    if not ok then return nil, U.err(400, "VALIDATION_ERROR", msg) end
    f.subject, f.body = tostring(subject):gsub("^%s+", ""):gsub("%s+$", ""), tostring(text)
    if body.supplier_uuid ~= nil then
        if U.nz(body.supplier_uuid) and body.supplier_uuid ~= U.null then
            local s = db.query("SELECT id FROM shop_suppliers WHERE namespace_id = ? AND uuid = ?", ns_id, body.supplier_uuid)[1]
            if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
            f.supplier_id = s.id
        else
            f.supplier_id = db.NULL
        end
    end
    if body.is_default ~= nil then f.is_default = body.is_default == true end
    if body.is_active ~= nil then f.is_active = body.is_active ~= false end
    if f.is_default and f.is_active == false then
        return nil, U.err(400, "VALIDATION_ERROR", "A default template must be active")
    end
    return f
end

local function clear_default(ns_id, kind, keep_id)
    db.query("UPDATE shop_message_templates SET is_default = false, updated_at = NOW() WHERE namespace_id = ? AND kind = ? "
        .. "AND is_default AND id <> ?", ns_id, kind, keep_id or 0)
end

function Q.create(ns_id, body, user_id)
    body = type(body) == "table" and body or {}
    local f, err = fields(ns_id, body, nil)
    if not f then return nil, err end
    local uuid = Global.generateUUID()
    return U.tx(function()
        if f.is_default then clear_default(ns_id, f.kind) end
        db.query([[INSERT INTO shop_message_templates (uuid, namespace_id, kind, name, subject, body, supplier_id, is_default,
                       is_active, created_by_user_id, updated_by_user_id, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())]],
            uuid, ns_id, f.kind, f.name, f.subject, f.body, f.supplier_id or db.NULL, f.is_default == true,
            f.is_active ~= false, tonumber(user_id) or db.NULL, tonumber(user_id) or db.NULL)
        return shape(row(ns_id, uuid))
    end)
end

function Q.update(ns_id, uuid, body, user_id)
    body = type(body) == "table" and body or {}
    local r = row(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Template not found") end
    local f, err = fields(ns_id, body, r)
    if not f then return nil, err end
    if f.is_active == false and r.is_default and f.is_default == nil then f.is_default = false end
    return U.tx(function()
        if f.is_default then clear_default(ns_id, r.kind, r.id) end
        local set = { name = f.name, subject = f.subject, body = f.body, updated_at = db.raw("NOW()"),
                      updated_by_user_id = tonumber(user_id) or db.NULL }
        for _, k in ipairs({ "supplier_id", "is_default", "is_active" }) do
            if f[k] ~= nil then set[k] = f[k] end
        end
        db.update("shop_message_templates", set, { id = r.id })
        return shape(row(ns_id, uuid))
    end)
end

function Q.delete(ns_id, uuid)
    local r = row(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Template not found") end
    db.query("DELETE FROM shop_message_templates WHERE id = ?", r.id)
    return { deleted = true }
end

local function table_ready()
    local r = db.query("SELECT to_regclass('public.shop_message_templates') IS NOT NULL AS ok")[1]
    return r and r.ok == true
end

function Q.pick(ns_id, kind, opts)
    opts = type(opts) == "table" and opts or {}
    if not T.KINDS[kind] then return nil, U.err(400, "VALIDATION_ERROR", "Unknown template kind") end
    if not table_ready() then return builtin(kind) end
    local r
    if U.nz(opts.template_uuid) then
        if opts.template_uuid == "builtin" then return builtin(kind) end
        r = row(ns_id, opts.template_uuid)
        if not r or r.kind ~= kind then return nil, U.err(404, "TEMPLATE_NOT_FOUND", "That template isn't for this kind of message") end
        return shape(r)
    end
    if opts.supplier_id then
        r = db.query("SELECT t.id, " .. COLS .. FROM .. [[WHERE t.namespace_id = ? AND t.kind = ? AND t.is_active
                       AND t.supplier_id = ? ORDER BY t.is_default DESC, t.updated_at DESC LIMIT 1]], ns_id, kind, opts.supplier_id)[1]
        if r then return shape(r) end
    end
    r = db.query("SELECT t.id, " .. COLS .. FROM .. [[WHERE t.namespace_id = ? AND t.kind = ? AND t.is_active AND t.is_default
                   AND t.supplier_id IS NULL LIMIT 1]], ns_id, kind)[1]
    if r then return shape(r) end
    return builtin(kind)
end

function Q.choices(ns_id, kind, supplier_id)
    local out = { builtin(kind) }
    if table_ready() then
        for _, r in ipairs(db.query("SELECT t.id, " .. COLS .. FROM .. [[WHERE t.namespace_id = ? AND t.kind = ? AND t.is_active
                AND (t.supplier_id IS NULL OR t.supplier_id = ?) ORDER BY t.is_default DESC, t.name]], ns_id, kind, supplier_id or 0)) do
            out[#out + 1] = shape(r)
        end
    end
    return U.arr(out)
end

return Q
