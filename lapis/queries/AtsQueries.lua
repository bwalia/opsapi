--[[
    ATS — jobs, candidates, applications, notes, kits, settings, audit log and
    integration tokens (docs/plans/PROMPT_ATS_INTERVIEWS.md). Interviews are in
    AtsInterviewQueries.

    Every function takes the namespace id first and scopes every query to it;
    a uuid from another namespace is "not found". Rows go out with uuids, never
    internal ids. Functions return (data) or (nil, error message).

    A person decides: the only write of stage = 'rejected' is Q.reject().
]]

local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local db = require("lapis.db")
local J = require("lib.ats.json")
local T = require("lib.ats.text")
local Kit = require("lib.ats.kit")
local Hash = require("lib.ats.hash")

local Q = {}

local STAGES = { applied = true, screening = true, interview = true, review = true, offer = true, hired = true,
    rejected = true, withdrawn = true }
Q.STAGE_ORDER = { "applied", "screening", "interview", "review", "offer", "hired", "rejected", "withdrawn" }
local JOB_STATUSES = { draft = true, open = true, paused = true, closed = true }

local function v(x) return J.val(x) end

local function str(x, max)
    x = v(x)
    if x == nil then return nil end
    x = T.trim(tostring(x))
    if x == "" then return nil end
    return T.prefix(x, max or 500)
end

local function decode(x)
    x = v(x)
    if type(x) == "table" then return x end
    return J.decode(x) or nil
end

local function page_of(params)
    local page = math.max(1, math.floor(tonumber(params.page) or 1))
    local per = math.min(100, math.max(1, math.floor(tonumber(params.per_page) or 25)))
    return page, per, (page - 1) * per
end

local function meta(total, page, per)
    return { total = total, page = page, per_page = per, total_pages = math.max(1, math.ceil(total / per)) }
end

-- MARK: Audit

function Q.audit(namespace_id, actor, action, entity, entity_uuid, detail)
    db.insert("ats_audit_log", { namespace_id = namespace_id, actor = actor or "system", action = action,
        entity = entity, entity_uuid = entity_uuid, detail = J.encode(detail or {}) })
end

