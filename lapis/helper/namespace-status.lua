--[[
    Central "is this tenant active?" gate
    =====================================

    Only routes wrapped in NamespaceMiddleware.requireNamespace used to check
    namespaces.status, so ~95 route files (kanban, chat, orders, documents, …)
    kept serving a SUSPENDED / archived / pending tenant. This runs from the
    global before_filter in app.lua for every authenticated request: if the
    request is in the context of a namespace (X-Namespace-Id / X-Namespace-Slug
    header, else the namespace in the JWT) and that namespace is not 'active',
    it's refused with the same 403 requireNamespace returns.

    Still allowed for an inactive namespace: auth, listing/switching your
    namespaces, and invitations. (Nothing suspends tenants automatically —
    reactivation is a platform-admin action; billing routes use
    requireNamespace, which also refuses inactive tenants.)
    Platform admins are exempt (they manage/reactivate tenants); namespace-
    scoped routes still refuse them via requireNamespace.

    API-key principals are checked in requireNamespace / helper.api-key.
]]

local db = require("lapis.db")
local lrucache = require("resty.lrucache")
local AdminCheck = require("helper.admin-check")

local NamespaceStatus = {}

-- ponytail: per-worker cache, so a status change takes up to TTL seconds to
-- apply everywhere; move to ngx.shared + explicit invalidation if that matters.
local TTL = 30
local cache = lrucache.new(5000)

local ALLOWED_WHEN_INACTIVE = {
    "^/auth/",
    "^/api/v2/user/namespaces",
    "^/api/v2/user/invitations",
    "^/api/v2/invitations/",
}

--- Status of a namespace by uuid, slug or numeric id; nil if it doesn't exist.
function NamespaceStatus.lookup(identifier)
    identifier = tostring(identifier)
    local cached = cache:get(identifier)
    if cached ~= nil then return cached or nil end

    local row = db.query([[
        SELECT status FROM namespaces
        WHERE uuid::text = ? OR slug = ? OR id::text = ?
        LIMIT 1
    ]], identifier, identifier, identifier)[1]
    local status = row and row.status or false
    cache:set(identifier, status, TTL)
    return status or nil
end

local function identifier_for(self)
    local h = self.req.headers
    local id = h["x-namespace-id"]
    if id and id ~= "" then return id end
    local slug = h["x-namespace-slug"]
    if slug and slug ~= "" then return slug end
    local ns = self.current_user and self.current_user.namespace
    if type(ns) == "table" then return ns.uuid or ns.slug or ns.id end
    return nil
end

--- nil to continue, or a response table to refuse the request.
function NamespaceStatus.check(self, uri)
    local user = self.current_user
    if not user or user.api_key then return nil end

    local identifier = identifier_for(self)
    if not identifier then return nil end

    local status = NamespaceStatus.lookup(identifier)
    if status == nil or status == "active" then return nil end -- unknown ns: routes 404 as before

    for _, pattern in ipairs(ALLOWED_WHEN_INACTIVE) do
        if uri:match(pattern) then return nil end
    end
    if AdminCheck.isPlatformAdmin(user) then return nil end

    return { status = 403, json = { error = "Namespace is not accessible", status = status } }
end

return NamespaceStatus
