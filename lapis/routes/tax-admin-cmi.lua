--[[
    Config-as-Code (CMI) admin API — export / import for the admin dashboard.

    Endpoints (all POST for the write ones + one GET on export so a browser
    "Save As" works directly):

      POST /api/v2/tax/admin/cmi/export
        Body:  { namespace_slug = "tax-copilot" }
        Reply: 200 with the full bundle JSON (see M.export_bundle in
               scripts/config-cli.lua for the shape). The Content-
               Disposition header suggests a filename so browsers can
               offer "Save As" cleanly.

      POST /api/v2/tax/admin/cmi/import/dry-run
        Body:  { namespace_slug = "tax-copilot", bundle = <bundle object> }
        Reply: 200 with { plans = [...], totals = {...} }. No writes.

      POST /api/v2/tax/admin/cmi/import/apply
        Body:  { namespace_slug = "tax-copilot", bundle = <bundle object>,
                 confirm_token = "<echo of the last dry-run's total counts>" }
        Reply: 200 with { plans = [...], totals = {...} } after upsert +
               soft-deactivate. If confirm_token doesn't match what the
               plan would produce, refuse (409) — protects against
               apply-without-preview clicks.

    All three endpoints require the requester to hold the `administrative`
    or `tax_admin` role. Non-admins get 403 with no shape leakage. Same gate
    as routes/tax-admin-income-types.lua.

    Safety model
      * Every call is scoped by an explicit namespace_slug — the CLI refuses
        nil so leakage across tenants is impossible by construction.
      * Import goes through a mandatory dry-run + confirm_token round-trip.
        The client MUST show the dry-run diff to the human before applying.
      * Apply never DELETE's — rows dropped from the bundle get is_active =
        false (soft delete), consistent with the CLI + CI paths.

    This route is a thin adapter — every non-trivial branch is in
    scripts/config-cli.lua and shared with the CLI/CI paths. If you find
    yourself adding query logic here, put it in the CLI module instead.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")

-- Load the CLI module once at boot. Nothing here is stateful, so a single
-- reference for the lifetime of the openresty worker is fine.
local CMI = require("scripts.config-cli")

--=============================================================================
-- helpers
--=============================================================================

local function isAdmin(user)
    if not user then return false end
    local roles = user.roles or ""
    if type(roles) == "string" then
        for role in roles:gmatch("[^,]+") do
            local trimmed = role:match("^%s*(.-)%s*$")
            if trimmed == "administrative" or trimmed == "tax_admin" then return true end
        end
    end
    if type(roles) == "table" then
        for _, r in ipairs(roles) do
            local name = r.role_name or r
            if name == "administrative" or name == "tax_admin" then return true end
        end
    end
    local user_uuid = user.uuid or user.id
    local rows = db.query([[
        SELECT r.name FROM roles r
        JOIN user__roles ur ON ur.role_id = r.id
        JOIN users u ON u.id = ur.user_id
        WHERE u.uuid = ? AND r.name IN ('administrative', 'tax_admin')
        LIMIT 1
    ]], user_uuid)
    return rows and #rows > 0
end

local function forbidden()
    return { status = 403, json = { error = "Admin access required" } }
end

-- Body parser mirrors tax-admin-income-types.lua: handles both in-memory
-- bodies and OpenResty's spillover-to-tempfile for large uploads. The
-- import bundle for tax_copilot lands around 500KB — well under any
-- realistic body limit — but the temp-file path is free insurance.
local function parseJSON(self)
    local ok, result = pcall(function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        if not data or data == "" then
            local file = ngx.req.get_body_file()
            if file then
                local f = io.open(file, "r")
                if f then
                    data = f:read("*a")
                    f:close()
                end
            end
        end
        if not data or data == "" then return {} end
        return cjson.decode(data)
    end)
    if ok and type(result) == "table" then return result end
    return {}
end

-- Compute a token that captures the human-visible summary of a dry-run.
-- The admin UI echoes this token back when the user clicks "Apply", and
-- we refuse if it doesn't match — a race where the config changed
-- between preview and apply becomes visible instead of silent.
local function confirm_token_for(totals)
    return string.format("i%d-u%d-m%d-d%d-e%d",
        totals.inserts or 0, totals.updates or 0, totals.matches or 0,
        totals.deactivates or 0, totals.errors or 0)
end

--=============================================================================
-- routes
--=============================================================================

return function(app)

    -- --------------------------------------------------------------
    -- Export
    -- --------------------------------------------------------------
    app:post("/api/v2/tax/admin/cmi/export",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body = parseJSON(self)
            local slug = body.namespace_slug
            if not slug or slug == "" then
                return { status = 400, json = {
                    error = "namespace_slug is required (e.g. 'tax-copilot')"
                } }
            end
            local ok, bundle_or_err, total_rows, warnings =
                pcall(CMI.export_bundle, slug)
            if not ok then
                return { status = 500, json = { error = tostring(bundle_or_err) } }
            end
            ngx.header["Content-Disposition"] =
                'attachment; filename="cmi-' .. slug .. '-' ..
                (bundle_or_err.exported_at or "export"):gsub(":", "-") .. '.json"'
            return { status = 200, json = {
                bundle = bundle_or_err,
                summary = {
                    total_rows = total_rows or 0,
                    warnings = warnings or {},
                    table_row_counts = bundle_or_err.table_row_counts,
                }
            } }
        end)
    )

    -- --------------------------------------------------------------
    -- Import — dry-run (no writes)
    -- --------------------------------------------------------------
    app:post("/api/v2/tax/admin/cmi/import/dry-run",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body = parseJSON(self)
            local slug = body.namespace_slug
            local bundle = body.bundle
            if not slug or slug == "" then
                return { status = 400, json = {
                    error = "namespace_slug is required"
                } }
            end
            if not bundle or type(bundle) ~= "table" then
                return { status = 400, json = {
                    error = "bundle is required (upload the JSON blob from export)"
                } }
            end
            local ok, result_or_err = pcall(CMI.import_bundle_plan, bundle, slug)
            if not ok then
                return { status = 400, json = { error = tostring(result_or_err) } }
            end
            result_or_err.confirm_token = confirm_token_for(result_or_err.totals)
            return { status = 200, json = result_or_err }
        end)
    )

    -- --------------------------------------------------------------
    -- Import — apply (writes)
    -- --------------------------------------------------------------
    app:post("/api/v2/tax/admin/cmi/import/apply",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body = parseJSON(self)
            local slug = body.namespace_slug
            local bundle = body.bundle
            local claimed_token = body.confirm_token
            if not slug or slug == "" then
                return { status = 400, json = {
                    error = "namespace_slug is required"
                } }
            end
            if not bundle or type(bundle) ~= "table" then
                return { status = 400, json = {
                    error = "bundle is required"
                } }
            end
            if not claimed_token or claimed_token == "" then
                return { status = 400, json = {
                    error = "confirm_token is required; call dry-run first, echo its token"
                } }
            end

            -- Re-plan first so the actual apply matches what the human
            -- authorised. If the bundle or DB changed between preview and
            -- apply the token will diverge; we refuse rather than silently
            -- apply a different plan than the one they saw.
            local ok_plan, plan_or_err = pcall(CMI.import_bundle_plan, bundle, slug)
            if not ok_plan then
                return { status = 400, json = { error = tostring(plan_or_err) } }
            end
            local expected = confirm_token_for(plan_or_err.totals)
            if expected ~= claimed_token then
                return { status = 409, json = {
                    error = "Plan changed since preview — re-run dry-run and try again",
                    expected_token = expected,
                    submitted_token = claimed_token,
                } }
            end

            local ok, result_or_err = pcall(CMI.import_bundle_apply, bundle, slug)
            if not ok then
                return { status = 500, json = { error = tostring(result_or_err) } }
            end
            return { status = 200, json = result_or_err }
        end)
    )
end
