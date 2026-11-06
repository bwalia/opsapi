-- Local test fixture for the media library (run inside the opsapi container):
--   docker cp lapis/spec/media-library-e2e/setup.lua opsapi:/tmp/ml_setup.lua
--   docker exec -w /app opsapi lapis exec "assert(loadfile('/tmp/ml_setup.lua'))()"
-- Two workspaces: media-test-a (owner, an editor with cms read/update, a reader
-- with cms read only) and media-test-b (owner). e2e.invalid addresses, unusable
-- passwords. Tokens go to /tmp/ml_tokens.json in the container; never printed.
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")
local JWT = require("helper.jwt-helper")

local function user(email, first)
    local u = db.query("SELECT * FROM users WHERE lower(email) = lower(?)", email)[1]
    if u then return u end
    return db.query([[INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
        VALUES (?, ?, 'Test', ?, ?, '!disabled', TRUE, NOW(), NOW()) RETURNING *]], Global.generateUUID(), first, email, email)[1]
end

local function workspace(slug, name, owner)
    local ns = db.query("SELECT * FROM namespaces WHERE slug = ?", slug)[1]
    if not ns then
        local created, err = require("queries.NamespaceQueries").createWithOwner(owner.id, {
            name = name, slug = slug, project_code = "all", status = "active",
        })
        assert(created, err)
        ns = db.query("SELECT * FROM namespaces WHERE slug = ?", slug)[1]
    end
    db.query("UPDATE namespaces SET mfa_required = FALSE WHERE id = ?", ns.id)
    return ns
end

local function role(ns, name, perms)
    local r = db.query("SELECT * FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", ns.id, name)[1]
    local p = cjson.encode(perms)
    if not r then
        r = db.query([[INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, priority, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 20, NOW(), NOW()) RETURNING *]], Global.generateUUID(), ns.id, name, name, p)[1]
    else
        db.query("UPDATE namespace_roles SET permissions = ? WHERE id = ?", p, r.id)
    end
    return r
end

local function member(ns, u, is_owner, r)
    local m = db.query("SELECT * FROM namespace_members WHERE namespace_id = ? AND user_id = ?", ns.id, u.id)[1]
    if not m then
        m = db.query([[INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
            VALUES (?, ?, ?, 'active', ?, NOW(), NOW(), NOW()) RETURNING *]], Global.generateUUID(), ns.id, u.id, is_owner)[1]
    end
    if r and #db.query("SELECT 1 FROM namespace_user_roles WHERE namespace_member_id = ? AND namespace_role_id = ?", m.id, r.id) == 0 then
        db.query([[INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
            VALUES (?, ?, ?, NOW(), NOW())]], Global.generateUUID(), m.id, r.id)
    end
    return m
end

local function token(ns, u)
    local m = db.query("SELECT * FROM namespace_members WHERE namespace_id = ? AND user_id = ?", ns.id, u.id)[1]
    local roles = db.query([[SELECT r.role_name, r.display_name FROM namespace_user_roles ur
        JOIN namespace_roles r ON r.id = ur.namespace_role_id WHERE ur.namespace_member_id = ?]], m.id)
    u.roles = {}
    return { uuid = u.uuid, email = u.email, first_name = u.first_name, last_name = u.last_name,
        namespace_uuid = ns.uuid, slug = ns.slug, name = ns.name,
        token = JWT.generateNamespaceToken(u, ns, m, { namespace_roles = roles }) }
end

local owner_a = user("ml-owner-a@e2e.invalid", "Ada")
local editor = user("ml-editor@e2e.invalid", "Eli")
local reader = user("ml-reader@e2e.invalid", "Rae")
local owner_b = user("ml-owner-b@e2e.invalid", "Bo")

local a = workspace("media-test-a", "Media Test A", owner_a)
local b = workspace("media-test-b", "Media Test B", owner_b)
member(a, owner_a, true)
member(a, editor, false, role(a, "editor", { cms = { "read", "update" }, dashboard = { "read" } }))
member(a, reader, false, role(a, "reader", { cms = { "read" }, dashboard = { "read" } }))
member(b, owner_b, true)

-- A post in A that already shows an image (backfill + "used in").
if #db.query("SELECT 1 FROM cms_posts WHERE namespace_id = ? AND slug = 'media-test-post'", a.id) == 0 then
    db.query([[INSERT INTO cms_posts (uuid, namespace_id, title, slug, content_html, featured_image_url, status, created_at, updated_at)
        VALUES (?, ?, 'Media test post', 'media-test-post', '<p>Hi</p><img src="https://example.com/old.png">',
                '/img/old-cover.jpg', 'draft', NOW(), NOW())]], Global.generateUUID(), a.id)
end

-- Run the backfill again (it must be idempotent): the post's two images join A's library.
local backfill = require("migrations.media-library")[2]
backfill()
backfill()

local out = {
    a = { namespace_id = a.id, owner = token(a, owner_a), editor = token(a, editor), reader = token(a, reader) },
    b = { namespace_id = b.id, owner = token(b, owner_b) },
}
local f = assert(io.open("/tmp/ml_tokens.json", "w"))
f:write(cjson.encode(out))
f:close()
print("fixture ready: media-test-a (" .. a.id .. "), media-test-b (" .. b.id .. ")")
