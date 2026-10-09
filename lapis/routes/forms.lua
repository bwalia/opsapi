--[[
    Forms — admin API (docs/FORMS.md). Feature: forms. RBAC module: forms.

    GET    /api/v2/forms?status=&q=&cursor=&limit=          list (newest first, keyset)
    POST   /api/v2/forms                                    create {title, description, template, schema|fields,
                                                                    targets, settings}
    GET    /api/v2/forms/targets                            "create records" options here + roles you may give
    GET    /api/v2/forms/templates                          starter forms
    GET    /api/v2/forms/:uuid                              one form (draft schema, settings, share URL)
    PUT    /api/v2/forms/:uuid                              partial update {..., expected_updated_at} (409 if stale)
    DELETE /api/v2/forms/:uuid                              soft delete (link stops working)
    POST   /api/v2/forms/:uuid/publish                      the draft becomes a new live version
    POST   /api/v2/forms/:uuid/close | /reopen              stop / resume accepting responses
    POST   /api/v2/forms/:uuid/duplicate                    copy as a new draft
    GET    /api/v2/forms/:uuid/submissions?status=&from=&to=&q=&cursor=&limit=
    GET    /api/v2/forms/:uuid/submissions/:sid             one response (+ the fields it answered)
    PUT    /api/v2/forms/:uuid/submissions/:sid {status}    spam | complete ("not spam" runs its targets)
    POST   /api/v2/forms/:uuid/submissions/:sid/retry       re-run targets that failed
    DELETE /api/v2/forms/:uuid/submissions/:sid             delete a response (GDPR)
    GET    /api/v2/forms/:uuid/export                       CSV of the responses (streamed)

    Every query is scoped to the caller's namespace; a uuid from another
    workspace is a 404.
]]

local Http = require("helper.field-service-http")
local J = require("lib.forms.json")
local FormQueries = require("queries.FormQueries")
local FormSubmissionQueries = require("queries.FormSubmissionQueries")
local Targets = require("lib.forms.targets")
local Templates = require("lib.forms.templates")
local Fields = require("lib.forms.fields")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143

-- Encoded with the forms JSON instance so empty objects stay objects.
local function ok(data, status, meta)
    return { status = status or 200, layout = false, content_type = "application/json",
        J.encode({ success = true, data = data, meta = meta }) }
end

local function fail(status, message, errors)
    return { status = status, layout = false, content_type = "application/json",
        J.encode({ success = false, error = message, errors = errors }) }
end

local function result(data, err, status, errors)
    if data == nil then
        return fail(status or (tostring(err):lower():find("not found", 1, true) and 404) or 422, err, errors)
    end
    return ok(data, status)
end

local function body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw or raw == "" then
        if ngx.req.get_body_file() then return nil, "request body is too large" end
        return {}
    end
    local good, data = pcall(J.decode, raw)
    if not good or type(data) ~= "table" then return nil, "request body must be a JSON object" end
    return data
end

local function guard(action, fn)
    return Http.guard("forms", action, fn)
end

local function actor(self)
    return self.current_user and self.current_user.uuid
end

local NOT_FOUND = fail(404, "Form not found")

-- The form for :uuid in the caller's namespace, or nil.
local function form_of(self)
    return FormQueries.load(self.namespace.id, self.params.uuid)
end

