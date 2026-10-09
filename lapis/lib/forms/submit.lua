--[[
    Public form submission (POST /api/v2/public/forms/:public_id/submissions)
    ========================================================================

    1. Bot checks: the honeypot must be empty and the render token (issued by
       the public GET) must be valid and between MIN_FILL_SECONDS and a day
       old. A failure is answered like a success (no signal to the bot) and
       stored as spam: no targets, no emails.
    2. Answers are validated against the PUBLISHED version (Fields.validate).
    3. One transaction:
         - claim a slot atomically (status, close date and max_submissions are
           checked by the same UPDATE, so concurrent submits can't overshoot);
         - run the form's targets (lib/forms/targets.lua), each in a savepoint;
         - insert the response and its links (Idempotency-Key: a repeat is
           stored once and answered like the first).
    4. After commit: the outbox trigger on form_submissions queues
       form.submission.created (emails: lib/forms/jobs.lua; webhooks); target
       hooks (lead alerts) run.

    Rate limits are the route's job (routes/forms-public.lua).
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")
local Global = require("helper.global")
local Fields = require("lib.forms.fields")
local Targets = require("lib.forms.targets")

local Submit = {}

Submit.MIN_FILL_SECONDS = 2
Submit.TOKEN_TTL_SECONDS = 24 * 3600

local function secret()
    return Global.getEnvVar("JWT_SECRET_KEY") or error("JWT_SECRET_KEY not configured")
end

local function hmac_hex(data)
    local mac = assert(require("resty.openssl.hmac").new(secret(), "sha256")):final(data)
    return (mac:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- A render token for a form (issued by the public GET): "<unix time>.<mac>".
function Submit.render_token(form_id, now)
    now = math.floor(now or ngx.time())
    return now .. "." .. hmac_hex("forms.render:" .. form_id .. ":" .. now):sub(1, 32)
end

--- @param min_age seconds the page must have been open (default MIN_FILL_SECONDS;
--   0 for file uploads, which happen while the visitor fills the form in)
-- @return true | nil, reason
function Submit.check_token(form_id, token, now, min_age)
    now = now or ngx.time()
    local issued, mac = tostring(token or ""):match("^(%d+)%.(%x+)$")
    issued = tonumber(issued)
    if not issued or mac ~= hmac_hex("forms.render:" .. form_id .. ":" .. issued):sub(1, 32) then
        return nil, "bad_token"
    end
    if now - issued < (min_age or Submit.MIN_FILL_SECONDS) then return nil, "too_fast" end
    if now - issued > Submit.TOKEN_TTL_SECONDS then return nil, "token_expired" end
    return true
end

--- Keyed hash of the client IP: lets abuse be correlated without keeping IPs.
function Submit.ip_hash(ip)
    return ip and hmac_hex("forms.ip:" .. ip):sub(1, 24) or nil
end

local function str(v, max)
    if type(v) ~= "string" or v == "" then return nil end
    return Fields.text(v, max) or nil
end

-- The request context the page reports (page URL, referrer, UTM tags), trimmed.
local function client_meta(body, client)
    local c = type(body.context) == "table" and body.context or {}
    local utm = {}
    if type(c.utm) == "table" then
        for _, k in ipairs({ "source", "medium", "campaign", "term", "content" }) do
            utm[k] = str(c.utm[k], 200)
        end
    end
    return {
        ip_hash = Submit.ip_hash(client.ip),
        user_agent = str(client.user_agent, 256),
        referrer = str(c.referrer, 1000),
        page_url = str(c.page_url, 1000),
        utm = next(utm) and utm or nil,
        duration_ms = tonumber(c.duration_ms) and math.floor(math.max(0, math.min(tonumber(c.duration_ms), 86400000)))
            or nil,
    }
end

local function decode(v, fallback)
    if type(v) == "table" then return v end
    if type(v) == "string" and v ~= "" then
        local ok, d = pcall(cjson.decode, v)
        if ok then return d end
    end
    return fallback
end
Submit.decode = decode

--- Run a response's targets (inside the caller's transaction).
-- @return links { target = result }, any_failed
function Submit.run_targets(form, version, answers, submission_uuid, meta, namespace, after_commit)
    local schema = decode(version.schema, { fields = {} })
    local contact, mapped = Fields.contact(schema, answers)
    local links, failed = {}, false
    if not contact.email then return links, false end
    local ctx = {
        namespace_id = namespace.id,
        namespace = namespace,
        form = form,
        contact = contact,
        mapped = mapped,
        meta = meta,
        submission_uuid = submission_uuid,
        published_by_uuid = version.published_by_uuid,
        after_commit = after_commit,
    }
    for _, cfg in ipairs(decode(version.targets, {})) do
        local res = Targets.run(cfg, ctx)
        links[cfg.type] = res
        if res.outcome == "failed" then failed = true end
    end
    return links, failed
end

function Submit.save_links(submission_id, namespace_id, links)
    for target, l in pairs(links) do
        db.query([[
            INSERT INTO form_submission_links
                (submission_id, namespace_id, target, entity_type, entity_uuid, outcome, error_code)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (submission_id, target) DO UPDATE SET entity_type = EXCLUDED.entity_type,
                entity_uuid = EXCLUDED.entity_uuid, outcome = EXCLUDED.outcome,
                error_code = EXCLUDED.error_code, updated_at = NOW()
        ]], submission_id, namespace_id, target, l.entity_type or db.NULL, l.entity_uuid or db.NULL, l.outcome,
            l.error_code or db.NULL)
    end
end

local function run_hooks(hooks)
    for _, fn in ipairs(hooks) do
        local ok, err = pcall(fn)
        if not ok then ngx.log(ngx.WARN, "[forms] after-commit hook failed: ", tostring(err)) end
    end
end

--- Handle one public submission.
-- @param form       forms row joined with its namespace (namespace_name, max_users)
-- @param version    form_versions row of the published version
-- @param body       decoded request body { answers, _hp, render_token, context }
-- @param client     { ip, user_agent, idempotency_key }
-- @return { status, json }
function Submit.handle(form, version, body, client)
    local settings = decode(form.settings, {})
    local done = {
        status = 201,
        json = {
            success = true,
            message = settings.success_message or "Thanks — your response has been received.",
            redirect_url = settings.redirect_url,
        },
    }
    local meta = client_meta(body, client)
    local idem = type(client.idempotency_key) == "string" and client.idempotency_key:match("^[%w%-_]+$")
        and #client.idempotency_key <= 64 and client.idempotency_key or nil

    -- 1. Bots
    local spam
    if body._hp ~= nil and body._hp ~= "" and body._hp ~= cjson.null then
        spam = "honeypot"
    else
        local ok, why = Submit.check_token(form.id, body.render_token)
        if not ok then spam = why end
    end

    -- 2. Answers
    local schema = decode(version.schema, { fields = {} })
    local answers, errors = Fields.validate(schema, type(body.answers) == "table" and body.answers or {})
    if spam then
        -- Stored for review (what was sent, unvalidated, size-capped by the route).
        meta.spam_reason = spam
        local raw = type(body.answers) == "table" and body.answers or {}
        pcall(db.query, [[
            INSERT INTO form_submissions (uuid, namespace_id, form_id, version_id, data, status, meta)
            VALUES (?, ?, ?, ?, ?::jsonb, 'spam', ?::jsonb)
        ]], Global.generateUUID(), form.namespace_id, form.id, version.id, cjson.encode(answers or raw),
            cjson.encode(meta))
        return done
    end
    if not answers then
        return { status = 400, json = { success = false, error = "Please check the highlighted answers.",
            errors = errors } }
    end
    -- The form's "I'm not a robot" check, when the owner turned it on.
    if settings.captcha then
        local _, secret = require("lib.forms.workspace").turnstile(form.namespace_id)
        local ok = secret and require("lib.forms.workspace").verify(secret, body.captcha_token, client.ip)
        if not ok then
            return { status = 400, json = { success = false, code = "captcha",
                error = "Please complete the security check and try again." } }
        end
    end
    -- The workspace's monthly responses, when its plan has a limit.
    local full = require("lib.forms.limits").month_full(form.namespace_id)
    if full then
        return { status = 409, json = { success = false, code = "plan_limit",
            error = settings.closed_message or "This form can't take more responses right now." } }
    end

    -- A repeat of a response already stored: answer like the first time.
    if idem and db.query("SELECT 1 FROM form_submissions WHERE form_id = ? AND idempotency_key = ?",
            form.id, idem)[1] then
        return done
    end
    -- Attached files: this form's, unused, and swapped for their details.
    local Uploads = require("lib.forms.uploads")
    local file_errors
    answers, file_errors = Uploads.resolve(form.id, schema, answers)
    if not answers then
        return { status = 400, json = { success = false, error = "Please check the highlighted answers.",
            errors = file_errors } }
    end

    -- 3. One transaction
    local namespace = { id = form.namespace_id, name = form.namespace_name, max_users = form.max_users }
    local hooks = {}
    local uuid = Global.generateUUID()
    local contact = Fields.contact(schema, answers)
    db.query("BEGIN")
    local ok, res = pcall(function()
        local slot = db.query([[
            UPDATE forms SET submission_count = submission_count + 1, last_submission_at = NOW()
            WHERE id = ? AND status = 'published' AND deleted_at IS NULL
              AND (settings ->> 'close_at' IS NULL OR (settings ->> 'close_at')::timestamptz > NOW())
              AND (settings ->> 'max_submissions' IS NULL
                   OR submission_count < (settings ->> 'max_submissions')::int)
            RETURNING id
        ]], form.id)[1]
        if not slot then return "closed" end

        local links, failed = Submit.run_targets(form, version, answers, uuid, meta, namespace,
            function(fn) hooks[#hooks + 1] = fn end)
        local row = db.query([[
            INSERT INTO form_submissions (uuid, namespace_id, form_id, version_id, data, respondent_email, status,
                idempotency_key, meta, processed_at)
            VALUES (?, ?, ?, ?, ?::jsonb, ?, ?, ?, ?::jsonb, CASE WHEN ? THEN NOW() END)
            ON CONFLICT (form_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
            RETURNING id
        ]], uuid, form.namespace_id, form.id, version.id, cjson.encode(answers),
            contact.email and contact.email:lower() or db.NULL, failed and "needs_attention" or "complete",
            idem or db.NULL, cjson.encode(meta), next(links) ~= nil)[1]
        if not row then return "duplicate" end
        if not Uploads.claim(row.id, schema, answers) then return "files_taken" end
        Submit.save_links(row.id, form.namespace_id, links)
        return "saved"
    end)
    if not ok or res ~= "saved" then
        pcall(db.query, "ROLLBACK")
        if not ok then error(res, 0) end
        if res == "duplicate" then return done end
        if res == "files_taken" then
            return { status = 409, json = { success = false, error = "A file was already sent with another response. "
                .. "Please attach it again.", code = "files_taken" } }
        end
        -- Closed or full: say which.
        local max = tonumber(settings.max_submissions)
        local now = db.query("SELECT submission_count FROM forms WHERE id = ?", form.id)[1]
        if max and now and tonumber(now.submission_count) >= max then
            return { status = 409, json = { success = false, error = settings.closed_message
                or "This form has reached its response limit.", code = "form_full" } }
        end
        return { status = 410, json = { success = false, error = settings.closed_message
            or "This form is closed.", code = "form_closed" } }
    end
    db.query("COMMIT")
    run_hooks(hooks)
    return done
end

return Submit
