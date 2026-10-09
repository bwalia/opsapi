--[[
    Forms: create, edit, publish and list a workspace's forms
    =========================================================

    Every function takes the caller's namespace id and filters by it. Saving
    always goes through Fields.normalize() + Targets.clean(), so the builder,
    the REST API and the AI agent produce the same, valid forms.

    `auth` = { has_permission(module, action), can_assign_roles(names) } for
    the person acting (FormQueries.auth(self) for a request; the agent passes
    its own). Adding a target, or publishing a form that has one, needs that
    target's permission: publishing lets the public create those records.
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")
local Global = require("helper.global")
local Fields = require("lib.forms.fields")
local Targets = require("lib.forms.targets")
local Templates = require("lib.forms.templates")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143

local FormQueries = {}

FormQueries.MAX_PER_NAMESPACE = 1000
local PAGE = 50
local ALNUM = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local EMAIL = "^[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+$"
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function decode(v, fallback)
    if type(v) == "table" then return v end
    if type(v) == "string" and v ~= "" then
        local ok, d = pcall(cjson.decode, v)
        if ok and d ~= nil then return d end
    end
    return fallback
end
FormQueries.decode = decode

local function jsonb(v)
    return db.raw(db.escape_literal(cjson.encode(v)) .. "::jsonb")
end

local function nonnull(v)
    if v == nil or v == db.NULL or v == cjson.null then return nil end
    return v
end

function FormQueries.validUuid(v)
    return type(v) == "string" and v:match(UUID) ~= nil
end

--- The acting person's permissions, from a request.
function FormQueries.auth(self)
    local NamespaceMiddleware = require("middleware.namespace")
    local RbacGuard = require("helper.rbac-guard")
    return {
        has_permission = function(module, action) return NamespaceMiddleware.hasPermission(self, module, action) end,
        can_assign_roles = function(names) return RbacGuard.can_assign_role_names(self, names) end,
    }
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function setting_text(v, max, multiline)
    if v == nil or v == cjson.null or v == "" then return nil end
    local s, err = Fields.text(v, max, multiline)
    if not s then return nil, err end
    return s ~= "" and s or nil
end

--- Merge `raw` into `current` settings, validating each key.
-- @return settings | nil, err
function FormQueries.cleanSettings(raw, current, namespace_id)
    local s = {}
    for k, v in pairs(current or {}) do s[k] = v end
    if raw == nil or raw == cjson.null then return s end
    if type(raw) ~= "table" then return nil, "settings must be an object" end
    local function set(key, fn)
        if raw[key] == nil then return true end
        if raw[key] == cjson.null or raw[key] == "" then
            s[key] = nil
            return true
        end
        local v, err = fn(raw[key])
        if v == nil then return nil, key .. " " .. (err or "is invalid") end
        s[key] = v
        return true
    end
    local checks = {
        success_message = function(v) return setting_text(v, 1000, true) end,
        closed_message = function(v) return setting_text(v, 500, true) end,
        redirect_url = function(v)
            local u = setting_text(v, 2000)
            if not u or not u:match("^https://[%w%-%.]+[^%s]*$") then return nil, "must be an https:// address" end
            return u
        end,
        close_at = function(v)
            if type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d") or #v > 40 then
                return nil, "must be a date and time like 2026-12-31T17:00:00Z"
            end
            local ok, row = pcall(db.query, "SELECT to_char(?::timestamptz AT TIME ZONE 'UTC', "
                .. "'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS t", v)
            if not ok or not row[1] then return nil, "is not a valid date and time" end
            return row[1].t
        end,
        max_submissions = function(v)
            local n = tonumber(v)
            if not n or n ~= math.floor(n) or n < 1 or n > 10000000 then return nil, "must be a whole number from 1" end
            return n
        end,
        retention_days = function(v)
            local n = tonumber(v)
            if not n or n ~= math.floor(n) or n < 1 or n > 3650 then return nil, "must be 1-3650 days" end
            return n
        end,
        notify_emails = function(v)
            if type(v) == "string" then v = { v } end
            if type(v) ~= "table" or #v > 10 then return nil, "must be a list of at most 10 emails" end
            local out = {}
            for _, e in ipairs(v) do
                e = type(e) == "string" and e:match("^%s*(.-)%s*$") or ""
                if not e:match(EMAIL) or #e > 254 then return nil, "contains an invalid email" end
                out[#out + 1] = e:lower()
            end
            return setmetatable(out, cjson.array_mt)
        end,
        -- The workspace's Turnstile check on this form (keys: Forms -> Workspace settings).
        captcha = function(v)
            if v ~= true and v ~= "true" then return false end
            if namespace_id and not require("lib.forms.workspace").turnstile(namespace_id) then
                return nil, "needs your workspace's Turnstile keys first (Forms → Spam protection)"
            end
            return true
        end,
        notify_in_app = function(v) return v == true or v == "true" end,
        -- Post each new response to one of this workspace's chat channels.
        chat_channel_uuid = function(v)
            if type(v) ~= "string" or not v:match(UUID) then return nil, "must be a chat channel" end
            if not require("helper.project-config").isFeatureEnabled("chat") then return nil, "chat isn't available" end
            local ch = db.query("SELECT 1 FROM chat_channels WHERE uuid = ? AND namespace_id = ?", v,
                namespace_id or 0)[1]
            if not ch then return nil, "is not a channel of this workspace" end
            return v
        end,
        -- Branding of the public page.
        theme = function(v)
            if type(v) ~= "table" then return nil, "must be an object" end
            local t = {}
            for _, k in ipairs({ "primary_color", "background" }) do
                if v[k] ~= nil and v[k] ~= cjson.null and v[k] ~= "" then
                    if type(v[k]) ~= "string" or not v[k]:match("^#%x%x%x%x%x%x$") then
                        return nil, k .. " must be a colour like #1f6feb"
                    end
                    t[k] = v[k]:lower()
                end
            end
            if v.logo_url ~= nil and v.logo_url ~= cjson.null and v.logo_url ~= "" then
                local u = setting_text(v.logo_url, 1000)
                if not u or not u:match("^https://[%w%-%.]+[^%s\"'<>]*$") then
                    return nil, "logo_url must be an https:// address"
                end
                t.logo_url = u
            end
            if v.submit_label ~= nil and v.submit_label ~= cjson.null and v.submit_label ~= "" then
                local l, err = setting_text(v.submit_label, 40)
                if not l then return nil, "submit_label " .. (err or "is invalid") end
                t.submit_label = l
            end
            if v.hide_branding == true then
                if namespace_id and not require("lib.forms.limits").of(namespace_id).hide_branding then
                    return nil, "hiding \"Powered by\" isn't included in this workspace's plan"
                end
                t.hide_branding = true
            end
            return t
        end,
        auto_reply = function(v)
            if type(v) ~= "table" then return nil, "must be { enabled, subject, body }" end
            local subject, serr = setting_text(v.subject, 200)
            local body, berr = setting_text(v.body, 5000, true)
            if serr or berr then return nil, serr or berr end
            local enabled = v.enabled == true or v.enabled == "true"
            if enabled and (not subject or not body) then return nil, "needs a subject and a message" end
            return { enabled = enabled, subject = subject, body = body }
        end,
    }
    for key, fn in pairs(checks) do
        local ok, err = set(key, fn)
        if not ok then return nil, err end
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------

local SELECT = [[
    f.*, v.version AS published_version, v.created_at AS version_published_at,
    (f.published_version_id IS NOT NULL
        AND (f.draft_schema IS DISTINCT FROM v.schema OR f.targets IS DISTINCT FROM v.targets))
        AS has_unpublished_changes
    FROM forms f LEFT JOIN form_versions v ON v.id = f.published_version_id
]]

local function input_count(schema)
    local n = 0
    for _, f in ipairs(schema.fields or {}) do
        local def = Fields.TYPES[f.type]
        if def and def.input ~= false then n = n + 1 end
    end
    return n
end

--- API shape of a form row. `full` adds the draft schema and settings.
function FormQueries.present(row, full)
    local schema = decode(row.draft_schema, { fields = {} })
    local origin = nonnull(row.public_origin)
    local domain = require("lib.forms.domains").active_for(row.namespace_id)
    if domain then origin = "https://" .. domain end
    local out = {
        uuid = row.uuid,
        public_id = row.public_id,
        title = row.title,
        description = nonnull(row.description),
        status = row.status,
        question_count = input_count(schema),
        submission_count = tonumber(row.submission_count) or 0,
        last_submission_at = nonnull(row.last_submission_at),
        published_version = nonnull(row.published_version) and tonumber(row.published_version) or nil,
        published_at = nonnull(row.published_at),
        has_unpublished_changes = row.has_unpublished_changes == true,
        share_url = origin and (origin .. "/f/" .. row.public_id) or nil,
        share_path = "/f/" .. row.public_id,
        share_domain = domain,
        targets = setmetatable(decode(row.targets, {}), cjson.array_mt),
        created_by_uuid = nonnull(row.created_by_uuid),
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
    if full then
        local fields = schema.fields or {}
        schema.fields = setmetatable(fields, cjson.array_mt)
        out.schema = schema
        out.settings = decode(row.settings, {})
    end
    return out
end

local function load(namespace_id, uuid)
    if not FormQueries.validUuid(uuid) then return nil end
    return db.query("SELECT " .. SELECT .. " WHERE f.namespace_id = ? AND f.uuid = ? AND f.deleted_at IS NULL",
        namespace_id, uuid)[1]
end
FormQueries.load = load

--- @return the form with its draft, settings and the published version's
-- answer keys (the builder lets a key follow its label until it's published)
function FormQueries.get(namespace_id, uuid)
    local row = load(namespace_id, uuid)
    if not row then return nil end
    local out = FormQueries.present(row, true)
    local keys = {}
    if nonnull(row.published_version_id) then
        local v = db.query("SELECT schema FROM form_versions WHERE id = ?", row.published_version_id)[1]
        for _, f in ipairs(v and decode(v.schema, { fields = {} }).fields or {}) do keys[#keys + 1] = f.key end
    end
    out.published_keys = setmetatable(keys, cjson.array_mt)
    -- Where this workspace's emails go out from (the Settings tab says so).
    local smtp_ok, smtp = pcall(require("helper.namespace-mail").smtp, namespace_id)
    out.email_via = (smtp_ok and smtp) and "workspace"
        or (require("helper.mail").isConfigured() and "platform" or "none")
    out.can_hide_branding = require("lib.forms.limits").of(namespace_id).hide_branding == true
    return out
end

--- Newest-first list, keyset-paged by the last item's uuid (?cursor=).
function FormQueries.list(namespace_id, params)
    params = params or {}
    local where, args = { "f.namespace_id = ?", "f.deleted_at IS NULL" }, { namespace_id }
    if params.status and params.status ~= "" then
        if params.status ~= "draft" and params.status ~= "published" and params.status ~= "closed"
            and params.status ~= "archived" then
            return nil, "status must be draft, published, closed or archived"
        end
        where[#where + 1] = "f.status = ?"
        args[#args + 1] = params.status
    end
    if type(params.q) == "string" and params.q ~= "" then
        where[#where + 1] = "f.title ILIKE ?"
        args[#args + 1] = "%" .. params.q:sub(1, 100):gsub("[%%_\\]", "\\%0") .. "%"
    end
    if FormQueries.validUuid(params.cursor) then
        where[#where + 1] = [[(f.updated_at, f.id) < (SELECT updated_at, id FROM forms
            WHERE uuid = ? AND namespace_id = ?)]]
        args[#args + 1] = params.cursor
        args[#args + 1] = namespace_id
    end
    local limit = math.min(math.max(math.floor(tonumber(params.limit) or PAGE), 1), 100)
    args[#args + 1] = limit + 1
    local rows = db.query("SELECT " .. SELECT .. " WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY f.updated_at DESC, f.id DESC LIMIT ?", unpack(args))
    local items = {}
    for i = 1, math.min(#rows, limit) do items[i] = FormQueries.present(rows[i]) end
    return setmetatable(items, cjson.array_mt), {
        next_cursor = #rows > limit and rows[limit].uuid or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------

local function title_of(v)
    local t, err = Fields.text(v, 200)
    if not t then return nil, "title " .. err end
    if t == "" then return nil, "title is required" end
    return t
end

--- @return form | nil, err, status
function FormQueries.create(namespace_id, actor_uuid, body, auth, origin)
    body = body or {}
    local count = tonumber(db.query("SELECT COUNT(*) AS n FROM forms WHERE namespace_id = ? AND deleted_at IS NULL",
        namespace_id)[1].n)
    local plan_max = require("lib.forms.limits").of(namespace_id).forms
    local max = math.min(FormQueries.MAX_PER_NAMESPACE, plan_max or FormQueries.MAX_PER_NAMESPACE)
    if count >= max then
        return nil, plan_max and plan_max <= count
            and ("your plan includes " .. plan_max .. " forms; delete one or upgrade to add more")
            or ("this workspace has reached " .. max .. " forms; delete some first"), 403
    end

    local template
    if body.template ~= nil and body.template ~= "" then
        template = Templates.get(body.template)
        if not template then return nil, "unknown template '" .. tostring(body.template) .. "'" end
    end
    local title, terr = title_of(body.title or (template and template.title))
    if not title then return nil, terr end
    local description = body.description ~= nil and Fields.text(body.description, 2000, true)
        or (template and template.description) or nil

    local raw_targets = body.targets
    if raw_targets == nil and template then
        -- A template's targets are suggestions: keep the ones this deployment
        -- has and the creator may use.
        raw_targets = {}
        for _, t in ipairs(template.targets) do
            local spec = Targets.get(t)
            if spec and Targets.clean({ t }, auth, namespace_id) then raw_targets[#raw_targets + 1] = t end
        end
    end
    local targets, roles = Targets.clean(raw_targets, auth, namespace_id)
    if not targets then return nil, roles end
    local raw_schema = body.schema or (body.fields and { fields = body.fields })
        or (template and { fields = template.fields }) or { fields = {} }
    local schema, serr = Fields.normalize(raw_schema, roles)
    if not schema then return nil, serr end
    local settings, err = FormQueries.cleanSettings(body.settings, {}, namespace_id)
    if not settings then return nil, err end

    for _ = 1, 3 do -- a public_id collision (62^12 space) is astronomically rare; retry anyway
        local ok, res = pcall(db.query, [[
            INSERT INTO forms (uuid, namespace_id, public_id, title, description, draft_schema, targets, settings,
                public_origin, created_by_uuid, updated_by_uuid)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING uuid
        ]], Global.generateUUID(), namespace_id, require("helper.uuid").random_string(12, ALNUM), title,
            description or db.NULL, jsonb(schema), jsonb(targets), jsonb(settings), origin or db.NULL,
            actor_uuid or db.NULL, actor_uuid or db.NULL)
        if ok then return FormQueries.get(namespace_id, res[1].uuid) end
        if not tostring(res):find("forms_public_id_key", 1, true) then error(res, 0) end
    end
    return nil, "could not create the form, please try again"
end

--- Partial update of the draft (title, description, schema/fields, targets,
-- settings). `expected_updated_at` (optional): refuse with 409 when the form
-- changed since the caller read it.
-- @return form | nil, err, status
function FormQueries.update(namespace_id, uuid, actor_uuid, body, auth, origin)
    local row = load(namespace_id, uuid)
    if not row then return nil, "Form not found", 404 end
    body = body or {}
    local set = { "updated_at = NOW()", "updated_by_uuid = ?" }
    local args = { actor_uuid or db.NULL }

    if body.title ~= nil then
        local title, err = title_of(body.title)
        if not title then return nil, err end
        set[#set + 1] = "title = ?"
        args[#args + 1] = title
    end
    if body.description ~= nil then
        local d = body.description ~= cjson.null and Fields.text(body.description, 2000, true) or ""
        if not d then return nil, "description must be plain text (max 2000)" end
        set[#set + 1] = "description = ?"
        args[#args + 1] = d ~= "" and d or db.NULL
    end

    local targets, roles = decode(row.targets, {}), nil
    if body.targets ~= nil then
        local terr
        targets, terr = Targets.clean(body.targets, auth, namespace_id)
        if not targets then return nil, terr end
        roles = terr
        set[#set + 1] = "targets = ?"
        args[#args + 1] = jsonb(targets)
    end
    local raw_schema = body.schema or (body.fields and { fields = body.fields })
    if raw_schema or body.targets ~= nil then
        local schema, err = Fields.normalize(raw_schema or decode(row.draft_schema, { fields = {} }),
            roles or Targets.roles(targets))
        if not schema then return nil, err end
        set[#set + 1] = "draft_schema = ?"
        args[#args + 1] = jsonb(schema)
    end
    if body.settings ~= nil then
        local settings, err = FormQueries.cleanSettings(body.settings, decode(row.settings, {}), namespace_id)
        if not settings then return nil, err end
        set[#set + 1] = "settings = ?"
        args[#args + 1] = jsonb(settings)
    end
    if origin and nonnull(row.public_origin) == nil then
        set[#set + 1] = "public_origin = ?"
        args[#args + 1] = origin
    end

    local where = "id = ?"
    args[#args + 1] = row.id
    if body.expected_updated_at ~= nil and body.expected_updated_at ~= cjson.null then
        where = where .. " AND updated_at = ?::timestamptz"
        args[#args + 1] = tostring(body.expected_updated_at)
    end
    local ok, res = pcall(db.query, "UPDATE forms SET " .. table.concat(set, ", ") .. " WHERE " .. where
        .. " RETURNING id", unpack(args))
    if not ok then
        if tostring(res):find("invalid input syntax for type timestamp", 1, true) then
            return nil, "expected_updated_at is not a timestamp"
        end
        error(res, 0)
    end
    if not res[1] then
        return nil, "This form was changed by someone else. Reload it to see the latest version.", 409
    end
    -- Settings apply to the live form at once (they aren't versioned).
    if body.settings ~= nil then require("lib.forms.public-cache").bust(row.public_id) end
    return FormQueries.get(namespace_id, uuid)
end

--- Publish the draft: a new immutable version becomes the live form.
-- Re-checks the targets against the PUBLISHER's permissions.
function FormQueries.publish(namespace_id, uuid, actor_uuid, auth)
    local row = load(namespace_id, uuid)
    if not row then return nil, "Form not found", 404 end
    local targets, roles = Targets.clean(decode(row.targets, {}), auth, namespace_id)
    if not targets then return nil, roles, 403 end
    local schema, serr = Fields.normalize(decode(row.draft_schema, { fields = {} }), roles)
    if not schema then return nil, serr end
    if input_count(schema) == 0 then return nil, "add at least one question before publishing" end

    db.query("BEGIN")
    local ok, err = pcall(function()
        -- Serialises concurrent publishes of this form.
        db.query("SELECT id FROM forms WHERE id = ? FOR UPDATE", row.id)
        local v = db.query([[
            INSERT INTO form_versions (form_id, namespace_id, version, schema, targets, published_by_uuid)
            SELECT ?, ?, COALESCE(MAX(version), 0) + 1, ?, ?, ? FROM form_versions WHERE form_id = ?
            RETURNING id
        ]], row.id, namespace_id, jsonb(schema), jsonb(targets), actor_uuid, row.id)[1]
        db.query([[
            UPDATE forms SET published_version_id = ?, status = 'published', draft_schema = ?, targets = ?,
                published_at = NOW(), published_by_uuid = ?, updated_at = NOW(), updated_by_uuid = ?
            WHERE id = ?
        ]], v.id, jsonb(schema), jsonb(targets), actor_uuid, actor_uuid, row.id)
    end)
    if not ok then
        pcall(db.query, "ROLLBACK")
        error(err, 0)
    end
    db.query("COMMIT")
    require("lib.forms.public-cache").bust(row.public_id)
    return FormQueries.get(namespace_id, uuid)
end

--- Close (stop accepting responses) or reopen a published form.
function FormQueries.setOpen(namespace_id, uuid, actor_uuid, open)
    local row = load(namespace_id, uuid)
    if not row then return nil, "Form not found", 404 end
    if open and nonnull(row.published_version_id) == nil then return nil, "publish the form first" end
    db.query("UPDATE forms SET status = ?, updated_at = NOW(), updated_by_uuid = ? WHERE id = ?",
        open and "published" or "closed", actor_uuid or db.NULL, row.id)
    require("lib.forms.public-cache").bust(row.public_id)
    return FormQueries.get(namespace_id, uuid)
end

function FormQueries.duplicate(namespace_id, uuid, actor_uuid, auth, origin)
    local row = load(namespace_id, uuid)
    if not row then return nil, "Form not found", 404 end
    return FormQueries.create(namespace_id, actor_uuid, {
        title = ("Copy of " .. row.title):sub(1, 200),
        description = nonnull(row.description),
        schema = decode(row.draft_schema, { fields = {} }),
        targets = decode(row.targets, {}),
        settings = decode(row.settings, {}),
    }, auth, origin)
end

--- Soft delete: the public link stops working at once; responses stay until
-- the daily purge removes deleted forms after FormJobs.DELETED_FORM_DAYS.
function FormQueries.delete(namespace_id, uuid, actor_uuid)
    local row = load(namespace_id, uuid)
    if not row then return nil, "Form not found", 404 end
    db.query("UPDATE forms SET deleted_at = NOW(), updated_at = NOW(), updated_by_uuid = ? WHERE id = ?",
        actor_uuid or db.NULL, row.id)
    require("lib.forms.public-cache").bust(row.public_id)
    return true
end

-- ---------------------------------------------------------------------------
-- Public view
-- ---------------------------------------------------------------------------

--- The form behind a public link, with its namespace and published version.
function FormQueries.publicForm(public_id)
    if type(public_id) ~= "string" or not public_id:match("^[%w]+$") or #public_id > 16 then return nil end
    return db.query([[
        SELECT f.id, f.uuid, f.namespace_id, f.public_id, f.title, f.description, f.status, f.settings,
               f.published_version_id, f.deleted_at, f.submission_count,
               n.name AS namespace_name, n.status AS namespace_status, n.max_users, n.logo_url AS namespace_logo,
               v.id AS v_id, v.version AS v_version, v.schema AS v_schema, v.targets AS v_targets,
               v.published_by_uuid AS v_published_by_uuid
        FROM forms f
        JOIN namespaces n ON n.id = f.namespace_id
        LEFT JOIN form_versions v ON v.id = f.published_version_id
        WHERE f.public_id = ?
    ]], public_id)[1]
end

-- What a visitor's browser gets: the published fields without internals.
local PUBLIC_FIELD_KEYS = { "key", "type", "label", "help", "placeholder", "required", "options", "validation",
    "scale", "text", "param", "width", "logic", "max_files", "max_size_mb", "accept" }

function FormQueries.publicSchema(schema)
    local fields = {}
    for _, f in ipairs(schema.fields or {}) do
        local out = {}
        for _, k in ipairs(PUBLIC_FIELD_KEYS) do out[k] = f[k] end
        if out.options then out.options = setmetatable(out.options, cjson.array_mt) end
        fields[#fields + 1] = out
    end
    return setmetatable(fields, cjson.array_mt)
end

return FormQueries
