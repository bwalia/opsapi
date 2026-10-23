--[[
    Authoritative send eligibility gate.

    can_send(contact, campaign, channel, message_type) -> { allowed, reason }

    EVERY send path (preview test, scheduled, retry, bulk, AI-proposed) MUST call
    this immediately before handing a message to a channel provider. Suppression
    and unsubscribe beat campaign membership, segments, and AI recommendations.
    The AI agent cannot override this.
]]
local db = require("lapis.db")
local U = require("opsapi_marketing.util")

local E = {}

local function deny(reason)
    return { allowed = false, reason = reason }
end

local function allow(reason)
    return { allowed = true, reason = reason or "ok" }
end

local function log_decision(ns, campaign_id, contact_uuid, channel, message_type, result)
    pcall(db.query, [[
        INSERT INTO mkt_eligibility_log
            (namespace_id, campaign_id, contact_uuid, channel, message_type, allowed, reason)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], ns, campaign_id, contact_uuid, channel, message_type, result.allowed, result.reason)
end

local function contact_address(contact, channel)
    if channel == "email" then
        return U.norm_email(contact.email or contact.address)
    elseif channel == "sms" then
        return U.e164(contact.phone or contact.mobile or contact.address)
    end
    return contact.address
end

local function is_suppressed(ns, channel, address, contact_uuid)
    if address then
        local row = U.one([[
            SELECT id, reason FROM mkt_suppressions
            WHERE namespace_id = ?
              AND lower(address) = lower(?)
              AND (channel IS NULL OR channel = ?)
            LIMIT 1
        ]], ns, address, channel)
        if row then return true, row.reason end
    end
    if contact_uuid then
        local row = U.one([[
            SELECT id, reason FROM mkt_suppressions
            WHERE namespace_id = ?
              AND contact_uuid = ?
              AND (channel IS NULL OR channel = ?)
            LIMIT 1
        ]], ns, contact_uuid, channel)
        if row then return true, row.reason end
    end
    return false
end

local function subscription_blocks(ns, contact_uuid, channel, list_id, message_type)
    local global = U.one([[
        SELECT status FROM mkt_subscriptions
        WHERE namespace_id = ? AND contact_uuid = ? AND channel = ? AND list_id IS NULL
        ORDER BY changed_at DESC LIMIT 1
    ]], ns, contact_uuid, channel)

    if global and global.status == "unsubscribed" then
        return true, "unsubscribed_global"
    end

    if message_type == "transactional" then
        return false
    end

    if list_id then
        local list_sub = U.one([[
            SELECT status FROM mkt_subscriptions
            WHERE namespace_id = ? AND contact_uuid = ? AND channel = ? AND list_id = ?
            ORDER BY changed_at DESC LIMIT 1
        ]], ns, contact_uuid, channel, list_id)
        if list_sub and list_sub.status == "unsubscribed" then
            return true, "unsubscribed_list"
        end
        if list_sub and list_sub.status == "subscribed" then
            return false
        end
    end

    if global and global.status == "subscribed" then
        return false
    end

    return true, "no_marketing_consent"
end

local function frequency_cap_hit(ns, contact_uuid, channel, message_type, settings)
    if message_type ~= "marketing" then return false end
    local days = tonumber(settings.marketing_frequency_cap_days) or 7
    local cap = tonumber(settings.marketing_frequency_cap_count) or 3
    -- Messages already sent or mid-send (parallel sends), not queued ones: the delivery
    -- being checked is itself queued, so counting queued made a cap of N allow only N-1
    -- (and 1 allow none). Test sends don't count.
    local row = U.one([[
        SELECT COUNT(*)::int AS n FROM mkt_deliveries
        WHERE namespace_id = ? AND contact_uuid = ? AND channel = ?
          AND attempt_key NOT LIKE 'test-%'
          AND ((state IN ('accepted', 'delivered') AND accepted_at > NOW() - make_interval(days => ?))
               OR state = 'sending')
    ]], ns, contact_uuid, channel, days)
    return row and row.n >= cap
end

--- contact: { uuid|contact_uuid, namespace_id, email?, phone?, mobile?, address?, status?, deleted_at? }
--- campaign: { id?, namespace_id?, list_id?, message_type?, channel?, skip_quiet_hours? } or nil
function E.can_send(contact, campaign, channel, message_type)
    channel = channel or (campaign and campaign.channel) or "email"
    message_type = message_type or (campaign and campaign.message_type) or "marketing"

    if not U.CHANNELS[channel] then
        return deny("invalid_channel")
    end
    if not U.MESSAGE_TYPES[message_type] then
        return deny("invalid_message_type")
    end
    if type(contact) ~= "table" then
        return deny("invalid_contact")
    end

    local ns = contact.namespace_id or (campaign and campaign.namespace_id)
    if not ns then
        return deny("missing_namespace")
    end

    local contact_uuid = contact.uuid or contact.contact_uuid
    if not contact_uuid then
        return deny("missing_contact_uuid")
    end

    if contact.deleted_at then
        return deny("contact_deleted")
    end
    if contact.status and contact.status ~= "active" then
        return deny("contact_inactive")
    end

    local address = contact_address(contact, channel)
    if channel == "email" or channel == "sms" then
        if not address then
            return deny(channel == "email" and "invalid_email" or "invalid_phone")
        end
    end

    local suppressed, sreason = is_suppressed(ns, channel, address, contact_uuid)
    if suppressed then
        return deny("suppressed" .. (sreason and (":" .. sreason) or ""))
    end

    -- A test send goes to one address the sender chose (often their own): no consent or
    -- frequency checks, but anyone who unsubscribed (above) still never gets it.
    local test = campaign and campaign.test_send
    local list_id = campaign and campaign.list_id or nil
    local blocked, breason = subscription_blocks(ns, contact_uuid, channel, list_id, message_type)
    if blocked and not test then
        return deny(breason)
    end

    local settings = U.settings(ns)
    if message_type == "marketing" and not (campaign and campaign.skip_quiet_hours) then
        local qf = settings.quiet_hours_from or "21:00"
        local qt = settings.quiet_hours_to or "08:00"
        if U.in_quiet_hours(ns, qf, qt) then
            return deny("quiet_hours")
        end
    end

    if not test and frequency_cap_hit(ns, contact_uuid, channel, message_type, settings) then
        return deny("frequency_cap")
    end

    if campaign and campaign.id and not test then
        local excl = U.one([[
            SELECT id FROM mkt_campaign_recipients
            WHERE campaign_id = ? AND contact_uuid = ? AND excluded = true
            LIMIT 1
        ]], campaign.id, contact_uuid)
        if excl then
            return deny("campaign_excluded")
        end
    end

    return allow("eligible")
end

function E.check(contact, campaign, channel, message_type)
    local result = E.can_send(contact, campaign, channel, message_type)
    local ns = contact and (contact.namespace_id or (campaign and campaign.namespace_id))
    if ns then
        log_decision(ns, campaign and campaign.id, contact.uuid or contact.contact_uuid,
            channel or "email", message_type or "marketing", result)
    end
    return result
end

local function sql_null(v)
    if v == nil then return db.NULL end
    return v
end

--- Immediate unsubscribe / STOP. Idempotent. Takes effect before return.
function E.opt_out(ns, contact_uuid, channel, opts)
    opts = opts or {}
    channel = channel or "email"
    local address = opts.address and U.lower(opts.address) or nil
    local list_id = sql_null(opts.list_id)
    local source = opts.source or "unsubscribe"
    local reason = opts.reason or "unsubscribe"
    local evidence = sql_null(opts.evidence)

    U.tx(function()
        local prev
        if opts.list_id then
            prev = U.one([[
                SELECT id, status FROM mkt_subscriptions
                WHERE namespace_id = ? AND contact_uuid = ? AND channel = ? AND list_id = ?
                LIMIT 1
            ]], ns, contact_uuid, channel, opts.list_id)
        else
            prev = U.one([[
                SELECT id, status FROM mkt_subscriptions
                WHERE namespace_id = ? AND contact_uuid = ? AND channel = ? AND list_id IS NULL
                LIMIT 1
            ]], ns, contact_uuid, channel)
        end

        if prev then
            db.query([[
                UPDATE mkt_subscriptions SET status = 'unsubscribed', source = ?, evidence = ?,
                    changed_at = NOW(), updated_at = NOW()
                WHERE id = ?
            ]], source, evidence, prev.id)
        else
            db.query([[
                INSERT INTO mkt_subscriptions
                    (namespace_id, contact_uuid, channel, list_id, status, source, evidence)
                VALUES (?, ?, ?, ?, 'unsubscribed', ?, ?)
            ]], ns, contact_uuid, channel, list_id, source, evidence)
        end

        db.query([[
            INSERT INTO mkt_subscription_events
                (namespace_id, contact_uuid, channel, list_id, previous_status, new_status, source, evidence)
            VALUES (?, ?, ?, ?, ?, 'unsubscribed', ?, ?)
        ]], ns, contact_uuid, channel, list_id, sql_null(prev and prev.status), source, evidence)

        if address then
            local s = U.one([[
                SELECT id FROM mkt_suppressions
                WHERE namespace_id = ? AND lower(address) = lower(?) AND channel = ?
            ]], ns, address, channel)
            if not s then
                db.query([[
                    INSERT INTO mkt_suppressions
                        (namespace_id, channel, address, contact_uuid, reason, source)
                    VALUES (?, ?, ?, ?, ?, ?)
                ]], ns, channel, address, contact_uuid, reason, source)
            end
        end
    end)

    pcall(function()
        require("helper.plugin-sdk").emit(ns, "opsapi_marketing.subscription.opted_out", {
            contact_uuid = contact_uuid, channel = channel, list_id = list_id, source = source,
        })
    end)

    return true
end

--- Authorised consent grant. AI tools must never call this.
function E.opt_in(ns, contact_uuid, channel, opts)
    opts = opts or {}
    if not opts.source or opts.source == "ai" or opts.source == "agent" then
        return nil, "consent requires an authorised human/system source"
    end
    channel = channel or "email"
    local list_id = sql_null(opts.list_id)
    local evidence = sql_null(opts.evidence)
    local legal_basis = sql_null(opts.legal_basis)
    local actor = sql_null(opts.actor_uuid)

    U.tx(function()
        local existing
        if opts.list_id then
            existing = U.one([[
                SELECT id, status FROM mkt_subscriptions
                WHERE namespace_id = ? AND contact_uuid = ? AND channel = ? AND list_id = ?
            ]], ns, contact_uuid, channel, opts.list_id)
        else
            existing = U.one([[
                SELECT id, status FROM mkt_subscriptions
                WHERE namespace_id = ? AND contact_uuid = ? AND channel = ? AND list_id IS NULL
            ]], ns, contact_uuid, channel)
        end
        if existing then
            db.query([[
                UPDATE mkt_subscriptions SET status = 'subscribed', legal_basis = ?, source = ?,
                    evidence = ?, changed_at = NOW(), updated_at = NOW()
                WHERE id = ?
            ]], legal_basis, opts.source, evidence, existing.id)
        else
            db.query([[
                INSERT INTO mkt_subscriptions
                    (namespace_id, contact_uuid, channel, list_id, status, legal_basis, source, evidence)
                VALUES (?, ?, ?, ?, 'subscribed', ?, ?, ?)
            ]], ns, contact_uuid, channel, list_id, legal_basis, opts.source, evidence)
        end
        db.query([[
            INSERT INTO mkt_subscription_events
                (namespace_id, contact_uuid, channel, list_id, previous_status, new_status, source, evidence, actor_uuid)
            VALUES (?, ?, ?, ?, ?, 'subscribed', ?, ?, ?)
        ]], ns, contact_uuid, channel, list_id, sql_null(existing and existing.status),
            opts.source, evidence, actor)
    end)
    return true
end

return E
