--[[
    Hospital / care-home tenant gate
    ================================

    The hospital module's tables had no tenant column and its ~75 routes only
    checked "is logged in": any user of any tenant could read or change any
    patient's care plans, medications, family contacts, etc. by uuid.

    Rather than patching every handler, this registers ONE before_filter that
    runs ahead of every hospital route (current and future):

      /api/v2/patients/<patient_uuid>/<resource>[/<child_uuid>...]
      /api/v2/hospitals/<hospital_uuid>/<resource>[/<child_uuid>...]
      /api/v2/care-plans/due-for-review, /api/v2/dementia/*   (cross-patient lists)

    For each it (1) resolves the caller's namespace (requireNamespace — 400/403
    as usual), (2) checks the hospital module permission for the HTTP verb,
    (3) checks the patient's hospital / the hospital belongs to that namespace,
    and (4) when a child uuid is in the path, that the child row belongs to the
    same patient / hospital. Anything that fails is a 404 (don't leak existence).

    hospitals.namespace_id is the single tenant anchor (migration
    zzh_hospital_namespace_id); everything else hangs off a hospital. A
    hospital with NULL namespace_id is reachable by platform admins only.

    Share-token routes (/api/v2/access/verify, /api/v2/access/my-patients) are
    deliberately NOT gated: they implement explicit cross-user sharing.
]]

local db = require("lapis.db")
local NamespaceMiddleware = require("middleware.namespace")

-- URL resource segment -> table that holds that child, and its parent column.
local PATIENT_CHILDREN = {
    ["care-plans"] = "care_plans",
    ["care-logs"] = "care_logs",
    ["medications"] = "medications",
    ["access-controls"] = "patient_access_controls",
    ["alerts"] = "patient_alerts",
    ["audit-logs"] = "patient_audit_logs",
    ["daily-logs"] = "daily_logs",
    ["dementia-assessments"] = "dementia_assessments",
    ["family-members"] = "family_members",
}
local HOSPITAL_CHILDREN = {
    ["departments"] = "departments",
    ["wards"] = "wards",
    ["alerts"] = "patient_alerts",
}

local ACTION_FOR_METHOD = { GET = "read", HEAD = "read", POST = "create", PUT = "update", PATCH = "update", DELETE = "delete" }
local PERMISSION_MODULE = "hospital_patients"

local NOT_FOUND = { status = 404, json = { error = "Not found" } }

local function one(sql, ...)
    local rows = db.query(sql, ...)
    return rows and rows[1]
end

-- Does the hospital (by internal id) belong to the caller's namespace?
local function hospital_in_scope(self, hospital_id)
    if not hospital_id then return false end
    if self.is_platform_admin then return true end
    return one("SELECT 1 FROM hospitals WHERE id = ? AND namespace_id = ?",
        hospital_id, self.namespace.id) ~= nil
end

-- Child identified by uuid OR numeric id (routes differ) under the same parent.
local function child_belongs(tbl, parent_col, parent_id, child_ref)
    return one("SELECT 1 FROM " .. db.escape_identifier(tbl) ..
        " WHERE (uuid = ? OR id::text = ?) AND " .. db.escape_identifier(parent_col) .. " = ?",
        child_ref, child_ref, parent_id) ~= nil
end

-- Returns an error response table to halt, or nil to let the route run.
local function check(self, uri)
    local kind, parent_uuid, resource, child = uri:match("^/api/v2/(%a+)s/([^/]+)/([%a%-]+)/?([^/]*)")
    local is_list = uri:match("^/api/v2/care%-plans/due%-for%-review") or uri:match("^/api/v2/dementia/")
    if not (is_list or (kind == "patient" and PATIENT_CHILDREN[resource])
            or (kind == "hospital" and HOSPITAL_CHILDREN[resource])) then
        return nil -- not a hospital-module route
    end

    -- (1) namespace context (sets self.namespace, self.is_platform_admin, perms)
    local denied = NamespaceMiddleware.requireNamespace(function() return nil end)(self)
    if denied then return denied end

    -- (2) module permission for this verb
    local action = ACTION_FOR_METHOD[ngx.req.get_method()] or "read"
    if not self.is_platform_admin
        and not NamespaceMiddleware.hasPermission(self, PERMISSION_MODULE, action) then
        return { status = 403, json = { error = "Permission denied", required = PERMISSION_MODULE .. "." .. action } }
    end

    if is_list then return nil end -- the list routes filter by self.namespace.id

    -- (3) parent belongs to this tenant
    local parent_id
    if kind == "patient" then
        local p = one("SELECT id, hospital_id FROM patients WHERE uuid = ?", parent_uuid)
        if not p or not hospital_in_scope(self, p.hospital_id) then return NOT_FOUND end
        parent_id = p.id
    else
        local h = one("SELECT id FROM hospitals WHERE uuid = ?", parent_uuid)
        if not h or not hospital_in_scope(self, h.id) then return NOT_FOUND end
        parent_id = h.id
    end

    -- (4) child row. Word-only segments are sub-collections ("active",
    -- "next-of-kin", "today"); anything else is a record id and must belong
    -- to the same parent — fail closed.
    if child ~= "" and not child:match("^[%a%-]+$") then
        local tbl = kind == "patient" and PATIENT_CHILDREN[resource] or HOSPITAL_CHILDREN[resource]
        if not child_belongs(tbl, kind .. "_id", parent_id, child) then return NOT_FOUND end
    end
    return nil
end

return function(app)
    app:before_filter(function(self)
        local ok, res = pcall(check, self, ngx.var.uri or "")
        if not ok then
            ngx.log(ngx.ERR, "[hospital-scope] ", tostring(res))
            return self:write({ status = 500, json = { error = "Access check failed" } })
        end
        if res then return self:write(res) end
    end)
end
