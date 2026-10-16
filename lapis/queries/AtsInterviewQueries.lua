--[[
    ATS — interviews: invitations, the candidate's side (by link token), the
    evaluator, a person's review, imports from the Snazzy Pro desktop app,
    fairness reports and retention.

    The engine state lives in ats_interviews.session (JSONB): the kit snapshot,
    turns, flags, answers, times. Each change bumps session.rev, and a save
    only lands if rev is unchanged (two tabs can't interleave answers).
]]

local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local db = require("lapis.db")
local J = require("lib.ats.json")
local T = require("lib.ats.text")
local Kit = require("lib.ats.kit")
local Engine = require("lib.ats.engine")
local Ev = require("lib.ats.evaluator")
local P = require("lib.ats.prompts")
local L = require("lib.ats.llm")
local F = require("lib.ats.fairness")
local Hash = require("lib.ats.hash")
local Activation = require("lib.ats.activation")
local Q = require("queries.AtsQueries")

local I = {}

local DECISIONS = { advance = true, hold = true, decline = true }
local EARLY_STAGES = { applied = true, screening = true, interview = true }

local function v(x) return J.val(x) end
local function decode(x)
    x = v(x)
    if type(x) == "table" then return x end
    return J.decode(x) or nil
end
local function now() return ngx.time() end
local function ts_sql(t) return t and db.raw(("to_timestamp(%d)"):format(math.floor(t))) or db.NULL end

function I.dashboard_url(uuid)
    return Activation.public_url() .. "/dashboard/ats/interviews/" .. uuid
end

function I.row(namespace_id, uuid)
    return db.select("* FROM ats_interviews WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid or "")[1]
end

-- MARK: Invitations

function I.invite(namespace_id, data, actor)
    local blocked = Activation.require_active(namespace_id)
    if blocked then return nil, blocked.json.error, 402 end
    local app = Q.application_row(namespace_id, data.application_uuid)
    if not app then return nil, "Application not found" end
    local kit_row = Q.kit_row(namespace_id, data.kit_uuid)
    if not kit_row then
        local job = db.select("kit_id FROM ats_jobs WHERE id = ?", app.job_id)[1]
        kit_row = job and v(job.kit_id) and db.select("* FROM ats_kits WHERE id = ? AND deleted_at IS NULL",
            job.kit_id)[1]
    end
    if not kit_row then return nil, "Choose an interview kit (the job has none)." end
    if not v(kit_row.approved_at) then return nil, "Approve the kit before inviting candidates." end
    local pack_id, perr = require("queries.AtsPackQueries").id_for_invite(namespace_id, data.pack_uuid)
    if perr then return nil, perr end
    local settings = Q.settings(namespace_id)
    local kit = Q.kit_contract(kit_row)
    kit.settings.retention_days = settings.retention_days
    if not settings.ratings_enabled then kit.settings.ratings_enabled = false end
    local cand = db.select("* FROM ats_candidates WHERE id = ?", app.candidate_id)[1]
    local days = math.min(30, math.max(1, math.floor(tonumber(data.expires_in_days) or 7)))
    local token = Hash.random_token()
    local session = Engine.new_session(kit, { name = cand.name, email = v(cand.email) or "",
        reference = v(cand.reference) or "" }, now())
    session.channel = "hosted"
    session.rev = 0
    session.models = { interviewer = L.label("interviewer") }
    local r = db.insert("ats_interviews", { namespace_id = namespace_id, application_id = app.id, kit_id = kit_row.id,
        kit_version = kit_row.version, source = "hosted", state = "invited", session = J.encode(session),
        link_token_hash = Hash.sha256_hex(token), link_expires_at = db.raw(("NOW() + interval '%d days'"):format(days)),
        pack_id = pack_id,
        invited_by_uuid = actor, delete_after = ts_sql(session.delete_after_ts) }, { returning = "*" })[1]
    if EARLY_STAGES[app.stage] and app.stage ~= "interview" then Q.move_stage(namespace_id, app.uuid, "interview",
        actor) end
    Q.audit(namespace_id, actor, "interview_invited", "interview", r.uuid, { application = app.uuid,
        kit_version = kit_row.version })
    local url = Activation.public_url() .. "/i/" .. token
    return { uuid = r.uuid, url = url, app_url = pack_id and I.app_url(url) or nil, expires_at = r.link_expires_at,
        note = "Copy this link now: it isn't shown again." }
end

--- The link that opens an invite in the Snazzy Pro app (for interviews with a pack).
function I.app_url(url)
    return "snazzypro://interview?link=" .. ngx.escape_uri(url) .. "&api=" .. ngx.escape_uri(Activation.api_url())
end

--- The row for a kit made in the Snazzy Pro app, matched by the app's kit id and
-- version (kept as sent: it was approved in the app by a person), or created.
-- @return row, external_kit_id
function I.desktop_kit_row(namespace_id, kit, actor)
    local kit_ext = kit.id or ("title:" .. kit.title)
    local kit_row = db.select("* FROM ats_kits WHERE namespace_id = ? AND external_kit_id = ? AND version = ? LIMIT 1",
        namespace_id, kit_ext, kit.version or 0)[1]
    if not kit_row then
        kit_row = db.insert("ats_kits", { namespace_id = namespace_id, title = kit.title, kit = J.encode(kit),
            version = kit.version or 0, approved_at = kit.approved_at or db.NULL, approved_by = kit.approved_by,
            external_kit_id = kit_ext, source = "snazzy_desktop", created_by_uuid = actor }, { returning = "*" })[1]
    end
    return kit_row, kit_ext
end

I.MAX_BULK = 500

--- Invites many candidates to one kit (and pack) at once: each gets their own
-- link, so they can all interview in parallel. Without job_uuid, the kit's open
-- job is used (or made). One candidate's problem doesn't stop the others.
-- data: {kit_uuid | kit (the app's approved RoleKit), pack_uuid?, job_uuid?, expires_in_days?,
--        candidates = {{name, email, reference}}}
-- @return {invited, failed, results = {{name, email, uuid, url, app_url | error}}} | nil, err, status
function I.invite_many(namespace_id, data, actor)
    local blocked = Activation.require_active(namespace_id)
    if blocked then return nil, blocked.json.error, 402 end
    local list = type(data.candidates) == "table" and data.candidates or {}
    if #list == 0 then return nil, "Add at least one candidate." end
    if #list > I.MAX_BULK then return nil, ("At most %d candidates at a time."):format(I.MAX_BULK) end
    local kit_row
    if type(data.kit) == "table" then
        -- A kit from the Snazzy Pro app (approved there by a person): checked again here.
        local kit = Kit.normalise(data.kit)
        if not kit.approved_at or not Kit.can_approve(kit) then
            return nil, "The kit must be approved, with no errors, before inviting candidates."
        end
        kit_row = I.desktop_kit_row(namespace_id, kit, actor)
    else
        kit_row = Q.kit_row(namespace_id, data.kit_uuid)
    end
    if not kit_row then return nil, "Kit not found" end
    if not v(kit_row.approved_at) then return nil, "Approve the kit before inviting candidates." end
    local _, perr = require("queries.AtsPackQueries").id_for_invite(namespace_id, data.pack_uuid)
    if perr then return nil, perr end
    local job_uuid = v(data.job_uuid)
    if job_uuid then
        if not Q.job_row(namespace_id, job_uuid) then return nil, "Job not found" end
    else
        local job = db.select("uuid FROM ats_jobs WHERE namespace_id = ? AND kit_id = ? AND status = 'open' "
            .. "AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1", namespace_id, kit_row.id)[1]
        if not job then
            local created, jerr = Q.create_job(namespace_id, { title = kit_row.title, kit_uuid = kit_row.uuid }, actor)
            if not created then return nil, jerr end
            job = created
        end
        job_uuid = job.uuid
    end
    local results, invited, failed = J.array({}), 0, 0
    for _, c in ipairs(list) do
        c = type(c) == "table" and c or {}
        local item = { name = v(c.name), email = v(c.email) }
        local cand, cerr = Q.find_or_create_candidate(namespace_id, c, actor, "bulk_invite")
        local app, aerr
        if cand then app, aerr = Q.create_application(namespace_id, job_uuid, cand.uuid, actor) end
        local inv, ierr
        if app then
            inv, ierr = I.invite(namespace_id, { application_uuid = app.uuid, kit_uuid = kit_row.uuid,
                pack_uuid = data.pack_uuid, expires_in_days = data.expires_in_days }, actor)
        end
        if inv then
            item.uuid, item.url, item.app_url, item.expires_at = inv.uuid, inv.url, inv.app_url, inv.expires_at
            invited = invited + 1
        else
            item.error = tostring(cerr or aerr or ierr or "Couldn't invite")
            failed = failed + 1
        end
        results[#results + 1] = item
    end
    Q.audit(namespace_id, actor, "interviews_bulk_invited", "kit", kit_row.uuid, { invited = invited,
        failed = failed })
    return { invited = invited, failed = failed, job_uuid = job_uuid, kit_uuid = kit_row.uuid, results = results,
        note = "Copy these links now: they aren't shown again." }
end

function I.revoke(namespace_id, uuid, actor)
    local r = I.row(namespace_id, uuid)
    if not r then return nil, "Interview not found" end
    db.update("ats_interviews", { link_expires_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = r.id })
    Q.audit(namespace_id, actor, "link_revoked", "interview", uuid, {})
    return { uuid = uuid, revoked = true }
end

-- MARK: Recruiter views

local LIST_SELECT = [[
    SELECT i.uuid, i.state, i.source, i.evaluation_status, i.started_at, i.ended_at, i.created_at, i.link_expires_at,
      i.review->>'decision' AS decision, (i.review IS NOT NULL) AS reviewed,
      jsonb_array_length(COALESCE(i.session->'flags', '[]'::jsonb)) AS flag_count,
      c.uuid AS candidate_uuid, c.name AS candidate_name, j.uuid AS job_uuid, j.title AS job_title,
      a.uuid AS application_uuid
    FROM ats_interviews i JOIN ats_applications a ON a.id = i.application_id
    JOIN ats_candidates c ON c.id = a.candidate_id JOIN ats_jobs j ON j.id = a.job_id
]]

function I.list(namespace_id, params)
    local page = math.max(1, math.floor(tonumber(params.page) or 1))
    local per = math.min(100, math.max(1, math.floor(tonumber(params.per_page) or 25)))
    local where, args = "i.namespace_id = ?", { namespace_id }
    if params.state and params.state ~= "" then
        where = where .. " AND i.state = ?"
        args[#args + 1] = params.state
    end
    if params.to_review == "true" then where = where
        .. " AND i.state IN ('completed','human_requested') AND i.review IS NULL" end
    if params.job_uuid and params.job_uuid ~= "" then
        where = where .. " AND j.uuid = ?"
        args[#args + 1] = params.job_uuid
    end
    local total = db.query([[SELECT count(*)::int AS n FROM ats_interviews i
        JOIN ats_applications a ON a.id = i.application_id
        JOIN ats_jobs j ON j.id = a.job_id WHERE ]] .. where, unpack(args))[1].n
    args[#args + 1] = per
    args[#args + 1] = (page - 1) * per
    local rows = db.query(LIST_SELECT .. " WHERE " .. where .. " ORDER BY i.id DESC LIMIT ? OFFSET ?", unpack(args))
    return J.array(rows), { total = total, page = page, per_page = per, total_pages = math.max(1,
        math.ceil(total / per)) }
end

function I.detail(namespace_id, uuid)
    local r = db.query(LIST_SELECT .. " WHERE i.namespace_id = ? AND i.uuid = ?", namespace_id, uuid or "")[1]
    if not r then return nil, "Interview not found" end
    local full = I.row(namespace_id, uuid)
    local s = decode(full.session) or {}
    local kit = Kit.normalise(s.kit or {})
    local eligibility = J.array({})
    for _, q in ipairs(kit.eligibility) do
        local answer = s.eligibility_answers and s.eligibility_answers[q.id]
        eligibility[#eligibility + 1] = { id = q.id, text = q.text, answer = answer,
            meets = answer and Kit.meets(q, answer) }
    end
    r.kit = kit
    r.kit_version = full.kit_version
    r.turns = s.turns or J.array({})
    r.flags = s.flags or J.array({})
    r.eligibility = eligibility
    r.adjustments = s.adjustments or J.array({})
    r.forwarded_questions = s.forwarded_questions or J.array({})
    r.models = s.models or {}
    r.end_reason = s.end_reason
    r.notice_hash = s.notice_hash
    r.evaluation = decode(full.evaluation)
    r.review = decode(full.review)
    r.low_agreement = J.array(Ev.low_agreement(r.evaluation))
    r.settings = Q.settings(namespace_id)
    r.dashboard_url = I.dashboard_url(uuid)
    return r
end

-- MARK: The candidate's side (link token)

--- The interview for a raw link token. @return row | nil, status (404 unknown, 410 expired)
function I.by_token(token)
    if type(token) ~= "string" or #token < 20 or #token > 100 then return nil, 404 end
    local r = db.query("SELECT *, (link_expires_at > NOW()) AS live FROM ats_interviews WHERE link_token_hash = ?",
        Hash.sha256_hex(token))[1]
    if not r then return nil, 404 end
    local s = decode(r.session) or {}
    -- An expired link still shows a finished interview's thank-you page.
    if not r.live and not Engine.is_finished(s) and s.state ~= "in_progress" and s.state ~= "paused" then
        return nil, 410
    end
    return r
end

local function candidate_view(r, s)
    local e = Engine.new(s, now)
    local turns = J.array({})
    for _, t in ipairs(s.turns or {}) do
        if t.role ~= "system" then
            turns[#turns + 1] = { id = t.id, role = t.role, text = t.text, kind = t.kind, question_id = t.question_id }
        end
    end
    local kit = s.kit
    local settings = Q.settings(r.namespace_id)
    local notice = P.notice(kit, L.provider_name())
    if settings.legal_notice ~= "" then notice = notice .. "\n\n" .. settings.legal_notice end
    local finished = Engine.is_finished(s)
    return {
        state = s.state, role_title = kit.title, organisation = kit.organisation,
        interviewer_name = kit.settings.interviewer_name, minutes = kit.settings.minutes,
        allow_pause = kit.settings.allow_pause, allowed_adjustments = kit.settings.allowed_adjustments,
        notice = notice, notice_hash = Hash.notice(notice), next_steps = kit.settings.next_steps,
        turns = turns, choices = e:current_choices(), progress = e:progress(),
        seconds_left = s.started_ts and math.floor(e:seconds_left()) or nil,
        question_count = #kit.questions,
        has_pack = v(r.pack_id) ~= nil,
        self_id = (finished and not v(r.self_id_key)) and F.QUESTIONS or nil,
    }
end

function I.public_view(r)
    local s = decode(r.session) or {}
    s.kit = Kit.normalise(s.kit)
    -- Time may have run out since the last request.
    if s.state == "in_progress" then
        local e = Engine.new(s, now)
        if e:seconds_left() <= 0 then
            e:tick()
            I.save(r, s)
        end
    end
    return candidate_view(r, s)
end

--- Saves a session if nobody else saved since it was read (rev check).
function I.save(r, s)
    local rev = tonumber(s.rev) or 0
    s.rev = rev + 1
    local f = { session = J.encode(s), state = s.state, updated_at = db.raw("NOW()"),
        started_at = ts_sql(s.started_ts), ended_at = ts_sql(s.ended_ts), delete_after = ts_sql(s.delete_after_ts) }
    local res = db.update("ats_interviews", f, "id = ? AND COALESCE((session->>'rev')::int, 0) = ?", r.id, rev)
    local n = type(res) == "table" and (res.affected_rows or 0) or 0
    if n == 0 then return nil, "conflict" end
    if Engine.is_finished(s) then I.on_finished(r, s) end
    return true
end

--- After an interview ends: move the application to review and start the evaluator.
function I.on_finished(r, s)
    local app = db.select("* FROM ats_applications WHERE id = ?", r.application_id)[1]
    if app and EARLY_STAGES[app.stage] and s.state == "completed" then
        db.update("ats_applications", { stage = "review", stage_changed_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()") },
            { id = app.id })
    end
    Q.audit(r.namespace_id, "candidate", "interview_ended", "interview", r.uuid, { state = s.state,
        reason = s.end_reason })
    if s.state == "completed" then I.evaluate_async(r.namespace_id, r.uuid, "engine") end
end

--- Runs the engine for one candidate action, calling the model when the engine asks.
local function run(r, s, step)
    local e = Engine.new(s, now)
    local nxt = step(e)
    local guard = 0
    while nxt.type == "model" and guard < 2 do
        guard = guard + 1
        local text, label = L.complete("interviewer", P.interviewer_system(s.kit, false),
            P.interviewer_message(s, nxt.directive), { namespace_id = r.namespace_id })
        if text then
            s.models = s.models or {}
            s.models.interviewer = label .. " · " .. P.INTERVIEWER
            nxt = e:apply(Engine.parse_reply(text), text)
        else
            e:flag("technical", "The AI interviewer didn't answer; moved on.")
            nxt = e:apply(nil, "")
        end
    end
    e:tick()
    local ok = I.save(r, s)
    if not ok then return nil, "Your answer crossed with another one. Please reload the page.", 409 end
    return candidate_view(r, s)
end

local function load_session(r)
    local s = decode(r.session) or {}
    s.kit = Kit.normalise(s.kit)
    return s
end

function I.start(r, data)
    local s = load_session(r)
    if s.state ~= "invited" then return candidate_view(r, s) end
    local blocked = Activation.require_active(r.namespace_id)
    if blocked then return nil, "This interview can't start right now. Please contact the hiring team.", 402 end
    local view = candidate_view(r, s)
    if data.notice_hash ~= view.notice_hash then
        return nil, "The information page changed. Please reload and read it again.", 409
    end
    local adjustments = {}
    for i, a in ipairs(type(data.adjustments) == "table" and data.adjustments or {}) do
        if i <= 10 and type(a) == "string" then adjustments[#adjustments + 1] = T.prefix(a, 500) end
    end
    return run(r, s, function(e)
        e:acknowledge(data.notice_hash, adjustments)
        return e:start()
    end)
end

function I.answer(r, data)
    local s = load_session(r)
    if s.state ~= "in_progress" then return candidate_view(r, s) end
    local text = type(data.text) == "string" and data.text or ""
    if T.len(text) > Engine.MAX_ANSWER then return nil, "That answer is too long (6,000 characters at most).", 413 end
    return run(r, s, function(e) return e:receive({ type = "answer", text = text, input = data.input }) end)
end

local EVENTS = { ["repeat"] = true, rephrase = true, pause = true, resume = true, person = true, withdraw = true,
    adjustment = true }

function I.event(r, data)
    if not EVENTS[data.type] then return nil, "Unknown action", 422 end
    local s = load_session(r)
    if Engine.is_finished(s) or s.state == "invited" then
        if data.type == "person" and s.state == "invited" then
            -- Before starting: ask for a person instead.
            return run(r, s, function(e)
                s.state = "in_progress"
                s.started_ts = now()
                return e:receive({ type = "person" })
            end)
        end
        return candidate_view(r, s)
    end
    return run(r, s, function(e) return e:receive({ type = data.type, text = data.text }) end)
end

function I.self_id(r, data)
    local s = load_session(r)
    if not Engine.is_finished(s) then return nil, "This is asked after the interview.", 409 end
    if v(r.self_id_key) then return { saved = true } end
    local answers = {}
    for _, q in ipairs(F.QUESTIONS) do
        local a = type(data.answers) == "table" and data.answers[q.id]
        for _, opt in ipairs(q.options) do
            if a == opt then answers[q.id] = a end
        end
    end
    local key = Hash.random_token()
    db.insert("ats_self_id", { namespace_id = r.namespace_id, key = key, answers = J.encode(answers) })
    db.update("ats_interviews", { self_id_key = key }, { id = r.id })
    return { saved = true }
end

-- MARK: Evaluation

function I.evaluate_now(namespace_id, uuid)
    local r = I.row(namespace_id, uuid)
    if not r then return nil, "Interview not found" end
    local s = load_session(r)
    local prompt = P.evaluator_prompt(s)
    local system = "You assess evidence from structured interviews. Reply with JSON only."
    local first, label = L.complete("evaluator", system, prompt, { namespace_id = namespace_id })
    if not first then
        db.update("ats_interviews", { evaluation_status = "failed", updated_at = db.raw("NOW()") }, { id = r.id })
        return nil, "The evaluator didn't answer: " .. tostring(label)
    end
    local second = L.complete("evaluator", system, prompt, { namespace_id = namespace_id })
    local ev = Ev.combine(first, second, s, label, T.iso(now()))
    if not ev then
        db.update("ats_interviews", { evaluation_status = "failed", updated_at = db.raw("NOW()") }, { id = r.id })
        return nil, "The evaluator's answer couldn't be read."
    end
    db.update("ats_interviews", { evaluation = J.encode(ev), evaluation_status = "done", updated_at = db.raw("NOW()") },
        { id = r.id })
    Q.audit(namespace_id, "engine", "evaluated", "interview", uuid, { model = label,
        dropped_quotes = ev.dropped_quotes })
    return ev
end

function I.evaluate_async(namespace_id, uuid, actor)
    local r = I.row(namespace_id, uuid)
    if not r then return nil, "Interview not found" end
    local s = decode(r.session) or {}
    if not Engine.is_finished(s) then return nil, "The interview hasn't finished." end
    db.update("ats_interviews", { evaluation_status = "running", updated_at = db.raw("NOW()") }, { id = r.id })
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then return end
        local good, e = pcall(I.evaluate_now, namespace_id, uuid)
        if not good then
            ngx.log(ngx.ERR, "[ats] evaluation failed: ", tostring(e))
            pcall(db.update, "ats_interviews", { evaluation_status = "failed" }, { id = r.id })
        end
    end)
    if not ok then return nil, "Couldn't start the evaluator: " .. tostring(err) end
    if actor ~= "engine" then Q.audit(namespace_id, actor, "evaluation_requested", "interview", uuid, {}) end
    return { uuid = uuid, evaluation_status = "running" }
end

-- MARK: A person's review

function I.review(namespace_id, uuid, data, actor, actor_name)
    if not actor then return nil, "A review must be made by a signed-in person." end
    local r = I.row(namespace_id, uuid)
    if not r then return nil, "Interview not found" end
    local s = load_session(r)
    local decision = data.decision
    if decision ~= nil and decision ~= J.null and not DECISIONS[decision] then return nil, "Unknown decision" end
    local reason = type(data.reason) == "string" and T.prefix(T.trim(data.reason), 500) or ""
    if decision == "decline" and reason == "" then return nil, "Give a reason for declining." end
    local levels = {}
    for k, n in pairs(type(data.levels) == "table" and data.levels or {}) do
        n = tonumber(n)
        if Kit.competency(s.kit, k) and n and n >= 0 and n <= 5 then levels[k] = math.floor(n) end
    end
    local review = { reviewer = actor_name or actor, reviewer_uuid = actor, decision = DECISIONS[decision]
        and decision or nil,
        reason = reason, note = type(data.note) == "string" and T.prefix(data.note, 4000) or "", levels = levels,
        at = T.iso(now()) }
    db.update("ats_interviews", { review = J.encode(review), reviewed_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()") },
        { id = r.id })
    Q.audit(namespace_id, actor, "reviewed", "interview", uuid, { decision = review.decision, levels = levels })
    local app = db.select("uuid FROM ats_applications WHERE id = ?", r.application_id)[1]
    if review.decision == "decline" then
        Q.reject(namespace_id, app.uuid, reason, actor, actor_name)
    end
    local settings = Q.settings(namespace_id)
    if review.decision then
        db.query([[UPDATE ats_candidates
            SET delete_after = GREATEST(COALESCE(delete_after, NOW()), NOW() + (? || ' days')::interval)
            WHERE id = (SELECT candidate_id FROM ats_applications WHERE id = ?)]],
            tostring(settings.retention_days), r.application_id)
        db.query("UPDATE ats_interviews SET delete_after = NOW() + (? || ' days')::interval WHERE id = ?",
            tostring(settings.retention_days), r.id)
    end
    return I.detail(namespace_id, uuid)
end

-- MARK: Imports from Snazzy Pro (integration token or .snazzy_interview file)

local function newer(a, b)
    return type(a) == "string" and (type(b) ~= "string" or a > b)
end

--- Creates or updates everything for one interview run in the desktop app.
-- rec: Interop.parse() output. actor: who sent it ("token:<uuid>" or a user uuid).
function I.import(namespace_id, rec, actor, source)
    local kit = rec.kit
    local kit_row, kit_ext = I.desktop_kit_row(namespace_id, kit, actor)
    -- The job: matched by the kit's id, else by title, else created.
    local job = db.select(
        "* FROM ats_jobs WHERE namespace_id = ? AND external_kit_id = ? AND deleted_at IS NULL LIMIT 1",
        namespace_id, kit_ext)[1]
        or db.select("* FROM ats_jobs WHERE namespace_id = ? AND title = ? AND deleted_at IS NULL ORDER BY id LIMIT 1",
            namespace_id, kit.title)[1]
    if not job then
        job = db.insert("ats_jobs", { namespace_id = namespace_id, title = kit.title, status = "open",
            kit_id = kit_row.id,
            external_kit_id = kit_ext, description = kit.summary ~= "" and kit.summary or nil,
                created_by_uuid = actor },
            { returning = "*" })[1]
        Q.audit(namespace_id, actor, "job_created", "job", job.uuid, { source = source })
    elseif not v(job.external_kit_id) then
        db.update("ats_jobs", { external_kit_id = kit_ext }, { id = job.id })
    end
    local cand_data = { name = rec.candidate.name ~= "" and rec.candidate.name or "Unnamed candidate",
        email = rec.candidate.email ~= "" and rec.candidate.email or nil, reference = rec.candidate.reference }
    local cand, err = Q.find_or_create_candidate(namespace_id, cand_data, actor, source)
    if not cand then return nil, err end
    local app = db.select("* FROM ats_applications WHERE job_id = ? AND candidate_id = ?", job.id, cand.id)[1]
    if not app then
        app = db.insert("ats_applications", { namespace_id = namespace_id, job_id = job.id, candidate_id = cand.id,
            stage = "review" }, { returning = "*" })[1]
        Q.audit(namespace_id, actor, "application_created", "application", app.uuid, { source = source })
    end
    local session = {
        kit = kit, candidate = rec.candidate, channel = rec.channel, state = rec.state, turns = rec.turns,
        flags = rec.flags, eligibility_answers = rec.eligibility_answers, adjustments = rec.adjustments,
        forwarded_questions = rec.forwarded_questions, models = rec.models, audit = rec.audit,
        notice_hash = rec.notice_hash, end_reason = rec.end_reason, external = { app = rec.app,
            exported_at = rec.exported_at, notice_accepted_at = rec.notice_accepted_at, created = rec.created },
        rev = 0,
    }
    local settings = Q.settings(namespace_id)
    local existing = db.select("* FROM ats_interviews WHERE namespace_id = ? AND external_id = ?", namespace_id,
        rec.external_id)[1]
    local created = existing == nil
    if created then
        existing = db.insert("ats_interviews", { namespace_id = namespace_id, application_id = app.id,
            kit_id = kit_row.id,
            kit_version = kit_row.version, source = source, external_id = rec.external_id, state = rec.state,
            session = J.encode(session), started_at = rec.started_at or db.NULL, ended_at = rec.ended_at or db.NULL,
            evaluation = rec.evaluation and J.encode(rec.evaluation) or db.NULL,
            evaluation_status = rec.evaluation and "done" or "none",
            delete_after = db.raw(("NOW() + interval '%d days'"):format(settings.retention_days)) },
                { returning = "*" })[1]
        Q.audit(namespace_id, actor, "interview_imported", "interview", existing.uuid, { source = source,
            app = rec.app })
    else
        local old = decode(existing.session) or {}
        local f = { updated_at = db.raw("NOW()") }
        if #(rec.turns or {}) >= #(old.turns or {}) then
            f.session = J.encode(session)
            f.state = rec.state
            f.ended_at = rec.ended_at or db.NULL
        end
        local old_ev = decode(existing.evaluation)
        if rec.evaluation and newer(rec.evaluation.at, old_ev and old_ev.at) then
            f.evaluation = J.encode(rec.evaluation)
            f.evaluation_status = "done"
        end
        db.update("ats_interviews", f, { id = existing.id })
        Q.audit(namespace_id, actor, "interview_reimported", "interview", existing.uuid, { source = source })
    end
    -- A decision only when a person made one in the app.
    if rec.review and rec.review.decision then
        local old = decode(existing.review)
        if newer(rec.review.at, old and old.at) or not old then
            local review = { reviewer = rec.review.reviewer .. " (via Snazzy Pro)", decision = rec.review.decision,
                reason = rec.review.reason, note = rec.review.note, levels = rec.review.levels, at = rec.review.at,
                via = "Snazzy Pro" }
            db.update("ats_interviews", { review = J.encode(review), reviewed_at = db.raw("NOW()") },
                { id = existing.id })
            Q.audit(namespace_id, actor, "reviewed", "interview", existing.uuid,
                { decision = review.decision, reviewer = review.reviewer })
            if review.decision == "decline" and app.stage ~= "rejected" then
                Q.reject(namespace_id, app.uuid, review.reason ~= "" and review.reason or "Declined in Snazzy Pro",
                    actor, review.reviewer)
            end
        end
    end
    return { interview_uuid = existing.uuid, application_uuid = app.uuid, candidate_uuid = cand.uuid,
        job_uuid = job.uuid,
        created = created, dashboard_url = I.dashboard_url(existing.uuid) }
end

-- MARK: Fairness

function I.fairness(namespace_id, params)
    local question = params.question or "gender"
    local valid = false
    for _, q in ipairs(F.QUESTIONS) do if q.id == question then valid = true end end
    if not valid then return nil, "Unknown self-ID question" end
    local where, args = "i.namespace_id = ? AND i.self_id_key IS NOT NULL AND i.review->>'decision' IS NOT NULL",
        { namespace_id }
    if params.job_uuid and params.job_uuid ~= "" then
        where = where .. " AND j.uuid = ?"
        args[#args + 1] = params.job_uuid
    end
    local rows = db.query([[SELECT i.self_id_key AS key, i.review->>'decision' AS decision, s.answers
        FROM ats_interviews i JOIN ats_applications a ON a.id = i.application_id JOIN ats_jobs j ON j.id = a.job_id
        JOIN ats_self_id s ON s.key = i.self_id_key WHERE ]] .. where, unpack(args))
    local ids, outcomes = {}, {}
    for _, r in ipairs(rows) do
        ids[#ids + 1] = { key = r.key, answers = decode(r.answers) or {} }
        outcomes[r.key] = r.decision == "advance"
    end
    local report = F.report(question, ids, outcomes)
    report.questions = F.QUESTIONS
    report.min_group = F.MIN_GROUP
    report.rows = J.array(report.rows)
    return report
end

-- MARK: Retention

--- Deletes interviews and candidates past their delete_after. @return counts
function I.purge()
    local interviews = db.query([[WITH gone AS (DELETE FROM ats_interviews WHERE delete_after < NOW()
        RETURNING namespace_id, uuid, self_id_key) SELECT * FROM gone]])
    for _, g in ipairs(interviews) do
        if v(g.self_id_key) then db.query("DELETE FROM ats_self_id WHERE key = ?", g.self_id_key) end
        Q.audit(g.namespace_id, "retention", "interview_deleted", "interview", g.uuid, {})
    end
    local candidates = db.query([[WITH gone AS (DELETE FROM ats_candidates c WHERE c.delete_after < NOW()
        AND NOT EXISTS (SELECT 1 FROM ats_interviews i JOIN ats_applications a ON a.id = i.application_id
                        WHERE a.candidate_id = c.id) RETURNING namespace_id, uuid) SELECT * FROM gone]])
    for _, g in ipairs(candidates) do
        Q.audit(g.namespace_id, "retention", "candidate_deleted", "candidate", g.uuid, {})
    end
    db.query("DELETE FROM ats_stripe_events WHERE received_at < NOW() - interval '90 days'")
    return { interviews = #interviews, candidates = #candidates }
end

return I
