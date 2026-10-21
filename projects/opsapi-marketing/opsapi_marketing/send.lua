--[[
    Delivery orchestration: eligibility → render → channel.send → delivery row.
    Idempotent on (campaign, contact, channel, attempt_key). Re-checks can_send
    immediately before the provider call.
]]
local db = require("lapis.db")
local RateLimit = require("middleware.rate-limit")
local U = require("opsapi_marketing.util")
local E = require("opsapi_marketing.eligibility")
local Channels = require("opsapi_marketing.channels")
local Tokens = require("opsapi_marketing.tokens")

local S = {}

local function rate_key(ns, channel)
    return "mkt:send:" .. tostring(ns) .. ":" .. channel
end

local function rate_ok(ns, channel, settings)
    local per_min = channel == "sms" and (tonumber(settings.sms_rate_per_min) or 30)
        or (tonumber(settings.email_rate_per_min) or 60)
    local n = RateLimit.incr(rate_key(ns, channel), 60)
    if not n then return true end -- if counter unavailable, do not block permanently
    return n <= per_min
end

local function load_contact(ns, contact_uuid)
    return U.one([[
        SELECT uuid, namespace_id, first_name, last_name, email, phone, mobile, status, deleted_at,
               account_id, metadata
        FROM crm_contacts
        WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL
    ]], ns, contact_uuid)
end

local function merge_context(contact, campaign)
    return {
        contact = {
            first_name = contact.first_name,
            last_name = contact.last_name,
            email = contact.email,
            phone = contact.phone or contact.mobile,
            company = contact.company_name,
        },
        campaign = {
            name = campaign.name,
            uuid = campaign.uuid,
            channel = campaign.channel,
        },
    }
end

--- Queue or immediately process one recipient. Returns delivery row or nil, err.
function S.enqueue(ns, campaign, contact_uuid, opts)
    opts = opts or {}
    local attempt_key = tostring(opts.attempt_key or "1")
    local channel = campaign.channel or "email"
    local contact = load_contact(ns, contact_uuid)
    if not contact then return nil, "contact_not_found" end
    contact.namespace_id = ns

    local address
    if channel == "email" then address = U.norm_email(contact.email)
    elseif channel == "sms" then address = U.e164(contact.phone or contact.mobile)
    else address = contact.email or contact.uuid end
    if not address then return nil, "no_address" end

    -- Idempotent insert
    local existing = U.one([[
        SELECT * FROM mkt_deliveries
        WHERE namespace_id = ? AND campaign_id = ? AND contact_uuid = ?
          AND channel = ? AND attempt_key = ?
    ]], ns, campaign.id, contact_uuid, channel, attempt_key)
    if existing then
        if existing.state == "accepted" or existing.state == "delivered" then
            return existing, "already_sent"
        end
        if existing.state == "skipped" then
            return existing, "already_skipped"
        end
        return existing
    end

    local row = db.query([[
        INSERT INTO mkt_deliveries
            (namespace_id, campaign_id, contact_uuid, channel, address, attempt_key, state)
        VALUES (?, ?, ?, ?, ?, ?, 'queued')
        ON CONFLICT (namespace_id, campaign_id, contact_uuid, channel, attempt_key)
        DO NOTHING
        RETURNING *
    ]], ns, campaign.id, contact_uuid, channel, address, attempt_key)[1]

    if not row then
        return U.one([[
            SELECT * FROM mkt_deliveries
            WHERE namespace_id = ? AND campaign_id = ? AND contact_uuid = ?
              AND channel = ? AND attempt_key = ?
        ]], ns, campaign.id, contact_uuid, channel, attempt_key)
    end

    -- Ensure recipient row
    db.query([[
        INSERT INTO mkt_campaign_recipients
            (namespace_id, campaign_id, contact_uuid, address, display_name)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (namespace_id, campaign_id, contact_uuid) DO NOTHING
    ]], ns, campaign.id, contact_uuid, address,
        table.concat({ contact.first_name or "", contact.last_name or "" }, " "):match("^%s*(.-)%s*$"))

    pcall(function()
        require("helper.plugin-sdk").emit(ns, "opsapi_marketing.delivery.queued", {
            delivery_uuid = row.uuid, campaign_uuid = campaign.uuid, channel = channel,
        })
    end)

    if opts.send_now then
        return S.dispatch(row.id)
    end
    return row
end

