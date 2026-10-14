--[[
    Hiring (ATS + AI first-round interviews) — recruiter API.
    Feature: ats. RBAC modules: ats_jobs, ats_candidates, ats_interviews,
    ats_kits, ats_reports, ats_settings. docs/plans/PROMPT_ATS_INTERVIEWS.md §4.

    Every query is scoped to the caller's namespace; a uuid from another
    workspace is a 404. A person decides: rejecting is its own endpoint and
    needs a reason; nothing here rejects or advances anyone automatically.
]]

local Http = require("helper.field-service-http")
local J = require("lib.ats.json")
local Q = require("queries.AtsQueries")
local I = require("queries.AtsInterviewQueries")
local Activation = require("lib.ats.activation")
local Kit = require("lib.ats.kit")
local P = require("lib.ats.prompts")
local L = require("lib.ats.llm")
local Interop = require("lib.ats.interop")

local MAX_BODY = 1024 * 1024

local function respond(status, body)
    return { status = status, layout = false, content_type = "application/json", J.encode(body) }
end

local function ok(data, status, meta)
    return respond(status or 200, { success = true, data = data, meta = meta })
end

local function fail(status, message, extra)
    local b = { success = false, error = message }
    for k, v in pairs(extra or {}) do b[k] = v end
    return respond(status, b)
end

local function result(data, err, status)
    if data == nil then
        if status then return fail(status, err) end
        return fail(tostring(err):lower():find("not found", 1, true) and 404 or 422, err)
    end
    return ok(data, status)
end

local function body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw or raw == "" then
        if ngx.req.get_body_file() then return nil, "The request is too large." end
        return {}
    end
    if #raw > MAX_BODY then return nil, "The request is too large." end
    local data = J.decode(raw)
    if type(data) ~= "table" then return nil, "The request body must be a JSON object." end
    return data
end

local function actor(self) return self.current_user and self.current_user.uuid end
local function actor_name(self)
    local u = self.current_user or {}
    local name = u.name and u.name:gsub("^%s+", ""):gsub("%s+$", "") or ""
    return name ~= "" and name or u.email or u.uuid
end

local function guard(module, action, fn)
    return Http.guard(module, action, fn)
end

-- A handler that reads a JSON body first.
local function with_body(module, action, fn)
    return guard(module, action, function(self)
        local b, err = body()
        if not b then return fail(400, err) end
        return fn(self, b)
    end)
end

