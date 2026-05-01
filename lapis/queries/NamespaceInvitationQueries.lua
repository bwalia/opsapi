--[[
    NamespaceInvitationQueries.lua

    Manages namespace invitations - inviting users to namespaces via email.
    Handles creating invitations, accepting/declining, expiration, and revocation.
]]

local Global = require("helper.global")
local db = require("lapis.db")
local Model = require("lapis.db.model").Model

local NamespaceInvitations = Model:extend("namespace_invitations")
local NamespaceInvitationQueries = {}

-- Default invitation expiration in days
local DEFAULT_EXPIRATION_DAYS = 7

--- Generate a secure unique token for invitation
-- Uses multiple entropy sources to ensure uniqueness
-- @return string A unique 64-character token
local function generateToken()
    -- Seed with multiple entropy sources for randomness
    local time_seed = ngx.now() * 1000000 -- microseconds
    local worker_pid = ngx.worker.pid() or 0
    local random_seed = math.random(1, 2147483647)
    math.randomseed(time_seed + worker_pid + random_seed)

    -- Generate base using MD5 of unique data
    local unique_data = string.format("%s-%s-%s-%s",
        tostring(ngx.now()),
        tostring(worker_pid),
        tostring(math.random(1, 2147483647)),
        Global.generateUUID()
    )
    local hash = ngx.md5(unique_data)

    -- Expand to 64 characters using hash + random characters
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local token = hash -- 32 characters from MD5

    -- Add 32 more random characters
    for _ = 1, 32 do
        local idx = math.random(1, #chars)
        token = token .. string.sub(chars, idx, idx)
    end

    return token
end

--- Generate token with uniqueness check against database
-- @return string A unique token that doesn't exist in database
local function generateUniqueToken()
    local max_attempts = 5
    for _ = 1, max_attempts do
        local token = generateToken()
        -- Check if token already exists
        local existing = db.select("id FROM namespace_invitations WHERE token = ? LIMIT 1", token)
        if not existing or #existing == 0 then
            return token
        end
        -- Small delay before retry (ngx.sleep takes seconds)
        ngx.sleep(0.01)
    end
    -- Final fallback: use double UUID-based token (virtually impossible to collide)
    return ngx.md5(Global.generateUUID() .. tostring(ngx.now())) .. ngx.md5(Global.generateUUID())
end

--- Create a new invitation
-- @param data table { namespace_id, email, role_id?, invited_by, message?, expires_in_days? }
-- @return table The created invitation
function NamespaceInvitationQueries.create(data)
    local timestamp = Global.getCurrentTimestamp()

    -- Get numeric namespace ID
    local namespace_id = data.namespace_id
    if type(namespace_id) == "string" then
        local ns = db.select("id FROM namespaces WHERE uuid = ? OR id = ?", namespace_id, tonumber(namespace_id) or 0)
        namespace_id = ns[1] and ns[1].id
    end

    if not namespace_id then
        error("Invalid namespace_id")
    end

    -- Get numeric invited_by user ID
    local invited_by = data.invited_by
    if type(invited_by) == "string" then
        local u = db.select("id FROM users WHERE uuid = ? OR id = ?", invited_by, tonumber(invited_by) or 0)
        invited_by = u[1] and u[1].id
    end

    if not invited_by then
        error("Invalid invited_by user")
    end

    -- Check if user already exists and is already a member
    local existing_user = db.select("id FROM users WHERE LOWER(email) = LOWER(?)", data.email)
    if #existing_user > 0 then
        local existing_member = db.select([[
            id FROM namespace_members
            WHERE namespace_id = ? AND user_id = ? AND status != 'removed'
        ]], namespace_id, existing_user[1].id)
        if #existing_member > 0 then
            error("User is already a member of this namespace")
        end
    end

    -- Check for existing pending invitation
    local existing_invitation = db.select([[
        id FROM namespace_invitations
        WHERE namespace_id = ? AND LOWER(email) = LOWER(?) AND status = 'pending'
    ]], namespace_id, data.email)
    if #existing_invitation > 0 then
        error("An invitation is already pending for this email")
    end

    -- Calculate expiration
    local expires_in_days = data.expires_in_days or DEFAULT_EXPIRATION_DAYS
    local expires_at = os.date("!%Y-%m-%d %H:%M:%S", os.time() + (expires_in_days * 24 * 60 * 60))

    -- Validate role if provided
    local role_id = nil
    if data.role_id then
        local role = db.select("id FROM namespace_roles WHERE id = ? AND namespace_id = ?", data.role_id, namespace_id)
        if #role > 0 then
            role_id = role[1].id
        end
    end

    local invitation_data = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        email = data.email:lower(),
        role_id = role_id,
        token = generateUniqueToken(),
        status = "pending",
        message = data.message,
        invited_by = invited_by,
        expires_at = expires_at,
        created_at = timestamp,
        updated_at = timestamp
    }

    local invitation = NamespaceInvitations:create(invitation_data, { returning = "*" })
    return invitation
