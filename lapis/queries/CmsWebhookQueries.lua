--[[
    CMS Webhook Queries
    ===================
    Namespace-scoped CRUD for cms_webhooks — a generic, per-tenant outgoing
    webhook: a URL + signing secret + the events it wants. The dispatcher
    (lib/webhook-dispatcher.lua) reads active webhooks via activeForEvent().
]]

local CmsWebhookModel = require "models.CmsWebhookModel"
local Global = require "helper.global"
local db = require("lapis.db")

local CmsWebhookQueries = {}

local ALLOWED_EVENTS = {
    ["post.created"] = true,
    ["post.updated"] = true,
    ["post.deleted"] = true,
}
local DEFAULT_EVENTS = "post.created,post.updated,post.deleted"

-- A strong random signing secret (64 hex chars). resty.random in OpenResty;
-- falls back to two UUIDs off-request (e.g. tests / CLI).
local function gen_secret()
    local ok_r, resty_random = pcall(require, "resty.random")
    local ok_s, resty_string = pcall(require, "resty.string")
    if ok_r and ok_s then
        local bytes = resty_random.bytes(32, true) or resty_random.bytes(32)
        if bytes then return resty_string.to_hex(bytes) end
    end
    return (Global.generateUUID() .. Global.generateUUID()):gsub("-", "")
end

-- Accept events as a comma string or an array; keep only known events; default
-- to all when none are valid.
local function normalize_events(events)
    local raw = {}
    if type(events) == "string" then
        for part in events:gmatch("[^,]+") do raw[#raw + 1] = part end
    elseif type(events) == "table" then
        for _, e in ipairs(events) do raw[#raw + 1] = tostring(e) end
    end
    local valid = {}
    for _, e in ipairs(raw) do
        local trimmed = e:match("^%s*(.-)%s*$")
        if ALLOWED_EVENTS[trimmed] then valid[#valid + 1] = trimmed end
    end
    if #valid == 0 then return DEFAULT_EVENTS end
    return table.concat(valid, ",")
end

local function findScoped(namespace_id, uuid)
    local row = CmsWebhookModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not row or row.deleted_at then return nil end
    return row
end
CmsWebhookQueries.findScoped = findScoped

function CmsWebhookQueries.create(namespace_id, params)
    return CmsWebhookModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = params.name,
        url = params.url,
        secret = (params.secret and params.secret ~= "") and params.secret or gen_secret(),
        events = normalize_events(params.events),
        active = params.active ~= false,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

function CmsWebhookQueries.list(namespace_id)
    return CmsWebhookModel:select(
        "WHERE namespace_id = ? AND deleted_at IS NULL ORDER BY created_at DESC", namespace_id) or {}
end

function CmsWebhookQueries.getByUuid(namespace_id, uuid)
    return findScoped(namespace_id, uuid)
end

function CmsWebhookQueries.update(namespace_id, uuid, params)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    local fields = { updated_at = db.raw("NOW()") }
    if params.name ~= nil then fields.name = params.name end
    if params.url ~= nil then fields.url = params.url end
    if params.secret ~= nil and params.secret ~= "" then fields.secret = params.secret end
    if params.events ~= nil then fields.events = normalize_events(params.events) end
    if params.active ~= nil then fields.active = params.active and true or false end
    row:update(fields)
    return findScoped(namespace_id, uuid)
end

function CmsWebhookQueries.softDelete(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    row:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return row
end

--- Active webhooks in a namespace subscribed to `event` (dispatcher use).
function CmsWebhookQueries.activeForEvent(namespace_id, event)
    local rows = CmsWebhookModel:select(
        "WHERE namespace_id = ? AND active = TRUE AND deleted_at IS NULL", namespace_id) or {}
    local matched = {}
    for _, w in ipairs(rows) do
        for e in tostring(w.events or ""):gmatch("[^,]+") do
            if e:match("^%s*(.-)%s*$") == event then
                matched[#matched + 1] = w
                break
            end
        end
    end
    return matched
end

--- Best-effort delivery-status record (called by the dispatcher after a POST).
function CmsWebhookQueries.recordDelivery(id, status)
    pcall(function()
        db.query("UPDATE cms_webhooks SET last_status = ?, last_triggered_at = NOW() WHERE id = ?",
            status, id)
    end)
end

return CmsWebhookQueries
