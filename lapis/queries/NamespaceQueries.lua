--[[
    NamespaceQueries.lua

    CRUD operations for namespaces (tenants/organizations).
    Each namespace represents an isolated environment for a company.
]]

local Global = require("helper.global")
local db = require("lapis.db")
local Model = require("lapis.db.model").Model

local Namespaces = Model:extend("namespaces")
local NamespaceQueries = {}

--- Derive a sensible default ``allowed_redirect_origins`` for a freshly
-- created namespace from environment variables, mirroring the bootstrap
-- logic in migration 489.
--
-- Why this exists
--   Without this, ``NamespaceQueries.create`` leaves the column NULL,
--   so the runtime fallback in /auth/forgot-password kicks in for every
--   new tenant and every tenant ends up sharing the global env-var
--   FRONTEND_URL. Populating the column at create-time gives admins
--   a visible default they can later override via SQL or the (planned)
--   admin UI, and lets us eventually drop the runtime env-var fallback
--   entirely once every namespace has its column populated.
--
-- Multi-tenant caveat (intentional, not a bug)
--   The default is whatever ``FRONTEND_URL`` /
--   ``PASSWORD_RESET_ALLOWED_ORIGINS`` happen to be set to on the
--   opsapi instance — typically the URL of the FIRST tenant. For
--   subsequent tenants on a multi-tenant instance, callers MUST pass
--   their own ``allowed_redirect_origins`` in the ``data`` table to
--   override this default. See the route handlers in
--   ``routes/namespaces.lua`` for the recommended pattern: derive
--   from the request's X-Forwarded-Host or accept an explicit
--   parameter from the admin UI.
--
-- @return table  array of canonicalised origin strings (possibly empty)
local function derive_default_allowed_origins()
    local frontend_url = os.getenv("FRONTEND_URL")
    local extra_csv = os.getenv("PASSWORD_RESET_ALLOWED_ORIGINS")

    local origins = {}
    local seen = {}
    local function add(o)
        if not o or o == "" then return end
        local trimmed = o:match("^%s*(.-)%s*$")
        -- Canonicalise: strip path/query/fragment, keep scheme + host[:port].
        -- Same canonicalisation applied at runtime in routes/auth.lua so
        -- comparisons are apples-to-apples.
        local canon = trimmed:match("^(https?://[^/]+)") or trimmed
        if canon == "" or seen[canon] then return end
        seen[canon] = true
        table.insert(origins, canon)
    end
    add(frontend_url)
    if extra_csv and extra_csv ~= "" then
        for o in extra_csv:gmatch("[^,]+") do add(o) end
    end
    return origins
end


--- Generate a unique slug from name
-- @param name string The namespace name
-- @return string The generated slug
local function generateSlug(name)
    local slug = name:lower()
        :gsub("%s+", "-")        -- Replace spaces with hyphens
        :gsub("[^a-z0-9%-]", "") -- Remove non-alphanumeric except hyphens
        :gsub("%-+", "-")        -- Replace multiple hyphens with single
        :gsub("^%-", "")         -- Remove leading hyphen
        :gsub("%-$", "")         -- Remove trailing hyphen

    -- Check if slug exists, append number if needed
    local base_slug = slug
    local counter = 1
    while true do
        local existing = db.select("id FROM namespaces WHERE slug = ?", slug)
        if #existing == 0 then
            break
        end
        counter = counter + 1
        slug = base_slug .. "-" .. counter
    end

    return slug
end

