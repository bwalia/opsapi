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
    -- Capture the occurrence UUID so the envelope can carry an
    -- `occurrence_uuid` deep-link for admin (mirrors FastAPI). When the
    -- audit insert fails (e.g. DB hiccup), Occurrence.record returns nil
    -- and we just omit the field — clients gracefully degrade to
    -- correlation_id-only.
    local occurrence_uuid = Occurrence.record({
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
    if occurrence_uuid then
        envelope.occurrence_uuid = occurrence_uuid
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


-- ---------------------------------------------------------------------------
-- Client mistakes that surface as exceptions
-- ---------------------------------------------------------------------------

-- Postgres rejecting a value or a constraint, and lapis validations raised
-- outside capture_errors, are the CLIENT's input, not a server fault. Only
-- the text after "ERROR:" is examined (the SQL before it echoes user data
-- and is never returned). Each entry: pattern, status, code, reason,
-- message, and how to read the offending column (if any).
local INPUT_ERRORS = {
    { "invalid input syntax for type (%w+)", 400, "VALIDATION_400", "invalid_format",
        "A value in the request has the wrong format." },
    { "invalid input value for enum", 400, "VALIDATION_400", "invalid_value",
        "A value in the request isn't one of the allowed values." },
    { "out of range for type", 400, "VALIDATION_400", "out_of_range",
        "A number in the request is out of range." },
    { "value too long for type", 422, "VALIDATION_422", "too_long",
        "A value in the request is too long." },
    { "null value in column \"([%w_]+)\"[^\n]*violates not%-null constraint", 422, "VALIDATION_422", "required",
        "A required field is missing." },
    { "violates check constraint \"([%w_]+)\"", 422, "VALIDATION_422", "invalid_value",
        "A value in the request isn't allowed." },
    { "duplicate key value violates unique constraint", 409, "CONFLICT_409", "duplicate",
        "A record with these values already exists." },
    { "update or delete on table [^\n]*violates foreign key constraint", 409, "CONFLICT_409", "still_referenced",
        "This record is still used by other records." },
    { "violates foreign key constraint", 422, "VALIDATION_422", "reference_missing",
        "The request refers to a record that doesn't exist." },
}

--- Raise from query/helper code when the client's input is invalid (422)
-- or conflicts with existing data (409). The message is shown to the user.
-- A plain string, so it survives the pcall + tostring() of older routes.
function Errors.invalid(message)
    error("VALIDATION: " .. tostring(message), 0)
end

function Errors.conflict(message)
    error("CONFLICT: " .. tostring(message), 0)
end

--- Recognise an exception caused by the client's input.
-- @param err any  the raised error (string from lapis/pgmoon, or table)
-- @return nil, or { status, code, message, context }
function Errors.classify(err)
    if type(err) ~= "string" then return nil end
    -- lapis.validate's assert_valid raised outside capture_errors: its
    -- messages are written for users ("name must be provided").
    local invalid = err:match("assert_valid was not captured: ([^\n]+)")
    if invalid then
        return { status = 422, code = "VALIDATION_422", message = "The request has invalid fields.",
            context = { reason = "invalid", errors = invalid:sub(1, 500) } }
    end
    local raised = err:match("VALIDATION: ([^\n]+)")
    if raised then
        return { status = 422, code = "VALIDATION_422", message = raised:sub(1, 300), context = { reason = "invalid" } }
    end
    raised = err:match("CONFLICT: ([^\n]+)")
    if raised then
        return { status = 409, code = "CONFLICT_409", message = raised:sub(1, 300), context = { reason = "conflict" } }
    end
    local pg = err:match("ERROR:%s*([^\n]+)")
    if not pg then return nil end
    for _, rule in ipairs(INPUT_ERRORS) do
        local found, _, capture = pg:find(rule[1])
        if found then
            local context = { reason = rule[4] }
            if rule[4] == "required" then context.field = capture end
            if rule[4] == "invalid_format" then context.type = capture end
            if rule[4] == "invalid_value" and capture then context.constraint = capture end
            if rule[4] == "duplicate" then context.field = pg:match("Key %(([%w_, ]+)%)") end
            return { status = rule[2], code = rule[3], message = rule[5], context = context }
        end
    end
    return nil
end

local function client_error(info)
    return { status = info.status, json = { error = {
        code = info.code, category = "error", message = info.message, context = info.context,
    } } }
end

--- The `{ error = "<message>", details = ... }` body older routes return,
-- made safe. A 5xx caused by the client's input becomes that 4xx (with
-- `code` and `context`); otherwise the raw exception text — SQL with user
-- data — is never sent back (callers log it). 4xx details written by the
-- route itself are kept.
function Errors.legacy(status, message, details)
    if (tonumber(status) or 500) >= 500 then
        local input = Errors.classify(details)
        if input then
            return { status = input.status, json = { error = input.message, code = input.code, context = input.context } }
        end
        return { status = status, json = { error = message } }
    end
    return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
end

--- For handlers that catch errors themselves: a 4xx for the client's
-- mistakes (see classify), else a logged SYSTEM_500 envelope with a
-- correlation id. Never echoes the raw error to the client.
-- @param fallback_code string optional catalog code for the 500 (default SYSTEM_500)
function Errors.fromException(self, err, fallback_code)
    local info = Errors.classify(err)
    if info then
        ngx.log(ngx.NOTICE, "client error ", info.status, " ", info.code, ": ", info.context.reason)
        return client_error(info)
    end
    ngx.log(ngx.ERR, "Unhandled error: ", tostring(err))
    return Errors.response(self, fallback_code or "SYSTEM_500", { status = 500, cause = err })
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

        -- Lapis routing errors are CLIENT errors, not server faults. A request
        -- for a path we don't serve raises "Failed to find route: <uri>" (a 404)
        -- and a request with the wrong verb raises "don't know how to respond to
        -- <METHOD>" (a 405). Falling through to SYSTEM_500 makes every client
        -- typo, probe, and scanner hit look like a server crash — it pages
        -- on-call on 5xx alerts and floods error_occurrences with non-errors.
        -- Return a clean envelope with the correct status and skip the audit
        -- write (logged at NOTICE so it never trips ERR/5xx-based alerting).
        if type(err) == "string" then
            if err:find("Failed to find route", 1, true) then
                ngx.log(ngx.NOTICE, "404 (no route): ", err)
                return { status = 404, json = { error = {
                    code = "NOT_FOUND_404", category = "error",
                    message = "The requested resource was not found.",
                } } }
            end
            if err:find("don't know how to respond to", 1, true) then
                ngx.log(ngx.NOTICE, "405 (method not allowed): ", err)
                return { status = 405, json = { error = {
                    code = "METHOD_NOT_ALLOWED_405", category = "error",
                    message = "This method is not allowed for the requested resource.",
                } } }
            end
        end

        -- The client's input (malformed id, missing required field,
        -- duplicate, ...): a 4xx naming the problem, not a 500.
        local input = Errors.classify(err)
        if input then
            ngx.log(ngx.NOTICE, "client error ", input.status, " ", input.code, ": ", input.context.reason)
            return client_error(input)
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