end

--- Get all invitations for a namespace with pagination
-- @param namespace_id string|number Namespace ID or UUID
-- @param params table { page?, perPage?, status?, search? }
-- @return table { data, total, page, per_page, total_pages }
function NamespaceInvitationQueries.all(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.perPage) or tonumber(params.per_page) or 10
    local offset = (page - 1) * per_page

    -- Get numeric namespace ID
    local ns_id = namespace_id
    if type(namespace_id) == "string" then
        local ns = db.select("id FROM namespaces WHERE uuid = ? OR id = ?", namespace_id, tonumber(namespace_id) or 0)
        ns_id = ns[1] and ns[1].id
    end

    if not ns_id then
        return { data = {}, total = 0, page = page, per_page = per_page, total_pages = 0 }
    end

    -- Build conditions
    local conditions = { "ni.namespace_id = " .. ns_id }

    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "ni.status = " .. db.escape_literal(params.status))
    end

    if params.search and params.search ~= "" then
        local search_term = db.escape_literal("%" .. params.search .. "%")
        table.insert(conditions, "ni.email ILIKE " .. search_term)
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")

    -- Get total count
    local count_query = string.format([[
        SELECT COUNT(*) as total
        FROM namespace_invitations ni
        %s
    ]], where_clause)

    local count_result = db.query(count_query)
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data with relations
    local data_query = string.format([[
        SELECT
            ni.id, ni.uuid, ni.namespace_id, ni.email, ni.role_id,
            ni.token, ni.status, ni.message, ni.invited_by,
            ni.expires_at, ni.accepted_at, ni.created_at, ni.updated_at,
            nr.role_name, nr.display_name as role_display_name,
            u.first_name || ' ' || u.last_name as invited_by_name,
            u.email as invited_by_email
        FROM namespace_invitations ni
        LEFT JOIN namespace_roles nr ON ni.role_id = nr.id
        LEFT JOIN users u ON ni.invited_by = u.id
        %s
        ORDER BY ni.created_at DESC
        LIMIT %d OFFSET %d
    ]], where_clause, per_page, offset)

    local data = db.query(data_query)

    -- Structure the response
    for _, invitation in ipairs(data or {}) do
        if invitation.role_id then
            invitation.role = {
                id = invitation.role_id,
                role_name = invitation.role_name,
                display_name = invitation.role_display_name
            }
        end
        invitation.inviter = {
            name = invitation.invited_by_name,
            email = invitation.invited_by_email
        }
        -- Clean up flat fields
        invitation.role_name = nil
        invitation.role_display_name = nil
        invitation.invited_by_name = nil
        invitation.invited_by_email = nil
    end

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Find invitation by ID or UUID
-- @param id string|number Invitation ID or UUID
-- @return table|nil The invitation or nil
function NamespaceInvitationQueries.show(id)
    local invitation = NamespaceInvitations:find({ uuid = tostring(id) })
    if not invitation and tonumber(id) then
        invitation = NamespaceInvitations:find({ id = tonumber(id) })
    end
    return invitation
end

