--[[
    SAML 2.0 single sign-on — a workspace signs its people in with its own IdP
    (Okta, Microsoft Entra ID, Google Workspace, OneLogin, JumpCloud, Keycloak…)

    Public (no JWT; prefix /auth/saml/ is in app.lua's public list):
      GET  /auth/saml/discover?email=… | ?workspace=slug   providers for a sign-in
      GET  /auth/saml/:id/metadata    SP metadata XML to upload to the IdP
      GET  /auth/saml/:id/login       start sign-in → redirect to the IdP
                                      (?frontend_url=<dashboard origin>&from=<path>)
      POST /auth/saml/:id/acs         assertion consumer: the IdP posts here; we
                                      validate, sign the user in, and redirect to
                                      <dashboard>/auth/callback?saml_code=… (one-time)
      POST /auth/saml/exchange        { code } → { token }: the dashboard redeems the
                                      code. The JWT never rides in a URL — it can be
                                      several KB (too big for some proxies' header
                                      buffers) and URLs end up in logs and history.

    Workspace admin (namespace read to view, namespace manage to change):
      GET    /api/v2/sso/saml/providers
      POST   /api/v2/sso/saml/providers
      GET    /api/v2/sso/saml/providers/:id
      PUT    /api/v2/sso/saml/providers/:id
      DELETE /api/v2/sso/saml/providers/:id
      POST   /api/v2/sso/saml/metadata/parse    { xml } → IdP fields

    Who a SAML sign-in may become (an IdP only vouches for its own workspace):
      - the email must be in the provider's email domains (when any are set);
      - a platform admin never signs in through SAML;
      - an existing account may only be signed in when it belongs to no other
        workspace — otherwise a workspace owner who controls an IdP could take
        over someone's account in other workspaces. Such users sign in with
        their password (or Google) instead;
      - unknown emails get an account (auto-provision) and join this workspace
        with the provider's default role; with auto-provision off they must be
        invited first.
]]

local cjson = require("cjson.safe")
local db = require("lapis.db")
local Global = require("helper.global")
local sdk = require("helper.plugin-sdk")
local NamespaceMiddleware = require("middleware.namespace")
local RateLimit = require("middleware.rate-limit")
local SP = require("lib.saml.sp")
local Q = require("queries.SamlProviderQueries")

local SSO_LIMIT = { rate = 20, window = 60, prefix = "auth:saml" }
local STATE_COOKIE = "opsapi_saml_state"
local STATE_TTL = 600

local function api_base()
    return require("lib.billing-urls").opsapi_base() or ""
end

local function sp_urls(provider)
    local base = api_base() .. "/auth/saml/" .. provider.uuid
    return { sp_entity_id = base .. "/metadata", acs_url = base .. "/acs", login_url = base .. "/login" }
end

local function allowed_frontends()
    local origins = {}
    for _, key in ipairs({ "PASSWORD_RESET_ALLOWED_ORIGINS", "FRONTEND_URL" }) do
        local raw = Global.getEnvVar(key)
        if raw then
            for o in raw:gmatch("[^,%s]+") do origins[(o:gsub("/+$", ""))] = true end
        end
    end
    return origins
end

local function trusted_frontend(url)
    return require("middleware.cors").trustedFrontend(url, allowed_frontends())
end

local function default_frontend()
    return (Global.getEnvVar("FRONTEND_URL") or "http://127.0.0.1:8039"):gsub("/+$", "")
end

-- Signed, short-lived sign-in state, kept in a cookie between /login and /acs.
local function hmac(data)
    local secret = Global.getEnvVar("JWT_SECRET_KEY") or ""
    local mac = require("resty.openssl.hmac").new(secret, "sha256"):final(data)
    return ngx.encode_base64(mac):gsub("[+/=]", { ["+"] = "-", ["/"] = "_", ["="] = "" })
end

local function encode_state(state)
    local payload = ngx.encode_base64(cjson.encode(state)):gsub("[+/=]", { ["+"] = "-", ["/"] = "_", ["="] = "" })
    return payload .. "." .. hmac(payload)
end

local function decode_state(raw)
    if type(raw) ~= "string" then return nil end
    local payload, mac = raw:match("^([%w%-_]+)%.([%w%-_]+)$")
    if not payload or hmac(payload) ~= mac then return nil end
    local b64 = payload:gsub("[-_]", { ["-"] = "+", ["_"] = "/" })
    b64 = b64 .. string.rep("=", (4 - #b64 % 4) % 4)
    local state = cjson.decode(ngx.decode_base64(b64) or "")
    if type(state) ~= "table" or (tonumber(state.exp) or 0) < ngx.time() then return nil end
    return state
end

local function set_cookie(value, max_age)
    local secure = api_base():match("^https://") and "; Secure; SameSite=None" or "; SameSite=Lax"
    local cookie = STATE_COOKIE .. "=" .. value .. "; Path=/; Max-Age=" .. max_age .. "; HttpOnly" .. secure
    local existing = ngx.header["Set-Cookie"]
    if type(existing) == "table" then
        table.insert(existing, cookie)
    elseif existing then
        existing = { existing, cookie }
    else
        existing = cookie
    end
    ngx.header["Set-Cookie"] = existing
end

-- The ACS body can be larger than nginx's in-memory buffer; read it either way.
local function post_args()
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local path = ngx.req.get_body_file()
        local f = path and io.open(path, "rb")
        if f then
            data = f:read("*a")
            f:close()
        end
    end
    return data and ngx.decode_args(data, 0) or {}
end

local function back_to_dashboard(frontend, params)
    return { redirect_to = frontend .. "/auth/callback?" .. ngx.encode_args(params) }
end

local function signin_error(frontend, message)
    ngx.log(ngx.WARN, "[SAML] sign-in refused: ", message)
    return back_to_dashboard(frontend, { error = message })
end

local function is_true(v) return v == true or v == "t" or v == "true" end

-- The account a validated assertion signs in, per the rules in the header.
-- @return user row (from users), membership | nil, message
local function resolve_account(provider, profile)
    local email = profile.email
    if not email then return nil, "Your identity provider did not send an email address" end
    local domain = email:match("@(.+)$")
    if #provider.email_domains > 0 then
        local ok = false
        for _, d in ipairs(provider.email_domains) do if d == domain then ok = true end end
        if not ok then return nil, "Accounts at " .. tostring(domain) .. " can't sign in with this provider" end
    end

    local ns_id = provider.namespace_id
    local user = db.select("* FROM users WHERE lower(email) = ? LIMIT 1", email)[1]
    if user then
        if not is_true(user.active) then return nil, "This account has been deactivated" end
        if require("helper.admin-check").isPlatformAdmin({ uuid = user.uuid }) then
            return nil, "Platform administrators sign in with their password"
        end
        local other = db.select([[1 FROM namespace_members
            WHERE user_id = ? AND namespace_id <> ? AND status = 'active' LIMIT 1]], user.id, ns_id)
        if #other > 0 then
            return nil, "This account belongs to other workspaces too, so it can't use single sign-on. "
                .. "Sign in with your password instead."
        end
    elseif is_true(provider.auto_provision) then
        user = require("queries.UserQueries").createOAuthUser({
            uuid = Global.generateUUID(),
            email = email,
            username = email,
            first_name = profile.first_name or "",
            last_name = profile.last_name or "",
            password = Global.generateRandomPassword(),
            role = "buyer",
            oauth_provider = "saml",
            oauth_id = provider.uuid,
            active = true,
        })
    else
        return nil, "You don't have an account yet. Ask a workspace admin to invite you."
    end

    local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
    local membership = db.select("* FROM namespace_members WHERE user_id = ? AND namespace_id = ?", user.id, ns_id)[1]
    if membership and membership.status ~= "active" then
        return nil, "Your access to this workspace is " .. tostring(membership.status)
    end
    if not membership then
        if not is_true(provider.auto_provision) then
            return nil, "You aren't a member of this workspace. Ask a workspace admin to invite you."
        end
        local role_ids
        if provider.default_role then
            local role = db.select("id FROM namespace_roles WHERE namespace_id = ? AND role_name = ?",
                ns_id, provider.default_role)[1]
            role_ids = role and { role.id } or nil
        end
        membership = NamespaceMemberQueries.create({
            namespace_id = ns_id, user_id = user.id, status = "active", role_ids = role_ids,
        })
    end
    return user, membership
end

local function issue_token(self, user, membership, namespace_id)
    local UserQueries = require("queries.UserQueries")
    local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
    local full = UserQueries.show(user.uuid)
    if not full then return nil end
    local roles = {}
    for _, role in ipairs(full.roles or {}) do
        roles[#roles + 1] = { id = role.id, role_id = role.role_id,
            role_name = role.name or role.role_name, name = role.name or role.role_name }
    end
    local namespace = db.select("* FROM namespaces WHERE id = ?", namespace_id)[1]
    local member_roles = NamespaceMemberQueries.getRoles(membership.id)
    local token = require("helper.jwt-helper").generateNamespaceToken(full, namespace, membership, {
        user_roles = roles,
        namespace_roles = member_roles,
        namespace_permissions = NamespaceMemberQueries.getPermissions(membership.id),
    })
    pcall(require("queries.NamespaceQueries").updateLastActiveNamespace, user.id, namespace_id)
    local ua = ngx.req.get_headers()["user-agent"]
    local ok, rt = pcall(require("helper.refresh-token").create, user.id, ua and ua:sub(1, 255))
    if ok and rt then pcall(require("helper.auth-cookies").set, self, rt) end
    return token, full
end

local function with_sp(p)
    p.sp = sp_urls(p)
    return p
end

local function guard(action, fn)
    return NamespaceMiddleware.requirePermission("namespace", action, fn)
end

return function(app)
    app:get("/auth/saml/discover", RateLimit.wrap(SSO_LIMIT, function(self)
        local rows
        if self.params.email then
            local domain = tostring(self.params.email):lower():match("@([%w%.%-]+)$")
            rows = Q.findByEmailDomain(domain)
        else
            rows = Q.findByNamespaceSlug(self.params.workspace)
        end
        local base = api_base()
        local out = setmetatable({}, cjson.array_mt)
        for _, r in ipairs(rows) do
            out[#out + 1] = { id = r.uuid, name = r.name, workspace = r.namespace_name,
                login_url = base .. "/auth/saml/" .. r.uuid .. "/login" }
        end
        return { json = { success = true, data = out } }
    end))

    app:get("/auth/saml/:id/metadata", function(self)
        local p = Q.findPublic(self.params.id)
        if not p then return { status = 404, json = { error = "Unknown SAML provider" } } end
        local urls = sp_urls(p)
        return { layout = false, content_type = "application/samlmetadata+xml",
            SP.metadata({ sp_entity_id = urls.sp_entity_id, acs_url = urls.acs_url }) }
    end)

    app:get("/auth/saml/:id/login", RateLimit.wrap(SSO_LIMIT, function(self)
        local p = Q.findPublic(self.params.id)
        local frontend = trusted_frontend(self.params.frontend_url) or default_frontend()
        if not p then return signin_error(frontend, "This single sign-on link is no longer active") end
        local urls = sp_urls(p)
        local from = type(self.params.from) == "string" and self.params.from:match("^/[^/\\]") and self.params.from
            or nil
        local url, request_id, err = SP.authn_redirect_url({
            idp_sso_url = p.idp_sso_url, acs_url = urls.acs_url, sp_entity_id = urls.sp_entity_id,
        })
        if not url then return signin_error(frontend, err) end
        set_cookie(encode_state({ rid = request_id, pid = p.uuid, fe = frontend, from = from,
            exp = ngx.time() + STATE_TTL }), STATE_TTL)
        return { redirect_to = url }
    end))

    app:post("/auth/saml/:id/acs", RateLimit.wrap(SSO_LIMIT, function(self)
        local p = Q.findPublic(self.params.id)
        local state = decode_state(ngx.var["cookie_" .. STATE_COOKIE])
        if state and state.pid ~= self.params.id then state = nil end
        local frontend = state and trusted_frontend(state.fe) or default_frontend()
        set_cookie("", 0)
        if not p then return signin_error(frontend, "This single sign-on provider is no longer active") end

        local urls = sp_urls(p)
        local args = post_args()
        local result, err = SP.validate_response(args.SAMLResponse, {
            idp_entity_id = p.idp_entity_id,
            idp_x509_cert = p.idp_x509_cert,
            sp_entity_id = urls.sp_entity_id,
            acs_url = urls.acs_url,
            request_id = state and state.rid,
            allow_idp_initiated = is_true(p.allow_idp_initiated),
        })
        if not result then return signin_error(frontend, "Single sign-on failed: " .. err) end
        if not Q.consumeAssertion(p.id, result.assertion_id, result.expires_at) then
            return signin_error(frontend, "Single sign-on failed: this sign-in response was already used")
        end

        local profile = SP.profile(result, p.attribute_mapping)
        local user, membership = resolve_account(p, profile)
        if not user then return signin_error(frontend, membership) end
        local token, full = issue_token(self, user, membership, p.namespace_id)
        if not token then return signin_error(frontend, "Could not load your account") end

        Q.recordLogin(p.id)
        pcall(function()
            require("lib.user-activity").auth("login", { method = "saml", user = full })
        end)
        return back_to_dashboard(frontend, {
            saml_code = Q.issueLoginCode(token), redirect = state and state.from or "/dashboard",
        })
    end))

    app:post("/auth/saml/exchange", RateLimit.wrap(SSO_LIMIT, function(self)
        local body = sdk.body(self) or {}
        local token = Q.redeemLoginCode(body.code or self.params.code)
        if not token then
            return { status = 400, json = { error = "This sign-in link has expired. Please sign in again." } }
        end
        return { json = { success = true, token = token } }
    end))

    -- ── Workspace admin ────────────────────────────────────────────────
    app:get("/api/v2/sso/saml/providers", guard("read", function(self)
        local list = Q.list(self.namespace.id)
        for _, p in ipairs(list) do with_sp(p) end
        return sdk.ok(list)
    end))

    app:post("/api/v2/sso/saml/providers", guard("manage", function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local p, msg = Q.create(self.namespace.id, body)
        if not p then return sdk.error(422, msg) end
        return sdk.created(with_sp(p))
    end))

    app:get("/api/v2/sso/saml/providers/:id", guard("read", function(self)
        local p = Q.find(self.namespace.id, self.params.id)
        if not p then return sdk.not_found("SAML provider") end
        return sdk.ok(with_sp(p))
    end))

    app:put("/api/v2/sso/saml/providers/:id", guard("manage", function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local p, msg = Q.update(self.namespace.id, self.params.id, body)
        if msg then return sdk.error(422, msg) end
        if not p then return sdk.not_found("SAML provider") end
        return sdk.ok(with_sp(p))
    end))

    app:delete("/api/v2/sso/saml/providers/:id", guard("manage", function(self)
        if not Q.delete(self.namespace.id, self.params.id) then return sdk.not_found("SAML provider") end
        return sdk.ok()
    end))

    app:post("/api/v2/sso/saml/metadata/parse", guard("manage", function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local fields, perr = SP.parse_idp_metadata(body.xml)
        if not fields then return sdk.error(422, "Couldn't read the IdP metadata: " .. tostring(perr)) end
        return sdk.ok(fields)
    end))
end
