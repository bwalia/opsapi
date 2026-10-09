--[[
    Forms — public API (no auth: everything under /api/v2/public/ skips it).
    Feature: forms.

    GET  /api/v2/public/forms/:public_id               the published form + a render token
    POST /api/v2/public/forms/:public_id/submissions   submit {answers, render_token, _hp, context}
                                                       header Idempotency-Key (a repeat is stored once)

    The namespace comes from the form row, never from the client. Draft,
    deleted and archived forms, and forms of a suspended workspace, are 404
    (the global suspended-workspace check doesn't run on public routes).
    Any origin may call these (no credentials are involved): forms are
    embedded on customers' own sites.
]]

local db = require("lapis.db")
local J = require("lib.forms.json")
local RateLimit = require("middleware.rate-limit")
local FormQueries = require("queries.FormQueries")
local Submit = require("lib.forms.submit")
local PublicCache = require("lib.forms.public-cache")

local MAX_BODY = 64 * 1024
-- ponytail: fixed limits; per-plan limits when a plan needs more than ~10/s per form.
local SUBMIT_LIMITS = {
    { "ip_form", 5, 60 },     -- per IP per form per minute
    { "ip", 30, 3600 },       -- per IP across all forms per hour
    { "form", 600, 60 },      -- per form per minute, every visitor together
}

local function respond(status, body, headers)
    return { status = status, layout = false, content_type = "application/json", headers = headers,
        J.encode(body) }
end

local function allow_any_origin(self)
    if not self.res.headers["Access-Control-Allow-Origin"] then
        self.res.headers["Access-Control-Allow-Origin"] = "*"
    end
end

local function too_many(retry)
    return respond(429, { success = false, error = "Too many requests. Please wait a moment and try again." },
        { ["Retry-After"] = tostring(retry) })
end

local function nonnull(v)
    if v == nil or v == db.NULL then return nil end
    return v
end

-- Why a form can't take responses right now (nil = it can).
local function unavailable(row, settings)
    if not row or nonnull(row.deleted_at) or row.namespace_status ~= "active" or not nonnull(row.v_id)
        or row.status == "draft" or row.status == "archived" then
        return 404
    end
    if row.status == "closed" then return 410, "form_closed" end
    if settings.close_at and settings.close_at <= os.date("!%Y-%m-%dT%H:%M:%SZ") then return 410, "form_closed" end
    local max = tonumber(settings.max_submissions)
    if max and (tonumber(row.submission_count) or 0) >= max then return 409, "form_full" end
end

local function closed_body(row, settings, code)
    return { success = false, code = code, title = row.title, error = settings.closed_message
        or (code == "form_full" and "This form has reached its response limit."
            or "This form is no longer accepting responses.") }
end

local NOT_AVAILABLE = { success = false, error = "This form isn't available.", code = "form_not_found" }

-- What the public GET returns for a form (cached per worker: lib/forms/public-cache.lua).
local function view(public_id)
    local row = FormQueries.publicForm(public_id)
    local settings = row and FormQueries.decode(row.settings, {}) or {}
    local status, code = unavailable(row, settings)
    if status == 404 then return { status = 404, body = NOT_AVAILABLE } end
    if status then return { status = 410, body = closed_body(row, settings, code) } end
    local schema = FormQueries.decode(row.v_schema, { fields = {} })
    return {
        status = 200,
        form_id = tonumber(row.id),
        body = {
            success = true,
            data = {
                title = row.title,
                description = nonnull(row.description),
                version = tonumber(row.v_version),
                fields = FormQueries.publicSchema(schema),
                workspace = { name = row.namespace_name, logo_url = nonnull(row.namespace_logo) },
            },
        },
    }
end

return function(app)
    app:get("/api/v2/public/forms/:public_id", function(self)
        allow_any_origin(self)
        local allowed, _, retry = RateLimit.check("forms_view:" .. RateLimit.getClientIP(), 120, 60)
        if not allowed then return too_many(retry) end
        local id = self.params.public_id
        local v = PublicCache.get(id)
        if not v then
            v = view(id)
            PublicCache.set(id, v)
        end
        if v.status ~= 200 then return respond(v.status, v.body, { ["Cache-Control"] = "no-store" }) end
        -- The token is per request (it dates the page view), so the body is copied.
        local data = {}
        for k, val in pairs(v.body.data) do data[k] = val end
        data.render_token = Submit.render_token(v.form_id)
        return respond(200, { success = true, data = data }, { ["Cache-Control"] = "no-store" })
    end)

    app:post("/api/v2/public/forms/:public_id/submissions", function(self)
        allow_any_origin(self)
        local id = self.params.public_id
        if type(id) ~= "string" or not id:match("^%w+$") or #id > 16 then return respond(404, NOT_AVAILABLE) end
        local ip = RateLimit.getClientIP()
        for _, l in ipairs(SUBMIT_LIMITS) do
            local who = l[1] == "ip" and ip or l[1] == "form" and id or (id .. ":" .. ip)
            local key = "forms_submit:" .. l[1] .. ":" .. who
            local allowed, _, retry = RateLimit.check(key, l[2], l[3])
            if not allowed then return too_many(retry) end
        end

        ngx.req.read_body()
        local raw = ngx.req.get_body_data()
        if (not raw and ngx.req.get_body_file()) or (raw and #raw > MAX_BODY) then
            return respond(413, { success = false, error = "That's too much to send in one response." })
        end
        local good, body = pcall(J.decode, raw or "")
        if not good or type(body) ~= "table" then
            return respond(400, { success = false, error = "The request must be a JSON object." })
        end

        local row = FormQueries.publicForm(id)
        local settings = row and FormQueries.decode(row.settings, {}) or {}
        local status, code = unavailable(row, settings)
        if status == 404 then return respond(404, NOT_AVAILABLE) end
        if status then return respond(status, closed_body(row, settings, code)) end

        local res = Submit.handle({
            id = row.id, uuid = row.uuid, namespace_id = row.namespace_id, title = row.title,
            settings = settings, namespace_name = row.namespace_name, max_users = row.max_users,
        }, {
            id = row.v_id, schema = row.v_schema, targets = row.v_targets, published_by_uuid = row.v_published_by_uuid,
        }, body, {
            ip = ip,
            user_agent = ngx.var.http_user_agent,
            idempotency_key = self.req.headers["idempotency-key"],
        })
        return respond(res.status, res.json)
    end)
end
