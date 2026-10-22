-- Campaigns CRUD + full lifecycle (validate, approve, schedule, pause/resume, A/B, stats).
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local U = require("opsapi_marketing.util")
local E = require("opsapi_marketing.eligibility")
local Camp = require("opsapi_marketing.campaigns")
local Send = require("opsapi_marketing.send")
local cjson = require("cjson")
local db = require("lapis.db")

return function(app)
    -- status is driven only by the lifecycle routes below (validate/approve/schedule/...),
    -- never by create/update — otherwise an update could skip validation or approval.
    local FIELDS = {
        name = { type = "string", required = true },
        objective = { type = "text" },
        channel = { type = "string", required = true, enum = { "email", "sms", "push", "webhook" } },
        message_type = { type = "string", enum = { "marketing", "transactional", "other" } },
        subject = { type = "string", max = 998 },
        preview_text = { type = "string", max = 255 },
        body_html = { type = "text" },
        body_text = { type = "text" },
        from_email = { type = "email" },
        from_name = { type = "string" },
        reply_to = { type = "email" },
        scheduled_at = { type = "datetime" },
        approval_required = { type = "boolean" },
        max_deliveries = { type = "integer", min = 1 },
        -- { track_opens, track_clicks, attribution, utm = { enabled, source, medium, campaign, content },
        --   goal_event }
        tracking = { type = "json" },
    }

    local R = sdk.crud(app, "/campaigns", {
        table = "mkt_campaigns",
        module = "opsapi_marketing_campaigns",
        only = { "list", "show", "create", "delete" },
        fields = FIELDS,
        searchable = { "name", "subject", "status", "channel" },
        filterable = { "status", "channel", "message_type" },
        sortable = { "name", "status", "channel", "scheduled_at", "created_at", "updated_at" },
        ui = {
            label = "Campaigns",
            columns = { "name", "channel", "message_type", "scheduled_at" },
            form = { "name", "channel", "message_type", "subject", "preview_text",
                     "from_email", "from_name", "body_html", "body_text", "scheduled_at",
                     "approval_required", "max_deliveries", "objective" },
        },
    })

    -- What changes the message or who gets it: re-validation (and re-approval) required.
    local REVALIDATE = {
        channel = true, message_type = true, subject = true, preview_text = true, body_html = true,
        body_text = true, from_email = true, from_name = true, reply_to = true, approval_required = true,
    }

    app:put("/campaigns/:id", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        if not Camp.editable(campaign.status) then
            return sdk.error(409, "Campaign can't be edited while " .. tostring(campaign.status)
                .. " — pause it first, or duplicate it.", { code = "not_editable" })
        end
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local data, errors = sdk.validate(body, FIELDS, true)
        if not data then return sdk.error(422, "Validation failed", errors) end
        local row, status, msg = R.update(ns, campaign.uuid, data)
        if status then return sdk.error(status, msg) end
        if not row then return sdk.not_found("campaign") end

        local changed = false
        for k in pairs(data) do
            if REVALIDATE[k] then changed = true end
        end
        if changed and (campaign.status == "validated" or campaign.status == "awaiting_approval") then
            db.query([[
                UPDATE mkt_campaigns SET status = 'draft', approved_by = NULL, approved_at = NULL, updated_at = NOW()
                WHERE id = ?
            ]], campaign.id)
            row = Camp.find(ns, campaign.id)
        end
        return sdk.ok(row)
    end))

    app:get("/campaigns/:id/stats", sdk.handler({ permission = "opsapi_marketing_campaigns.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        return sdk.ok(Camp.delivery_stats(ns, campaign.id))
    end))

    local function fail(err)
        return sdk.error(400, Camp.friendly_error(err), { code = err })
    end

    local function read_body(self)
        local body, berr = sdk.body(self)
        if not body then return nil, sdk.error(400, berr) end
        return body
    end

    app:post("/campaigns/:id/audience-preview", sdk.handler({ permission = "opsapi_marketing_campaigns.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body, bad = read_body(self)
        if not body then return bad end
        if body.list_uuid then
            local list = U.one("SELECT id FROM mkt_lists WHERE namespace_id = ? AND uuid = ?", ns, body.list_uuid)
            if list then
                db.query("UPDATE mkt_campaigns SET list_id = ? WHERE id = ?", list.id, campaign.id)
                campaign.list_id = list.id
            end
        end
        local preview, err = Camp.audience_preview(ns, campaign, body)
        if not preview then return fail(err) end
        return sdk.ok(preview)
    end))

    app:post("/campaigns/:id/validate", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body, bad = read_body(self)
        if not body then return bad end
        if body.list_uuid then
            local list = U.one("SELECT id FROM mkt_lists WHERE namespace_id = ? AND uuid = ?", ns, body.list_uuid)
            if not list then return fail("list_not_found") end
            db.query("UPDATE mkt_campaigns SET list_id = ? WHERE id = ?", list.id, campaign.id)
        end
        local out, err = Camp.validate(ns, campaign.id, body)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    app:post("/campaigns/:id/request-approval", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body, bad = read_body(self)
        if not body then return bad end
        local out, err = Camp.request_approval(ns, campaign.id, body.notes)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    -- Approval is a privileged action; owners/admins hold manage (or update via role grants).
    app:post("/campaigns/:id/approve", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local user = sdk.user(self) or {}
        local out, err = Camp.approve(ns, campaign.id, user.uuid)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    -- Owners/admins often have manage; also allow update if can() says so — fallback to update for owners
    app:post("/campaigns/:id/reject", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body, bad = read_body(self)
        if not body then return bad end
        local out, err = Camp.reject(ns, campaign.id, body.reason)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    app:post("/campaigns/:id/schedule", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body, bad = read_body(self)
        if not body then return bad end
        local out, err = Camp.schedule(ns, campaign.id, body)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    app:post("/campaigns/:id/pause", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local out, err = Camp.pause(ns, campaign.id)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    app:post("/campaigns/:id/resume", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local out, err = Camp.resume(ns, campaign.id)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    app:post("/campaigns/:id/cancel", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local out, err = Camp.cancel(ns, campaign.id)
        if not out then return fail(err) end
        return sdk.ok(out)
    end))

    app:post("/campaigns/:id/duplicate", sdk.handler({ permission = "opsapi_marketing_campaigns.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body, bad = read_body(self)
        if not body then return bad end
        local out, err = Camp.duplicate(ns, campaign.id, body.name)
        if not out then return fail(err) end
        return sdk.created(out)
    end))

    app:put("/campaigns/:id/ab-config", sdk.handler({ permission = "opsapi_marketing_campaigns.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        if campaign.status ~= "draft" and campaign.status ~= "validated" then
            return sdk.error(400, "ab_config only editable in draft/validated")
        end
        local body = sdk.body(self) or {}
        local ab = body.ab_config or body
        if type(ab.variants) ~= "table" or #ab.variants < 2 then
            return sdk.error(400, "ab_config.variants needs at least 2 variants")
        end
        for _, v in ipairs(ab.variants) do
            if type(v.key) ~= "string" or v.key == "" then
                return sdk.error(400, "each variant needs a key")
            end
        end
        ab.enabled = ab.enabled ~= false
        db.query("UPDATE mkt_campaigns SET ab_config = ?::jsonb, updated_at = NOW() WHERE id = ?",
            cjson.encode(ab), campaign.id)
        return sdk.ok(U.one("SELECT * FROM mkt_campaigns WHERE id = ?", campaign.id))
    end))

    app:post("/campaigns/:id/eligibility", sdk.handler({ permission = "opsapi_marketing_campaigns.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body = sdk.body(self) or {}
        local contact_uuid = body.contact_uuid
        if not U.is_uuid(contact_uuid) then return sdk.error(400, "contact_uuid required") end
        local contact = U.one([[
            SELECT uuid, namespace_id, first_name, last_name, email, phone, mobile, status, deleted_at
            FROM crm_contacts WHERE namespace_id = ? AND uuid = ?
        ]], ns, contact_uuid)
        if not contact then return sdk.not_found("contact") end
        campaign.namespace_id = ns
        campaign.skip_quiet_hours = body.skip_quiet_hours == true
        return sdk.ok(E.check(contact, campaign, campaign.channel, campaign.message_type))
    end))

    app:post("/campaigns/:id/test-send", sdk.handler({ permission = "opsapi_marketing_campaigns.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        local body = sdk.body(self) or {}
        if not U.is_uuid(body.contact_uuid) then return sdk.error(400, "contact_uuid required") end
        campaign.namespace_id = ns
        campaign.skip_quiet_hours = true
        local row, err = Send.enqueue(ns, campaign, body.contact_uuid, {
            attempt_key = "test-" .. tostring(ngx.time()),
            send_now = true,
        })
        if not row then return sdk.error(400, err) end
        return sdk.ok(row)
    end))
end
