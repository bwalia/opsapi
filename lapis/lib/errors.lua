--[[
    Errors — ergonomic front door for emitting catalog-backed error
    responses from Lapis route handlers. Lua-idiomatic equivalent of
    backend/app/errors/exceptions.py + middleware.py.

    Usage:

        local Errors = require("lib.errors")

        app:post("/auth/login", function(self)
            if not identifier then
                return Errors.response(self, "VALIDATION_400", {
                    context = { field = "identifier", reason = "required" }
                })
            end
            ...
        end)

    The helper handles three things that would otherwise be repeated at
    every error site:
      1. Resolving the user's locale from the request.
      2. Looking up the catalog entry + translation (with TTL cache).
      3. Writing a sanitised row to error_occurrences for the admin view.
      4. Building the standard { error = {...} } envelope.

    Options (second arg to Errors.response / .raise):
      status         number   override the catalog's http_status
      context        table    placeholder values + extra metadata persisted to app_context
      cause          any      original exception string (for raw_error)
      stack_trace    string   optional traceback
]]

local Catalog = require("lib.error_catalog")
local Locale  = require("lib.error_locale")
local Occurrence = require("lib.error_occurrence")
local Global = require("helper.global")

local Errors = {}


--- Resolve correlation id from X-Request-ID header or mint a fresh one.
-- Keeping this in one place means every envelope + occurrence share the
-- same id for cross-system correlation (Python → Lapis via reverse proxy).
local function resolve_correlation_id(self)
    if self and self.req and self.req.headers then
        local rid = self.req.headers["x-request-id"] or self.req.headers["X-Request-ID"]
        if rid and rid ~= "" then
            return rid
        end
    end
    return Global.generateUUID()
end


--- Resolve the authenticated user's UUID from common places, best-effort.
local function resolve_user_uuid(self)
    if not self then return nil end

    -- Lapis middlewares often stash the authenticated user on self.user.
    if self.user and type(self.user) == "table" then
        return self.user.uuid or self.user.id
    end
    if self.current_user and type(self.current_user) == "table" then
        return self.current_user.uuid or self.current_user.id
    end
    return nil
end


--- Build the catalog-backed response envelope.
-- @param self table   Lapis request
-- @param code string   catalog code (e.g. "AUTH_INVALID_CREDENTIALS")
-- @param opts table    optional { status, context, cause, stack_trace }
-- @return table { status, json }  ready to return from a route handler
function Errors.response(self, code, opts)
    opts = opts or {}
    local locale = Locale.resolve(self)
    local resolved = Catalog.resolve(code, locale, opts.context)
    local status = tonumber(opts.status) or resolved.http_status or 500
    local correlation_id = resolve_correlation_id(self)

    -- Synchronous audit write. A single INSERT is <5ms and keeps the
    -- audit guarantee tight: if the handler returned an envelope, the
    -- row is in the table. ``Occurrence.record`` wraps its own pcall so
    -- a DB hiccup can't kill the request path.
    --
    -- An earlier revision used ``ngx.timer.at(0, fn)`` for fire-and-forget
    -- writes, but the timer runs in a detached context where the captured
    -- ``self`` has already been torn down — inserts silently dropped. If
    -- the sync path ever becomes a hot-spot we'll move to a lua-resty-
    -- producer queue, not back to naked timers.
    Occurrence.record({
        self = self,
        code = resolved.code,
        catalog_uuid = resolved.catalog_uuid ~= "" and resolved.catalog_uuid or nil,
        correlation_id = correlation_id,
        http_status = status,
        raw_error = opts.cause and tostring(opts.cause) or nil,
        stack_trace = opts.stack_trace,
        user_uuid = resolve_user_uuid(self),
        app_context = opts.context,
    })

    local envelope = {
        code = resolved.code,
        message = resolved.user_message,
        category = resolved.category,
        correlation_id = correlation_id,
    }
    if resolved.title and resolved.title ~= "" then
        envelope.title = resolved.title
    end
    if opts.context and next(opts.context) then
        envelope.context = opts.context
    end

    return {
        status = status,
        headers = { ["X-Request-ID"] = correlation_id },
        json = { error = envelope },
    }
end


--- Raise a structured error for the Lapis app.handle_error hook to catch.
-- Useful inside deep helper calls where returning { status, json } isn't
-- ergonomic. The handle_error wrapper installed by errors.install_handler
-- detects these and builds an envelope.
function Errors.raise(code, opts)
    opts = opts or {}
    error({
        __app_error = true,
        code = code,
        status = opts.status,
        context = opts.context,
        cause = opts.cause,
    }, 2)
end


--- Install the app-level error handler that catches raised AppErrors
-- and unknown exceptions, renders a catalog envelope for both. Call
-- once in app.lua.
function Errors.install_handler(app)
    app.handle_error = function(self, err, trace)
        -- AppError raised via Errors.raise(): render the normal envelope.
        if type(err) == "table" and err.__app_error then
            ngx.log(ngx.INFO, "AppError ", tostring(err.code), " at ",
                self.req and self.req.parsed_url and self.req.parsed_url.path or "?")
            return Errors.response(self, err.code, {
                status = err.status,
                context = err.context,
                cause = err.cause,
                stack_trace = trace,
            })
        end

        -- Genuine surprise: log fully, return SYSTEM_500 envelope with
        -- a correlation id the user can quote to support.
        ngx.log(ngx.ERR, "Unhandled error: ", tostring(err))
        ngx.log(ngx.ERR, "Stack trace: ", tostring(trace))
        return Errors.response(self, "SYSTEM_500", {
            status = 500,
            cause = err,
            stack_trace = trace,
        })
    end
end


return Errors