return function(app)
    app:get("/api/v2/forms", guard("read", function(self)
        local items, meta = FormQueries.list(self.namespace.id, self.params)
        if not items then return fail(400, meta) end
        return ok(items, 200, meta)
    end))

    app:post("/api/v2/forms", guard("create", function(self)
        local b, err = body()
        if not b then return fail(400, err) end
        local form, ferr, status = FormQueries.create(self.namespace.id, actor(self), b, FormQueries.auth(self),
            require("middleware.cors").frontendOrigin(self))
        return result(form, ferr, status or (form and 201))
    end))

    app:get("/api/v2/forms/targets", guard("read", function(self)
        return ok(Targets.available(FormQueries.auth(self), self.namespace.id))
    end))

    app:get("/api/v2/forms/templates", guard("read", function()
        local out = {}
        for _, t in ipairs(Templates.list) do
            local schema = Fields.normalize({ fields = t.fields }, {})
            out[#out + 1] = { key = t.key, title = t.title, description = t.description,
                targets = setmetatable({ unpack(t.targets) }, J.array_mt),
                question_count = schema and #schema.fields or 0 }
        end
        return ok(setmetatable(out, J.array_mt))
    end))

    -- Responses linked to a record (?entity_type=customer|lead|user|invitation&entity_uuid=).
    app:get("/api/v2/forms/responses", guard("read", function(self)
        local items, err = FormSubmissionQueries.forEntity(self.namespace.id, self.params.entity_type,
            self.params.entity_uuid)
        if not items then return fail(400, err) end
        return ok(items)
    end))

    -- Draft a form from a description with AI (nothing saved).
    app:post("/api/v2/forms/generate", guard("create", function(self)
        local b, err = body()
        if not b then return fail(400, err) end
        local draft, gerr, status = require("lib.forms.ai").generate(self.namespace.id, actor(self), b.prompt,
            FormQueries.auth(self))
        return result(draft, gerr, status)
    end))

    -- Workspace-wide forms settings (Turnstile keys). The secret is write-only.
    app:get("/api/v2/forms/workspace-settings", guard("read", function(self)
        return ok(require("lib.forms.workspace").get(self.namespace.id))
    end))
    app:put("/api/v2/forms/workspace-settings", guard("manage", function(self)
        local b, err = body()
        if not b then return fail(400, err) end
        return result(require("lib.forms.workspace").save(self.namespace.id, actor(self), b))
    end))

    app:get("/api/v2/forms/:uuid", guard("read", function(self)
        local form = FormQueries.get(self.namespace.id, self.params.uuid)
        if not form then return NOT_FOUND end
        return ok(form)
    end))

    app:put("/api/v2/forms/:uuid", guard("update", function(self)
        local b, err = body()
        if not b then return fail(400, err) end
        return result(FormQueries.update(self.namespace.id, self.params.uuid, actor(self), b, FormQueries.auth(self),
            require("middleware.cors").frontendOrigin(self)))
    end))

    app:delete("/api/v2/forms/:uuid", guard("delete", function(self)
        local done, err, status = FormQueries.delete(self.namespace.id, self.params.uuid, actor(self))
        if not done then return fail(status or 422, err) end
        return ok({ deleted = true })
    end))

    app:post("/api/v2/forms/:uuid/publish", guard("update", function(self)
        return result(FormQueries.publish(self.namespace.id, self.params.uuid, actor(self), FormQueries.auth(self)))
    end))

    app:post("/api/v2/forms/:uuid/close", guard("update", function(self)
        return result(FormQueries.setOpen(self.namespace.id, self.params.uuid, actor(self), false))
    end))

    app:post("/api/v2/forms/:uuid/reopen", guard("update", function(self)
        return result(FormQueries.setOpen(self.namespace.id, self.params.uuid, actor(self), true))
    end))

    app:post("/api/v2/forms/:uuid/duplicate", guard("create", function(self)
        local form, err, status = FormQueries.duplicate(self.namespace.id, self.params.uuid, actor(self),
            FormQueries.auth(self), require("middleware.cors").frontendOrigin(self))
        return result(form, err, status or (form and 201))
    end))

    -- Responses ---------------------------------------------------------------

    app:get("/api/v2/forms/:uuid/submissions", guard("read", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        local items, meta = FormSubmissionQueries.list(form, self.params)
        if not items then return fail(400, meta) end
        meta.columns = FormSubmissionQueries.columns(form)
        return ok(items, 200, meta)
    end))

    app:get("/api/v2/forms/:uuid/submissions/:sid", guard("read", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        local s = FormSubmissionQueries.get(form, self.params.sid)
        if not s then return fail(404, "Response not found") end
        return ok(s)
    end))

    app:put("/api/v2/forms/:uuid/submissions/:sid", guard("update", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        local b, err = body()
        if not b then return fail(400, err) end
        return result(FormSubmissionQueries.setStatus(form, self.params.sid, b.status))
    end))

    app:post("/api/v2/forms/:uuid/submissions/:sid/retry", guard("update", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        return result(FormSubmissionQueries.retry(form, self.params.sid))
    end))

    app:delete("/api/v2/forms/:uuid/submissions/:sid", guard("delete", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        local done, err, status = FormSubmissionQueries.delete(form, self.params.sid)
        if not done then return fail(status or 422, err) end
        return ok({ deleted = true })
    end))

    -- A short-lived link to a file attached to a response.
    app:get("/api/v2/forms/:uuid/submissions/:sid/files/:file", guard("read", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        local s = FormSubmissionQueries.get(form, self.params.sid)
        if not s then return fail(404, "Response not found") end
        local row = require("lapis.db").query("SELECT id FROM form_submissions WHERE uuid = ?", s.uuid)[1]
        local url, err = require("lib.forms.uploads").link(row.id, self.params.file)
        if not url then return fail(404, err) end
        return ok({ url = url, expires_in = require("lib.forms.uploads").LINK_SECONDS })
    end))

    -- Numbers about the responses plus an AI-written summary (?numbers_only=true skips the AI).
    app:post("/api/v2/forms/:uuid/summary", guard("read", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        return ok(require("lib.forms.ai").summarise(form, actor(self),
            { numbers_only = self.params.numbers_only == "true" }))
    end))

    app:get("/api/v2/forms/:uuid/analytics", guard("read", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        return ok(require("lib.forms.stats").report(form, self.params.days))
    end))

    -- Streamed: never builds the whole file in memory.
    app:get("/api/v2/forms/:uuid/export", guard("read", function(self)
        local form = form_of(self)
        if not form then return NOT_FOUND end
        local name = form.title:gsub("[^%w%-_ ]", ""):gsub("%s+", "-"):sub(1, 60)
        for k, v in pairs(self.res.headers) do ngx.header[k] = v end -- CORS etc. (skip_render bypasses lapis)
        ngx.status = 200
        ngx.header["Content-Type"] = "text/csv; charset=utf-8"
        ngx.header["Content-Disposition"] = ('attachment; filename="%s-responses.csv"'):format(
            name ~= "" and name or "form")
        ngx.header["Cache-Control"] = "no-store"
        ngx.print("\239\187\191") -- UTF-8 byte order mark, so Excel reads accents correctly
        FormSubmissionQueries.export(form, self.params, function(chunk)
            ngx.print(chunk)
            ngx.flush(true)
        end)
        return { skip_render = true }
    end))
end
