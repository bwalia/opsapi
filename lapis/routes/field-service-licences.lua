--[[
    Field Service — employee licence routes (Simpro "Licences")

    Endpoints:
    - GET    /api/v2/field-service/employees/:uuid/licences  - An employee's licences
    - POST   /api/v2/field-service/employees/:uuid/licences  - Add one
    - PUT    /api/v2/field-service/licences/:uuid            - Update
    - DELETE /api/v2/field-service/licences/:uuid            - Soft delete

    The portfolio view (who expires soon) is the employee_licences report, so
    there is no separate list-everything endpoint here.

    Gated on the employees module: whoever maintains the staff directory
    maintains the licences on it.
]]

local db = require("lapis.db")
local Http = require("helper.field-service-http")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable = Common.nilify, Common.nullable

local function shape(l)
    return {
        uuid = l.uuid, licence_type = l.licence_type, licence_number = l.licence_number,
        issuing_body = l.issuing_body, issued_on = l.issued_on, expires_on = l.expires_on,
        reminder_days = l.reminder_days, notes = l.notes, attachment_url = l.attachment_url,
        simpro_id = l.simpro_id, simpro_sync_state = l.simpro_sync_state,
        created_at = l.created_at, updated_at = l.updated_at,
    }
end

local FIELDS = { "licence_type", "licence_number", "issuing_body", "issued_on", "expires_on",
                 "notes", "attachment_url" }

local function patch_from(body)
    local patch = {}
    for _, key in ipairs(FIELDS) do
        if body[key] ~= nil then patch[key] = nullable(body[key]) end
    end
    if body.reminder_days ~= nil then
        patch.reminder_days = Common.to_number(body.reminder_days) or 60
    end
    return patch
end

return function(app)
    app:get("/api/v2/field-service/employees/:uuid/licences", Http.guard("employees", "read", function(self)
        local employee_id = Common.resolve_id("employees", self.namespace.id, self.params.uuid)
        if not employee_id then return Http.fail(404, "Employee not found") end
        local rows = db.query([[
            SELECT * FROM employee_licences
            WHERE namespace_id = ? AND employee_id = ? AND deleted_at IS NULL
            ORDER BY expires_on NULLS LAST, licence_type
        ]], self.namespace.id, employee_id)
        local out = {}
        for _, r in ipairs(rows) do table.insert(out, shape(r)) end
        return Http.ok(Common.arr(out))
    end))

    app:post("/api/v2/field-service/employees/:uuid/licences", Http.guard("employees", "update", function(self)
        local employee_id = Common.resolve_id("employees", self.namespace.id, self.params.uuid)
        if not employee_id then return Http.fail(404, "Employee not found") end
        local body = Http.body(self)
        if not nilify(body.licence_type) then return Http.fail(422, "Licence type is required") end

        local row = patch_from(body)
        row.uuid = Common.uuid()
        row.namespace_id = self.namespace.id
        row.employee_id = employee_id
        row.created_by_uuid = Http.actor(self)
        row.simpro_sync_state = "pending"
        return Http.ok(shape(db.insert("employee_licences", row, { returning = "*" })[1]), 201)
    end))

    app:put("/api/v2/field-service/licences/:uuid", Http.guard("employees", "update", function(self)
        local id = Common.resolve_id("employee_licences", self.namespace.id, self.params.uuid)
        if not id then return Http.fail(404, "Licence not found") end
        local patch = patch_from(Http.body(self))
        if next(patch) == nil then return Http.fail(422, "Nothing to update") end
        patch.updated_at = db.raw("NOW()")
        patch.simpro_sync_state = "pending"
        db.update("employee_licences", patch, { id = id })
        return Http.ok(shape(db.query("SELECT * FROM employee_licences WHERE id = ?", id)[1]))
    end))

    app:delete("/api/v2/field-service/licences/:uuid", Http.guard("employees", "update", function(self)
        local id = Common.resolve_id("employee_licences", self.namespace.id, self.params.uuid)
        if not id then return Http.fail(404, "Licence not found") end
        db.update("employee_licences", { deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = id })
        return Http.ok({ message = "Licence removed" })
    end))
end
