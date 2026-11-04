-- Local test fixture for the lead pipeline (run inside the opsapi container):
--   docker exec -w /app opsapi lapis exec "dofile('/tmp/lp_setup.lua')"
-- Creates a test workspace "lead-pipeline-test" with an owner and two sales reps
-- (e2e.invalid addresses, unusable passwords) and writes their tokens to
-- /tmp/lp_tokens.json inside the container. Never prints a token.
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local function user(email, first, last)
    local u = db.query("SELECT * FROM users WHERE lower(email) = lower(?)", email)[1]
    if u then return u end
    return db.query([[INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '!disabled', TRUE, NOW(), NOW()) RETURNING *]], Global.generateUUID(), first, last, email, email)[1]
end

local owner = user("lp-owner@e2e.invalid", "Olivia", "Owner")
local rep1 = user("lp-rep1@e2e.invalid", "Ravi", "Rep")
local rep2 = user("lp-rep2@e2e.invalid", "Rosa", "Rep")

local ns = db.query("SELECT * FROM namespaces WHERE slug = 'lead-pipeline-test'")[1]
if not ns then
    local created, err = require("queries.NamespaceQueries").createWithOwner(owner.id, {
        name = "Lead Pipeline Test", slug = "lead-pipeline-test", project_code = "all", status = "active",
    })
    assert(created, err)
    ns = db.query("SELECT * FROM namespaces WHERE slug = 'lead-pipeline-test'")[1]
end
db.query("UPDATE namespaces SET mfa_required = FALSE WHERE id = ?", ns.id)

local role = db.query("SELECT * FROM namespace_roles WHERE namespace_id = ? AND role_name = 'sales'", ns.id)[1]
local perms = cjson.encode({
    crm_leads = { "create", "read", "update" }, crm_contacts = { "create", "read", "update" },
    crm_deals = { "create", "read", "update" }, crm_activities = { "create", "read", "update", "delete" },
    crm_accounts = { "read" }, crm_pipelines = { "read" }, dashboard = { "read" },
})
if not role then
    role = db.query([[INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, priority, created_at, updated_at)
        VALUES (?, ?, 'sales', 'Sales', ?, 20, NOW(), NOW()) RETURNING *]], Global.generateUUID(), ns.id, perms)[1]
else
    db.query("UPDATE namespace_roles SET permissions = ? WHERE id = ?", perms, role.id)
end

local function member(u, is_owner)
    local m = db.query("SELECT * FROM namespace_members WHERE namespace_id = ? AND user_id = ?", ns.id, u.id)[1]
    if not m then
        m = db.query([[INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
            VALUES (?, ?, ?, 'active', ?, NOW(), NOW(), NOW()) RETURNING *]], Global.generateUUID(), ns.id, u.id, is_owner)[1]
    end
    return m
end
local m_owner = member(owner, true)
for _, u in ipairs({ rep1, rep2 }) do
    local m = member(u, false)
    if #db.query("SELECT 1 FROM namespace_user_roles WHERE namespace_member_id = ? AND namespace_role_id = ?", m.id, role.id) == 0 then
        db.query([[INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
            VALUES (?, ?, ?, NOW(), NOW())]], Global.generateUUID(), m.id, role.id)
    end
end

local JWT = require("helper.jwt-helper")
local tokens = { namespace_id = ns.id, slug = ns.slug, users = {} }
for key, u in pairs({ owner = owner, rep1 = rep1, rep2 = rep2 }) do
    local m = db.query("SELECT * FROM namespace_members WHERE namespace_id = ? AND user_id = ?", ns.id, u.id)[1]
    local roles = db.query([[SELECT r.role_name, r.display_name FROM namespace_user_roles ur JOIN namespace_roles r ON r.id = ur.namespace_role_id
        WHERE ur.namespace_member_id = ?]], m.id)
    u.roles = {}
    tokens.users[key] = { uuid = u.uuid, email = u.email,
        token = JWT.generateNamespaceToken(u, ns, m, { namespace_roles = roles }) }
end
local f = assert(io.open("/tmp/lp_tokens.json", "w"))
f:write(cjson.encode(tokens))
f:close()
print("fixture ready: workspace " .. ns.slug .. " (id " .. ns.id .. "), users owner/rep1/rep2")
