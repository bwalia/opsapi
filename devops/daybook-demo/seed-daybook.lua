-- Daybook demo: workspaces, people, the public read-only login and the Daybook theme.
-- One workspace per vertical (devops/daybook-demo/verticals/*.lua). Safe to re-run.
-- Follow it with seed-daybook-data.lua for each vertical's tax data.
--
--   seed everything:  lapis exec 'assert(loadfile("/tmp/daybook-seed/seed-daybook.lua"))()'
--   one vertical:     lapis exec 'assert(loadfile("/tmp/daybook-seed/seed-daybook.lua"))("practice")'
--
-- The published password (daybook.co.uk/demo) is read from <seed dir>/demo-password,
-- because lapis exec runs inside nginx, which doesn't pass environment variables on.
--
-- What it guarantees, per vertical:
--   * workspace <namespace.slug>, project_code tax_copilot, emailed sign-in code OFF
--   * a `viewer` role: "read" on every module the owner role has; changes nothing
--   * staff (fictional, @sample.daybook.co.uk, random passwords nobody knows), the first
--     "owner" owning the workspace; clients as plain members
--   * demo@daybook.co.uk as a viewer (and nothing more) in EVERY demo workspace
--   * the Daybook theme (navy, gold, warm paper) active for the workspace
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")
local UserQueries = require("queries.UserQueries")
local NamespaceQueries = require("queries.NamespaceQueries")

local slug_arg = ...
local SRC = debug.getinfo(1, "S").source
local DIR = (SRC:match("^@(.*/)")) or "/tmp/daybook-seed/"
local C = assert(loadfile(DIR .. "daybook-common.lua"))()
local verticals, index = C.verticals(DIR, slug_arg)

