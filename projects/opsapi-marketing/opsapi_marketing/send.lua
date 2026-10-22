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
local Links = require("opsapi_marketing.links")

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
        SELECT c.uuid, c.namespace_id, c.first_name, c.last_name, c.email, c.phone, c.mobile, c.status,
               c.deleted_at, c.account_id, c.metadata, a.name AS account_name
        FROM crm_contacts c
        LEFT JOIN crm_accounts a ON a.id = c.account_id AND a.namespace_id = c.namespace_id
        WHERE c.namespace_id = ? AND c.uuid = ? AND c.deleted_at IS NULL
    ]], ns, contact_uuid)
end

-- The same registry context the preview uses (defaults such as "there" for a missing first
-- name). Company: the CRM account, else the company an import recorded on the contact.
local function merge_context(ns, contact, campaign, links)
    local meta = U.json(contact.metadata)
    if type(meta) ~= "table" then meta = {} end
    return require("opsapi_marketing.merge_fields").build_context(ns, {
        contact = {
            first_name = contact.first_name,
            last_name = contact.last_name,
            email = contact.email,
            phone = contact.phone or contact.mobile,
            company = contact.account_name or meta.company,
        },
        campaign = { name = campaign.name },
        unsubscribe_url = links.unsubscribe_url,
        preferences_url = links.preferences_url,
    })
end

--- Absolute base for tracking/unsubscribe links: workspace setting, else OPSAPI_PUBLIC_URL.
function S.public_base(settings)
    local base = settings and settings.public_base_url or ""
    if base == "" then base = os.getenv("OPSAPI_PUBLIC_URL") or "" end
    return (base:gsub("/+$", ""))
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
    elseif channel == "sms" then address = U.e164(contact.phone or contact.mobile) end
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
        return S.dispatch(row.id, { skip_quiet_hours = campaign.skip_quiet_hours })
    end
    return row
end

