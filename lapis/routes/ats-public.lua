--[[
    Hiring (ATS) — public API: no OpsAPI login. Core public routes must live
    under /api/v2/public/ (app.lua's before_filter).

    Candidates (link token in the URL; only its SHA-256 is stored):
      GET  /api/v2/public/ats/interviews/:token            the candidate's view (404 unknown, 410 expired)
      POST /api/v2/public/ats/interviews/:token/start      {notice_hash, adjustments[]}
      POST /api/v2/public/ats/interviews/:token/answer     {text, input: typed|spoken|pasted}
      POST /api/v2/public/ats/interviews/:token/event      {type, text?}: repeat | rephrase | pause | resume |
                                                           person | withdraw | adjustment
      POST /api/v2/public/ats/interviews/:token/self-id    {answers}: voluntary, after the interview
      POST /api/v2/public/ats/interviews/:token/pack       {device_id}: the Snazzy Pro app redeems its invite for
                                                           the interview pack (signed S3 link + key); the
                                                           first device keeps the invite

    Snazzy Pro desktop app (Authorization: Bearer snz_<token>, from Hiring › Settings):
      GET  /api/v2/public/ats/integration/ping             {namespace, active}
      GET  /api/v2/public/ats/integration/kits             approved kits, as the app's RoleKit JSON
      POST /api/v2/public/ats/integration/interviews       an InterviewSession or a .snazzy_interview file (≤ 1 MB)
      POST /api/v2/public/ats/integration/packs            {title, kit_uuid?, size_bytes, sha256, key}:
                                                           a signed S3 upload link for the encrypted pack
      POST /api/v2/public/ats/integration/packs/:uuid/complete
      POST /api/v2/public/ats/integration/invites          {kit_uuid, pack_uuid?, candidates[], expires_in_days?}

    Stripe:
      POST /api/v2/public/ats/billing/webhook              activation events (signature checked, idempotent)
]]

local J = require("lib.ats.json")
local RateLimit = require("middleware.rate-limit")
local Q = require("queries.AtsQueries")
local I = require("queries.AtsInterviewQueries")
local Packs = require("queries.AtsPackQueries")
local Engine = require("lib.ats.engine")
local Activation = require("lib.ats.activation")
local Interop = require("lib.ats.interop")

local MAX_BODY = 64 * 1024

local function respond(status, body, headers)
    return { status = status, layout = false, content_type = "application/json", headers = headers, J.encode(body) }
end
local function ok(data, status) return respond(status or 200, { success = true, data = data }) end
local function fail(status, message, code) return respond(status, { success = false, error = message, code = code }) end

local function limited(key, rate, window)
    local allowed, _, retry = RateLimit.check("ats:" .. key, rate, window)
    if allowed then return nil end
    return respond(429, { success = false, error = "Too many requests. Please wait a moment and try again." },
        { ["Retry-After"] = tostring(retry) })
end

--- The raw request body (also when nginx spooled it to a file). @return string | nil (too large)
local function raw_body(max)
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local path = ngx.req.get_body_file()
        if not path then return "" end
        local f = io.open(path, "rb")
        if not f then return "" end
        raw = f:read(max + 1) or ""
        f:close()
    end
    if #raw > max then return nil end
    return raw
end

local function body(max)
    local raw = raw_body(max or MAX_BODY)
    if not raw then return nil, nil, "too_large" end
    if raw == "" then return {}, "" end
    local data = J.decode(raw)
    if type(data) ~= "table" then return nil, raw, "bad_json" end
    return data, raw
end

-- The interview for :token, rate-limited per IP and per token.
local function interview(self, per_token)
    local ip = RateLimit.getClientIP()
    local busy = limited("ip:" .. ip, 240, 60)
    if busy then return nil, busy end
    local token = self.params.token or ""
    busy = limited("tok:" .. ngx.md5(token), per_token or 60, 60)
    if busy then return nil, busy end
    local r, status = I.by_token(token)
    if not r then
        if status == 410 then return nil, fail(410,
            "This interview link has expired. Please contact the hiring team.", "expired") end
        return nil, fail(404, "This interview link isn't valid.", "not_found")
    end
    return r
end

local function action(fn, per_token)
    return function(self)
        local r, err = interview(self, per_token)
        if not r then return err end
        local b, _, berr = body()
        if not b then return fail(berr == "too_large" and 413 or 400, berr == "too_large" and "That's too long."
            or "Bad request.") end
        local view, verr, status = fn(r, b)
        if not view then return fail(status or 422, verr) end
        return ok(view)
    end
end

-- The namespace for a desktop integration token, or an error response.
local function integration(self)
    local ip = RateLimit.getClientIP()
    local busy = limited("int-ip:" .. ip, 120, 60)
    if busy then return nil, busy end
    local auth = self.req.headers["authorization"] or ""
    local raw = auth:match("^[Bb]earer%s+(snz_[%w%-_]+)%s*$")
    if not raw then return nil, fail(401, "Send an integration token: Authorization: Bearer snz_…", "no_token") end
    local t = Q.verify_token(raw)
    if not t then
        -- 20 bad tokens from one address in 15 minutes locks it out for the rest of the window.
        local locked = limited("int-bad:" .. ip, 20, 900)
        if locked then return nil, locked end
        return nil, fail(401, "That integration token isn't valid or was revoked.", "bad_token")
    end
    busy = limited("int-tok:" .. t.uuid, 600, 60)
    if busy then return nil, busy end
    return t
end

local M = { raw_body = raw_body }

function M.routes(app)
    -- MARK: Candidates

    app:get("/api/v2/public/ats/interviews/:token", function(self)
        local r, err = interview(self)
        if not r then return err end
        return ok(I.public_view(r))
    end)
    app:post("/api/v2/public/ats/interviews/:token/start", action(I.start, 10))
    app:post("/api/v2/public/ats/interviews/:token/answer", action(I.answer, 30))
    app:post("/api/v2/public/ats/interviews/:token/event", action(I.event, 30))
    app:post("/api/v2/public/ats/interviews/:token/self-id", action(I.self_id, 5))
    -- The invite link is the credential: no passcode. Rate-limited like the others.
    app:post("/api/v2/public/ats/interviews/:token/pack", action(function(r, b)
        local s = type(r.session) == "table" and r.session or J.decode(tostring(r.session or "")) or {}
        return Packs.for_invite(r, b.device_id, Engine.is_finished(s))
    end, 10))

    -- MARK: Snazzy Pro desktop integration

    app:get("/api/v2/public/ats/integration/ping", function(self)
        local t, err = integration(self)
        if not t then return err end
        return ok({ namespace = t.namespace_name, namespace_uuid = t.namespace_uuid,
            active = Activation.is_active(t.namespace_id), dashboard_url = Activation.public_url()
                .. "/dashboard/ats" })
    end)

    app:get("/api/v2/public/ats/integration/kits", function(self)
        local t, err = integration(self)
        if not t then return err end
        local db = require("lapis.db")
        local kits = J.array({})
        for _, r in ipairs(db.query([[SELECT * FROM ats_kits WHERE namespace_id = ? AND deleted_at IS NULL
            AND approved_at IS NOT NULL ORDER BY updated_at DESC LIMIT 200]], t.namespace_id)) do
            kits[#kits + 1] = Q.kit_contract(r)
        end
        return ok(kits)
    end)

    app:post("/api/v2/public/ats/integration/interviews", function(self)
        local t, err = integration(self)
        if not t then return err end
        local raw = raw_body(Interop.MAX_BYTES)
        if not raw then return fail(413, "The interview is larger than 1 MB.", "too_large") end
        local rec, perr = Interop.parse(raw)
        if not rec then return fail(422, perr, "invalid") end
        if not Activation.is_active(t.namespace_id) then return fail(402, Activation.LAPSED_MESSAGE, "ats_inactive") end
        local res, ierr = I.import(t.namespace_id, rec, "token:" .. t.uuid, "snazzy_desktop")
        if not res then return fail(422, ierr) end
        return ok(res, res.created and 201 or 200)
    end)

    -- Interview packs from the recruiter's Mac: encrypted there, uploaded once to S3.
    local function integration_body(self, fn, max)
        local t, err = integration(self)
        if not t then return err end
        local b, _, berr = body(max)
        if not b then return fail(berr == "too_large" and 413 or 400, "Bad request.") end
        local res, ferr, status = fn(t, b)
        if not res then return fail(status or (tostring(ferr):find("not found", 1, true) and 404 or 422), ferr) end
        return ok(res, 201)
    end
    app:post("/api/v2/public/ats/integration/packs", function(self)
        return integration_body(self, function(t, b) return Packs.create(t.namespace_id, b, "token:" .. t.uuid) end)
    end)
    app:post("/api/v2/public/ats/integration/packs/:uuid/complete", function(self)
        return integration_body(self, function(t)
            return Packs.complete(t.namespace_id, self.params.uuid, "token:" .. t.uuid)
        end)
    end)
    app:post("/api/v2/public/ats/integration/invites", function(self)
        return integration_body(self, function(t, b) return I.invite_many(t.namespace_id, b, "token:" .. t.uuid) end,
            512 * 1024)
    end)

    -- MARK: Stripe activation webhook

    app:post("/api/v2/public/ats/billing/webhook", function(self)
        local raw = raw_body(512 * 1024) or ""
        local secret = os.getenv("ATS_STRIPE_WEBHOOK_SECRET")
        if not secret or secret == "" then secret = os.getenv("STRIPE_WEBHOOK_SECRET") end
        local event, verr = require("lib.stripe").construct_event(raw, self.req.headers["stripe-signature"], secret)
        if not event then return fail(400, "Signature check failed: " .. tostring(verr)) end
        local db = require("lapis.db")
        local fresh = db.query([[INSERT INTO ats_stripe_events (event_id, type) VALUES (?, ?)
            ON CONFLICT (event_id) DO NOTHING RETURNING event_id]], event.id or "", event.type or "")[1]
        if not fresh then return ok({ duplicate = true }) end
        local good, herr = pcall(Activation.handle_event, event)
        if not good then
            db.query("DELETE FROM ats_stripe_events WHERE event_id = ?", event.id or "")
            ngx.log(ngx.ERR, "[ats] webhook failed: ", tostring(herr))
            return fail(500, "Couldn't process the event.")
        end
        return ok({ received = true })
    end)
end

return setmetatable(M, { __call = function(_, app) return M.routes(app) end })
