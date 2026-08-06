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
local RateLimit = require("middleware.rate-limit")

-- Load the CLI module once at boot. Nothing here is stateful, so a single
-- reference for the lifetime of the openresty worker is fine.
local CMI = require("scripts.config-cli")

-- Rate limits. CMI writes are heavy (dozens of upserts in one call);
-- read (export) is a many-table SELECT scan. Both should be admin-only
-- and rare in absolute terms.
local CMI_READ_LIMIT  = { rate = 30, window = 60, prefix = "cmi:read"  }
local CMI_WRITE_LIMIT = { rate = 10, window = 60, prefix = "cmi:write" }

-- Reject bundles larger than this at the HTTP boundary. Baseline is
-- ~500KB; 32MB gives 60× headroom while stopping a hostile upload from
-- blocking a worker parsing multi-GB JSON.
local MAX_BUNDLE_BYTES = 32 * 1024 * 1024

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
-- bodies and OpenResty's spillover-to-tempfile for large uploads.
--
-- Returns (parsed_table, nil) on success, or (nil, err_string) on any
-- shape/size violation. Callers MUST inspect the error — the previous
-- silent-empty-on-error was hiding malformed uploads as "empty body".
local function parseJSON(self)
    local ok, data_or_err = pcall(function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        if not data or data == "" then
            local file = ngx.req.get_body_file()
            if file then
                local f = io.open(file, "r")
                if f then
                    -- Peek size before reading — cap at MAX_BUNDLE_BYTES.
                    local sz = f:seek("end") or 0
                    if sz > MAX_BUNDLE_BYTES then
                        f:close()
                        error("body exceeds " .. MAX_BUNDLE_BYTES .. " bytes")
                    end
                    f:seek("set", 0)
                    data = f:read("*a")
                    f:close()
                end
            end
        elseif #data > MAX_BUNDLE_BYTES then
            error("body exceeds " .. MAX_BUNDLE_BYTES .. " bytes")
        end
        if not data or data == "" then return nil end
        return data
    end)
    if not ok then return nil, tostring(data_or_err) end
    if data_or_err == nil then return {}, nil end
    local ok_decode, parsed = pcall(cjson.decode, data_or_err)
    if not ok_decode then return nil, "malformed JSON body" end
    if type(parsed) ~= "table" then return nil, "body must be a JSON object" end
    return parsed, nil
end

