--[[
    Accountants acting for clients' VAT (VAT plan phase 8).

    An accountant (RBAC module vat_agent) saves their Agent Reference Number, then
    asks a client in the same workspace for authority (HMRC invitation, by the
    client's VAT number + VAT registration date). The client accepts on HMRC's site.
    refresh() then asks HMRC: only when HMRC's relationship check confirms it does the
    link become 'active' — and only then may the accountant see or file that
    client's VAT (routes/vat.lua resolve(), ?client=<link uuid>).
]]

local db = require("lapis.db")
local HMRC = require("helper.hmrc")
local Client = require("lib.hmrc-agent-client")

local Q = {}

local function null(v) return v == nil or v == db.NULL or (ngx and v == ngx.null) end

function Q.profile(namespace_id, user_id)
    return db.query("SELECT arn FROM vat_agents WHERE namespace_id = ? AND user_id = ? LIMIT 1",
        namespace_id, user_id)[1]
end

function Q.save_profile(namespace_id, user_id, arn)
    arn = tostring(arn or ""):upper():gsub("%s", "")
    if not Client.valid_arn(arn) then return nil, "An Agent Reference Number looks like AARN1234567", 400 end
    db.query([[INSERT INTO vat_agents (namespace_id, user_id, arn) VALUES (?, ?, ?)
        ON CONFLICT (namespace_id, user_id) DO UPDATE SET arn = EXCLUDED.arn, updated_at = NOW()]],
        namespace_id, user_id, arn)
    return Q.profile(namespace_id, user_id)
end

local function token_for(user_uuid)
    local token, err = HMRC.get_valid_token(user_uuid)
    if not token then return nil, err or "Connect to HMRC with your agent sign-in first", "NOT_CONNECTED" end
    local row = db.query("SELECT scope FROM hmrc_tokens WHERE user_uuid = ? LIMIT 1", user_uuid)[1]
    if not tostring(row and row.scope or ""):find("write:sent-invitations", 1, true) then
        return nil, "Connect to HMRC with your agent sign-in (for clients) first.", "AGENT_SCOPE_MISSING"
    end
    return token
end

-- err is our own text (URLs, socket errors): logged, never sent.
local function hmrc_fail(err, body, status)
    local msg, code = Client.explain(body)
    ngx.log(ngx.WARN, "[vat-agent] ", tostring(err), " (HTTP ", tostring(status), ")")
    return { status = (status and status < 500) and 422 or 502,
        json = { success = false, error = msg, code = code, hmrc = body } }
end

--- The accountant's clients with their status.
function Q.list(namespace_id, agent_user_id)
    return db.query([[SELECT c.uuid, c.client_vrn, c.status, c.client_action_url, c.expires_on, c.last_checked_at,
            c.created_at, r.business_name, r.scheme, r.stagger
        FROM vat_agent_clients c JOIN vat_registrations r ON r.id = c.registration_id
        WHERE c.namespace_id = ? AND c.agent_user_id = ?
        ORDER BY (c.status = 'active') DESC, c.updated_at DESC]], namespace_id, agent_user_id) or {}
end

--- Ask a client (by VAT number, in this workspace) for authority at HMRC.
function Q.invite(namespace_id, agent_user_id, agent_uuid, body)
    body = body or {}
    local prof = Q.profile(namespace_id, agent_user_id)
    if not prof then
        return nil, { status = 409, json = { success = false, error = "Add your Agent Reference Number first" } }
    end
    local vrn = require("lib.vat").valid_vrn(body.vrn)
    if not vrn then
        return nil, { status = 400, json = { success = false, error = "Enter the client's VAT number" } }
    end
    -- VAT numbers aren't verified when saved, so two businesses here may both claim one:
    -- never guess which is the client.
    local regs = db.query([[SELECT * FROM vat_registrations WHERE namespace_id = ? AND vrn = ? AND status = 'active'
        LIMIT 2]], namespace_id, vrn) or {}
    local reg = regs[1]
    if not reg then
        return nil, { status = 404, json = { success = false,
            error = "No client in this workspace has registered that VAT number in OpsAPI yet." } }
    end
    if regs[2] then
        return nil, { status = 409, json = { success = false, error = "More than one business in this workspace "
            .. "has entered that VAT number. Ask your client to check their VAT details first." } }
    end
    local known = body.vat_registration_date
    if (not known or known == "") and not null(reg.effective_date) then known = tostring(reg.effective_date) end
    if not require("lib.vat").valid_date(known and tostring(known)) then
        return nil, { status = 400, json = { success = false,
            error = "Give the client's VAT registration date (it's on their VAT certificate)" } }
    end
    local token, terr, tcode = token_for(agent_uuid)
    if not token then return nil, { status = 409, json = { success = false, error = terr, code = tcode } } end
    local id, err, hbody, status = Client.create_invitation(token, prof.arn, vrn, known)
    if not id then return nil, hmrc_fail(err, hbody, status) end
    local inv = Client.get_invitation(token, prof.arn, id) or {}
    db.insert("vat_agent_clients", { namespace_id = namespace_id, agent_user_id = agent_user_id, arn = prof.arn,
        registration_id = reg.id, client_vrn = vrn, known_fact = known, invitation_id = id,
        client_action_url = inv.clientActionUrl or db.NULL, status = "pending",
        expires_on = inv.expiresOn or db.NULL })
    return db.query([[SELECT uuid, client_vrn, status, client_action_url, expires_on FROM vat_agent_clients
        WHERE invitation_id = ? LIMIT 1]], id)[1]
end

local STATUS = { Pending = "pending", Accepted = "accepted", Rejected = "rejected", Expired = "expired",
    Cancelled = "cancelled" }

--- Ask HMRC where a request stands; confirm the relationship when accepted.
function Q.refresh(namespace_id, agent_user_id, agent_uuid, uuid)
    local c = db.query([[SELECT * FROM vat_agent_clients WHERE uuid = ? AND namespace_id = ? AND agent_user_id = ?
        LIMIT 1]], uuid, namespace_id, agent_user_id)[1]
    if not c then return nil, { status = 404, json = { success = false, error = "Not found" } } end
    local token, terr, tcode = token_for(agent_uuid)
    if not token then return nil, { status = 409, json = { success = false, error = terr, code = tcode } } end
    local status = c.status
    if c.status == "pending" and not null(c.invitation_id) then
        local inv, err, hbody, hstatus = Client.get_invitation(token, c.arn, c.invitation_id)
        if not inv then return nil, hmrc_fail(err, hbody, hstatus) end
        status = STATUS[inv.status] or c.status
    end
    if status == "accepted" or status == "active" then
        local ok = Client.check_relationship(token, c.arn, c.client_vrn, tostring(c.known_fact))
        if ok == true then status = "active"
        elseif ok == false then status = (c.status == "active") and "revoked" or "accepted" end
    end
    db.query([[UPDATE vat_agent_clients SET status = ?, last_checked_at = NOW(), updated_at = NOW() WHERE id = ?]],
        status, c.id)
    return db.query("SELECT uuid, client_vrn, status, client_action_url, expires_on, last_checked_at "
        .. "FROM vat_agent_clients WHERE id = ?", c.id)[1]
end

function Q.cancel(namespace_id, agent_user_id, agent_uuid, uuid)
    local c = db.query([[SELECT * FROM vat_agent_clients WHERE uuid = ? AND namespace_id = ? AND agent_user_id = ?
        LIMIT 1]], uuid, namespace_id, agent_user_id)[1]
    if not c then return nil, { status = 404, json = { success = false, error = "Not found" } } end
    if c.status == "pending" and not null(c.invitation_id) then
        local token = token_for(agent_uuid)
        if token then pcall(Client.cancel_invitation, token, c.arn, c.invitation_id) end
    end
    -- An active authority is ended at HMRC by the client (or the agent's HMRC account);
    -- here the accountant simply stops acting for them.
    db.query("UPDATE vat_agent_clients SET status = 'cancelled', updated_at = NOW() WHERE id = ?", c.id)
    return true
end

-- How long HMRC's "yes, you act for this client" is trusted before asking again.
Q.RECHECK_HOURS = 24

--- The client's registration, when this accountant is authorised (HMRC-confirmed).
-- HMRC is asked again once the last check is older than RECHECK_HOURS: a client can end
-- the authority at HMRC at any time.
-- @return registration, or nil + message + http status
function Q.active_registration(namespace_id, agent_user_id, uuid, agent_uuid)
    local c = db.query([[SELECT id, registration_id, arn, client_vrn, known_fact,
            (last_checked_at IS NULL OR last_checked_at < NOW() - make_interval(hours => ?)) AS stale
        FROM vat_agent_clients WHERE uuid = ? AND namespace_id = ?
        AND agent_user_id = ? AND status = 'active' LIMIT 1]], Q.RECHECK_HOURS, uuid, namespace_id, agent_user_id)[1]
    if not c then return nil, "HMRC hasn't confirmed you can act for this client yet", 403 end
    if c.stale == true or c.stale == "t" then
        local token = token_for(agent_uuid)
        local ok = token and Client.check_relationship(token, c.arn, c.client_vrn, tostring(c.known_fact))
        if ok == false then
            db.query("UPDATE vat_agent_clients SET status = 'revoked', last_checked_at = NOW(), updated_at = NOW() "
                .. "WHERE id = ?", c.id)
            return nil, "HMRC says you no longer act for this client.", 403
        end
        if ok ~= true then
            return nil, "We couldn't check with HMRC that you still act for this client. Connect to HMRC with "
                .. "your agent sign-in, then try again.", 409
        end
        db.query("UPDATE vat_agent_clients SET last_checked_at = NOW() WHERE id = ?", c.id)
    end
    return db.query([[SELECT * FROM vat_registrations WHERE id = ? AND namespace_id = ? AND status = 'active'
        LIMIT 1]], c.registration_id, namespace_id)[1]
end

--- The accountants linked to a registration, for the client to see.
function Q.for_registration(reg)
    return db.query([[SELECT c.uuid, c.arn, c.status, c.created_at, c.last_checked_at,
            u.first_name, u.last_name, u.email
        FROM vat_agent_clients c LEFT JOIN users u ON u.id = c.agent_user_id
        WHERE c.registration_id = ? AND c.namespace_id = ? AND c.status IN ('pending', 'accepted', 'active')
        ORDER BY c.created_at DESC]], reg.id, reg.namespace_id) or {}
end

--- The client stops an accountant acting for them here (HMRC's authority is ended at HMRC).
function Q.revoke_for_registration(reg, uuid)
    local r = db.query([[UPDATE vat_agent_clients SET status = 'revoked', updated_at = NOW()
        WHERE uuid = ? AND registration_id = ? AND namespace_id = ? AND status IN ('pending', 'accepted', 'active')
        RETURNING id]], uuid, reg.id, reg.namespace_id)
    if not r or #r == 0 then return nil, "Not found", 404 end
    return true
end

return Q