--- Claim and send one queued delivery by id. Re-checks can_send.
function S.dispatch(delivery_id)
    return U.tx(function()
        local d = U.one("SELECT * FROM mkt_deliveries WHERE id = ? AND state = 'queued' FOR UPDATE SKIP LOCKED", delivery_id)
        if not d then return nil, "not_found_or_locked" end

        local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", d.campaign_id, d.namespace_id)
        if not campaign then
            db.query("UPDATE mkt_deliveries SET state = 'failed', reason = 'campaign_missing', failed_at = NOW(), updated_at = NOW() WHERE id = ?", d.id)
            return nil, "campaign_missing"
        end
        if campaign.status == "paused" then
            return d, "campaign_paused"
        end
        if campaign.status == "cancelled" then
            db.query("UPDATE mkt_deliveries SET state = 'skipped', reason = 'campaign_cancelled', updated_at = NOW() WHERE id = ?", d.id)
            return U.one("SELECT * FROM mkt_deliveries WHERE id = ?", d.id), "campaign_cancelled"
        end

        local Camp = require("opsapi_marketing.campaigns")
        local remaining = Camp.budget_remaining(campaign)
        if remaining == 0 then
            db.query("UPDATE mkt_deliveries SET state = 'skipped', reason = 'budget_exhausted', updated_at = NOW() WHERE id = ?", d.id)
            return U.one("SELECT * FROM mkt_deliveries WHERE id = ?", d.id), "budget_exhausted"
        end

        local contact = load_contact(d.namespace_id, d.contact_uuid)
        if not contact then
            db.query("UPDATE mkt_deliveries SET state = 'skipped', reason = 'contact_missing', updated_at = NOW() WHERE id = ?", d.id)
            return nil, "contact_missing"
        end
        contact.namespace_id = d.namespace_id
        contact.address = d.address

        local settings = U.settings(d.namespace_id)
        if not rate_ok(d.namespace_id, d.channel, settings) then
            return d, "rate_limited" -- leave queued for next tick
        end

        -- CRITICAL: re-check eligibility at send time
        campaign.namespace_id = d.namespace_id
        local gate = E.check(contact, campaign, d.channel, campaign.message_type or "marketing")
        if not gate.allowed then
            db.query([[
                UPDATE mkt_deliveries SET state = 'skipped', eligibility_reason = ?, reason = ?,
                    updated_at = NOW()
                WHERE id = ?
            ]], gate.reason, gate.reason, d.id)
            return U.one("SELECT * FROM mkt_deliveries WHERE id = ?", d.id), gate.reason
        end

        local adapter = Channels.get(d.channel)
        if not adapter then
            db.query("UPDATE mkt_deliveries SET state = 'failed', reason = 'unknown_channel', failed_at = NOW(), updated_at = NOW() WHERE id = ?", d.id)
            return nil, "unknown_channel"
        end

        local base = settings.public_base_url or ""
        local unsub = Tokens.unsubscribe_url(d.namespace_id, d.contact_uuid, d.channel, campaign.list_id, base)
        local pixel = d.channel == "email" and Tokens.open_pixel_url(d.namespace_id, d.uuid, base) or nil

        local variant_key, content = Camp.pick_variant(campaign, d.contact_uuid)
        local template = {
            subject = content.subject,
            body_html = content.body_html,
            body_text = content.body_text,
        }
        if campaign.template_id and not content.body_html then
            local t = U.one("SELECT * FROM mkt_templates WHERE id = ? AND namespace_id = ?", campaign.template_id, d.namespace_id)
            if t then
                template.subject = content.subject or t.subject
                template.body_html = content.body_html or t.body_html
                template.body_text = content.body_text or t.body_text
            end
        end

        local payload, rerr = adapter.render(template, merge_context(contact, campaign), {
            unsubscribe_url = unsub,
            open_pixel_url = pixel,
        })
        if not payload then
            db.query("UPDATE mkt_deliveries SET state = 'failed', reason = ?, failed_at = NOW(), updated_at = NOW() WHERE id = ?",
                tostring(rerr):sub(1, 200), d.id)
            return nil, rerr
        end

        local vok, verr = adapter.validate_message({
            subject = payload.subject, html = payload.html, text = payload.text, to = d.address,
        }, { address = d.address })
        if not vok then
            db.query("UPDATE mkt_deliveries SET state = 'failed', reason = ?, failed_at = NOW(), updated_at = NOW() WHERE id = ?",
                tostring(verr):sub(1, 200), d.id)
            return nil, verr
        end

        local result = adapter.send(payload, { address = d.address, email = contact.email, phone = contact.phone }, {
            namespace_id = d.namespace_id,
            settings = settings,
            delivery_uuid = d.uuid,
            from_email = campaign.from_email,
            from_name = campaign.from_name,
            reply_to = campaign.reply_to,
            unsubscribe_url = unsub,
        })

        local state = result.state or "unknown"
        if state == "accepted" then
            db.query([[
                UPDATE mkt_deliveries SET state = 'accepted', provider_message_id = ?, reason = ?,
                    subject = ?, body_html = ?, body_text = ?, eligibility_reason = ?,
                    variant_key = ?, accepted_at = NOW(), updated_at = NOW()
                WHERE id = ?
            ]], result.provider_message_id or db.NULL, result.reason or db.NULL, payload.subject or db.NULL,
                payload.html and payload.html:sub(1, 200000) or db.NULL,
                payload.text and payload.text:sub(1, 50000) or db.NULL,
                gate.reason or db.NULL, variant_key or db.NULL, d.id)
            pcall(function()
                require("helper.plugin-sdk").emit(d.namespace_id, "opsapi_marketing.delivery.accepted", {
                    delivery_uuid = d.uuid, campaign_uuid = campaign.uuid, channel = d.channel,
                })
            end)
        elseif state == "failed" or state == "bounced" then
            db.query([[
                UPDATE mkt_deliveries SET state = ?, reason = ?, failed_at = NOW(), updated_at = NOW()
                WHERE id = ?
            ]], state, result.reason, d.id)
        else
            db.query([[
                UPDATE mkt_deliveries SET state = ?, reason = ?, updated_at = NOW() WHERE id = ?
            ]], state, result.reason, d.id)
        end

        return U.one("SELECT * FROM mkt_deliveries WHERE id = ?", d.id)
    end)
