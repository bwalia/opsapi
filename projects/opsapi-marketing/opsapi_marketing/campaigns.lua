--[[
    Campaign lifecycle:
      draft → validated → [awaiting_approval →] scheduled → sending → completed
      + paused / cancelled / failed

    Validation re-checks audience eligibility counts. Approval is RBAC-gated.
    A/B variants live in ab_config JSONB; budget in max_deliveries.
]]
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("opsapi_marketing.util")
local E = require("opsapi_marketing.eligibility")
local T = require("opsapi_marketing.templates")

local C = {}

local EDITABLE = {
    draft = true, validated = true, awaiting_approval = true, paused = true,
}

local function nvl(v)
    if v == nil then return db.NULL end
    return v
end

local function present(v)
    return v ~= nil and v ~= db.NULL
end

--- Approval is needed when the campaign asks for it or the workspace requires it for all.
local function needs_approval(ns, campaign)
    return campaign.approval_required == true or U.settings(ns).require_approval == true
end

--- What's sent or who gets it changed: it must be validated (and approved) again.
function C.invalidate(campaign_id)
    db.query([[
        UPDATE mkt_campaigns SET approved_by = NULL, approved_at = NULL, resume_status = NULL,
            status = CASE WHEN status IN ('validated', 'awaiting_approval', 'scheduled', 'paused')
                          THEN 'draft' ELSE status END,
            updated_at = NOW()
        WHERE id = ?
    ]], campaign_id)
end

--- Attach the audience list. Changing it re-opens validation and approval; once
-- sending has started the audience is fixed.
function C.attach_list(ns, campaign, list_id)
    if tonumber(campaign.list_id) == tonumber(list_id) then return campaign end
    if present(campaign.started_at) then return nil, "list_locked" end
    db.query("UPDATE mkt_campaigns SET list_id = ?, updated_at = NOW() WHERE id = ? AND namespace_id = ?",
        list_id, campaign.id, ns)
    C.invalidate(campaign.id)
    return U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
end

local function sdk_emit(ns, name, data)
    pcall(function()
        require("helper.plugin-sdk").emit(ns, name, data)
    end)
end

function C.editable(status)
    return EDITABLE[status] == true
end

function C.find(ns, id)
    if U.is_uuid(id) then
        return U.one("SELECT * FROM mkt_campaigns WHERE namespace_id = ? AND uuid = ?", ns, id)
    end
    return U.one("SELECT * FROM mkt_campaigns WHERE namespace_id = ? AND id = ?", ns, tonumber(id))
end

--- Refresh dynamic list membership (segment → mkt_list_members) before counting/sending.
-- Static lists are left as-is. Empty/invalid segment rules return a clear error
-- instead of a silent empty_audience.
local function ensure_list_ready(ns, list_id)
    local list = U.one("SELECT * FROM mkt_lists WHERE id = ? AND namespace_id = ?", list_id, ns)
    if not list then return nil, "list_not_found" end
    if list.list_type ~= "dynamic" then return list end

    local rule = U.json(list.segment_rule) or {}
    local has_rule = type(rule) == "table"
        and (rule["and"] ~= nil or rule["or"] ~= nil or rule.field ~= nil)
    if not has_rule then
        return nil, "dynamic_list_needs_segment_rule"
    end

    local Seg = require("opsapi_marketing.segments")
    local sync, err = Seg.sync_list(ns, list_id)
    if not sync then return nil, err or "list_sync_failed" end
    return list, nil, sync
end