--- Create a new namespace
-- @param data table {
--   name, slug?, description?, domain?, logo_url?, plan?, settings?,
--   max_users?, max_stores?, owner_user_id?,
--   allowed_redirect_origins? — array of canonical origin strings
--     (``scheme://host[:port]``) that this namespace's password-reset
--     emails are allowed to link to. If omitted, defaults to the value
--     derived from FRONTEND_URL + PASSWORD_RESET_ALLOWED_ORIGINS env
--     vars (same shape as migration 489's bootstrap). For multi-tenant
--     deployments the caller SHOULD pass this explicitly so each
--     tenant gets its own URL — see the helper docstring above for
--     the rationale.
-- }
-- @return table The created namespace
function NamespaceQueries.create(data)
    local timestamp = Global.getCurrentTimestamp()

    -- Generate slug if not provided
    local slug = data.slug
    if not slug or slug == "" then
        slug = generateSlug(data.name)
    end

    -- Resolve the allow-list. Caller-supplied wins; an explicit empty
    -- table is respected (treated as "deliberately empty"); only
    -- ``nil`` (key absent) triggers the env-var fallback. Distinguishes
    -- "I want no origins" from "I forgot to pass any" — important when
    -- an admin UI explicitly clears the list to lock the namespace
    -- out of password-reset emails.
    local allowed_origins = data.allowed_redirect_origins
    if allowed_origins == nil then
        allowed_origins = derive_default_allowed_origins()
    end

    local namespace_data = {
        uuid = data.uuid or Global.generateUUID(),
        name = data.name,
        slug = slug,
        description = data.description,
        domain = data.domain,
        logo_url = data.logo_url,
        banner_url = data.banner_url,
        status = data.status or "active",
        plan = data.plan or "free",
        settings = data.settings or "{}",
        max_users = data.max_users or 10,
        max_stores = data.max_stores or 5,
        owner_user_id = data.owner_user_id,
        created_at = timestamp,
        updated_at = timestamp
    }

    -- Only set the array column when we actually have origins. An
    -- empty Lua table sent to Postgres TEXT[] becomes ``{}`` (empty
    -- array), which the runtime treats the same as NULL — but the
    -- DB column allows NULL too, so this is just clarity for any
    -- admin querying the table later.
    if #allowed_origins > 0 then
        namespace_data.allowed_redirect_origins = db.array(allowed_origins)
    end

    return Namespaces:create(namespace_data, { returning = "*" })
end

--- Get all namespaces with pagination
-- @param params table { page?, perPage?, orderBy?, orderDir?, status?, search? }
-- @return table { data, total }
function NamespaceQueries.all(params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.perPage) or tonumber(params.per_page) or 10
    local order_by = params.orderBy or params.order_by or "created_at"
    local order_dir = params.orderDir or params.order_dir or "desc"

    -- Validate order_by to prevent SQL injection
    local valid_fields = {
        id = true,
        name = true,
        slug = true,
        status = true,
        plan = true,
        created_at = true,
        updated_at = true
    }
    if not valid_fields[order_by] then
        order_by = "created_at"
    end
    order_dir = order_dir:lower() == "asc" and "ASC" or "DESC"

    -- Build WHERE clause
    local conditions = {}
    local values = {}

    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "status = ?")
        table.insert(values, params.status)
    end

    if params.search and params.search ~= "" then
        table.insert(conditions, "(name ILIKE ? OR slug ILIKE ? OR description ILIKE ?)")
        local search_term = "%" .. params.search .. "%"
        table.insert(values, search_term)
        table.insert(values, search_term)
        table.insert(values, search_term)
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "WHERE " .. table.concat(conditions, " AND ")
    end

    -- Get total count
    local count_query = "SELECT COUNT(*) as total FROM namespaces " .. where_clause
    local count_result = db.query(count_query, table.unpack(values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data
    local offset = (page - 1) * per_page
    local data_query = string.format([[
        SELECT
            id, uuid, name, slug, description, domain, logo_url, banner_url,
            status, plan, settings, max_users, max_stores, owner_user_id,
            project_code, created_at, updated_at,
            (SELECT COUNT(*) FROM namespace_members WHERE namespace_id = namespaces.id AND status = 'active') as member_count
        FROM namespaces
        %s
        ORDER BY %s %s
        LIMIT %d OFFSET %d
    ]], where_clause, order_by, order_dir, per_page, offset)

    local data = db.query(data_query, table.unpack(values))

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Find namespace by ID or UUID
-- @param id string|number ID or UUID
-- @return table|nil The namespace or nil
function NamespaceQueries.show(id)
    local namespace = Namespaces:find({ uuid = tostring(id) })
    if not namespace and tonumber(id) then
        namespace = Namespaces:find({ id = tonumber(id) })
    end
    return namespace
end

--- Find namespace by slug
-- @param slug string The namespace slug
-- @return table|nil The namespace or nil
function NamespaceQueries.findBySlug(slug)
    return Namespaces:find({ slug = slug })
end

--- Find namespace by domain
-- @param domain string The custom domain
-- @return table|nil The namespace or nil
function NamespaceQueries.findByDomain(domain)
    return Namespaces:find({ domain = domain })
end

--- Find namespace by ID, UUID, or slug
-- @param identifier string ID, UUID, or slug
-- @return table|nil The namespace or nil
function NamespaceQueries.findByIdentifier(identifier)
    -- Try UUID first
    local namespace = Namespaces:find({ uuid = tostring(identifier) })
    if namespace then return namespace end

    -- Try slug
    namespace = Namespaces:find({ slug = tostring(identifier) })
    if namespace then return namespace end

    -- Try numeric ID
    if tonumber(identifier) then
        namespace = Namespaces:find({ id = tonumber(identifier) })
    end

    return namespace
end

--- Update namespace
-- @param id string|number ID or UUID
-- @param params table Fields to update
-- @return table|nil The updated namespace or nil
function NamespaceQueries.update(id, params)
    local namespace = NamespaceQueries.show(id)
    if not namespace then
        return nil
    end

    -- Set updated_at timestamp
    params.updated_at = Global.getCurrentTimestamp()

    -- Don't allow updating certain fields
    params.id = nil
    params.uuid = nil

    namespace:update(params)
    return namespace
end

--- Delete namespace
-- @param id string|number ID or UUID
-- @return boolean Success status
function NamespaceQueries.destroy(id)
    local namespace = NamespaceQueries.show(id)
    if not namespace then
        return nil
    end
    return namespace:delete()
end

--- Get namespaces for a user
-- @param user_id string|number User ID or UUID
-- @return table List of namespaces
function NamespaceQueries.getForUser(user_id)
    local query = [[
        SELECT
            n.id, n.uuid, n.name, n.slug, n.description, n.logo_url,
            n.status, n.plan, n.settings,
            nm.is_owner, nm.status as member_status, nm.joined_at,
            (
                SELECT json_agg(json_build_object(
                    'id', nr.id,
                    'uuid', nr.uuid,
                    'role_name', nr.role_name,
                    'display_name', nr.display_name,
                    'permissions', nr.permissions
                ))
                FROM namespace_user_roles nur
                JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
                WHERE nur.namespace_member_id = nm.id
            ) as roles
        FROM namespaces n
        JOIN namespace_members nm ON n.id = nm.namespace_id
        JOIN users u ON nm.user_id = u.id
        WHERE (u.uuid = ? OR u.id = ?)
        AND nm.status = 'active'
        AND n.status = 'active'
        ORDER BY nm.is_owner DESC, n.name ASC
    ]]

    local user_id_num = tonumber(user_id)
    return db.query(query, tostring(user_id), user_id_num or 0)
end

--- Check if user is member of namespace
-- @param user_id string|number User ID or UUID
-- @param namespace_id string|number Namespace ID or UUID
-- @return boolean
function NamespaceQueries.isUserMember(user_id, namespace_id)
    local query = [[
        SELECT nm.id
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE (u.uuid = ? OR u.id = ?)
        AND (n.uuid = ? OR n.id = ?)
        AND nm.status = 'active'
        LIMIT 1
    ]]

    local user_id_num = tonumber(user_id)
    local namespace_id_num = tonumber(namespace_id)

    local result = db.query(query,
        tostring(user_id), user_id_num or 0,
        tostring(namespace_id), namespace_id_num or 0
    )

    return result and #result > 0
end

--- Check if user is owner of namespace
-- @param user_id string|number User ID or UUID
-- @param namespace_id string|number Namespace ID or UUID
-- @return boolean
function NamespaceQueries.isUserOwner(user_id, namespace_id)
    local query = [[
        SELECT nm.id
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE (u.uuid = ? OR u.id = ?)
        AND (n.uuid = ? OR n.id = ?)
        AND nm.status = 'active'
        AND nm.is_owner = true
        LIMIT 1
    ]]

    local user_id_num = tonumber(user_id)
    local namespace_id_num = tonumber(namespace_id)

    local result = db.query(query,
        tostring(user_id), user_id_num or 0,
        tostring(namespace_id), namespace_id_num or 0
    )

    return result and #result > 0
end

--- Get namespace statistics
-- @param namespace_id string|number Namespace ID or UUID
-- @return table Statistics
function NamespaceQueries.getStats(namespace_id)
    local namespace = NamespaceQueries.show(namespace_id)
    if not namespace then
        return nil
    end

    -- Core stats (tables always exist)
    local core_stats = db.query([[
        SELECT
            (SELECT COUNT(*) FROM namespace_members WHERE namespace_id = ? AND status = 'active') as total_members,
            (SELECT COUNT(*) FROM namespace_roles WHERE namespace_id = ?) as total_roles
    ]], namespace.id, namespace.id)

    local result = {
        total_members = core_stats and core_stats[1] and core_stats[1].total_members or 0,
        total_roles = core_stats and core_stats[1] and core_stats[1].total_roles or 0,
        total_stores = 0,
        total_orders = 0,
        total_customers = 0,
        total_products = 0,
        total_revenue = 0
    }

    -- Ecommerce stats (only if tables exist)
    local ProjectConfig = require("helper.project-config")
    if ProjectConfig.isEcommerceEnabled() then
        local ok, ecom_stats = pcall(db.query, [[
            SELECT
                (SELECT COUNT(*) FROM stores WHERE namespace_id = ?) as total_stores,
                (SELECT COUNT(*) FROM orders WHERE namespace_id = ?) as total_orders,
                (SELECT COUNT(*) FROM customers WHERE namespace_id = ?) as total_customers,
                (SELECT COUNT(*) FROM storeproducts WHERE namespace_id = ?) as total_products,
                (SELECT COALESCE(SUM(total_amount), 0) FROM orders WHERE namespace_id = ? AND status != 'cancelled') as total_revenue
        ]], namespace.id, namespace.id, namespace.id, namespace.id, namespace.id)
        if ok and ecom_stats and ecom_stats[1] then
            result.total_stores = ecom_stats[1].total_stores or 0
            result.total_orders = ecom_stats[1].total_orders or 0
            result.total_customers = ecom_stats[1].total_customers or 0
            result.total_products = ecom_stats[1].total_products or 0
            result.total_revenue = ecom_stats[1].total_revenue or 0
        end
    end

    return result
end

--- Count all namespaces
-- @param params table { status? }
-- @return number
function NamespaceQueries.count(params)
    params = params or {}
    local where_clause = ""
    local values = {}

    if params.status then
        where_clause = "WHERE status = ?"
        table.insert(values, params.status)
    end

    local result = db.query("SELECT COUNT(*) as count FROM namespaces " .. where_clause, table.unpack(values))
    return result[1] and result[1].count or 0
end

--- Check if slug is available
-- @param slug string The slug to check
-- @param exclude_id number|nil Namespace ID to exclude (for updates)
-- @return boolean
function NamespaceQueries.isSlugAvailable(slug, exclude_id)
    local query = "SELECT id FROM namespaces WHERE slug = ?"
    local values = { slug }

    if exclude_id then
        query = query .. " AND id != ?"
        table.insert(values, exclude_id)
    end

    local result = db.query(query, table.unpack(values))
    return not result or #result == 0
end

--- Check if domain is available
-- @param domain string The domain to check
-- @param exclude_id number|nil Namespace ID to exclude (for updates)
-- @return boolean
function NamespaceQueries.isDomainAvailable(domain, exclude_id)
    if not domain or domain == "" then
        return true
    end

    local query = "SELECT id FROM namespaces WHERE domain = ?"
    local values = { domain }

    if exclude_id then
        query = query .. " AND id != ?"
        table.insert(values, exclude_id)
    end

    local result = db.query(query, table.unpack(values))
    return not result or #result == 0
end

-- ============================================
-- User Namespace Settings (User-First Architecture)
-- ============================================

--- Get user's namespace settings (default and last active namespace)
-- @param user_id number User ID
-- @return table|nil Settings or nil
function NamespaceQueries.getUserSettings(user_id)
    local query = [[
        SELECT
            uns.*,
            dn.uuid as default_namespace_uuid,
            dn.name as default_namespace_name,
            dn.slug as default_namespace_slug,
            ln.uuid as last_active_namespace_uuid,
            ln.name as last_active_namespace_name,
            ln.slug as last_active_namespace_slug
        FROM user_namespace_settings uns
        LEFT JOIN namespaces dn ON uns.default_namespace_id = dn.id
        LEFT JOIN namespaces ln ON uns.last_active_namespace_id = ln.id
        WHERE uns.user_id = ?
    ]]
    local result = db.query(query, user_id)
    return result and result[1] or nil
end

--- Set or update user's namespace settings
-- @param user_id number User ID
-- @param settings table { default_namespace_id?, last_active_namespace_id? }
-- @return table The settings
function NamespaceQueries.setUserSettings(user_id, settings)
    local timestamp = Global.getCurrentTimestamp()

    -- Check if settings exist
    local existing = db.query("SELECT id FROM user_namespace_settings WHERE user_id = ?", user_id)

    if existing and #existing > 0 then
        -- Update existing settings
        local update_data = { updated_at = timestamp }
        if settings.default_namespace_id ~= nil then
            update_data.default_namespace_id = settings.default_namespace_id
        end
        if settings.last_active_namespace_id ~= nil then
            update_data.last_active_namespace_id = settings.last_active_namespace_id
        end

        db.update("user_namespace_settings", update_data, { user_id = user_id })
    else
        -- Create new settings record using raw SQL to properly handle NULL values
        -- This avoids the ORM inserting default 0 values for foreign key columns
        local default_ns = settings.default_namespace_id and settings.default_namespace_id > 0
            and tostring(settings.default_namespace_id) or "NULL"
        local last_active_ns = settings.last_active_namespace_id and settings.last_active_namespace_id > 0
            and tostring(settings.last_active_namespace_id) or "NULL"

        db.query(string.format([[
            INSERT INTO user_namespace_settings
            (user_id, default_namespace_id, last_active_namespace_id, created_at, updated_at)
            VALUES (%d, %s, %s, %s, %s)
        ]], user_id, default_ns, last_active_ns,
            db.escape_literal(timestamp), db.escape_literal(timestamp)))
    end

    return NamespaceQueries.getUserSettings(user_id)
end

--- Update user's last active namespace
-- @param user_id number User ID
-- @param namespace_id number Namespace ID
-- @return table|nil The settings
function NamespaceQueries.updateLastActiveNamespace(user_id, namespace_id)
    return NamespaceQueries.setUserSettings(user_id, { last_active_namespace_id = namespace_id })
end

--- Get user's default namespace (or first available if not set)
-- @param user_id number User ID
-- @return table|nil The namespace or nil
function NamespaceQueries.getUserDefaultNamespace(user_id)
    -- First try to get the configured default
    local settings = NamespaceQueries.getUserSettings(user_id)
    if settings and settings.default_namespace_id then
        local namespace = NamespaceQueries.show(settings.default_namespace_id)
        if namespace and namespace.status == "active" then
            return namespace
        end
    end

    -- If no default or default is inactive, try last active
    if settings and settings.last_active_namespace_id then
        local namespace = NamespaceQueries.show(settings.last_active_namespace_id)
        if namespace and namespace.status == "active" then
            return namespace
        end
    end

    -- Finally, get first available namespace for user
    local namespaces = NamespaceQueries.getForUser(user_id)
    if namespaces and #namespaces > 0 then
        return NamespaceQueries.show(namespaces[1].id)
    end

    return nil
end

--- Validate + canonicalise a list of frontend origin strings.
--
-- Rules:
--   - Must be ``http://`` or ``https://`` only — rejects ``javascript:``,
--     ``data:``, ``file:``, etc. that would be useful for XSS pivots
--     in an email link.
--   - Path/query/fragment stripped — only the origin (scheme + host
--     + optional port) is stored.
--   - Whitespace trimmed.
--   - Duplicates removed (preserves first-seen order).
--   - Empty list is allowed (admin can intentionally disable password
--     reset for a namespace); caller can enforce non-empty if desired.
--
-- Returns ``(canonicalised_array, nil)`` on success or
-- ``(nil, error_message)`` on validation failure (first bad entry
-- wins so the message points at the actual offender).
local function validate_origins(input)
    if type(input) ~= "table" then
        return nil, "expected an array of URL strings"
    end
    local out = {}
    local seen = {}
    for i, raw in ipairs(input) do
        if type(raw) ~= "string" then
            return nil, ("entry #%d is not a string"):format(i)
        end
        local trimmed = raw:match("^%s*(.-)%s*$")
        if trimmed == "" then
            return nil, ("entry #%d is empty"):format(i)
        end
        -- Strict scheme check: only http/https. The match anchors the
        -- whole string so embedded ``http://`` inside ``javascript:..``
        -- can't sneak through.
        local canon = trimmed:match("^(https?://[^/%s]+)")
        if not canon or canon == "" then
            return nil, ("entry #%d is not a valid http(s) origin: %s")
                :format(i, trimmed)
        end
        -- Reject anything more than the canonical origin — if the
        -- input still has trailing path/query that we stripped, fine,
        -- silently keep just the origin. But we already trimmed
        -- whitespace; the regex eats nothing past the host so any
        -- residue (path) gets dropped naturally.
        if not seen[canon] then
            seen[canon] = true
            table.insert(out, canon)
        end
    end
    return out, nil
end


--- Replace the namespace's ``allowed_redirect_origins`` with a
-- validated array. Used by the admin UI's "Frontend URLs" settings
-- panel.
--
-- Validation is centralised here (not at the route layer) so any
-- caller — admin UI, future bulk-import script, programmatic
-- onboarding — gets the same guarantees.
--
-- @param id string|number ID or UUID of the namespace
-- @param origins table  array of URL strings (validated + canonicalised)
-- @return table|nil  the updated namespace row, or nil on failure
-- @return string|nil error message on failure
function NamespaceQueries.updateAllowedRedirectOrigins(id, origins)
    local validated, err = validate_origins(origins or {})
    if not validated then
        return nil, err
    end

    local namespace = NamespaceQueries.show(id)
    if not namespace then
        return nil, "namespace not found"
    end

    -- ``db.array({})`` for empty arrays is also accepted by the
    -- driver — produces the empty Postgres array literal ``{}``.
    -- Distinct from NULL (which the runtime treats as "use env-var
    -- fallback"), an empty array means "explicitly no origins
    -- allowed" — admin chose to disable password reset for this
    -- namespace.
    -- Empty input collapses to NULL in the column. Postgres can't
    -- handle ``ARRAY[]`` without an explicit cast, and treating
    -- "empty admin input" the same as "never configured" simplifies
    -- the runtime fallback contract: NULL = use env-var FRONTEND_URL.
    -- An admin who wants to fully disable password reset for a
    -- tenant clears the env var separately.
    if #validated == 0 then
        namespace:update({
            allowed_redirect_origins = db.raw("NULL"),
            updated_at = Global.getCurrentTimestamp(),
        })
    else
        namespace:update({
            allowed_redirect_origins = db.array(validated),
            updated_at = Global.getCurrentTimestamp(),
        })
    end

    return namespace
end


--- Return the namespace's allow-list of frontend origins for redirect
-- emails (password reset, future invitation links, etc.).
--
-- Schema: ``namespaces.allowed_redirect_origins TEXT[]``. Stored as
-- canonical origins (``scheme://host[:port]``); migration 489 also
-- bootstraps it from FRONTEND_URL + PASSWORD_RESET_ALLOWED_ORIGINS env
-- vars when first added.
--
-- Returns an empty Lua array (NOT nil) when the column is unset, so
-- callers can safely iterate without nil-guards.
--
-- @param namespace_id number
-- @return table  array of origin strings (possibly empty)
function NamespaceQueries.getAllowedRedirectOrigins(namespace_id)
    if not namespace_id then return {} end
    local rows = db.query(
        "SELECT allowed_redirect_origins FROM namespaces WHERE id = ? LIMIT 1",
        namespace_id
    )
    if not rows or #rows == 0 then return {} end
    local arr = rows[1].allowed_redirect_origins
    if type(arr) ~= "table" then return {} end
    return arr
end


--- Get user's permissions in a namespace
-- @param user_id number User ID
-- @param namespace_id number Namespace ID
-- @return table Merged permissions from all roles
function NamespaceQueries.getUserPermissions(user_id, namespace_id)
    local query = [[
        SELECT nr.permissions
        FROM namespace_user_roles nur
        JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
        JOIN namespace_members nm ON nur.namespace_member_id = nm.id
        WHERE nm.user_id = ? AND nm.namespace_id = ? AND nm.status = 'active'
        ORDER BY nr.priority DESC
    ]]

    local roles = db.query(query, user_id, namespace_id)
    local merged = {}

    for _, role in ipairs(roles or {}) do
        local ok, perms = pcall(require("cjson").decode, role.permissions or "{}")
        if ok and type(perms) == "table" then
            for module, actions in pairs(perms) do
                if not merged[module] then
                    merged[module] = {}
                end
                for _, action in ipairs(actions) do
                    -- Add action if not already present
                    local found = false
                    for _, existing in ipairs(merged[module]) do
                        if existing == action then
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(merged[module], action)
                    end
                end
            end
        end
    end

    return merged
end

--- Get user's membership in a specific namespace
-- @param user_id number User ID
-- @param namespace_id number Namespace ID
-- @return table|nil Membership details or nil
function NamespaceQueries.getUserMembership(user_id, namespace_id)
    local query = [[
        SELECT
            nm.id, nm.uuid, nm.namespace_id, nm.user_id,
            nm.status, nm.is_owner, nm.joined_at, nm.invited_by,
            nm.created_at, nm.updated_at,
            n.name as namespace_name, n.slug as namespace_slug,
            (
                SELECT json_agg(json_build_object(
                    'id', nr.id,
                    'uuid', nr.uuid,
                    'role_name', nr.role_name,
                    'display_name', nr.display_name,
                    'permissions', nr.permissions,
                    'priority', nr.priority
                ))
                FROM namespace_user_roles nur
                JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
                WHERE nur.namespace_member_id = nm.id
            ) as roles
        FROM namespace_members nm
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE nm.user_id = ? AND nm.namespace_id = ?
    ]]

    local result = db.query(query, user_id, namespace_id)
    return result and result[1] or nil
end

--- Create namespace and add user as owner
-- @param user_id number The user creating the namespace
-- @param data table Namespace data
-- @return table { namespace, membership }
function NamespaceQueries.createWithOwner(user_id, data)
    local timestamp = Global.getCurrentTimestamp()

    -- Create namespace
    data.owner_user_id = user_id
    local namespace = NamespaceQueries.create(data)

    if not namespace then
        return nil, "Failed to create namespace"
    end

    -- Add user as owner member
    local member_uuid = Global.generateUUID()
    db.insert("namespace_members", {
        uuid = member_uuid,
        namespace_id = namespace.id,
        user_id = user_id,
        status = "active",
        is_owner = true,
        joined_at = timestamp,
        created_at = timestamp,
        updated_at = timestamp
    })

    -- Get member record
    local member = db.select("* FROM namespace_members WHERE uuid = ?", member_uuid)
    if not member or #member == 0 then
        return nil, "Failed to create membership"
    end

    -- Create default roles using DB-driven permissions, filtered by project_code
    local NamespaceRoleQueries = require("queries.NamespaceRoleQueries")
    NamespaceRoleQueries.createDefaultRoles(namespace.id, data.project_code)

    -- Find the owner role and assign it to the user
    local owner_role = db.select(
        "id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'owner'",
        namespace.id
    )
    if owner_role and #owner_role > 0 then
        db.insert("namespace_user_roles", {
            uuid = Global.generateUUID(),
            namespace_member_id = member[1].id,
            namespace_role_id = owner_role[1].id,
            created_at = timestamp,
            updated_at = timestamp
        })
    end

    -- Set as user's default namespace if they don't have one
    local settings = NamespaceQueries.getUserSettings(user_id)
    if not settings or not settings.default_namespace_id then
        NamespaceQueries.setUserSettings(user_id, {
            default_namespace_id = namespace.id,
            last_active_namespace_id = namespace.id
        })
    end

    local membership = NamespaceQueries.getUserMembership(user_id, namespace.id)

    return {
        namespace = namespace,
        membership = membership
    }
end

return NamespaceQueries