--- Find invitation by token
-- @param token string The invitation token
-- @return table|nil The invitation with full details or nil
function NamespaceInvitationQueries.findByToken(token)
    local result = db.query([[
        SELECT
            ni.*,
            n.uuid as namespace_uuid, n.name as namespace_name, n.slug as namespace_slug,
            n.logo_url as namespace_logo, n.status as namespace_status,
            nr.role_name, nr.display_name as role_display_name,
            u.first_name || ' ' || u.last_name as invited_by_name,
            u.email as invited_by_email
        FROM namespace_invitations ni
        JOIN namespaces n ON ni.namespace_id = n.id
        LEFT JOIN namespace_roles nr ON ni.role_id = nr.id
        LEFT JOIN users u ON ni.invited_by = u.id
        WHERE ni.token = ?
        LIMIT 1
    ]], token)

    if not result or #result == 0 then
        return nil
    end

    local invitation = result[1]

    -- Structure the response
    invitation.namespace = {
        uuid = invitation.namespace_uuid,
        name = invitation.namespace_name,
        slug = invitation.namespace_slug,
        logo_url = invitation.namespace_logo,
        status = invitation.namespace_status
    }

    if invitation.role_id then
        invitation.role = {
            id = invitation.role_id,
            role_name = invitation.role_name,
            display_name = invitation.role_display_name
        }
    end

    invitation.inviter = {
        name = invitation.invited_by_name,
        email = invitation.invited_by_email
    }

    -- Clean up flat fields
    invitation.namespace_uuid = nil
    invitation.namespace_name = nil
    invitation.namespace_slug = nil
    invitation.namespace_logo = nil
    invitation.namespace_status = nil
    invitation.role_name = nil
    invitation.role_display_name = nil
    invitation.invited_by_name = nil
    invitation.invited_by_email = nil

    return invitation
end

--- Find pending invitation by email and namespace
-- @param email string The email address
-- @param namespace_id string|number Namespace ID or UUID
-- @return table|nil The invitation or nil
function NamespaceInvitationQueries.findPendingByEmail(email, namespace_id)
    local query = [[
        SELECT ni.*
        FROM namespace_invitations ni
        JOIN namespaces n ON ni.namespace_id = n.id
        WHERE LOWER(ni.email) = LOWER(?)
        AND (n.uuid = ? OR n.id = ?)
        AND ni.status = 'pending'
        AND ni.expires_at > NOW()
        LIMIT 1
    ]]

    local result = db.query(query, email, tostring(namespace_id), tonumber(namespace_id) or 0)
    return result and result[1] or nil
end

--- Accept an invitation
-- @param token string The invitation token
-- @param user_id string|number The accepting user's ID or UUID
-- @return table { success, member?, error? }
function NamespaceInvitationQueries.accept(token, user_id)
    local invitation = NamespaceInvitationQueries.findByToken(token)

    if not invitation then
        return { success = false, error = "Invitation not found" }
    end

    if invitation.status ~= "pending" then
        return { success = false, error = "Invitation is no longer valid" }
    end

    -- Check expiration
    local expires_time = Global.parseTimestamp(invitation.expires_at)
    if expires_time and os.time() > expires_time then
        -- Update status to expired
        db.update("namespace_invitations", {
            status = "expired",
            updated_at = Global.getCurrentTimestamp()
        }, { id = invitation.id })
        return { success = false, error = "Invitation has expired" }
    end

    -- Get numeric user ID
    local numeric_user_id = user_id
    if type(user_id) == "string" then
        local u = db.select("id FROM users WHERE uuid = ? OR id = ?", user_id, tonumber(user_id) or 0)
        numeric_user_id = u[1] and u[1].id
    end

    if not numeric_user_id then
        return { success = false, error = "User not found" }
    end

    -- Verify the accepting user's email matches the invitation
    local user = db.select("email FROM users WHERE id = ?", numeric_user_id)
    if not user or #user == 0 or user[1].email:lower() ~= invitation.email:lower() then
        return { success = false, error = "This invitation was sent to a different email address" }
    end

    -- Check if already a member
    local existing_member = db.select([[
        id FROM namespace_members
        WHERE namespace_id = ? AND user_id = ?
    ]], invitation.namespace_id, numeric_user_id)

    if #existing_member > 0 then
        -- Update invitation status anyway
        db.update("namespace_invitations", {
            status = "accepted",
            accepted_at = Global.getCurrentTimestamp(),
            updated_at = Global.getCurrentTimestamp()
        }, { id = invitation.id })
        return { success = false, error = "You are already a member of this namespace" }
    end

    local timestamp = Global.getCurrentTimestamp()

    -- Create membership
    local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
    local role_ids = invitation.role_id and { invitation.role_id } or nil

    local ok, member = pcall(NamespaceMemberQueries.create, {
        namespace_id = invitation.namespace_id,
        user_id = numeric_user_id,
        status = "active",
        invited_by = invitation.invited_by,
        role_ids = role_ids
    })

    if not ok then
        return { success = false, error = "Failed to create membership: " .. tostring(member) }
    end

    -- Update invitation status
    db.update("namespace_invitations", {
        status = "accepted",
        accepted_at = timestamp,
        updated_at = timestamp
    }, { id = invitation.id })

    return { success = true, member = member }