-- Log the full internal error to nginx logs (with correlation) and
-- return a compact user-facing message. Never leak Lua paths, SQL
-- fragments, or file names in an HTTP response body.
local function internal_error(context, err)
    local corr = require("helper.global").generateUUID()
    ngx.log(ngx.ERR, "[cmi] " .. context .. " corr=" .. corr .. " err=" .. tostring(err))
    return { status = 500, json = {
        error = "Internal error while processing " .. context ..
                "; check server logs (correlation " .. corr .. ")",
        correlation_id = corr,
    } }
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
        AuthMiddleware.requireAuth(RateLimit.wrap(CMI_READ_LIMIT, function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body, body_err = parseJSON(self)
            if not body then
                return { status = 400, json = { error = body_err } }
            end
            local slug = body.namespace_slug
            if not slug or slug == "" then
                return { status = 400, json = {
                    error = "namespace_slug is required (e.g. 'tax-copilot')"
                } }
            end
            local ok, bundle_or_err, total_rows, warnings =
                pcall(CMI.export_bundle, slug)
            if not ok then
                -- validate_slug / resolve_namespace failures are 400s,
                -- not 500s — user-fixable input errors.
                local msg = tostring(bundle_or_err)
                if msg:find("Invalid namespace slug") or msg:find("does not exist on this environment") then
                    return { status = 400, json = { error = msg } }
                end
                return internal_error("cmi export", bundle_or_err)
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
        end))
    )

    -- --------------------------------------------------------------
    -- Import — dry-run (no writes)
    -- --------------------------------------------------------------
    app:post("/api/v2/tax/admin/cmi/import/dry-run",
        AuthMiddleware.requireAuth(RateLimit.wrap(CMI_WRITE_LIMIT, function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body, body_err = parseJSON(self)
            if not body then
                return { status = 400, json = { error = body_err } }
            end
            local slug = body.namespace_slug
            local bundle = body.bundle
            if not slug or slug == "" then
                return { status = 400, json = { error = "namespace_slug is required" } }
            end
            if not bundle or type(bundle) ~= "table" then
                return { status = 400, json = {
                    error = "bundle is required (upload the JSON blob from export)"
                } }
            end
            local ok, result_or_err = pcall(CMI.import_bundle_plan, bundle, slug)
            if not ok then
                -- CLI-thrown validation errors → 400. Real crashes → 500.
                local msg = tostring(result_or_err)
                if msg:find("bundle version") or msg:find("Invalid namespace slug") or
                   msg:find("does not exist on this environment") or
                   msg:find("bundle contains unknown file path") or
                   msg:find("exceeds MAX_ENTRIES_PER_TABLE") then
                    return { status = 400, json = { error = msg } }
                end
                return internal_error("cmi dry-run", result_or_err)
            end
            result_or_err.confirm_token = confirm_token_for(result_or_err.totals)
            return { status = 200, json = result_or_err }
        end))
    )

    -- --------------------------------------------------------------
    -- Import — apply (writes)
    -- --------------------------------------------------------------
    app:post("/api/v2/tax/admin/cmi/import/apply",
        AuthMiddleware.requireAuth(RateLimit.wrap(CMI_WRITE_LIMIT, function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body, body_err = parseJSON(self)
            if not body then
                return { status = 400, json = { error = body_err } }
            end
            local slug = body.namespace_slug
            local bundle = body.bundle
            local claimed_token = body.confirm_token
            if not slug or slug == "" then
                return { status = 400, json = { error = "namespace_slug is required" } }
            end
            if not bundle or type(bundle) ~= "table" then
                return { status = 400, json = { error = "bundle is required" } }
            end
            if not claimed_token or claimed_token == "" then
                return { status = 400, json = {
                    error = "confirm_token is required; call dry-run first, echo its token"
                } }
            end
            -- Defense in depth: the bundle carries its authoring
            -- namespace_slug; refuse to import it into a different
            -- namespace unless the operator explicitly acknowledges by
            -- matching. Prevents a UI bug (or URL tampering) from
            -- cross-tenant applying.
            if bundle.namespace_slug and bundle.namespace_slug ~= slug then
                return { status = 400, json = {
                    error = "Bundle was exported for namespace '" ..
                            tostring(bundle.namespace_slug) ..
                            "' but this request targets '" .. slug ..
                            "'. Re-export from the source or dispatch to the correct target.",
                } }
            end

            -- Re-plan first so the actual apply matches what the human
            -- authorised. If the bundle or DB changed between preview and
            -- apply the token will diverge; we refuse rather than silently
            -- apply a different plan than the one they saw.
            local ok_plan, plan_or_err = pcall(CMI.import_bundle_plan, bundle, slug)
            if not ok_plan then
                local msg = tostring(plan_or_err)
                if msg:find("bundle version") or msg:find("Invalid namespace slug") or
                   msg:find("does not exist on this environment") or
                   msg:find("bundle contains unknown file path") or
                   msg:find("exceeds MAX_ENTRIES_PER_TABLE") then
                    return { status = 400, json = { error = msg } }
                end
                return internal_error("cmi apply (dry-run stage)", plan_or_err)
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
                return internal_error("cmi apply", result_or_err)
            end
            -- Structured audit log so the "who applied what, when" is
            -- reconstructable from nginx logs even without a dedicated
            -- audit table. Follow-up: promote to audit_events.
            ngx.log(ngx.WARN, string.format(
                "[cmi apply] user=%s slug=%s applied=%s inserts=%d updates=%d deactivates=%d errors=%d",
                tostring(self.current_user and self.current_user.uuid or "?"),
                slug,
                tostring(result_or_err.applied),
                result_or_err.totals.inserts or 0,
                result_or_err.totals.updates or 0,
                result_or_err.totals.deactivates or 0,
                result_or_err.totals.errors or 0))
            return { status = 200, json = result_or_err }
        end))
    )
end