--- Claim and send one queued delivery by id. Re-checks can_send.
-- opts.skip_quiet_hours: test sends (the campaign row is reloaded, so it's passed here).
function S.dispatch(delivery_id, opts)
    opts = opts or {}
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
        campaign.skip_quiet_hours = opts.skip_quiet_hours
        local gate = E.check(contact, campaign, d.channel, campaign.message_type or "marketing")
        if gate.reason == "quiet_hours" then
            return d, "quiet_hours" -- defer: stays queued and goes out when quiet hours end
        end
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

        local base = S.public_base(settings)
        local unsub = Tokens.unsubscribe_url(d.namespace_id, d.contact_uuid, d.channel, campaign.list_id, base)
        local variant_key, content = Camp.pick_variant(campaign, d.contact_uuid)

        -- Tracking: open pixel, UTM tagging and click-through rewrite (email only). Without a
        -- public base URL the links would be relative and broken, so only UTM is applied.
        local tracking = U.json(campaign.tracking)
        if type(tracking) ~= "table" then tracking = {} end
        local pixel = d.channel == "email" and base ~= "" and tracking.track_opens ~= false
            and Tokens.open_pixel_url(d.namespace_id, d.uuid, base) or nil
        local link_rewriter
        if d.channel == "email" then
            local utm = Links.utm_params(campaign, tracking, variant_key)
            link_rewriter = function(url)
                local tagged = Links.add_params(url, utm)
                if base == "" or tracking.track_clicks == false then return tagged end
                return Tokens.click_url(d.namespace_id, d.uuid, tagged, base)
            end
        end
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

        local prefs = base ~= "" and Tokens.preferences_url(d.namespace_id, d.contact_uuid, base) or nil
        local merge = merge_context(d.namespace_id, contact, campaign, { unsubscribe_url = unsub, preferences_url = prefs })
        local payload, rerr = adapter.render(template, merge, {
            unsubscribe_url = unsub,
            open_pixel_url = pixel,
            link_rewriter = link_rewriter,
            link_skip = { "/public/unsubscribe", "/public/preferences", "/public/c?" },
            preheader = campaign.preview_text,
            sender_address = settings.sender_address,
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
    local settings = U.settings(ns)
    -- Default: as many as the per-minute rate allows (the rate limiter still applies per message).
    limit = tonumber(limit) or math.min(500, math.max(tonumber(settings.email_rate_per_min) or 60,
        tonumber(settings.sms_rate_per_min) or 30))
    -- Only campaigns currently sending (paused/cancelled deliveries stay queued or get skipped in dispatch),
    -- and only deliveries whose batch is due. In quiet hours marketing messages wait in the queue.
    local quiet = U.in_quiet_hours(ns, settings.quiet_hours_from or "21:00", settings.quiet_hours_to or "08:00")
    local rows = db.query([[
        SELECT d.id FROM mkt_deliveries d
        JOIN mkt_campaigns c ON c.id = d.campaign_id
        WHERE d.namespace_id = ? AND d.state = 'queued' AND c.status = 'sending'
          AND (d.send_after IS NULL OR d.send_after <= NOW())
          AND (? = false OR c.message_type <> 'marketing')
        ORDER BY COALESCE(d.send_after, d.queued_at), d.id
        LIMIT ?
    ]], ns, quiet, limit)
    local sent, skipped, failed = 0, 0, 0
    for _, r in ipairs(rows) do
        local d, err = S.dispatch(r.id)
        if err == "not_found_or_locked" or err == "campaign_paused" or err == "quiet_hours" then
            -- leave for later
        elseif err == "rate_limited" then break
        elseif err == "budget_exhausted" then
            -- Cap reached: skip remaining queued for this campaign
            if d and d.campaign_id then
                local n = db.query([[
                    UPDATE mkt_deliveries SET state = 'skipped', reason = 'budget_exhausted', updated_at = NOW()
                    WHERE campaign_id = ? AND state = 'queued'
                ]], d.campaign_id)
                skipped = skipped + 1 + (n and n.affected_rows or 0)
            end
            break
        elseif d and d.state == "accepted" then sent = sent + 1
        elseif d and d.state == "skipped" then skipped = skipped + 1
        else failed = failed + 1 end
    end
    return { sent = sent, skipped = skipped, failed = failed, claimed = #rows }
end

--- Queue an email campaign's whole list in one statement (bought lists run to tens of
-- thousands; one INSERT … SELECT, not a query per contact). One delivery per address.
-- With batches set, the nth waits until floor(n / batch_size) * interval from now:
-- e.g. 400 now, 400 an hour later, ...
local function enqueue_list_email(ns, campaign)
    local done = U.one("SELECT COUNT(*)::int AS n FROM mkt_deliveries WHERE campaign_id = ? AND attempt_key = '1'",
        campaign.id).n
    local max = tonumber(campaign.max_deliveries)
    local room = max and math.max(0, max - done) or 2147483647
    local size, every = tonumber(campaign.batch_size), tonumber(campaign.batch_interval_minutes)
    local batched = (size and size > 0 and every and every > 0) and true or false
    local res = db.query([==[
        WITH audience AS (
            SELECT a.*, row_number() OVER (ORDER BY a.member_id) - 1 AS n
            FROM (
                SELECT DISTINCT ON (lower(trim(c.email)))
                       m.id AS member_id, m.contact_uuid, lower(trim(c.email)) AS address,
                       NULLIF(trim(concat_ws(' ', c.first_name, c.last_name)), '') AS display_name
                FROM mkt_list_members m
                JOIN crm_contacts c ON c.uuid = m.contact_uuid AND c.namespace_id = m.namespace_id
                                    AND c.deleted_at IS NULL
                WHERE m.namespace_id = ? AND m.list_id = ? AND m.removed_at IS NULL
                  AND lower(trim(c.email)) ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
                  AND NOT EXISTS (SELECT 1 FROM mkt_deliveries d
                                  WHERE d.campaign_id = ? AND d.attempt_key = '1'
                                    AND (d.contact_uuid = m.contact_uuid OR d.address = lower(trim(c.email))))
                ORDER BY lower(trim(c.email)), m.id
            ) a
            ORDER BY a.member_id
            LIMIT ?
        ), recipients AS (
            INSERT INTO mkt_campaign_recipients (namespace_id, campaign_id, contact_uuid, address, display_name)
            SELECT ?, ?, contact_uuid, address, display_name FROM audience
            ON CONFLICT (namespace_id, campaign_id, contact_uuid) DO NOTHING
        )
        INSERT INTO mkt_deliveries (namespace_id, campaign_id, contact_uuid, channel, address, attempt_key,
            state, send_after)
        SELECT ?, ?, contact_uuid, 'email', address, '1', 'queued',
               CASE WHEN ? THEN NOW() + (n / ?) * make_interval(mins => ?) END
        FROM audience
        ON CONFLICT (namespace_id, campaign_id, contact_uuid, channel, attempt_key) DO NOTHING
    ]==], ns, campaign.list_id, campaign.id, room, ns, campaign.id, ns, campaign.id,
        batched, batched and size or 1, batched and every or 0)
    return res.affected_rows or 0
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
            if (campaign.channel or "email") ~= "email" then
                members = db.query([[
                    SELECT contact_uuid FROM mkt_list_members
                    WHERE namespace_id = ? AND list_id = ? AND removed_at IS NULL
                ]], ns, campaign.list_id)
            end
        else
            members = db.query([[
                SELECT contact_uuid FROM mkt_campaign_recipients
                WHERE namespace_id = ? AND campaign_id = ? AND excluded = false
            ]], ns, campaign_id)
        end

        local max = tonumber(campaign.max_deliveries)
        local queued = 0
        if not members then
            queued = enqueue_list_email(ns, campaign)
        end
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