end

--- Process up to `limit` queued deliveries for a namespace (used by campaign_sender job).
function S.process_queue(ns, limit)
    limit = tonumber(limit) or 50
    -- Only campaigns currently sending (paused/cancelled deliveries stay queued or get skipped in dispatch)
    local rows = db.query([[
        SELECT d.id FROM mkt_deliveries d
        JOIN mkt_campaigns c ON c.id = d.campaign_id
        WHERE d.namespace_id = ? AND d.state = 'queued' AND c.status = 'sending'
        ORDER BY d.queued_at ASC
        LIMIT ?
    ]], ns, limit)
    local sent, skipped, failed = 0, 0, 0
    for _, r in ipairs(rows) do
        local d, err = S.dispatch(r.id)
        if err == "not_found_or_locked" or err == "campaign_paused" then
            -- leave for later
        elseif d and d.state == "accepted" then sent = sent + 1
        elseif d and d.state == "skipped" then skipped = skipped + 1
        elseif err == "rate_limited" then break
        elseif err == "budget_exhausted" then
            -- Cap reached: skip remaining queued for this campaign
            if d and d.campaign_id then
                local n = db.query([[
                    UPDATE mkt_deliveries SET state = 'skipped', reason = 'budget_exhausted', updated_at = NOW()
                    WHERE campaign_id = ? AND state = 'queued'
                ]], d.campaign_id)
                skipped = skipped + (n and n.affected_rows or 0)
            end
            break
        else failed = failed + 1 end
    end
    return { sent = sent, skipped = skipped, failed = failed, claimed = #rows }
end

--- Start a scheduled/sending campaign: materialise recipients from list, enqueue, emit.
function S.start_campaign(ns, campaign_id)
    local campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?", campaign_id, ns)
    if not campaign then return nil, "not_found" end
    if campaign.status ~= "scheduled" and campaign.status ~= "sending" and campaign.status ~= "validated" then
        return nil, "bad_status:" .. tostring(campaign.status)
    end

    return U.tx(function()
        db.query([[
            UPDATE mkt_campaigns SET status = 'sending', started_at = COALESCE(started_at, NOW()), updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], campaign_id, ns)
        campaign.status = "sending"

        local members
        if campaign.list_id then
            local list = U.one("SELECT list_type FROM mkt_lists WHERE id = ? AND namespace_id = ?",
                campaign.list_id, ns)
            if list and list.list_type == "dynamic" then
                pcall(function()
                    require("opsapi_marketing.segments").sync_list(ns, campaign.list_id)
                end)
            end
            members = db.query([[
                SELECT contact_uuid FROM mkt_list_members
                WHERE namespace_id = ? AND list_id = ? AND removed_at IS NULL
            ]], ns, campaign.list_id)
        else
            members = db.query([[
                SELECT contact_uuid FROM mkt_campaign_recipients
                WHERE namespace_id = ? AND campaign_id = ? AND excluded = false
            ]], ns, campaign_id)
        end

        local max = tonumber(campaign.max_deliveries)
        local queued = 0
        for _, m in ipairs(members or {}) do
            if max and queued >= max then break end
            local row = S.enqueue(ns, campaign, m.contact_uuid)
            if row then queued = queued + 1 end
        end

        require("helper.plugin-sdk").emit(ns, "opsapi_marketing.campaign.sending", {
            campaign_uuid = campaign.uuid, queued = queued,
        })
        return { campaign = U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign_id), queued = queued }
    end)
end

return S
