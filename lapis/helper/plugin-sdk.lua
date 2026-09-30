--[[
    OpsAPI plugin SDK
    =================

    The stable API for plugin code (projects/<plugin>/api/*.lua). Plugins
    should need nothing but this module; internals may change between OpsAPI
    releases, this module only changes with ProjectLoader.SDK_VERSION.
    Full guide: PLUGINS.md.

        local sdk = require("helper.plugin-sdk")

        return function(app)
            -- Tenant-scoped, RBAC-guarded list/show/create/update/delete
            sdk.crud(app, "/tickets", {
                table = "helpdesk_tickets",
                module = "helpdesk_tickets",
                fields = { title = { type = "string", required = true } },
            })

            -- Custom route: namespace + permission checked before the handler
            app:get("/stats", sdk.handler({ permission = "helpdesk_tickets.read" }, function(self)
                return sdk.ok(sdk.db.query(
                    "SELECT status, COUNT(*) FROM helpdesk_tickets WHERE namespace_id = ? GROUP BY status",
                    sdk.namespace_id(self)))
            end))
        end

    Security model: the global before_filter has already verified the JWT (or
    API key) for every route outside /public/. sdk.handler adds the tenant:
    the caller must be an active member of an active namespace, and with
    `permission` must hold that RBAC permission. sdk.resource/sdk.crud put
    `namespace_id = <caller's namespace>` into every query, so one tenant can
    never read or change another's rows.
]]

local sdk = {}

-- Lazily loaded so the pure helpers (validate) work without a database.
setmetatable(sdk, {
    __index = function(t, k)
        if k == "db" then
            local db = require("lapis.db")
            rawset(t, "db", db)
            return db
        end
    end,
})

sdk.VERSION = require("helper.project-loader").SDK_VERSION

--- Mark a Lua list so an empty one encodes as [] (cjson's default is {}).
function sdk.array(t)
    return setmetatable(t or {}, require("cjson").array_mt)
end
local array = sdk.array

-- ---------------------------------------------------------------------------
-- Responses — the house envelope { success, data, meta } / { success, error }
-- ---------------------------------------------------------------------------

function sdk.ok(data, meta)
    return { status = 200, json = { success = true, data = data, meta = meta } }
end

function sdk.created(data)
    return { status = 201, json = { success = true, data = data } }
end

function sdk.error(status, message, details)
    return { status = status, json = { success = false, error = message, details = details } }
end

function sdk.not_found(what)
    return sdk.error(404, (what or "Record") .. " not found")
end

-- ---------------------------------------------------------------------------
-- Request context
-- ---------------------------------------------------------------------------

--- Guard a handler. opts:
--   permission = "module.action"  namespace member holding that permission
--                                 (platform admins pass; owners via their role)
--   namespace = false             no tenant context — any authenticated user
--   (default)                     any active member of the request's namespace
-- The namespace comes from X-Namespace-Id / X-Namespace-Slug, else the JWT.
function sdk.handler(opts, fn)
    if type(opts) == "function" then
        opts, fn = {}, opts
    end
    local NamespaceMiddleware = require("middleware.namespace")
    if opts.namespace == false then
        return fn
    end
    if opts.permission then
        local module, action = opts.permission:match("^([%w_]+)%.(%a+)$")
        assert(module, "sdk.handler: permission must look like 'module.action'")
        return NamespaceMiddleware.requirePermission(module, action, fn)
    end
    return NamespaceMiddleware.requireNamespace(fn)
end

function sdk.namespace_id(self)
    return self.namespace and self.namespace.id
end

function sdk.user(self)
    return self.current_user
end

--- Does the caller hold module.action in the current namespace?
function sdk.can(self, module, action)
    return require("middleware.namespace").hasPermission(self, module, action)
end

--- Decoded JSON request body (cached on self). nil + message when it isn't a
-- JSON object; {} when there is no body.
function sdk.body(self)
    if self._sdk_body then
        return self._sdk_body
    end
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local file = ngx.req.get_body_file() -- large bodies are buffered to disk
        if file then
            local f = io.open(file, "rb")
            if f then
                raw = f:read("*a")
                f:close()
            end
        end
    end
    local data = {}
    if raw and raw ~= "" then
        data = require("cjson.safe").decode(raw)
        if type(data) ~= "table" or data[1] ~= nil then -- a JSON array decodes to a table too
            return nil, "Request body must be a JSON object"
        end
    end
    self._sdk_body = data
    return data
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local captured_env = {}

--- Snapshot PLUGIN_* environment variables. nginx strips every variable not
-- declared with an `env` line from its workers, and plugins can't add those
-- lines — so nginx.conf's init_by_lua (the master, before workers fork)
-- calls this.
function sdk.capture_env()
    local f = io.open("/proc/self/environ", "rb")
    if not f then return end
    for entry in f:read("*a"):gmatch("[^%z]+") do
        local name, value = entry:match("^(PLUGIN_[%w_]+)=(.*)$")
        if name then captured_env[name] = value end
    end
    f:close()
end

--- A deployment setting for a plugin: set PLUGIN_<CODE>_<NAME> (e.g.
-- PLUGIN_HELPDESK_SLACK_URL) on the OpsAPI container. Tenant-specific
-- settings belong in the database, not here.
function sdk.env(name, default)
    local value = captured_env[name] or os.getenv(name)
    if value == nil or value == "" then return default end
    return value
end

--- page, per_page and SQL offset from ?page=&per_page= (clamped, 1..100).
function sdk.page(params)
    local Global = require("helper.global")
    local page = Global.pageParam(params and params.page)
    local per_page = Global.perPageParam(params and (params.per_page or params.perPage), 20, 100)
    return page, per_page, (page - 1) * per_page
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

local PATTERNS = {
    date = "^%d%d%d%d%-%d%d%-%d%d$",
    datetime = "^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d",
    email = "^[^%s@]+@[^%s@]+%.[^%s@]+$",
    uuid = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$",
}
local INT_MAX = 2147483647 -- Postgres INTEGER

-- Coerce one value to a rule's type. Returns value, or nil + message.
local function coerce(v, rule)
    local t = rule.type or "string"
    if t == "string" or t == "text" or PATTERNS[t] then
        if type(v) ~= "string" then return nil, "must be a string" end
        v = v:match("^%s*(.-)%s*$")
        local max = rule.max or (t ~= "text" and 255 or nil)
        if max and #v > max then return nil, "must be at most " .. max .. " characters" end
        if rule.min and #v < rule.min then return nil, "must be at least " .. rule.min .. " characters" end
        if PATTERNS[t] and not v:match(PATTERNS[t]) then return nil, "must be a valid " .. t end
    elseif t == "integer" or t == "number" then
        local n = tonumber(v)
        if not n or n ~= n or n == math.huge or n == -math.huge then return nil, "must be a number" end
        if t == "integer" and (n % 1 ~= 0 or n > INT_MAX or n < -INT_MAX) then
            return nil, "must be a whole number"
        end
        if rule.min and n < rule.min then return nil, "must be at least " .. rule.min end
        if rule.max and n > rule.max then return nil, "must be at most " .. rule.max end
        v = n
    elseif t == "boolean" then
        if v == "true" then v = true elseif v == "false" then v = false end
        if type(v) ~= "boolean" then return nil, "must be true or false" end
    elseif t == "json" then
        if type(v) ~= "table" then return nil, "must be an object or array" end
        v = require("cjson").encode(v)
    else
        error("sdk.validate: unknown field type '" .. tostring(t) .. "'")
    end

    if rule.enum then
        for _, allowed in ipairs(rule.enum) do
            if allowed == v then return v end
        end
        return nil, "must be one of: " .. table.concat(rule.enum, ", ")
    end
    return v
end

--- Validate input against field rules and return ONLY the declared fields
-- (unknown keys are dropped — no mass assignment).
--
--   rules = { title = { type = "string", required = true, max = 120 },
--             status = { enum = { "open", "closed" } },
--             amount = { type = "number", min = 0 } }
--
-- Types: string (default, max 255) text integer number boolean date datetime
-- email uuid json. `partial` (updates) only checks the fields present.
-- JSON null clears an optional field. Returns clean, or nil + { field = msg }.
function sdk.validate(input, rules, partial)
    input = input or {}
    local null = require("cjson").null
    local clean, errors = {}, {}

    for field, rule in pairs(rules) do
        local v = input[field]
        local t = rule.type or "string"
        if v == "" and t ~= "string" and t ~= "text" then
            v = null -- empty form value for a date/number/... means "no value"
        end

        if v == nil or v == null then
            if rule.required and (not partial or v == null) then
                errors[field] = "is required"
            elseif v == null then
                clean[field] = sdk.db.NULL
            end
        else
            local value, msg = coerce(v, rule)
            if msg then
                errors[field] = msg
            elseif rule.required and value == "" then
                errors[field] = "is required"
            else
                clean[field] = value
            end
        end
    end

    if next(errors) then
        return nil, errors
    end
    return clean
end

-- ---------------------------------------------------------------------------
-- Tenant-scoped data access
-- ---------------------------------------------------------------------------

-- Run a write; turn constraint violations into (nil, status, message) instead
-- of a 500.
local function guarded(fk_status, fn)
    local ok, res = pcall(fn)
    if ok then return res end
    -- lapis errors are "<sql>\nERROR: ..."; only look at Postgres' part, the
    -- SQL carries user data.
    local msg = tostring(res):match(".*\n(ERROR:.*)$") or tostring(res)
    if msg:find("duplicate key value", 1, true) then
        return nil, 409, "A record with these values already exists"
    end
    if msg:find("foreign key constraint", 1, true) then
        return nil, fk_status, fk_status == 409 and "Record is still referenced by other records"
            or "A referenced record does not exist"
    end
    error(res, 0)
end

local function set(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

--- Repository for a table with a namespace_id column. Every method takes the
-- caller's namespace id first and filters by it.
--
-- opts: fields (validate rules), searchable/filterable/sortable (column
-- lists), key (public id column, default "uuid" — needs a DB default such as
-- gen_random_uuid()), timestamps (default true: bump updated_at on update).
--
--   list(ns, params)    rows, meta         | nil, status, message
--   find(ns, id)        row | nil
--   create(ns, data)    row                | nil, status, message
--   update(ns, id, data) row | nil         | nil, status, message
--   delete(ns, id)      true | false       | nil, status, message
function sdk.resource(tbl, opts)
    opts = opts or {}
    local db = sdk.db
    local key = opts.key or "uuid"
    local T, K = db.escape_identifier(tbl), db.escape_identifier(key)
    local fields = opts.fields or {}
    local sortable = set(opts.sortable)
    local R = {}

    local function scope(ns, id)
        return "namespace_id = " .. db.escape_literal(ns) .. " AND " .. K .. " = " .. db.escape_literal(id)
    end
    -- A malformed id must be a 404, not a Postgres cast error (500).
    local function valid_id(id)
        return id ~= nil and (key ~= "uuid" or tostring(id):match(PATTERNS.uuid) ~= nil)
    end

    function R.list(ns, params)
        params = params or {}
        local where = { "namespace_id = " .. db.escape_literal(ns) }

        for _, col in ipairs(opts.filterable or {}) do
            local v = params[col]
            if v ~= nil and v ~= "" then
                local value, msg = coerce(v, fields[col] or {})
                if msg then return nil, 400, col .. " " .. msg end
                where[#where + 1] = db.escape_identifier(col) .. " = " .. db.escape_literal(value)
            end
        end

        local q = params.q or params.search
        if type(q) == "string" and q ~= "" and opts.searchable and #opts.searchable > 0 then
            local like = db.escape_literal("%" .. (q:gsub("[%%_\\]", "\\%0")) .. "%")
            local any = {}
            for _, col in ipairs(opts.searchable) do
                any[#any + 1] = db.escape_identifier(col) .. " ILIKE " .. like
            end
            where[#where + 1] = "(" .. table.concat(any, " OR ") .. ")"
        end

        local order_by = "id DESC"
        if sortable[params.sort] then
            order_by = db.escape_identifier(params.sort)
                .. (tostring(params.order):lower() == "asc" and " ASC" or " DESC")
        end

        -- No "?" placeholders here: lapis would also substitute any "?"
        -- inside the escaped literals above.
        local page, per_page, offset = sdk.page(params)
        local w = table.concat(where, " AND ")
        local rows = db.query("SELECT * FROM " .. T .. " WHERE " .. w .. " ORDER BY " .. order_by
            .. " LIMIT " .. per_page .. " OFFSET " .. offset)
        local total = db.query("SELECT COUNT(*)::int AS n FROM " .. T .. " WHERE " .. w)[1].n
        return array(rows), {
            page = page, per_page = per_page, total = total,
            total_pages = math.ceil(total / per_page),
        }
    end

    function R.find(ns, id)
        if not valid_id(id) then return nil end
        return db.query("SELECT * FROM " .. T .. " WHERE " .. scope(ns, id) .. " LIMIT 1")[1]
    end

    function R.create(ns, data)
        local values = {}
        for k, v in pairs(data) do values[k] = v end
        values.namespace_id = ns
        return guarded(422, function()
            return db.insert(tbl, values, { returning = "*" })[1]
        end)
    end

    function R.update(ns, id, data)
        if not valid_id(id) then return nil end
        local values = {}
        for k, v in pairs(data) do values[k] = v end
        values.namespace_id, values[key] = nil, nil -- tenant and id are immutable
        if next(values) == nil then return R.find(ns, id) end
        if opts.timestamps ~= false then values.updated_at = db.raw("NOW()") end
        return guarded(422, function()
            return db.query("UPDATE " .. T .. " SET " .. db.encode_assigns(values)
                .. " WHERE " .. scope(ns, id) .. " RETURNING *")[1]
        end)
    end

    function R.delete(ns, id)
        if not valid_id(id) then return false end
        return guarded(409, function()
            return db.query("DELETE FROM " .. T .. " WHERE " .. scope(ns, id)).affected_rows > 0
        end)
    end

    return R
end

local function humanize(name)
    local words = name:gsub("_", " ")
    return (words:gsub("^%l", string.upper))
end

-- The dashboard page for a crud resource (served by GET
-- /api/v2/plugins/:code/resources/:key): fields in form order, table columns,
-- filters and which actions exist. Built once at boot.
local function page_schema(path, opts, only)
    local fields, ui = opts.fields or {}, opts.ui or {}
    local order, seen = {}, {}
    for _, name in ipairs(ui.form or {}) do
        if fields[name] and not seen[name] then
            order[#order + 1], seen[name] = name, true
        end
    end
    local rest = {}
    for name in pairs(fields) do
        if not seen[name] then rest[#rest + 1] = name end
    end
    table.sort(rest, function(a, b) -- required first, then by name
        local ra, rb = fields[a].required and 1 or 0, fields[b].required and 1 or 0
        if ra ~= rb then return ra > rb end
        return a < b
    end)
    for _, name in ipairs(rest) do order[#order + 1] = name end

    local list, filters, columns = {}, {}, {}
    local filterable = set(opts.filterable)
    for _, name in ipairs(order) do
        local rule = fields[name]
        local field = {
            name = name, label = rule.label or humanize(name), type = rule.type or "string",
            required = rule.required == true, enum = rule.enum, min = rule.min, max = rule.max,
        }
        list[#list + 1] = field
        -- Only closed-set fields get a filter dropdown in the UI.
        if filterable[name] and (field.enum or field.type == "boolean") then
            filters[#filters + 1] = field
        end
    end
    for _, name in ipairs(ui.columns or {}) do
        if fields[name] then columns[#columns + 1] = name end
    end
    if #columns == 0 then
        for _, f in ipairs(list) do
            if #columns < 5 and f.type ~= "text" and f.type ~= "json" then columns[#columns + 1] = f.name end
        end
    end

    local key = path:gsub("^/", ""):gsub("[^%w_%-]", "-")
    return key, {
        key = key,
        label = ui.label or humanize(key:gsub("%-", "_")),
        module = opts.module,
        fields = array(list),
        columns = array(columns),
        filters = array(filters),
        searchable = opts.searchable ~= nil and #opts.searchable > 0,
        sortable = array(opts.sortable or {}),
        actions = {
            create = not only or only.create == true,
            update = not only or only.update == true,
            delete = not only or only.delete == true,
        },
    }
end

--- Register REST routes for a tenant-scoped table and return its resource:
--
--   GET    path        list  ?page=&per_page=&q=&sort=&order=&<filterable>=
--   GET    path/:id    show
--   POST   path        create           (201, 422 on validation errors)
--   PUT    path/:id    partial update
--   DELETE path/:id    delete
--
-- opts: table, module (RBAC module; routes need module.read/create/update/
-- delete), fields, searchable, filterable, sortable, key, timestamps, and
-- only = { "list", "show", "create", "update", "delete" } to register a subset.
--
-- Each crud resource also gets a dashboard page (list + create/edit form) at
-- /dashboard/plugins/<plugin>/<path> once the manifest's `menu` links to it.
-- opts.ui = { label = "Tickets", columns = { ... }, form = { ... } } sets the
-- title, table columns and form field order; a field's `label` its caption.
function sdk.crud(app, path, opts)
    assert(opts and opts.table, "sdk.crud: opts.table is required")
    assert(opts.module, "sdk.crud: opts.module (the RBAC module guarding these routes) is required")

    local R = sdk.resource(opts.table, opts)
    local fields = opts.fields or {}
    local only = opts.only and set(opts.only)
    if app.plugin then
        local key, page = page_schema(path, opts, only)
        page.api_path = app.plugin.api_prefix .. path
        app.plugin.resources[key] = page
    end
    local function on(action) return not only or only[action] end
    local function guard(action, fn)
        return sdk.handler({ permission = opts.module .. "." .. action }, fn)
    end
    local function input(self, partial)
        local body, err = sdk.body(self)
        if not body then return nil, sdk.error(400, err) end
        local data, errors = sdk.validate(body, fields, partial)
        if not data then return nil, sdk.error(422, "Validation failed", errors) end
        return data
    end

    if on("list") then
        app:get(path, guard("read", function(self)
            local rows, meta, msg = R.list(self.namespace.id, self.params)
            if not rows then return sdk.error(meta, msg) end
            return sdk.ok(rows, meta)
        end))
    end

    if on("show") then
        app:get(path .. "/:id", guard("read", function(self)
            local row = R.find(self.namespace.id, self.params.id)
            if not row then return sdk.not_found() end
            return sdk.ok(row)
        end))
    end

    if on("create") then
        app:post(path, guard("create", function(self)
            local data, bad = input(self)
            if not data then return bad end
            local row, status, msg = R.create(self.namespace.id, data)
            if not row then return sdk.error(status, msg) end
            return sdk.created(row)
        end))
    end

    if on("update") then
        app:put(path .. "/:id", guard("update", function(self)
            local data, bad = input(self, true)
            if not data then return bad end
            local row, status, msg = R.update(self.namespace.id, self.params.id, data)
            if status then return sdk.error(status, msg) end
            if not row then return sdk.not_found() end
            return sdk.ok(row)
        end))
    end

    if on("delete") then
        app:delete(path .. "/:id", guard("delete", function(self)
            local deleted, status, msg = R.delete(self.namespace.id, self.params.id)
            if status then return sdk.error(status, msg) end
            if not deleted then return sdk.not_found() end
            return sdk.ok()
        end))
    end

    return R
end

return sdk
