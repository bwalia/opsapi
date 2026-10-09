--[[
    Form targets: "create a customer / lead / user from this form"
    ===============================================================

    A registry. Each target says which deployment features it needs, which
    permission the person who publishes the form must hold (publishing lets
    the public create these records with that person's authority), which
    contact fields it needs (added to the form and locked by
    Fields.normalize), and how to find or create its record.

    Rules every target follows (lib/forms/submit.lua runs them):
      * find first, in THIS namespace, by lower(email); a match is linked
        ("matched") and never updated: public input can't edit a record;
      * otherwise create it with the module's own query function;
      * under pg_advisory_xact_lock on (target, namespace, email), so two
        people submitting the same email at once can't create two records.

    Adding a target (CRM contact, support ticket, kanban task, ...) = one more
    register{} block.
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")
local ProjectConfig = require("helper.project-config")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143

local Targets = {}
local REGISTRY, ORDER = {}, {}

local function register(spec)
    REGISTRY[spec.key] = spec
    ORDER[#ORDER + 1] = spec.key
end

local function blank_nil(v)
    if v == nil or v == "" or v == cjson.null then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- customer: the sidebar's Customers (customers table)
-- ---------------------------------------------------------------------------
register({
    key = "customer",
    rank = 2,
    label = "Create a customer",
    description = "Adds each person to Customers, or links the existing customer with that email.",
    features = { "ecommerce", "billing" },
    permission = { "customers", "create" },
    requires = { "contact.name", "contact.email" },
    entity_type = "customer",
    find = function(ctx)
        local row = db.query([[SELECT uuid FROM customers WHERE namespace_id = ? AND lower(email) = lower(?)
            ORDER BY id LIMIT 1]], ctx.namespace_id, ctx.contact.email)[1]
        return row and { outcome = "matched", entity_uuid = row.uuid }
    end,
    create = function(ctx)
        local CustomerQueries = require("queries.CustomerQueries")
        if not CustomerQueries.validEmail(ctx.contact.email) then return nil, "invalid_email" end
        local m = ctx.mapped
        local row = CustomerQueries.create({
            namespace_id = ctx.namespace_id,
            email = ctx.contact.email,
            first_name = ctx.contact.first_name,
            last_name = blank_nil(ctx.contact.last_name),
            phone = blank_nil(m.phone),
            notes = blank_nil(m.notes),
            accepts_marketing = m.marketing_consent == true,
            state = "enabled",
        })
        return { outcome = "created", entity_uuid = row.uuid }
    end,
})

-- ---------------------------------------------------------------------------
-- lead: crm_leads. The table is core, but the Leads screen only exists with
-- CRM, so the option is offered only there.
-- ---------------------------------------------------------------------------
register({
    key = "lead",
    rank = 3,
    label = "Create a lead",
    description = "Adds each person to Leads (source: form), or links their open lead.",
    features = { "crm" },
    permission = { "crm_accounts", "create" }, -- the module the Leads menu uses
    requires = { "contact.name", "contact.email" },
    entity_type = "lead",
    find = function(ctx)
        local row = db.query([[SELECT uuid FROM crm_leads WHERE namespace_id = ? AND lower(email) = lower(?)
            AND deleted_at IS NULL ORDER BY id DESC LIMIT 1]], ctx.namespace_id, ctx.contact.email)[1]
        return row and { outcome = "matched", entity_uuid = row.uuid }
    end,
    create = function(ctx)
        local m, meta = ctx.mapped, ctx.meta
        local utm = type(meta.utm) == "table" and meta.utm or {}
        local lead = require("queries.CrmLeadQueries").createLead({
            namespace_id = ctx.namespace_id,
            first_name = ctx.contact.first_name,
            last_name = blank_nil(ctx.contact.last_name),
            email = ctx.contact.email,
            phone = blank_nil(m.phone),
            company_name = blank_nil(m.company),
            job_title = blank_nil(m.job_title),
            notes = blank_nil(m.notes),
            source = "form",
            channel = blank_nil(utm.medium) or blank_nil(utm.source),
            campaign = blank_nil(utm.campaign),
            referrer_url = blank_nil(meta.referrer),
            landing_page_url = blank_nil(meta.page_url),
            status = "new",
            score = 0,
            metadata = cjson.encode({
                form_uuid = ctx.form.uuid, form_title = ctx.form.title, submission_uuid = ctx.submission_uuid,
            }),
        })
        -- The workspace's lead alerts (email/Telegram), after the commit.
        ctx.after_commit(function()
            require("queries.CrmLeadNotificationQueries").notify(ctx.namespace, lead)
        end)
        return { outcome = "created", entity_uuid = lead.uuid }
    end,
})

-- ---------------------------------------------------------------------------
-- user: an INVITATION to the workspace. The account is created only when the
-- person accepts it from the email and sets a password, which proves they
-- own the address, so a form can't create accounts for other people's
-- emails, nor fill the workspace with fake members.
-- ---------------------------------------------------------------------------
-- Requests from forms don't hold seats (see migrations/invitation-source.lua),
-- so how many may wait at once is capped instead: a flood of them can't grow
-- without bound. ponytail: fixed multiple of the seat limit; make it a setting
-- if a workspace needs more.
local function request_cap(max_users)
    return math.max(50, (tonumber(max_users) or 10) * 5)
end

register({
    key = "user",
    rank = 1,
    label = "Invite them to this workspace",
    description = "Emails each person an invitation with the role you choose. Their account is created when they "
        .. "accept and set a password.",
    permission = { "users", "create" },
    requires = { "contact.name", "contact.email" },
    entity_type = "invitation",
    --- Check the target's settings: the role must exist here and be one the
    -- editor may give (you can't grant what you don't hold).
    configure = function(cfg, auth, namespace_id)
        local role = cfg.role == nil and "member" or cfg.role
        if type(role) ~= "string" or role == "" or #role > 100 then return nil, "role must be a role name" end
        local exists = db.query("SELECT 1 FROM namespace_roles WHERE namespace_id = ? AND role_name = ?",
            namespace_id, role)[1]
        if not exists then
            return nil, "role '" .. role .. "' does not exist in this workspace"
        end
        local ok, why = auth.can_assign_roles({ role })
        if not ok then return nil, why or ("you can't give the role '" .. role .. "'") end
        return { type = "user", role = role }
    end,
    find = function(ctx)
        local member = db.query([[
            SELECT u.uuid FROM namespace_members m JOIN users u ON u.id = m.user_id
            WHERE m.namespace_id = ? AND lower(u.email) = lower(?) AND m.status <> 'removed' LIMIT 1
        ]], ctx.namespace_id, ctx.contact.email)[1]
        if member then return { outcome = "matched", entity_type = "user", entity_uuid = member.uuid } end
        -- An expired invitation still says "pending" until someone opens it.
        db.query([[UPDATE namespace_invitations SET status = 'expired', updated_at = NOW()
            WHERE namespace_id = ? AND lower(email) = lower(?) AND status = 'pending' AND expires_at <= NOW()]],
            ctx.namespace_id, ctx.contact.email)
        local invite = db.query([[SELECT uuid FROM namespace_invitations
            WHERE namespace_id = ? AND lower(email) = lower(?) AND status = 'pending' LIMIT 1]],
            ctx.namespace_id, ctx.contact.email)[1]
        -- Already invited: link it, but don't email again (no inbox flooding).
        return invite and { outcome = "matched", entity_uuid = invite.uuid }
    end,
    create = function(ctx, cfg)
        local Invites = require("queries.NamespaceInvitationQueries")
        if not Invites.hasFreeSeat(ctx.namespace_id, ctx.namespace.max_users) then
            return nil, "workspace_full"
        end
        if Invites.pendingFormRequests(ctx.namespace_id) >= request_cap(ctx.namespace.max_users) then
            return nil, "too_many_requests"
        end
        local role = db.query("SELECT id FROM namespace_roles WHERE namespace_id = ? AND role_name = ?",
            ctx.namespace_id, cfg.role or "member")[1]
        if not role then return nil, "role_missing" end
        local inviter = db.query("SELECT id FROM users WHERE uuid = ?", ctx.published_by_uuid)[1]
        if not inviter then return nil, "publisher_missing" end
        local invite = Invites.create({
            namespace_id = ctx.namespace_id,
            email = ctx.contact.email,
            role_id = role.id,
            invited_by = inviter.id,
            source = "form", -- reserves no seat until accepted
            message = ("You asked to join through the form \"%s\"."):format(ctx.form.title),
        })
        return { outcome = "invited", entity_uuid = invite.uuid }
    end,
})

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

function Targets.get(key)
    return REGISTRY[key]
end

local function deployed(spec)
    return not spec.features or ProjectConfig.isAnyFeatureEnabled(spec.features)
end

--- Targets this deployment has that the caller may add (GET /forms/targets).
-- @param auth { has_permission(module, action) }
function Targets.available(auth, namespace_id)
    local out = {}
    for _, key in ipairs(ORDER) do
        local spec = REGISTRY[key]
        if deployed(spec) then
            local item = {
                key = key, label = spec.label, description = spec.description,
                requires = setmetatable({ unpack(spec.requires) }, cjson.array_mt),
                allowed = auth.has_permission(spec.permission[1], spec.permission[2]) == true,
                permission = spec.permission[1] .. "." .. spec.permission[2],
            }
            if key == "user" then
                item.roles = setmetatable({}, cjson.array_mt)
                for _, r in ipairs(db.query([[SELECT role_name, display_name FROM namespace_roles
                    WHERE namespace_id = ? ORDER BY role_name]], namespace_id)) do
                    if auth.can_assign_roles({ r.role_name }) then
                        item.roles[#item.roles + 1] = { name = r.role_name, label = r.display_name ~= db.NULL
                            and r.display_name or r.role_name }
                    end
                end
            end
            out[#out + 1] = item
        end
    end
    return setmetatable(out, cjson.array_mt)
end

--- Validate a form's target list against this deployment and the editor.
-- @param list { { type = "customer" }, { type = "user", role = "member" }, ... }
-- @param auth { has_permission(module, action), can_assign_roles(names) }
-- @return clean list, set of contact roles they need | nil, err
function Targets.clean(list, auth, namespace_id)
    if type(list) == "string" then
        local ok, decoded = pcall(cjson.decode, list)
        list = ok and decoded or nil
    end
    if list == nil or list == cjson.null then list = {} end
    if type(list) ~= "table" then return nil, "targets must be a list" end
    local out, roles, seen = {}, {}, {}
    for _, t in ipairs(list) do
        if type(t) == "string" then t = { type = t } end
        local spec = type(t) == "table" and REGISTRY[t.type]
        if not spec then return nil, "unknown target '" .. tostring(type(t) == "table" and t.type or t) .. "'" end
        if not deployed(spec) then return nil, "'" .. spec.key .. "' isn't available in this deployment" end
        if seen[spec.key] then return nil, "target '" .. spec.key .. "' is listed twice" end
        seen[spec.key] = true
        if not auth.has_permission(spec.permission[1], spec.permission[2]) then
            return nil, ("you need %s.%s permission to %s"):format(spec.permission[1], spec.permission[2],
                spec.label:lower())
        end
        local cfg = { type = spec.key }
        if spec.configure then
            local err
            cfg, err = spec.configure(t, auth, namespace_id)
            if not cfg then return nil, err end
        end
        out[#out + 1] = cfg
        for _, r in ipairs(spec.requires) do roles[r] = true end
    end
    table.sort(out, function(a, b) return REGISTRY[a.type].rank < REGISTRY[b.type].rank end)
    return setmetatable(out, cjson.array_mt), roles
end

--- Contact roles a stored (already clean) target list needs.
function Targets.roles(list)
    local roles = {}
    for _, t in ipairs(list or {}) do
        local spec = REGISTRY[t.type]
        for _, r in ipairs(spec and spec.requires or {}) do roles[r] = true end
    end
    return roles
end

--- Run one target inside the caller's transaction, isolated by a savepoint so
-- its failure keeps the response. @return { outcome, entity_type, entity_uuid, error_code }
function Targets.run(cfg, ctx)
    local spec = REGISTRY[cfg.type]
    if not spec then return { outcome = "failed", error_code = "unknown_target" } end
    local sp = "forms_target_" .. spec.key
    db.query("SAVEPOINT " .. sp)
    local ok, res, code = pcall(function()
        db.query("SELECT pg_advisory_xact_lock(hashtext(?))",
            "forms:" .. spec.key .. ":" .. ctx.namespace_id .. ":" .. ctx.contact.email:lower())
        local found = spec.find(ctx, cfg)
        if found then return found end
        return spec.create(ctx, cfg) -- may be nil, error_code (an `or` would drop the code)
    end)
    if ok and res then
        db.query("RELEASE SAVEPOINT " .. sp)
    else
        db.query("ROLLBACK TO SAVEPOINT " .. sp)
        -- A unique violation: the record was created another way meanwhile.
        if not ok and tostring(res):find("duplicate key", 1, true) then
            local found_ok, found = pcall(spec.find, ctx, cfg)
            res = found_ok and found or nil
            code = res and nil or "email_in_use"
        elseif not ok then
            ngx.log(ngx.WARN, "[forms] target ", spec.key, " failed: ", tostring(res))
            res, code = nil, "error"
        end
        db.query("RELEASE SAVEPOINT " .. sp)
        if not res then return { outcome = "failed", entity_type = spec.entity_type, error_code = code or "error" } end
    end
    res.entity_type = res.entity_type or spec.entity_type
    return res
end

return Targets