local function audience_contact_uuids(ns, campaign)
    local uuids = {}
    if campaign.list_id then
        local ok, err = ensure_list_ready(ns, campaign.list_id)
        if not ok then return nil, err end
        local rows = db.query([[
            SELECT contact_uuid FROM mkt_list_members
            WHERE namespace_id = ? AND list_id = ? AND removed_at IS NULL
        ]], ns, campaign.list_id)
        for _, r in ipairs(rows) do uuids[#uuids + 1] = r.contact_uuid end
    else
        local rows = db.query([[
            SELECT contact_uuid FROM mkt_campaign_recipients
            WHERE namespace_id = ? AND campaign_id = ? AND excluded = false
        ]], ns, campaign.id)
        for _, r in ipairs(rows) do uuids[#uuids + 1] = r.contact_uuid end
    end
    return uuids
end

--- Count eligible / excluded / suppressed for the campaign audience (capped sample for speed).
-- Returns nil, err when the audience list cannot be resolved (e.g. dynamic list with no rule).
function C.audience_preview(ns, campaign, opts)
    opts = opts or {}
    local limit = math.min(tonumber(opts.limit) or 500, 2000)
    local uuids, aerr = audience_contact_uuids(ns, campaign)
    if not uuids then return nil, aerr end
    local total = #uuids
    local eligible, suppressed, no_consent, other, missing_address = 0, 0, 0, 0, 0
    local sample = {}
    campaign.namespace_id = ns
    campaign.skip_quiet_hours = opts.skip_quiet_hours ~= false -- validation preview ignores quiet hours by default

    local n = math.min(total, limit)
    for i = 1, n do
        local contact = U.one([[
            SELECT uuid, namespace_id, first_name, last_name, email, phone, mobile, status, deleted_at
            FROM crm_contacts WHERE namespace_id = ? AND uuid = ?
        ]], ns, uuids[i])
        if not contact then
            other = other + 1
        else
            contact.namespace_id = ns
            local gate = E.can_send(contact, campaign, campaign.channel, campaign.message_type or "marketing")
            if gate.allowed then
                eligible = eligible + 1
                if #sample < 20 then
                    sample[#sample + 1] = { contact_uuid = contact.uuid, email = contact.email, reason = gate.reason }
                end
            else
                local r = gate.reason or ""
                if r:find("suppress", 1, true) then suppressed = suppressed + 1
                elseif r:find("consent", 1, true) or r:find("unsubscribed", 1, true) then no_consent = no_consent + 1
                elseif r:find("invalid_", 1, true) then missing_address = missing_address + 1
                else other = other + 1 end
            end
        end
    end

    -- Extrapolate if we sampled
    local scale = total > 0 and (total / n) or 1
    return {
        audience_total = total,
        sampled = n,
        eligible = math.floor(eligible * scale + 0.5),
        suppressed = math.floor(suppressed * scale + 0.5),
        no_consent = math.floor(no_consent * scale + 0.5),
        missing_address = math.floor(missing_address * scale + 0.5),
        other_excluded = math.floor(other * scale + 0.5),
        sample_eligible = sample,
        exact = n >= total,
    }
end

local FRIENDLY = {
    empty_audience = "Audience list has no contacts. Add members, or set a segment rule on a dynamic list and sync.",
    no_eligible_recipients = "No eligible recipients (suppressed, missing consent, or invalid address).",
    audience_required = "Select a list (or add campaign recipients) before validating.",
    dynamic_list_needs_segment_rule = "This dynamic list has no segment rule yet — edit the list segment, then Validate again.",
    list_not_found = "Selected list was not found.",
    list_sync_failed = "Could not sync the dynamic list.",
    subject_required = "Email subject is required.",
    body_required = "Email body is required.",
    sms_body_required = "SMS text is required.",
    unknown_merge_fields = "Template has merge fields that are not in the registry.",
    approval_required = "This campaign needs approval before it can be sent.",
    self_approval = "You can't approve a campaign you created. Ask another admin to approve it.",
    list_locked = "The audience can't change once sending has started. Duplicate the campaign to send to another list.",
    template_error = "The message can't be rendered. Fix the template, then validate again.",
}

--- detail: extra text for the message (e.g. the template error and where it is).
function C.friendly_error(err, detail)
    if type(err) ~= "string" then return "Campaign action failed" end
    if FRIENDLY[err] then return FRIENDLY[err] .. (detail and (" " .. detail) or "") end
    if err:match("^bad_status:") then
        return "Campaign status does not allow this action (" .. err:sub(12) .. ")"
    end
    return err
end

local function content_ok(campaign)
    local channel = campaign.channel or "email"
    if channel == "email" then
        if not present(campaign.subject) or campaign.subject == "" then return nil, "subject_required" end
        if (not present(campaign.body_html) or campaign.body_html == "")
            and (not present(campaign.body_text) or campaign.body_text == "") then
            return nil, "body_required"
        end
    elseif channel == "sms" then
        if not present(campaign.body_text) or campaign.body_text == "" then return nil, "sms_body_required" end
    end
    return true
end

--- Render the content (and every A/B variant) once with sample data: a template
-- that doesn't render must fail validation, not reach the audience.
local function renders(ns, campaign)
    local parts = { { subject = campaign.subject, body_html = campaign.body_html, body_text = campaign.body_text } }
    local ab = U.json(campaign.ab_config) or {}
    if ab.enabled == true and type(ab.variants) == "table" then
        for _, v in ipairs(ab.variants) do
            parts[#parts + 1] = {
                key = v.key,
                subject = v.subject or campaign.subject,
                body_html = v.body_html or campaign.body_html,
                body_text = v.body_text or campaign.body_text,
            }
        end
    end
    for _, p in ipairs(parts) do
        local out, err = T.preview(ns, {
            channel = campaign.channel, name = campaign.name,
            subject = present(p.subject) and p.subject or nil,
            body_html = present(p.body_html) and p.body_html or nil,
            body_text = present(p.body_text) and p.body_text or nil,
        })
        if not out then
            return nil, (p.key and ("Variant " .. tostring(p.key) .. ": ") or "") .. tostring(err)
        end
    end
    return true
end

--- draft → validated (or awaiting_approval if approval_required).
function C.validate(ns, campaign_id, opts)
    opts = opts or {}
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status ~= "draft" and campaign.status ~= "validated" and campaign.status ~= "awaiting_approval" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end
    if not campaign.list_id then
        local recip = U.one("SELECT id FROM mkt_campaign_recipients WHERE campaign_id = ? AND excluded = false LIMIT 1", campaign.id)
        if not recip then return nil, "audience_required" end
    end
    local ok, err = content_ok(campaign)
    if not ok then return nil, err end
    local rendered, rerr = renders(ns, campaign)
    if not rendered then return nil, "template_error", rerr end

    local analysis = T.analyse(ns, {
        channel = campaign.channel,
        subject = campaign.subject,
        body_html = campaign.body_html,
        body_text = campaign.body_text,
    })
    if #(analysis.unknown_merge or {}) > 0 then return nil, "unknown_merge_fields" end

    local preview, perr = C.audience_preview(ns, campaign, { skip_quiet_hours = true })
    if not preview then return nil, perr end
    if preview.audience_total == 0 then return nil, "empty_audience" end
    if preview.eligible == 0 then return nil, "no_eligible_recipients" end

    -- Already approved and unchanged since (any change clears approved_at): stays approved.
    local next_status = "validated"
    if needs_approval(ns, campaign) and not present(campaign.approved_at) then
        next_status = "awaiting_approval"
    end
    db.query("UPDATE mkt_campaigns SET status = ?, updated_at = NOW() WHERE id = ?", next_status, campaign.id)
    sdk_emit(ns, "opsapi_marketing.campaign.validated", { campaign_uuid = campaign.uuid, preview = preview })
    return {
        campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id),
        preview = preview,
        warnings = analysis.warnings,
    }
end

function C.request_approval(ns, campaign_id, notes)
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status ~= "validated" and campaign.status ~= "draft" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end
    db.query([[
        UPDATE mkt_campaigns SET status = 'awaiting_approval', approval_required = true,
            approval_notes = ?, updated_at = NOW()
        WHERE id = ?
    ]], nvl(notes), campaign.id)
    return U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
end

function C.approve(ns, campaign_id, actor_uuid)
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status ~= "awaiting_approval" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end
    if present(campaign.created_by) and tostring(campaign.created_by) == tostring(actor_uuid) then
        return nil, "self_approval"
    end
    db.query([[
        UPDATE mkt_campaigns SET status = 'validated', approved_by = ?, approved_at = NOW(),
            rejected_reason = NULL, updated_at = NOW()
        WHERE id = ?
    ]], nvl(actor_uuid), campaign.id)
    sdk_emit(ns, "opsapi_marketing.campaign.approved", { campaign_uuid = campaign.uuid })
    return U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
end

function C.reject(ns, campaign_id, reason)
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status ~= "awaiting_approval" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end
    db.query([[
        UPDATE mkt_campaigns SET status = 'draft', rejected_reason = ?, updated_at = NOW()
        WHERE id = ?
    ]], nvl(reason or "rejected"), campaign.id)
    return U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
end

function C.schedule(ns, campaign_id, opts)
    opts = opts or {}
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end

    if opts.list_uuid or opts.list_id then
        local list_uuid = opts.list_uuid or opts.list_id
        local list = U.is_uuid(tostring(list_uuid))
            and U.one("SELECT id FROM mkt_lists WHERE namespace_id = ? AND uuid = ?", ns, list_uuid)
            or U.one("SELECT id FROM mkt_lists WHERE namespace_id = ? AND id = ?", ns, tonumber(list_uuid))
        if not list then return nil, "list_not_found" end
        local attached, aerr = C.attach_list(ns, campaign, list.id)
        if not attached then return nil, aerr end
        campaign = attached
    end

    -- Must be validated (or approved → validated) unless send_now from draft with force.
    -- (Content changes go through PUT / ab-config, which send it back to draft.)
    if campaign.status == "draft" then
        local v, verr, vdetail = C.validate(ns, campaign.id)
        if not v then return nil, verr, vdetail end
        campaign = v.campaign
    end
    if campaign.status == "awaiting_approval"
        or (needs_approval(ns, campaign) and not present(campaign.approved_at)) then
        return nil, "approval_required"
    end
    if campaign.status ~= "validated" and campaign.status ~= "scheduled" and campaign.status ~= "paused" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end

    if opts.max_deliveries then
        db.query("UPDATE mkt_campaigns SET max_deliveries = ? WHERE id = ?", tonumber(opts.max_deliveries), campaign.id)
    end

    local when = opts.scheduled_at
    if when then
        db.query([[
            UPDATE mkt_campaigns SET status = 'scheduled', scheduled_at = ?::timestamptz, updated_at = NOW()
            WHERE id = ?
        ]], when, campaign.id)
    else
        db.query([[
            UPDATE mkt_campaigns SET status = 'scheduled', scheduled_at = NOW(), updated_at = NOW()
            WHERE id = ?
        ]], campaign.id)
    end
    campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
    sdk_emit(ns, "opsapi_marketing.campaign.scheduled", { campaign_uuid = campaign.uuid })

    if opts.send_now == true then
        return require("opsapi_marketing.send").start_campaign(ns, campaign.id)
    end
    return { campaign = campaign }
end

function C.pause(ns, campaign_id)
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status ~= "sending" and campaign.status ~= "scheduled" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end
    db.query([[
        UPDATE mkt_campaigns SET status = 'paused', paused_at = NOW(),
            resume_status = ?, updated_at = NOW()
        WHERE id = ?
    ]], campaign.status, campaign.id)
    return U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
end

function C.resume(ns, campaign_id)
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status ~= "paused" then return nil, "bad_status:" .. tostring(campaign.status) end
    local resume = campaign.resume_status
    if resume ~= "sending" and resume ~= "scheduled" then resume = "scheduled" end
    if resume == "scheduled" then
        db.query([[
            UPDATE mkt_campaigns SET status = 'scheduled',
                scheduled_at = COALESCE(scheduled_at, NOW()), paused_at = NULL, resume_status = NULL, updated_at = NOW()
            WHERE id = ?
        ]], campaign.id)
    else
        db.query([[
            UPDATE mkt_campaigns SET status = 'sending', paused_at = NULL, resume_status = NULL, updated_at = NOW()
            WHERE id = ?
        ]], campaign.id)
    end
    return U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
end

function C.cancel(ns, campaign_id)
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status == "completed" or campaign.status == "cancelled" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end
    db.query("UPDATE mkt_campaigns SET status = 'cancelled', updated_at = NOW() WHERE id = ?", campaign.id)
    db.query([[
        UPDATE mkt_deliveries SET state = 'skipped', reason = 'campaign_cancelled', updated_at = NOW()
        WHERE campaign_id = ? AND state = 'queued'
    ]], campaign.id)
    return U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id)
end

function C.duplicate(ns, campaign_id, name, actor_uuid)
    local row = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not row then return nil, "not_found" end
    local created = db.query([[
        INSERT INTO mkt_campaigns
            (namespace_id, name, objective, channel, message_type, status, list_id, template_id,
             subject, preview_text, body_html, body_text, from_email, from_name, reply_to,
             approval_required, exclusion_rules, ab_config, max_deliveries, tracking, created_by)
        VALUES (?, ?, ?, ?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING *
    ]], ns, name or (row.name .. " (copy)"), nvl(row.objective), row.channel, row.message_type,
        nvl(row.list_id), nvl(row.template_id), nvl(row.subject), nvl(row.preview_text),
        nvl(row.body_html), nvl(row.body_text), nvl(row.from_email), nvl(row.from_name),
        nvl(row.reply_to), row.approval_required == true,
        type(row.exclusion_rules) == "string" and row.exclusion_rules or cjson.encode(U.json(row.exclusion_rules) or {}),
        type(row.ab_config) == "string" and row.ab_config or cjson.encode(U.json(row.ab_config) or {}),
        nvl(row.max_deliveries),
        type(row.tracking) == "string" and row.tracking or cjson.encode(U.json(row.tracking) or {}),
        nvl(actor_uuid))[1]
    return created
end

--- Pick A/B variant for a contact (stable hash of contact_uuid).
function C.pick_variant(campaign, contact_uuid)
    local ab = U.json(campaign.ab_config) or {}
    if ab.enabled ~= true or type(ab.variants) ~= "table" or #ab.variants == 0 then
        return nil, {
            subject = campaign.subject,
            body_html = campaign.body_html,
            body_text = campaign.body_text,
        }
    end
    local total = 0
    for _, v in ipairs(ab.variants) do
        total = total + (tonumber(v.weight) or 1)
    end
    if total < 1 then total = #ab.variants end
    -- Stable bucket 0..total-1 from uuid hex
    local hex = (contact_uuid or ""):gsub("%-", "")
    local n = 0
    for i = 1, math.min(8, #hex) do
        n = n * 16 + (tonumber(hex:sub(i, i), 16) or 0)
    end
    local bucket = n % total
    local acc = 0
    for _, v in ipairs(ab.variants) do
        acc = acc + (tonumber(v.weight) or 1)
        if bucket < acc then
            return v.key or "A", {
                subject = v.subject or campaign.subject,
                body_html = v.body_html or campaign.body_html,
                body_text = v.body_text or campaign.body_text,
            }
        end
    end
    local v = ab.variants[1]
    return v.key or "A", {
        subject = v.subject or campaign.subject,
        body_html = v.body_html or campaign.body_html,
        body_text = v.body_text or campaign.body_text,
    }
end

function C.delivery_stats(ns, campaign_id)
    local rows = db.query([[
        SELECT state, COUNT(*)::int AS n, variant_key
        FROM mkt_deliveries
        WHERE namespace_id = ? AND campaign_id = ? AND attempt_key NOT LIKE 'test-%'
        GROUP BY state, variant_key
    ]], ns, campaign_id)
    local by_state, by_variant = {}, {}
    local total = 0
    for _, r in ipairs(rows) do
        by_state[r.state] = (by_state[r.state] or 0) + r.n
        total = total + r.n
        if r.variant_key then
            by_variant[r.variant_key] = by_variant[r.variant_key] or { total = 0 }
            by_variant[r.variant_key][r.state] = r.n
            by_variant[r.variant_key].total = by_variant[r.variant_key].total + r.n
        end
    end
    return { total = total, by_state = by_state, by_variant = by_variant }
end

function C.budget_remaining(campaign)
    local max = tonumber(campaign.max_deliveries)
    if not max or max < 1 then return nil end -- unlimited
    -- Sent so far (not queued: the delivery asking is itself queued, so counting
    -- queued dropped the first recipient). Enqueueing already stops at the budget.
    local sent = U.one([[
        SELECT COUNT(*)::int AS n FROM mkt_deliveries
        WHERE campaign_id = ? AND state IN ('accepted', 'delivered') AND attempt_key NOT LIKE 'test-%'
    ]], campaign.id)
    return math.max(0, max - (sent and sent.n or 0))
end

return C
