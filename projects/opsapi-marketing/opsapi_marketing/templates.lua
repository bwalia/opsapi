-- Template studio backend: sanitise, preview, version, publish, seed defaults.
local cjson = require("cjson")
local db = require("lapis.db")
local TemplateRenderer = require("lib.template-renderer")
local U = require("opsapi_marketing.util")
local S = require("opsapi_marketing.sanitize")
local Merge = require("opsapi_marketing.merge_fields")
local Channels = require("opsapi_marketing.channels")

local T = {}

-- The ready-made templates (opsapi_marketing/designs.lua).
local DEFAULTS = require("opsapi_marketing.designs")

function T.prepare_payload(payload)
    local out = {
        name = payload.name,
        channel = payload.channel or "email",
        subject = payload.subject,
        preview_text = payload.preview_text,
        body_html = payload.body_html and S.strip_html(payload.body_html) or nil,
        body_text = payload.body_text,
        status = payload.status or "draft",
    }
    return out
end

function T.analyse(ns, payload)
    local channel = payload.channel or "email"
    local prepared = T.prepare_payload(payload)
    local ok_merge, merge_info = Merge.validate_template(ns, prepared)
    local warnings = S.warnings(prepared, channel)
    if not ok_merge then
        for _, k in ipairs(merge_info.unknown or {}) do
            warnings[#warnings + 1] = "unknown_merge:" .. k
        end
    end
    return {
        ok = ok_merge and not (function()
            for _, w in ipairs(warnings) do
                if w == "unsafe_html_detected" or w:match("^unknown_merge:") then return true end
            end
            return false
        end)(),
        warnings = warnings,
        merge_fields = merge_info.fields or {},
        unknown_merge = merge_info.unknown or {},
        sanitised = prepared,
    }
end

function T.preview(ns, template_or_payload, sample)
    local payload = template_or_payload
    if payload.body_html == nil and payload.uuid then
        -- already a row
    end
    local channel = payload.channel or "email"
    local adapter = Channels.get(channel)
    if not adapter then return nil, "unknown channel" end

    local analysis = T.analyse(ns, payload)
    local raw_ctx = sample or {
        contact = { first_name = "Alex", last_name = "Example", email = "alex@example.com",
                    phone = "+447700900000", company = "Example Ltd" },
        campaign = { name = payload.name or "Preview campaign" },
        custom = { industry = "Technology" },
        unsubscribe_url = "https://example.com/unsub",
        preferences_url = "https://example.com/prefs",
        view_online_url = "https://example.com/view",
    }
    local ctx = Merge.build_context(ns, raw_ctx)
    -- TemplateRenderer uses {{contact.first_name}} with nested tables — build_context nests them.
    local rendered, err = adapter.render({
        subject = analysis.sanitised.subject or payload.subject,
        body_html = analysis.sanitised.body_html or payload.body_html,
        body_text = analysis.sanitised.body_text or payload.body_text,
    }, ctx, { unsubscribe_url = raw_ctx.unsubscribe_url })
    if not rendered then return nil, err end
    return {
        channel = channel,
        subject = rendered.subject,
        html = rendered.html,
        text = rendered.text,
        warnings = analysis.warnings,
        merge_fields = analysis.merge_fields,
        opens_estimated = channel == "email",
    }
end

function T.publish(ns, template_id)
    local row = U.one("SELECT * FROM mkt_templates WHERE id = ? AND namespace_id = ?", template_id, ns)
    if not row then return nil, "not_found" end
    local analysis = T.analyse(ns, row)
    if #analysis.unknown_merge > 0 then
        return nil, "unknown_merge_fields"
    end
    for _, w in ipairs(analysis.warnings) do
        if w == "unsafe_html_detected" then return nil, "unsafe_html" end
    end
    db.query([[
        UPDATE mkt_templates SET status = 'published', body_html = ?, published_at = NOW(), updated_at = NOW()
        WHERE id = ?
    ]], analysis.sanitised.body_html or row.body_html, template_id)
    return U.one("SELECT * FROM mkt_templates WHERE id = ?", template_id), analysis.warnings
end

local function nvl(v)
    if v == nil then return db.NULL end
    return v
end

function T.clone(ns, template_id, name)
    local row = U.one("SELECT * FROM mkt_templates WHERE id = ? AND namespace_id = ?", template_id, ns)
    if not row then return nil, "not_found" end
    local new_version = (tonumber(row.version) or 1) + 1
    local created = db.query([[
        INSERT INTO mkt_templates
            (namespace_id, name, channel, subject, preview_text, body_html, body_text, status, version, parent_uuid)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'draft', ?, ?)
        RETURNING *
    ]], ns, name or (row.name .. " (copy)"), row.channel, nvl(row.subject), nvl(row.preview_text),
        nvl(row.body_html), nvl(row.body_text), new_version, row.uuid)[1]
    return created
end

function T.seed_defaults(ns)
    Merge.ensure_defaults(ns)
    local created = {}
    -- The designs say "[Your business name]": use the workspace's name instead.
    local ws = U.one("SELECT name FROM namespaces WHERE id = ?", ns)
    local biz = ws and (tostring(ws.name):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&#39;" }):gsub("%%", "%%%%")) or nil
    local function ours(v)
        if type(v) ~= "string" or not biz then return v end
        return (v:gsub("%[Your business name%]", biz))
    end
    for _, d0 in ipairs(DEFAULTS) do
        local d = { name = d0.name, channel = d0.channel, subject = d0.subject, preview_text = d0.preview_text,
            body_html = ours(d0.body_html), body_text = d0.body_text }
        local exists = U.one([[
            SELECT id FROM mkt_templates WHERE namespace_id = ? AND name = ? AND channel = ?
        ]], ns, d.name, d.channel)
        if not exists then
            local row = db.query([[
                INSERT INTO mkt_templates
                    (namespace_id, name, channel, subject, preview_text, body_html, body_text, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'draft')
                RETURNING *
            ]], ns, d.name, d.channel, d.subject or db.NULL, d.preview_text or db.NULL,
                d.body_html or db.NULL, d.body_text or db.NULL)[1]
            created[#created + 1] = row
        end
    end
    return created
end

-- silence unused
assert(cjson)

return T