function Q.audit_list(namespace_id, params)
    local page, per, offset = page_of(params)
    local where, args = "namespace_id = ?", { namespace_id }
    if str(params.entity_uuid) then
        where = where .. " AND entity_uuid = ?"
        args[#args + 1] = params.entity_uuid
    end
    local total = db.query("SELECT count(*)::int AS n FROM ats_audit_log WHERE " .. where, unpack(args))[1].n
    args[#args + 1] = per
    args[#args + 1] = offset
    local rows = db.query("SELECT uuid, actor, action, entity, entity_uuid, detail, created_at "
        .. "FROM ats_audit_log WHERE "
        .. where .. " ORDER BY id DESC LIMIT ? OFFSET ?", unpack(args))
    for _, r in ipairs(rows) do r.detail = decode(r.detail) or {} end
    return rows, meta(total, page, per)
end

-- MARK: Settings

function Q.settings(namespace_id)
    local r = db.select("* FROM ats_settings WHERE namespace_id = ?", namespace_id)[1]
    if not r then
        db.query("INSERT INTO ats_settings (namespace_id) VALUES (?) ON CONFLICT (namespace_id) DO NOTHING",
            namespace_id)
        r = db.select("* FROM ats_settings WHERE namespace_id = ?", namespace_id)[1]
    end
    return { retention_days = r.retention_days, ratings_enabled = r.ratings_enabled,
        decline_reasons = decode(r.decline_reasons) or {}, legal_notice = v(r.legal_notice) or "" }
end

function Q.update_settings(namespace_id, data, actor)
    Q.settings(namespace_id)
    local f = { updated_at = db.raw("NOW()") }
    if data.retention_days ~= nil then
        local n = math.floor(tonumber(data.retention_days) or 0)
        if n < 1 or n > 3650 then return nil, "Retention must be between 1 and 3650 days." end
        f.retention_days = n
    end
    if data.ratings_enabled ~= nil then f.ratings_enabled = data.ratings_enabled == true end
    if type(data.decline_reasons) == "table" then
        local reasons = J.array({})
        for _, r in ipairs(data.decline_reasons) do
            local s = str(r, 200)
            if s then reasons[#reasons + 1] = s end
        end
        if #reasons == 0 then return nil, "Keep at least one decline reason." end
        f.decline_reasons = J.encode(reasons)
    end
    if data.legal_notice ~= nil then f.legal_notice = str(data.legal_notice, 4000) or db.NULL end
    db.update("ats_settings", f, { namespace_id = namespace_id })
    Q.audit(namespace_id, actor, "settings_updated", "settings", nil, {})
    return Q.settings(namespace_id)
end

-- MARK: Jobs

local function job_out(r)
    return { uuid = r.uuid, title = r.title, department = v(r.department), location = v(r.location),
        employment_type = v(r.employment_type), description = v(r.description), status = r.status,
        kit_uuid = v(r.kit_uuid), created_at = r.created_at, updated_at = r.updated_at,
        candidates = tonumber(v(r.candidates)) or 0, to_review = tonumber(v(r.to_review)) or 0 }
end

local JOB_SELECT = [[
    SELECT j.*, k.uuid AS kit_uuid,
      (SELECT count(*) FROM ats_applications a WHERE a.job_id = j.id)::int AS candidates,
      (SELECT count(*) FROM ats_interviews i JOIN ats_applications a ON a.id = i.application_id
        WHERE a.job_id = j.id AND i.state IN ('completed', 'human_requested') AND i.review IS NULL)::int AS to_review
    FROM ats_jobs j LEFT JOIN ats_kits k ON k.id = j.kit_id
]]

function Q.job_row(namespace_id, uuid)
    return db.select("* FROM ats_jobs WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", namespace_id, uuid
        or "")[1]
end

function Q.jobs(namespace_id, params)
    local page, per, offset = page_of(params)
    local where, args = "j.namespace_id = ? AND j.deleted_at IS NULL", { namespace_id }
    if JOB_STATUSES[params.status] then
        where = where .. " AND j.status = ?"
        args[#args + 1] = params.status
    end
    if str(params.q) then
        where = where .. " AND j.title ILIKE ?"
        args[#args + 1] = "%" .. str(params.q, 100):gsub("[%%_]", "\\%0") .. "%"
    end
    local total = db.query("SELECT count(*)::int AS n FROM ats_jobs j WHERE " .. where, unpack(args))[1].n
    args[#args + 1] = per
    args[#args + 1] = offset
    local out = {}
    for _, r in ipairs(db.query(JOB_SELECT .. " WHERE " .. where .. " ORDER BY j.created_at DESC LIMIT ? OFFSET ?",
        unpack(args))) do
        out[#out + 1] = job_out(r)
    end
    return J.array(out), meta(total, page, per)
end

function Q.job(namespace_id, uuid)
    local r = db.query(JOB_SELECT .. " WHERE j.namespace_id = ? AND j.uuid = ? AND j.deleted_at IS NULL",
        namespace_id, uuid or "")[1]
    if not r then return nil, "Job not found" end
    return job_out(r)
end

local function kit_id_of(namespace_id, kit_uuid)
    if not str(kit_uuid) then return nil end
    local k = db.select("id FROM ats_kits WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", namespace_id,
        kit_uuid)[1]
    return k and k.id or false
end

function Q.create_job(namespace_id, data, actor)
    local title = str(data.title, 200)
    if not title then return nil, "Give the job a title." end
    local status = JOB_STATUSES[data.status] and data.status or "open"
    local kit_id = kit_id_of(namespace_id, data.kit_uuid)
    if kit_id == false then return nil, "Kit not found" end
    local r = db.insert("ats_jobs", { namespace_id = namespace_id, title = title, department = str(data.department,
        120),
        location = str(data.location, 200), employment_type = str(data.employment_type, 40),
        description = str(data.description, 20000), status = status, kit_id = kit_id, created_by_uuid = actor },
        { returning = "*" })[1]
    Q.audit(namespace_id, actor, "job_created", "job", r.uuid, { title = title })
    return Q.job(namespace_id, r.uuid)
end

function Q.update_job(namespace_id, uuid, data, actor)
    local r = Q.job_row(namespace_id, uuid)
    if not r then return nil, "Job not found" end
    local f = { updated_at = db.raw("NOW()") }
    if data.title ~= nil then
        f.title = str(data.title, 200)
        if not f.title then return nil, "Give the job a title." end
    end
    for _, k in ipairs({ "department", "location", "employment_type" }) do
        if data[k] ~= nil then f[k] = str(data[k], 200) or db.NULL end
    end
    if data.description ~= nil then f.description = str(data.description, 20000) or db.NULL end
    if data.status ~= nil then
        if not JOB_STATUSES[data.status] then return nil, "Unknown status" end
        f.status = data.status
    end
    if data.kit_uuid ~= nil then
        local kit_id = kit_id_of(namespace_id, data.kit_uuid)
        if kit_id == false then return nil, "Kit not found" end
        f.kit_id = kit_id or db.NULL
    end
    db.update("ats_jobs", f, { id = r.id })
    Q.audit(namespace_id, actor, "job_updated", "job", uuid, {})
    return Q.job(namespace_id, uuid)
end

function Q.delete_job(namespace_id, uuid, actor)
    local r = Q.job_row(namespace_id, uuid)
    if not r then return nil, "Job not found" end
    db.update("ats_jobs", { deleted_at = db.raw("NOW()"), status = "closed" }, { id = r.id })
    Q.audit(namespace_id, actor, "job_deleted", "job", uuid, {})
    return { uuid = uuid, deleted = true }
end

-- MARK: Applications

local function application_out(r)
    return { uuid = r.uuid, stage = r.stage, stage_changed_at = r.stage_changed_at,
        decision_reason = v(r.decision_reason),
        decided_by = v(r.decided_by_name), decided_at = v(r.decided_at), created_at = r.created_at,
        job = r.job_uuid and { uuid = r.job_uuid, title = r.job_title } or nil,
        candidate = r.candidate_uuid and { uuid = r.candidate_uuid, name = r.candidate_name,
            email = v(r.candidate_email) } or nil,
        latest_interview = r.interview_uuid and { uuid = r.interview_uuid, state = r.interview_state,
            evaluation_status = r.evaluation_status, reviewed = v(r.interview_reviewed) == true } or nil }
end

local APP_SELECT = [[
    SELECT a.*, j.uuid AS job_uuid, j.title AS job_title, c.uuid AS candidate_uuid, c.name AS candidate_name,
      c.email AS candidate_email, i.uuid AS interview_uuid, i.state AS interview_state, i.evaluation_status,
      (i.review IS NOT NULL) AS interview_reviewed
    FROM ats_applications a
    JOIN ats_jobs j ON j.id = a.job_id
    JOIN ats_candidates c ON c.id = a.candidate_id
    LEFT JOIN LATERAL (SELECT * FROM ats_interviews x WHERE x.application_id = a.id
                       ORDER BY x.id DESC LIMIT 1) i ON TRUE
]]

function Q.application_row(namespace_id, uuid)
    return db.select("* FROM ats_applications WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid or "")[1]
end

function Q.application(namespace_id, uuid)
    local r = db.query(APP_SELECT .. " WHERE a.namespace_id = ? AND a.uuid = ?", namespace_id, uuid or "")[1]
    if not r then return nil, "Application not found" end
    return application_out(r)
end

--- The job's applications grouped by stage, for the kanban.
function Q.pipeline(namespace_id, job_uuid)
    local job = Q.job_row(namespace_id, job_uuid)
    if not job then return nil, "Job not found" end
    local columns = {}
    for _, s in ipairs(Q.STAGE_ORDER) do columns[s] = J.array({}) end
    for _, r in ipairs(db.query(APP_SELECT
        .. " WHERE a.namespace_id = ? AND a.job_id = ? ORDER BY a.stage_changed_at DESC",
        namespace_id, job.id)) do
        local col = columns[r.stage]
        col[#col + 1] = application_out(r)
    end
    local out = J.array({})
    for _, s in ipairs(Q.STAGE_ORDER) do out[#out + 1] = { stage = s, applications = columns[s] } end
    return out
end

function Q.create_application(namespace_id, job_uuid, candidate_uuid, actor, stage)
    local job = Q.job_row(namespace_id, job_uuid)
    if not job then return nil, "Job not found" end
    local cand = Q.candidate_row(namespace_id, candidate_uuid)
    if not cand then return nil, "Candidate not found" end
    local existing = db.select("uuid FROM ats_applications WHERE job_id = ? AND candidate_id = ?", job.id, cand.id)[1]
    if existing then return Q.application(namespace_id, existing.uuid) end
    stage = (STAGES[stage] and stage ~= "rejected") and stage or "applied"
    local r = db.insert("ats_applications", { namespace_id = namespace_id, job_id = job.id, candidate_id = cand.id,
        stage = stage }, { returning = "*" })[1]
    Q.audit(namespace_id, actor, "application_created", "application", r.uuid, { job = job.uuid,
        candidate = cand.uuid })
    return Q.application(namespace_id, r.uuid)
end

--- Moves to any stage except rejected (that's Q.reject, a person's decision with a reason).
function Q.move_stage(namespace_id, uuid, stage, actor)
    if not STAGES[stage] then return nil, "Unknown stage" end
    if stage == "rejected" then return nil, "Use reject, with a reason, to reject a candidate." end
    local r = Q.application_row(namespace_id, uuid)
    if not r then return nil, "Application not found" end
    if r.stage ~= stage then
        db.update("ats_applications", { stage = stage, stage_changed_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()") },
            { id = r.id })
        Q.audit(namespace_id, actor, "stage_changed", "application", uuid, { from = r.stage, to = stage })
    end
    return Q.application(namespace_id, uuid)
end

--- A person's rejection. The only code that writes stage = 'rejected'.
function Q.reject(namespace_id, uuid, reason, actor, actor_name)
    reason = str(reason, 500)
    if not reason then return nil, "Give a reason for the decision." end
    if not actor then return nil, "A rejection must be made by a signed-in person." end
    local r = Q.application_row(namespace_id, uuid)
    if not r then return nil, "Application not found" end
    db.update("ats_applications", { stage = "rejected", stage_changed_at = db.raw("NOW()"), decision_reason = reason,
        decided_by_uuid = actor, decided_by_name = actor_name or actor, decided_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()") }, { id = r.id })
    Q.audit(namespace_id, actor, "rejected", "application", uuid, { from = r.stage, reason = reason })
    return Q.application(namespace_id, uuid)
end

-- MARK: Notes

function Q.notes(namespace_id, candidate_id)
    return J.array(db.query([[SELECT n.uuid, n.body, n.author_name, n.created_at, a.uuid AS application_uuid
        FROM ats_notes n LEFT JOIN ats_applications a ON a.id = n.application_id
        WHERE n.namespace_id = ? AND n.candidate_id = ? ORDER BY n.id DESC]], namespace_id, candidate_id))
end

function Q.add_note(namespace_id, candidate_uuid, data, actor, actor_name)
    local cand = Q.candidate_row(namespace_id, candidate_uuid)
    if not cand then return nil, "Candidate not found" end
    local body = str(data.body, 10000)
    if not body then return nil, "Write something first." end
    local app_id
    if str(data.application_uuid) then
        local a = Q.application_row(namespace_id, data.application_uuid)
        if not a or a.candidate_id ~= cand.id then return nil, "Application not found" end
        app_id = a.id
    end
    local r = db.insert("ats_notes", { namespace_id = namespace_id, candidate_id = cand.id, application_id = app_id,
        body = body, author_uuid = actor, author_name = actor_name }, { returning = "*" })[1]
    Q.audit(namespace_id, actor, "note_added", "candidate", cand.uuid, {})
    return { uuid = r.uuid, body = r.body, author_name = actor_name, created_at = r.created_at }
end

-- MARK: Candidates

function Q.candidate_row(namespace_id, uuid)
    return db.select("* FROM ats_candidates WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid or "")[1]
end

local function candidate_out(r)
    return { uuid = r.uuid, name = r.name, email = v(r.email), phone = v(r.phone), reference = v(r.reference),
        links = decode(r.links) or J.array({}), source = v(r.source), tags = decode(r.tags) or J.array({}),
        created_at = r.created_at, updated_at = r.updated_at, applications = tonumber(v(r.applications)) }
end

local function valid_email(e)
    return e == nil or e:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") ~= nil
end

function Q.candidates(namespace_id, params)
    local page, per, offset = page_of(params)
    local where, args = "c.namespace_id = ?", { namespace_id }
    if str(params.q) then
        local like = "%" .. str(params.q, 100):gsub("[%%_]", "\\%0") .. "%"
        where = where .. " AND (c.name ILIKE ? OR c.email ILIKE ? OR c.reference ILIKE ?)"
        args[#args + 1], args[#args + 2], args[#args + 3] = like, like, like
    end
    local total = db.query("SELECT count(*)::int AS n FROM ats_candidates c WHERE " .. where, unpack(args))[1].n
    args[#args + 1] = per
    args[#args + 1] = offset
    local out = {}
    for _, r in ipairs(db.query([[SELECT c.*, (SELECT count(*) FROM ats_applications a WHERE a.candidate_id = c.id)::int
        AS applications FROM ats_candidates c WHERE ]] .. where .. " ORDER BY c.created_at DESC LIMIT ? OFFSET ?",
        unpack(args))) do
        out[#out + 1] = candidate_out(r)
    end
    return J.array(out), meta(total, page, per)
end

--- Finds a candidate by email (else by name + reference), or creates one.
function Q.find_or_create_candidate(namespace_id, data, actor, source)
    local name = str(data.name, 200)
    local email = str(data.email, 254)
    email = email and email:lower() or nil
    if not valid_email(email) then return nil, "That email address doesn't look right." end
    if email then
        local r = db.query("SELECT * FROM ats_candidates WHERE namespace_id = ? AND lower(email) = ?", namespace_id,
            email)[1]
        if r then return r, false end
    elseif name and str(data.reference) then
        local r = db.select("* FROM ats_candidates WHERE namespace_id = ? AND name = ? AND reference = ?",
            namespace_id, name, str(data.reference, 200))[1]
        if r then return r, false end
    end
    if not name then return nil, "Give the candidate's name." end
    local r = db.insert("ats_candidates", { namespace_id = namespace_id, name = name, email = email,
        phone = str(data.phone, 40), reference = str(data.reference, 200), source = str(source or data.source, 64),
        links = J.encode(type(data.links) == "table" and data.links or J.array({})),
        tags = J.encode(type(data.tags) == "table" and data.tags or J.array({})) }, { returning = "*" })[1]
    Q.audit(namespace_id, actor, "candidate_created", "candidate", r.uuid, { source = source })
    return r, true
end

function Q.create_candidate(namespace_id, data, actor)
    local email = str(data.email, 254)
    if email and db.query("SELECT 1 FROM ats_candidates WHERE namespace_id = ? AND lower(email) = ?", namespace_id,
        email:lower())[1] then
        return nil, "A candidate with that email already exists."
    end
    local r, err = Q.find_or_create_candidate(namespace_id, data, actor, data.source or "dashboard")
    if not r then return nil, err end
    if str(data.job_uuid) then Q.create_application(namespace_id, data.job_uuid, r.uuid, actor) end
    return Q.candidate(namespace_id, r.uuid)
end

function Q.candidate(namespace_id, uuid)
    local r = Q.candidate_row(namespace_id, uuid)
    if not r then return nil, "Candidate not found" end
    local out = candidate_out(r)
    local apps = {}
    for _, a in ipairs(db.query(APP_SELECT .. " WHERE a.namespace_id = ? AND a.candidate_id = ? ORDER BY a.id DESC",
        namespace_id, r.id)) do
        apps[#apps + 1] = application_out(a)
    end
    out.applications = J.array(apps)
    out.interviews = J.array(db.query([[SELECT i.uuid, i.state, i.source, i.evaluation_status, i.started_at, i.ended_at,
        (i.review IS NOT NULL) AS reviewed, i.review->>'decision' AS decision, j.title AS job_title,
        a.uuid AS application_uuid
        FROM ats_interviews i JOIN ats_applications a ON a.id = i.application_id JOIN ats_jobs j ON j.id = a.job_id
        WHERE i.namespace_id = ? AND a.candidate_id = ? ORDER BY i.id DESC]], namespace_id, r.id))
    out.notes = Q.notes(namespace_id, r.id)
    out.attachments = J.array(db.query([[SELECT uuid, name, content_type, size, created_at FROM ats_attachments
        WHERE namespace_id = ? AND candidate_id = ? ORDER BY id DESC]], namespace_id, r.id))
    return out
end

function Q.update_candidate(namespace_id, uuid, data, actor)
    local r = Q.candidate_row(namespace_id, uuid)
    if not r then return nil, "Candidate not found" end
    local f = { updated_at = db.raw("NOW()") }
    if data.name ~= nil then
        f.name = str(data.name, 200)
        if not f.name then return nil, "Give the candidate's name." end
    end
    if data.email ~= nil then
        local e = str(data.email, 254)
        e = e and e:lower()
        if not valid_email(e) then return nil, "That email address doesn't look right." end
        if e and db.query("SELECT 1 FROM ats_candidates WHERE namespace_id = ? AND lower(email) = ? AND id <> ?",
            namespace_id, e, r.id)[1] then
            return nil, "A candidate with that email already exists."
        end
        f.email = e or db.NULL
    end
    for _, k in ipairs({ "phone", "reference", "source" }) do
        if data[k] ~= nil then f[k] = str(data[k], 200) or db.NULL end
    end
    if type(data.links) == "table" then f.links = J.encode(data.links) end
    if type(data.tags) == "table" then f.tags = J.encode(data.tags) end
    db.update("ats_candidates", f, { id = r.id })
    Q.audit(namespace_id, actor, "candidate_updated", "candidate", uuid, {})
    return Q.candidate(namespace_id, uuid)
end

--- Everything held about a candidate (subject access request).
function Q.export_candidate(namespace_id, uuid, actor)
    local r = Q.candidate_row(namespace_id, uuid)
    if not r then return nil, "Candidate not found" end
    local out = Q.candidate(namespace_id, uuid)
    out.interviews = J.array({})
    for _, i in ipairs(db.query([[SELECT i.uuid, i.state, i.source, i.session, i.evaluation, i.review, i.started_at,
        i.ended_at, i.created_at FROM ats_interviews i JOIN ats_applications a ON a.id = i.application_id
        WHERE i.namespace_id = ? AND a.candidate_id = ? ORDER BY i.id]], namespace_id, r.id)) do
        local s = decode(i.session) or {}
        out.interviews[#out.interviews + 1] = { uuid = i.uuid, state = i.state, source = i.source,
            started_at = v(i.started_at), ended_at = v(i.ended_at), transcript = s.turns or J.array({}),
            eligibility_answers = s.eligibility_answers or {}, adjustments = s.adjustments or J.array({}),
            flags = s.flags or J.array({}), evaluation = decode(i.evaluation), review = decode(i.review) }
    end
    out.exported_at = T.iso(ngx and ngx.time() or os.time())
    Q.audit(namespace_id, actor, "candidate_exported", "candidate", uuid, {})
    return out
end

--- Deletes a candidate for real: interviews, notes, files, self-ID. Only an audit entry stays.
function Q.delete_candidate(namespace_id, uuid, actor)
    local r = Q.candidate_row(namespace_id, uuid)
    if not r then return nil, "Candidate not found" end
    local keys = db.query([[SELECT i.self_id_key FROM ats_interviews i
        JOIN ats_applications a ON a.id = i.application_id
        WHERE a.candidate_id = ? AND i.self_id_key IS NOT NULL]], r.id)
    local files = db.select("object_key FROM ats_attachments WHERE candidate_id = ?", r.id)
    db.query("BEGIN")
    local ok, err = pcall(function()
        for _, k in ipairs(keys) do db.query("DELETE FROM ats_self_id WHERE key = ?", k.self_id_key) end
        db.query("DELETE FROM ats_candidates WHERE id = ?",
            r.id) -- cascades: applications, interviews, notes, attachments
        Q.audit(namespace_id, actor, "candidate_deleted", "candidate", uuid, {})
    end)
    db.query(ok and "COMMIT" or "ROLLBACK")
    if not ok then return nil, "Couldn't delete the candidate: " .. tostring(err) end
    for _, f in ipairs(files) do
        pcall(function() require("helper.minio").quickDelete(f.object_key) end)
    end
    return { uuid = uuid, deleted = true }
end

-- MARK: Kits

local function kit_out(r, full)
    local kit = decode(r.kit) or {}
    local out = { uuid = r.uuid, title = r.title, version = r.version, approved_at = v(r.approved_at),
        approved_by = v(r.approved_by), source = r.source, created_at = r.created_at, updated_at = r.updated_at,
        job_uuid = v(r.job_uuid), competencies = #(kit.competencies or {}), questions = #(kit.questions or {}) }
    if full then
        out.kit = kit
        out.issues = Kit.validate(kit)
    end
    return out
end

local KIT_SELECT = "SELECT k.*, j.uuid AS job_uuid FROM ats_kits k LEFT JOIN ats_jobs j ON j.id = k.job_id"

function Q.kit_row(namespace_id, uuid)
    return db.select("* FROM ats_kits WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", namespace_id, uuid
        or "")[1]
end

function Q.kits(namespace_id, params)
    local where = "k.namespace_id = ? AND k.deleted_at IS NULL"
    if params.approved == "true" then where = where .. " AND k.approved_at IS NOT NULL" end
    local out = {}
    for _, r in ipairs(db.query(KIT_SELECT .. " WHERE " .. where .. " ORDER BY k.updated_at DESC LIMIT 500",
        namespace_id)) do
        out[#out + 1] = kit_out(r, params.full == true)
    end
    return J.array(out)
end

function Q.kit(namespace_id, uuid)
    local r = db.query(KIT_SELECT .. " WHERE k.namespace_id = ? AND k.uuid = ? AND k.deleted_at IS NULL",
        namespace_id, uuid or "")[1]
    if not r then return nil, "Kit not found" end
    return kit_out(r, true)
end

--- The kit as stored (normalised), with its id and approval written in, as the app's RoleKit.
function Q.kit_contract(r)
    local kit = Kit.normalise(decode(r.kit) or {})
    kit.id = v(r.external_kit_id) or r.uuid
    kit.version = r.version
    -- ISO 8601: the app's kit format (the column prints as "2026-10-18 10:00:00+00").
    kit.approved_at = v(r.approved_at) and require("lib.ats.offline").to_iso(r.approved_at) or nil
    kit.approved_by = v(r.approved_by)
    return kit
end

function Q.create_kit(namespace_id, data, actor)
    local kit = Kit.normalise(type(data.kit) == "table" and data.kit or data)
    if str(data.title) then kit.title = str(data.title, 200) end
    local job_id
    if str(data.job_uuid) then
        local job = Q.job_row(namespace_id, data.job_uuid)
        if not job then return nil, "Job not found" end
        job_id = job.id
    end
    kit.approved_at, kit.approved_by, kit.version = nil, nil, 0
    local r = db.insert("ats_kits", { namespace_id = namespace_id, job_id = job_id, title = kit.title,
        kit = J.encode(kit), version = 0, created_by_uuid = actor, source = str(data.source, 32) or "dashboard" },
        { returning = "*" })[1]
    if job_id then db.update("ats_jobs", { kit_id = r.id }, { id = job_id, kit_id = db.NULL }) end
    Q.audit(namespace_id, actor, "kit_created", "kit", r.uuid, { title = kit.title })
    return Q.kit(namespace_id, r.uuid)
end

--- Any edit clears approval: the kit needs approving again.
function Q.update_kit(namespace_id, uuid, data, actor)
    local r = Q.kit_row(namespace_id, uuid)
    if not r then return nil, "Kit not found" end
    local kit = Kit.normalise(type(data.kit) == "table" and data.kit or decode(r.kit) or {})
    kit.approved_at, kit.approved_by = nil, nil
    db.update("ats_kits", { kit = J.encode(kit), title = kit.title, approved_at = db.NULL, approved_by = db.NULL,
        updated_at = db.raw("NOW()") }, { id = r.id })
    Q.audit(namespace_id, actor, "kit_updated", "kit", uuid, {})
    return Q.kit(namespace_id, uuid)
end

function Q.delete_kit(namespace_id, uuid, actor)
    local r = Q.kit_row(namespace_id, uuid)
    if not r then return nil, "Kit not found" end
    db.update("ats_kits", { deleted_at = db.raw("NOW()") }, { id = r.id })
    Q.audit(namespace_id, actor, "kit_deleted", "kit", uuid, {})
    return { uuid = uuid, deleted = true }
end

function Q.approve_kit(namespace_id, uuid, actor, actor_name)
    local r = Q.kit_row(namespace_id, uuid)
    if not r then return nil, "Kit not found" end
    local kit = Kit.normalise(decode(r.kit) or {})
    if not Kit.can_approve(kit) then return nil, "Fix the errors in the kit before approving it." end
    local version = (tonumber(r.version) or 0) + 1
    kit.version = version
    kit.approved_by = actor_name or actor
    db.update("ats_kits", { kit = J.encode(kit), version = version, approved_at = db.raw("NOW()"),
        approved_by = actor_name or actor, updated_at = db.raw("NOW()") }, { id = r.id })
    Q.audit(namespace_id, actor, "kit_approved", "kit", uuid, { version = version })
    return Q.kit(namespace_id, uuid)
end

-- MARK: Integration tokens (Snazzy Pro desktop)

Q.TOKEN_PREFIX = "snz_"

function Q.tokens(namespace_id)
    return J.array(db.query([[SELECT uuid, name, token_prefix, created_at, last_used_at, revoked_at
        FROM ats_integration_tokens WHERE namespace_id = ? ORDER BY id DESC]], namespace_id))
end

--- Creates a token; the raw value is returned once and never stored.
function Q.create_token(namespace_id, name, actor)
    name = str(name, 120) or "Snazzy Pro"
    local raw = Q.TOKEN_PREFIX .. Hash.random_token()
    local r = db.insert("ats_integration_tokens", { namespace_id = namespace_id, name = name,
        token_hash = Hash.sha256_hex(raw), token_prefix = raw:sub(1, 10), created_by_uuid = actor },
            { returning = "*" })[1]
    Q.audit(namespace_id, actor, "token_created", "token", r.uuid, { name = name })
    return { uuid = r.uuid, name = name, token = raw, token_prefix = r.token_prefix, created_at = r.created_at }
end

function Q.revoke_token(namespace_id, uuid, actor)
    local r = db.select("* FROM ats_integration_tokens WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid
        or "")[1]
    if not r then return nil, "Token not found" end
    db.update("ats_integration_tokens", { revoked_at = db.raw("NOW()") }, { id = r.id })
    Q.audit(namespace_id, actor, "token_revoked", "token", uuid, {})
    return { uuid = uuid, revoked = true }
end

--- The namespace a raw token belongs to (nil when unknown or revoked). Looked up
-- by its SHA-256 (a unique index); the stored hash is then compared in constant time.
function Q.verify_token(raw)
    if type(raw) ~= "string" or raw:sub(1, #Q.TOKEN_PREFIX) ~= Q.TOKEN_PREFIX or #raw > 100 then return nil end
    local h = Hash.sha256_hex(raw)
    local r = db.query([[SELECT t.id, t.uuid, t.token_hash, t.namespace_id, n.name AS namespace_name,
        n.uuid AS namespace_uuid
        FROM ats_integration_tokens t JOIN namespaces n ON n.id = t.namespace_id
        WHERE t.token_hash = ? AND t.revoked_at IS NULL]], h)[1]
    if not r or not require("lib.stripe")._secure_compare(r.token_hash, h) then return nil end
    db.query([[UPDATE ats_integration_tokens SET last_used_at = NOW()
        WHERE id = ? AND (last_used_at IS NULL OR last_used_at < NOW() - interval '1 minute')]], r.id)
    return r
end

return Q