end

--- Decline an invitation
-- @param token string The invitation token
-- @return table { success, error? }
function NamespaceInvitationQueries.decline(token)
    local invitation = NamespaceInvitationQueries.findByToken(token)

    if not invitation then
        return { success = false, error = "Invitation not found" }
    end

    if invitation.status ~= "pending" then
        return { success = false, error = "Invitation is no longer valid" }
    end

    db.update("namespace_invitations", {
        status = "declined",
        updated_at = Global.getCurrentTimestamp()
    }, { id = invitation.id })

    return { success = true }
end

--- Revoke an invitation (by namespace admin)
-- @param id string|number Invitation ID or UUID
-- @return boolean Success status
function NamespaceInvitationQueries.revoke(id)
    local invitation = NamespaceInvitationQueries.show(id)
    if not invitation then
        return nil
    end

    if invitation.status ~= "pending" then
        error("Can only revoke pending invitations")
    end

    db.update("namespace_invitations", {
        status = "revoked",
        updated_at = Global.getCurrentTimestamp()
    }, { id = invitation.id })

    return true
end

--- Resend an invitation (creates new token and extends expiration)
-- @param id string|number Invitation ID or UUID
-- @param expires_in_days number? Days until expiration (default: 7)
-- @return table The updated invitation
function NamespaceInvitationQueries.resend(id, expires_in_days)
    local invitation = NamespaceInvitationQueries.show(id)
    if not invitation then
        return nil
    end

    if invitation.status ~= "pending" and invitation.status ~= "expired" then
        error("Can only resend pending or expired invitations")
    end

    expires_in_days = expires_in_days or DEFAULT_EXPIRATION_DAYS
    local expires_at = os.date("!%Y-%m-%d %H:%M:%S", os.time() + (expires_in_days * 24 * 60 * 60))
    local timestamp = Global.getCurrentTimestamp()

    db.update("namespace_invitations", {
        token = generateUniqueToken(),
        status = "pending",
        expires_at = expires_at,
        updated_at = timestamp
    }, { id = invitation.id })

    return NamespaceInvitationQueries.show(id)
end

--- Delete an invitation permanently
-- @param id string|number Invitation ID or UUID
-- @return boolean Success status
function NamespaceInvitationQueries.destroy(id)
    local invitation = NamespaceInvitationQueries.show(id)
    if not invitation then
        return nil
    end

    return invitation:delete()
end

--- Count invitations in a namespace
-- @param namespace_id number Namespace ID
-- @param status string|nil Filter by status
-- @return number
function NamespaceInvitationQueries.count(namespace_id, status)
    local query = "SELECT COUNT(*) as count FROM namespace_invitations WHERE namespace_id = ?"
    local values = { namespace_id }

    if status then
        query = query .. " AND status = ?"
        table.insert(values, status)
    end

    local result = db.query(query, table.unpack(values))
    return result[1] and result[1].count or 0
end

--- Expire all overdue invitations
-- @return number Number of expired invitations
function NamespaceInvitationQueries.expireOverdue()
    local result = db.update("namespace_invitations", {
        status = "expired",
        updated_at = Global.getCurrentTimestamp()
    }, db.raw("status = 'pending' AND expires_at < NOW()"))

    return result and result.affected_rows or 0
end

--- Get pending invitations for a user by email
-- @param email string The user's email
-- @return table List of pending invitations
function NamespaceInvitationQueries.getPendingForEmail(email)
    return db.query([[
        SELECT
            ni.*,
            n.uuid as namespace_uuid, n.name as namespace_name, n.slug as namespace_slug,
            n.logo_url as namespace_logo,
            nr.role_name, nr.display_name as role_display_name,
            u.first_name || ' ' || u.last_name as invited_by_name
        FROM namespace_invitations ni
        JOIN namespaces n ON ni.namespace_id = n.id
        LEFT JOIN namespace_roles nr ON ni.role_id = nr.id
        LEFT JOIN users u ON ni.invited_by = u.id
        WHERE LOWER(ni.email) = LOWER(?)
        AND ni.status = 'pending'
        AND ni.expires_at > NOW()
        ORDER BY ni.created_at DESC
    ]], email)
end

return NamespaceInvitationQueries
