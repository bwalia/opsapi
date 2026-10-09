local jwt = require("resty.jwt")
local Global = require("helper.global")

local _M = {}

-- Routes that need no login, and the methods allowed without one: `true` =
-- GET/HEAD only (public reads); a table lists other methods explicitly. A
-- write is public only if it is listed here (a public GET route stays closed
-- to anonymous POST/PUT/DELETE).
local GET = true
local PUBLIC_ROUTES = {
    ["^/$"] = GET,
    ["^/health$"] = GET,
    ["^/swagger$"] = GET,
    ["^/api%-docs$"] = GET,
    ["^/openapi%.json$"] = GET,
    ["^/swagger/swagger%.json$"] = GET,
    ["^/metrics$"] = GET,
    ["^/api/v2/register$"] = { POST = true },
    -- Storefront browsing (products.lua / stores.lua / categories.lua / variants.lua).
    ["^/api/v2/stores/[^/]+/products$"] = GET,
    ["^/api/v2/products/[^/]+/variants$"] = GET,
    ["^/api/v2/stores$"] = GET,
    ["^/api/v2/products$"] = GET,
    ["^/api/v2/categories$"] = GET,
    -- Webhooks: no login, their signature is their authentication.
    ["^/api/v2/public/academy/stripe/webhook$"] = { POST = true },
    ["^/api/v2/webhooks/stripe$"] = { POST = true },
    ["^/api/v2/webhooks/github$"] = { POST = true },
}

--- Is this request allowed without a login?
-- @param uri string
-- @param method string|nil (defaults to the request's)
function _M.is_public_route(uri, method)
    method = method or (ngx and ngx.var.request_method) or "GET"
    for pattern, methods in pairs(PUBLIC_ROUTES) do
        if uri:match(pattern) then -- Lua patterns, as written above (%-, %.)
            if methods == GET then return method == "GET" or method == "HEAD" end
            return methods[method] == true
        end
    end
    return false
end

function _M.authenticate()
    -- Skip authentication for OPTIONS requests (CORS preflight)
    if ngx.var.request_method == "OPTIONS" then
        ngx.log(ngx.DEBUG, "Skipping authentication for OPTIONS request")
        return
    end

    local uri = ngx.var.uri
    -- ngx.say(uri)
    -- ngx.exit(ngx.HTTP_OK)
    -- Skip authentication for public routes
    if _M.is_public_route(uri) then
        ngx.log(ngx.NOTICE, "Skipping authentication for public route: ", uri)
        return
    end

    ngx.log(ngx.NOTICE, "Protected route, checking authentication: ", uri)

    -- Get Authorization header
    local auth_header = ngx.var.http_authorization

    if not auth_header then
        ngx.log(ngx.WARN, "Missing Authorization header for: ", uri)
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Missing Authorization header"}')
        ngx.exit(401)
    end

    -- Extract token
    local token = auth_header:match("Bearer%s+(.+)")

    if not token then
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Invalid Authorization format. Use: Bearer <token>"}')
        ngx.exit(401)
    end

    -- API keys ("opsk_...") are opaque credentials, not JWTs — authenticate
    -- against the api_keys table instead of verifying a signature.
    local ApiKeyHelper = require("helper.api-key")
    if ApiKeyHelper.is_api_key(token) then
        local principal, err_msg, err_status = ApiKeyHelper.authenticate(token)
        if not principal then
            ngx.log(ngx.WARN, "API key authentication failed: ", err_msg or "unknown")
            ngx.status = err_status or 401
            ngx.header.content_type = "application/json"
            ngx.say('{"error":"' .. (err_msg or "Invalid API key") .. '"}')
            ngx.exit(err_status or 401)
        end
        -- Confine the key to the modules it is scoped for. Routes that use
        -- requireAuth without namespace middleware never check scopes, so
        -- without this a cms-only key would reach them.
        if not ApiKeyHelper.permits_uri(principal, uri) then
            ngx.log(ngx.WARN, "API key ", principal.key_uuid, " denied for out-of-scope URI: ", uri)
            ngx.status = 403
            ngx.header.content_type = "application/json"
            ngx.say('{"error":"API key is not scoped for this endpoint"}')
            ngx.exit(403)
        end

        -- An API key is bound to exactly ONE namespace. Reject any request that
        -- names a DIFFERENT namespace via header — centrally, here, so it also
        -- covers routes that resolve the namespace OUTSIDE requireNamespace
        -- (optionalNamespace, raw X-Namespace-Id reads) and any route added
        -- later. requireNamespace has its own equivalent check; this closes the
        -- gap for everything else (fail-closed, same as permits_uri above).
        local ns = principal.namespace or {}
        local req_headers = ngx.req.get_headers()
        local hdr_id = req_headers["x-namespace-id"]
        local hdr_slug = req_headers["x-namespace-slug"]
        if (hdr_id and hdr_id ~= "" and hdr_id ~= tostring(ns.id) and hdr_id ~= ns.uuid)
            or (hdr_slug and hdr_slug ~= "" and hdr_slug ~= ns.slug) then
            ngx.log(ngx.WARN, "API key ", principal.key_uuid,
                " used with a namespace it does not belong to")
            ngx.status = 403
            ngx.header.content_type = "application/json"
            ngx.say('{"error":"API key is not valid for the requested namespace"}')
            ngx.exit(403)
        end

        ngx.ctx.user = principal
        require("helper.request-context").refresh()
        ngx.ctx.api_key_auth = true
        ngx.log(ngx.NOTICE, "API key authentication successful: ", principal.key_uuid,
            " (namespace ", tostring(principal.namespace.slug), ")")
        return
    end

    -- Verify JWT
    local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
    if not JWT_SECRET_KEY then
        ngx.log(ngx.ERR, "JWT_SECRET_KEY not configured")
        ngx.status = 500
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Authentication not configured"}')
        ngx.exit(500)
    end

    local jwt_obj = require("helper.jwt-verify")(JWT_SECRET_KEY, token)

    if not jwt_obj.verified then
        ngx.log(ngx.WARN, "JWT verification failed: ", jwt_obj.reason)
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Invalid or expired token","reason":"' .. (jwt_obj.reason or "unknown") .. '"}')
        ngx.exit(401)
    end

    -- Store user info in ngx.ctx
    ngx.ctx.user = jwt_obj.payload.userinfo
    require("helper.request-context").refresh()
    ngx.log(ngx.NOTICE, "Authentication successful for user: ", tostring(ngx.ctx.user and ngx.ctx.user.uuid or "unknown"))
end

return _M