return function(app)
    -- MARK: Overview

    app:get("/api/v2/ats/overview", guard("ats_jobs", "read", function(self)
        local db = require("lapis.db")
        local ns = self.namespace.id
        local stages = {}
        for _, r in ipairs(db.query([[SELECT a.stage, count(*)::int AS n FROM ats_applications a
            JOIN ats_jobs j ON j.id = a.job_id WHERE a.namespace_id = ? AND j.deleted_at IS NULL GROUP BY a.stage]], ns)) do
            stages[r.stage] = r.n
        end
        local counts = db.query([[SELECT
            (SELECT count(*) FROM ats_jobs WHERE namespace_id = ? AND status = 'open' AND deleted_at IS NULL)::int AS open_jobs,
            (SELECT count(*) FROM ats_candidates WHERE namespace_id = ?)::int AS candidates,
            (SELECT count(*) FROM ats_interviews WHERE namespace_id = ? AND state IN ('completed','human_requested')
               AND review IS NULL)::int AS to_review,
            (SELECT count(*) FROM ats_interviews WHERE namespace_id = ? AND state IN ('invited','in_progress','paused'))::int
               AS in_progress]], ns, ns, ns, ns)[1]
        counts.stages = stages
        counts.activation = Activation.status(ns)
        return ok(counts)
    end))

    -- MARK: Jobs

    app:get("/api/v2/ats/jobs", guard("ats_jobs", "read", function(self)
        local items, meta = Q.jobs(self.namespace.id, self.params)
        return ok(items, 200, meta)
    end))
    app:post("/api/v2/ats/jobs", with_body("ats_jobs", "create", function(self, b)
        local job, err = Q.create_job(self.namespace.id, b, actor(self))
        return result(job, err, job and 201)
    end))
    app:get("/api/v2/ats/jobs/:uuid", guard("ats_jobs", "read", function(self)
        return result(Q.job(self.namespace.id, self.params.uuid))
    end))
    app:put("/api/v2/ats/jobs/:uuid", with_body("ats_jobs", "update", function(self, b)
        return result(Q.update_job(self.namespace.id, self.params.uuid, b, actor(self)))
    end))
    app:delete("/api/v2/ats/jobs/:uuid", guard("ats_jobs", "delete", function(self)
        return result(Q.delete_job(self.namespace.id, self.params.uuid, actor(self)))
    end))
    app:get("/api/v2/ats/jobs/:uuid/pipeline", guard("ats_jobs", "read", function(self)
        return result(Q.pipeline(self.namespace.id, self.params.uuid))
    end))

    -- MARK: Candidates

    app:get("/api/v2/ats/candidates", guard("ats_candidates", "read", function(self)
        local items, meta = Q.candidates(self.namespace.id, self.params)
        return ok(items, 200, meta)
    end))
    app:post("/api/v2/ats/candidates", with_body("ats_candidates", "create", function(self, b)
        local c, err = Q.create_candidate(self.namespace.id, b, actor(self))
        return result(c, err, c and 201)
    end))
    app:get("/api/v2/ats/candidates/:uuid", guard("ats_candidates", "read", function(self)
        return result(Q.candidate(self.namespace.id, self.params.uuid))
    end))
    app:put("/api/v2/ats/candidates/:uuid", with_body("ats_candidates", "update", function(self, b)
        return result(Q.update_candidate(self.namespace.id, self.params.uuid, b, actor(self)))
    end))
    app:delete("/api/v2/ats/candidates/:uuid", guard("ats_candidates", "delete", function(self)
        return result(Q.delete_candidate(self.namespace.id, self.params.uuid, actor(self)))
    end))
    app:get("/api/v2/ats/candidates/:uuid/export", guard("ats_candidates", "read", function(self)
        return result(Q.export_candidate(self.namespace.id, self.params.uuid, actor(self)))
    end))
    app:post("/api/v2/ats/candidates/:uuid/notes", with_body("ats_candidates", "update", function(self, b)
        local n, err = Q.add_note(self.namespace.id, self.params.uuid, b, actor(self), actor_name(self))
        return result(n, err, n and 201)
    end))

    -- MARK: Applications

    app:post("/api/v2/ats/applications", with_body("ats_candidates", "update", function(self, b)
        local a, err = Q.create_application(self.namespace.id, b.job_uuid, b.candidate_uuid, actor(self), b.stage)
        return result(a, err, a and 201)
    end))
    app:post("/api/v2/ats/applications/:uuid/stage", with_body("ats_candidates", "update", function(self, b)
        return result(Q.move_stage(self.namespace.id, self.params.uuid, b.stage, actor(self)))
    end))
    -- A person's rejection, with a reason. Nothing is sent to the candidate.
    app:post("/api/v2/ats/applications/:uuid/reject", with_body("ats_candidates", "update", function(self, b)
        return result(Q.reject(self.namespace.id, self.params.uuid, b.reason, actor(self), actor_name(self)))
    end))

    -- MARK: Kits

    app:get("/api/v2/ats/kits", guard("ats_kits", "read", function(self)
        return ok(Q.kits(self.namespace.id, self.params))
    end))
    app:post("/api/v2/ats/kits", with_body("ats_kits", "create", function(self, b)
        local k, err = Q.create_kit(self.namespace.id, b, actor(self))
        return result(k, err, k and 201)
    end))
    -- Draft a kit from a job description with AI (saved as an unapproved kit).
    app:post("/api/v2/ats/kits/generate", with_body("ats_kits", "create", function(self, b)
        local jd = type(b.job_description) == "string" and b.job_description or ""
        if #jd < 40 then return fail(422, "Paste the job description (at least a few sentences).") end
        if #jd > 30000 then return fail(413, "That job description is too long.") end
        local text, label = L.complete("generator", "You draft structured interview kits. Reply with JSON only.",
            P.kit_generator_prompt(jd, b.language or "en-GB"), { namespace_id = self.namespace.id, user_uuid = actor(self) })
        if not text then return fail(502, "The AI didn't answer: " .. tostring(label)) end
        local kit = P.parse_generated_kit(text, jd)
        if not kit then return fail(502, "The AI's draft couldn't be read. Try again.") end
        local k, err = Q.create_kit(self.namespace.id, { kit = kit, job_uuid = b.job_uuid, source = "generated" }, actor(self))
        if k then k.model = label end
        return result(k, err, k and 201)
    end))
    app:get("/api/v2/ats/kits/:uuid", guard("ats_kits", "read", function(self)
        return result(Q.kit(self.namespace.id, self.params.uuid))
    end))
    app:put("/api/v2/ats/kits/:uuid", with_body("ats_kits", "update", function(self, b)
        return result(Q.update_kit(self.namespace.id, self.params.uuid, b, actor(self)))
    end))
    app:delete("/api/v2/ats/kits/:uuid", guard("ats_kits", "delete", function(self)
        return result(Q.delete_kit(self.namespace.id, self.params.uuid, actor(self)))
    end))
    app:post("/api/v2/ats/kits/validate", with_body("ats_kits", "read", function(_, b)
        return ok(J.array(Kit.validate(type(b.kit) == "table" and b.kit or b)))
    end))
    app:get("/api/v2/ats/kits/:uuid/validate", guard("ats_kits", "read", function(self)
        local k, err = Q.kit(self.namespace.id, self.params.uuid)
        if not k then return fail(404, err) end
        return ok(J.array(k.issues))
    end))
    app:post("/api/v2/ats/kits/:uuid/approve", guard("ats_kits", "update", function(self)
        return result(Q.approve_kit(self.namespace.id, self.params.uuid, actor(self), actor_name(self)))
    end))

    -- MARK: Interviews

    app:get("/api/v2/ats/interviews", guard("ats_interviews", "read", function(self)
        local items, meta = I.list(self.namespace.id, self.params)
        return ok(items, 200, meta)
    end))
    -- Invite: returns the candidate's link once.
    app:post("/api/v2/ats/interviews", with_body("ats_interviews", "create", function(self, b)
        local inv, err, status = I.invite(self.namespace.id, b, actor(self))
        if not inv and status == 402 then return fail(402, err, { code = "ats_inactive" }) end
        return result(inv, err, inv and 201)
    end))
    -- Import .snazzy_interview files (the dashboard posts each file's text as {content}).
    app:post("/api/v2/ats/interviews/import", guard("ats_interviews", "create", function(self)
        -- The file text, or {content: "<file text>"} (≤ 1 MB of interview, so 2 MB of JSON-escaped text).
        local raw = require("routes.ats-public").raw_body(2 * Interop.MAX_BYTES + 1024)
        if not raw then return fail(413, "The interview is larger than 1 MB.") end
        local wrapper = J.decode(raw)
        local content = type(wrapper) == "table" and type(wrapper.content) == "string" and wrapper.content or raw
        local rec, perr = Interop.parse(content)
        if not rec then return fail(422, perr) end
        local blocked = Activation.require_active(self.namespace.id)
        if blocked then return blocked end
        return result(I.import(self.namespace.id, rec, actor(self), "snazzy_file"))
    end))
    app:get("/api/v2/ats/interviews/:uuid", guard("ats_interviews", "read", function(self)
        return result(I.detail(self.namespace.id, self.params.uuid))
    end))
    app:post("/api/v2/ats/interviews/:uuid/evaluate", guard("ats_interviews", "update", function(self)
        return result(I.evaluate_async(self.namespace.id, self.params.uuid, actor(self)))
    end))
    app:post("/api/v2/ats/interviews/:uuid/review", with_body("ats_interviews", "update", function(self, b)
        return result(I.review(self.namespace.id, self.params.uuid, b, actor(self), actor_name(self)))
    end))
    app:post("/api/v2/ats/interviews/:uuid/revoke", guard("ats_interviews", "update", function(self)
        return result(I.revoke(self.namespace.id, self.params.uuid, actor(self)))
    end))

    -- MARK: Reports and audit

    app:get("/api/v2/ats/reports/fairness", guard("ats_reports", "read", function(self)
        return result(I.fairness(self.namespace.id, self.params))
    end))
    app:get("/api/v2/ats/audit", guard("ats_reports", "read", function(self)
        local rows, meta = Q.audit_list(self.namespace.id, self.params)
        return ok(J.array(rows), 200, meta)
    end))

    -- MARK: Settings, integration tokens, activation

    app:get("/api/v2/ats/settings", guard("ats_settings", "read", function(self)
        local s = Q.settings(self.namespace.id)
        s.activation = Activation.status(self.namespace.id)
        return ok(s)
    end))
    app:put("/api/v2/ats/settings", with_body("ats_settings", "update", function(self, b)
        return result(Q.update_settings(self.namespace.id, b, actor(self)))
    end))
    app:get("/api/v2/ats/settings/tokens", guard("ats_settings", "manage", function(self)
        return ok(Q.tokens(self.namespace.id))
    end))
    -- Creates a token for the Snazzy Pro desktop app; the token is shown once.
    app:post("/api/v2/ats/settings/tokens", with_body("ats_settings", "manage", function(self, b)
        return ok(Q.create_token(self.namespace.id, b.name, actor(self)), 201)
    end))
    app:delete("/api/v2/ats/settings/tokens/:uuid", guard("ats_settings", "manage", function(self)
        return result(Q.revoke_token(self.namespace.id, self.params.uuid, actor(self)))
    end))

    app:get("/api/v2/ats/activation", guard("ats_settings", "read", function(self)
        return ok(Activation.status(self.namespace.id))
    end))
    app:post("/api/v2/ats/activation/checkout", guard("ats_settings", "manage", function(self)
        local s, err = Activation.checkout(self.namespace, self.current_user)
        if not s then return fail(503, err) end
        Q.audit(self.namespace.id, actor(self), "checkout_started", "activation", nil, {})
        return ok(s)
    end))

    -- MARK: Platform admin

    app:post("/api/v2/ats/admin/activation", Http.route(function(self)
        if not self.is_platform_admin then return fail(403, "Platform admins only.") end
        local b, err = body()
        if not b then return fail(400, err) end
        local db = require("lapis.db")
        local ns = db.select("id FROM namespaces WHERE uuid = ?", b.namespace_uuid or "")[1]
        if not ns then return fail(404, "Namespace not found") end
        local s, serr = Activation.set_manual(ns.id, b.status, b.expires_at, actor(self))
        if s then Q.audit(ns.id, actor(self), "activation_set", "activation", nil, { status = b.status }) end
        return result(s, serr)
    end))
    app:post("/api/v2/ats/admin/purge", Http.route(function(self)
        if not self.is_platform_admin then return fail(403, "Platform admins only.") end
        return ok(I.purge())
    end))
end