local function read_file(p)
    local f = io.open(p)
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s and s:gsub("%s+$", "") or nil
end
local password = read_file(DIR .. "demo-password") or read_file("/tmp/demo-password")
assert(password and #password >= 12, "write the demo password (12+ chars) to " .. DIR .. "demo-password")

local PROJECT = "tax_copilot"

-- A Daybook theme for the dashboard: corporate-blue preset with the spec's palette.
local THEME = {
    colors = {
        primary = { ["50"] = "#EEF2F8", ["100"] = "#E3EAF3", ["200"] = "#C5D3E6", ["300"] = "#9DB4D3",
            ["400"] = "#274B78", ["500"] = "#1D3A5F", ["600"] = "#18314F", ["700"] = "#142A44",
            ["800"] = "#10223A", ["900"] = "#0B1729" },
        secondary = { ["50"] = "#F6F4EE", ["100"] = "#EFEBE1", ["200"] = "#DDD6C6", ["300"] = "#B3BDCE",
            ["400"] = "#8592A8", ["500"] = "#6E7890", ["600"] = "#46526A", ["700"] = "#2A3852",
            ["800"] = "#1A2740", ["900"] = "#14213D" },
        accent = "#9C7A2E", background = "#F6F4EE", surface = "#FFFFFF", surface_elevated = "#FFFFFF",
        foreground = "#14213D", warning = "#A85F00",
    },
    branding = { brand_name = "Daybook", logo_text = "Daybook" },
}

local function merge(into, from)
    for k, v in pairs(from) do
        if type(v) == "table" and type(into[k]) == "table" then merge(into[k], v) else into[k] = v end
    end
    return into
end

local function one(sql, ...) return (db.query(sql, ...) or {})[1] end

-- ── people ────────────────────────────────────────────────────────────────

local function username_for(email)
    local u = email:match("^[^@]+"):gsub("[^%w]", "-")
    return u:sub(1, 25)
end

-- Make sure the user exists and has this password. Never joins a workspace by itself
-- (a project_code that names no tenant stops UserQueries' auto-assignment).
local function ensure_user(email, first, last, pw)
    local row = one("SELECT id FROM users WHERE email = ?", email)
    if row then
        db.update("users", { active = true, first_name = first, last_name = last,
            password = Global.hashPassword(pw) }, { id = row.id })
        return row.id
    end
    local u = UserQueries.create({
        email = email, username = username_for(email), first_name = first, last_name = last,
        password = pw, role = "buyer", active = "true", project_code = "__daybook_no_tenant__",
    })
    return u.id
end

local function random_pw() return Global.generateRandomPassword() .. "Aa1!" end

-- Membership with exactly one role.
local function ensure_member(ns_id, user_id, role_name, is_owner)
    local ts = Global.getCurrentTimestamp()
    local m = one("SELECT id FROM namespace_members WHERE namespace_id = ? AND user_id = ?", ns_id, user_id)
    if not m then
        db.insert("namespace_members", { uuid = Global.generateUUID(), namespace_id = ns_id, user_id = user_id,
            status = "active", is_owner = is_owner or false, joined_at = ts, created_at = ts, updated_at = ts })
        m = one("SELECT id FROM namespace_members WHERE namespace_id = ? AND user_id = ?", ns_id, user_id)
    else
        db.update("namespace_members", { status = "active", is_owner = is_owner or false, updated_at = ts }, { id = m.id })
    end
    local role = one("SELECT id FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", ns_id, role_name)
    assert(role, "no role " .. role_name .. " in namespace " .. ns_id)
    db.query("DELETE FROM namespace_user_roles WHERE namespace_member_id = ?", m.id)
    db.insert("namespace_user_roles", { uuid = Global.generateUUID(), namespace_member_id = m.id,
        namespace_role_id = role.id, created_at = ts, updated_at = ts })
end

-- ── workspace ─────────────────────────────────────────────────────────────

local function ensure_namespace(v)
    local spec = v.namespace
    local owner
    for _, s in ipairs(v.staff) do if s.role == "owner" then owner = s break end end
    assert(owner, "vertical " .. v.slug .. " needs a staff member with role owner")
    local owner_id = ensure_user(owner.email, owner.first, owner.last, random_pw())

    local ns = one("SELECT * FROM namespaces WHERE slug = ?", spec.slug)
    if not ns then
        local _, err = NamespaceQueries.createWithOwner(owner_id, {
            name = spec.name, slug = spec.slug, project_code = PROJECT, description = spec.description,
            allowed_redirect_origins = { "https://demo.daybook.co.uk" },
        })
        assert(not err, err)
        ns = one("SELECT * FROM namespaces WHERE slug = ?", spec.slug)
    end
    db.update("namespaces", { name = spec.name, description = spec.description, project_code = PROJECT,
        mfa_required = false, owner_user_id = owner_id, status = "active" }, { id = ns.id })
    ensure_member(ns.id, owner_id, "owner", true)
    return ns
end

-- viewer: "read" on every module the owner role knows about (same as the OpsAPI showcase).
local function ensure_viewer_role(ns_id)
    local owner_role = one("SELECT permissions FROM namespace_roles WHERE namespace_id = ? AND role_name = 'owner'", ns_id)
    local perms = owner_role.permissions
    if type(perms) == "string" then perms = cjson.decode(perms) end
    local read = {}
    for module in pairs(perms or {}) do read[module] = { "read" } end
    local encoded = cjson.encode(read)
    local viewer = one("SELECT id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'viewer'", ns_id)
    if viewer then
        db.update("namespace_roles", { permissions = encoded }, { id = viewer.id })
    else
        local ts = Global.getCurrentTimestamp()
        db.insert("namespace_roles", { uuid = Global.generateUUID(), namespace_id = ns_id, role_name = "viewer",
            display_name = "Viewer (read-only)", description = "Can see every page, change nothing",
            permissions = encoded, is_system = false, is_default = false, priority = 5,
            created_at = ts, updated_at = ts })
    end
end

local function ensure_theme(ns_id)
    local ok_svc, ThemeService = pcall(require, "lib.theme-service")
    local ok_q, ThemeQueries = pcall(require, "queries.ThemeQueries")
    if not (ok_svc and ok_q) then print("  theme: theme module not loaded, skipped"); return end
    local base = {}
    for _, p in ipairs(ThemeQueries.listPresets(PROJECT) or {}) do
        if p.slug == "corporate-blue" then
            local t = ThemeQueries.getTokens(p.id)
            base = t and t.tokens or {}
            if type(base) == "string" then base = cjson.decode(base) end
        end
    end
    local tokens = merge(base, THEME)
    local existing = one("SELECT uuid FROM themes WHERE namespace_id = ? AND project_code = ? AND slug = 'daybook' AND deleted_at IS NULL",
        ns_id, PROJECT)
    local uuid
    if existing then
        uuid = existing.uuid
        local res = ThemeService.update(ns_id, nil, uuid, { tokens = tokens })
        if res and res.ok == false then print("  theme update: " .. cjson.encode(res)) end
    else
        local res = ThemeService.create(ns_id, PROJECT, nil, { name = "Daybook", slug = "daybook",
            description = "Navy, muted gold and warm paper", tokens = tokens })
        uuid = res and res.ok and res.data and res.data.uuid
        if not uuid then print("  theme create failed: " .. cjson.encode(res or {})); return end
    end
    local act = ThemeService.activate(ns_id, PROJECT, nil, tostring(uuid))
    if not (act and act.ok) then print("  theme activate failed: " .. cjson.encode(act or {})) end
end

-- ── run ───────────────────────────────────────────────────────────────────

local first_ns
for _, v in ipairs(verticals) do
    local ns = ensure_namespace(v)
    ensure_viewer_role(ns.id)
    for _, s in ipairs(v.staff) do
        if s.role ~= "owner" then
            ensure_member(ns.id, ensure_user(s.email, s.first, s.last, random_pw()), s.role, false)
        end
    end
    for _, c in ipairs(v.clients) do
        ensure_member(ns.id, ensure_user(c.email, c.first, c.last, random_pw()), "member", false)
    end
    local demo_id = ensure_user(C.DEMO_EMAIL, "Demo", "Visitor", password)
    ensure_member(ns.id, demo_id, "viewer", false)
    ensure_theme(ns.id)
    if v.slug == index[1] then first_ns = ns end
    print(("daybook %s: ns=%d (%s) staff=%d clients=%d viewer=%s"):format(v.slug, ns.id, ns.slug, #v.staff,
        #v.clients, C.DEMO_EMAIL))
end

-- The demo login opens on the first vertical's workspace.
if first_ns then
    local demo = one("SELECT id FROM users WHERE email = ?", C.DEMO_EMAIL)
    NamespaceQueries.setUserSettings(demo.id, { default_namespace_id = first_ns.id, last_active_namespace_id = first_ns.id })
end
