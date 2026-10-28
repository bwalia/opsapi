-- Public demo workspace for opsapi.org/demo. Safe to re-run.
--
-- `showcase` holds ONLY fictional sample users (example.com) and the public
-- read-only account demo@opsapi.org, so the published demo login never shows
-- the real people who sign in to the demo apps (they land in `demo`).
-- The emailed sign-in code is off here only, so the published password works
-- on its own; the viewer role can read every module and change nothing.
--
--   kubectl -n demo cp devops/demo/seed-showcase.lua <api-pod>:/tmp/seed-showcase.lua
--   kubectl -n demo exec <api-pod> -- sh -c 'cd /app && printf %s "$PASSWORD" > /tmp/demo-password && \
--     lapis exec "assert(loadfile(\"/tmp/seed-showcase.lua\"))()"; rm -f /tmp/demo-password'
-- (lapis exec runs inside nginx, which doesn't pass environment variables on.)
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")
local UserQueries = require("queries.UserQueries")
local NamespaceQueries = require("queries.NamespaceQueries")

local f = io.open("/tmp/demo-password")
local password = f and f:read("*a")
if f then f:close() end
assert(password and #password >= 12, "write the demo password (12+ chars) to /tmp/demo-password")

local owner = db.select("id FROM users WHERE email = ?", "tenthmatrix.mailer@gmail.com")[1]
assert(owner, "owner user not found")

local ns = db.select("* FROM namespaces WHERE slug = 'showcase'")[1]
if not ns then
    NamespaceQueries.createWithOwner(owner.id, {
        name = "OpsAPI Showcase", slug = "showcase", project_code = "core_only",
        description = "Public read-only demo workspace with fictional sample users",
    })
    ns = db.select("* FROM namespaces WHERE slug = 'showcase'")[1]
end
db.update("namespaces", { mfa_required = false }, { id = ns.id })

-- viewer: "read" on every module the owner role knows about
local owner_role = db.select("permissions FROM namespace_roles WHERE namespace_id = ? AND role_name = 'owner'", ns.id)[1]
local read = {}
for module in pairs(cjson.decode(owner_role.permissions)) do read[module] = { "read" } end
local perms = cjson.encode(read)
local viewer = db.select("id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'viewer'", ns.id)[1]
if viewer then
    db.update("namespace_roles", { permissions = perms }, { id = viewer.id })
else
    local ts = Global.getCurrentTimestamp()
    db.insert("namespace_roles", {
        uuid = Global.generateUUID(), namespace_id = ns.id, role_name = "viewer",
        display_name = "Viewer (read-only)", description = "Can see every page, change nothing",
        permissions = perms, is_system = false, is_default = false, priority = 5,
        created_at = ts, updated_at = ts,
    })
end

local function ensure_user(u, role)
    local row = db.select("id FROM users WHERE email = ?", u.email)[1]
    if row then
        db.update("users", { active = true, password = Global.hashPassword(u.password) }, { id = row.id })
        return
    end
    UserQueries.create({
        email = u.email, username = u.username, first_name = u.first_name, last_name = u.last_name,
        password = u.password, role = "buyer", active = "true",
        namespace_id = ns.id, namespace_role = role,
    })
end

ensure_user({ email = "demo@opsapi.org", username = "opsapi-demo", first_name = "Demo",
              last_name = "Viewer", password = password }, "viewer")

-- Fictional sample users; nobody can sign in as them (random passwords).
local samples = {
    { "ava.patel@example.com",   "Ava",    "Patel",   "admin" },
    { "liam.okafor@example.com", "Liam",   "Okafor",  "developer" },
    { "mia.chen@example.com",    "Mia",    "Chen",    "developer" },
    { "noah.berg@example.com",   "Noah",   "Berg",    "member" },
    { "zara.ali@example.com",    "Zara",   "Ali",     "member" },
    { "oscar.dubois@example.com","Oscar",  "Dubois",  "member" },
}
for _, s in ipairs(samples) do
    ensure_user({ email = s[1], username = s[1]:match("^[^@]+"):gsub("%.", "-"), first_name = s[2],
                  last_name = s[3], password = Global.generateRandomPassword() .. "Aa1!" }, s[4])
end

-- The fictional Ava owns the workspace, so the public member list shows no
-- real address; the real admin leaves it (platform admins still reach it).
local ava = db.select("id FROM users WHERE email = 'ava.patel@example.com'")[1]
local owner_role_id = db.select("id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'owner'", ns.id)[1].id
db.update("namespaces", { owner_user_id = ava.id }, { id = ns.id })
db.update("namespace_members", { is_owner = true }, { namespace_id = ns.id, user_id = ava.id })
db.query([[UPDATE namespace_user_roles SET namespace_role_id = ? WHERE namespace_member_id =
           (SELECT id FROM namespace_members WHERE namespace_id = ? AND user_id = ?)]], owner_role_id, ns.id, ava.id)
db.query([[DELETE FROM namespace_user_roles WHERE namespace_member_id IN
           (SELECT id FROM namespace_members WHERE namespace_id = ? AND user_id = ?)]], ns.id, owner.id)
db.delete("namespace_members", { namespace_id = ns.id, user_id = owner.id })

print("showcase ns=" .. ns.id .. " mfa_required=false viewer+demo+" .. #samples .. " samples")
