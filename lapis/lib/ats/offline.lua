--[[
    ATS — offline interviews: the checks on a transcript the candidate's Snazzy
    Pro app uploads once, after running the interview on their own Mac
    (docs/plans/PROMPT_ATS_INTERVIEWS.md, "Offline interviews").

    Pure Lua (no ngx, no database), so tests/ats/run.lua covers it. The upload is
    reported by the candidate's device: it can't be proven, only bounded. So:
      - the kit must be the invite's kit (the server's copy is what gets stored);
      - the notice the candidate accepted must be the one this server issued
        (except a request for a person before starting, which accepts nothing);
      - states, roles, sizes and question ids must be ones the engine can make;
      - times are clamped to when the app fetched the interview and now.
    Any evaluation or review in the upload is never used (the caller ignores it).
]]

local Offline = {}

--- Days after the link expires that a started offline interview may still upload.
Offline.GRACE_DAYS = 7
Offline.MAX_TURNS = 400
Offline.MAX_TURN_CHARS = 20000
--- How far before the app fetched the interview its start time may be (clock skew).
Offline.SKEW_SECONDS = 300

Offline.END_STATES = { completed = true, human_requested = true, withdrawn = true, abandoned = true,
    expired = true }
local ROLES = { interviewer = true, candidate = true, system = true }

local function chars(s)
    local _, n = tostring(s or ""):gsub("[^\128-\191]", "")
    return n
end

-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm): no os.time, no time zone.
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- Epoch seconds for an ISO 8601 time (UTC "Z", an offset, or none = UTC;
-- fractional seconds dropped). nil when it isn't one.
function Offline.parse_iso(text)
    if type(text) ~= "string" then return nil end
    -- "T" or a space between date and time (Postgres prints "2026-10-18 10:00:00+00").
    local y, mo, d, h, mi, s, rest = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then return nil end
    rest = rest:gsub("^%.%d+", "")
    local offset = 0
    if rest == "" or rest == "Z" or rest == "z" then
        offset = 0
    else
        local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
        if not sign then
            sign, oh = rest:match("^([%+%-])(%d%d)$")
            om = "00"
        end
        if not sign then return nil end
        offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
    end
    return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset
end

--- A time as the Snazzy app reads it (ISO 8601 UTC), from ISO text or a Postgres timestamp; nil if neither.
function Offline.to_iso(text)
    local t = Offline.parse_iso(text ~= nil and tostring(text) or nil)
    return t and os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(t)) or nil
end

local function clamp(t, lo, hi)
    if lo and t < lo then t = lo end
    if hi and t > hi then t = hi end
    return t
end

local function set_of(v)
    local out = {}
    if type(v) == "string" then
        out[v] = true
    elseif type(v) == "table" then
        for _, h in ipairs(v) do if type(h) == "string" then out[h] = true end end
    end
    return out
end

--- Checks an uploaded interview against the invite.
-- @param record   Interop.parse() output for the upload
-- @param kit      the server's kit for the invite (normalised)
-- @param notice_hashes  the notice hash this server issued (a string, or a list of them)
-- @param offline_started_ts  when the app fetched the interview (epoch seconds)
-- @param now      epoch seconds
-- @param raw      the uploaded InterviewSession as sent (before parse() dropped, capped or defaulted
--                 anything): its state and turns are checked; defaults to the record
-- @return {started_ts, ended_ts, notice_accepted_ts, candidate_turns, before_start} | nil, message
function Offline.validate(record, kit, notice_hashes, offline_started_ts, now, raw)
    if type(record) ~= "table" or type(kit) ~= "table" then return nil, "The interview couldn't be read." end
    if not record.kit or record.kit.id == nil or record.kit.id ~= kit.id then
        return nil, "These results are for a different interview."
    end
    raw = type(raw) == "table" and raw or record
    if not Offline.END_STATES[raw.state] or raw.state ~= record.state then
        return nil, "The interview hasn't finished, so there is nothing to send yet."
    end

    local turns = raw.turns or {}
    if type(turns) ~= "table" then return nil, "The transcript couldn't be read." end
    if #turns > Offline.MAX_TURNS then
        return nil, ("The transcript has more than %d turns."):format(Offline.MAX_TURNS)
    end
    local ids = {}
    for _, q in ipairs(kit.questions or {}) do ids[q.id] = true end
    for _, q in ipairs(kit.eligibility or {}) do ids[q.id] = true end
    local candidate_turns = 0
    for i, t in ipairs(turns) do
        if type(t) ~= "table" or not ROLES[t.role] then
            return nil, ("Turn %d has an unknown role."):format(i)
        end
        if type(t.text) ~= "string" and t.text ~= nil then return nil, ("Turn %d has no text."):format(i) end
        if chars(t.text) > Offline.MAX_TURN_CHARS then
            return nil, ("Turn %d is longer than %d characters."):format(i, Offline.MAX_TURN_CHARS)
        end
        local qid = t.question_id
        if qid ~= nil and type(qid) ~= "userdata" and not ids[qid] then
            return nil, ("Turn %d refers to a question that isn't in this interview."):format(i)
        end
        if t.role == "candidate" then candidate_turns = candidate_turns + 1 end
    end

    -- Asking for a person before starting accepts no notice; everything else must
    -- have accepted the notice this server issued.
    local before_start = record.state == "human_requested" and candidate_turns == 0
    if not before_start and not set_of(notice_hashes)[record.notice_hash or ""] then
        return nil, "The information page the candidate accepted isn't the one for this interview."
    end

    local floor = (offline_started_ts or now) - Offline.SKEW_SECONDS
    local started = Offline.parse_iso(record.started_at)
    if started then started = clamp(started, floor, now) end
    local ended = Offline.parse_iso(record.ended_at) or now
    ended = clamp(ended, started or floor, now)
    local accepted = Offline.parse_iso(record.notice_accepted_at)
    if accepted then accepted = clamp(accepted, floor, started or ended) end
    if before_start then accepted = nil end
    return { started_ts = started, ended_ts = ended, notice_accepted_ts = accepted,
        candidate_turns = candidate_turns, before_start = before_start }
end

return Offline
