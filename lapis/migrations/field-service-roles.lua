--[[
    Field Service — operational role seeding (Telecaller / Service Manager / Engineer)

    Backfills the three field-service roles into every existing namespace. New
    namespaces get them from NamespaceRoleQueries.createDefaultRoles. The role
    definitions live in one place (NamespaceRoleQueries.createFieldServiceRoles);
    this migration just applies them to namespaces that predate the feature.

    Idempotent — createFieldServiceRoles skips any role that already exists.
    Feature-gated under FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")

return {
    -- [1] Seed the three roles for all existing namespaces   (885)
    [1] = function()
        local NamespaceRoleQueries = require("queries.NamespaceRoleQueries")
        local namespaces = db.select("id FROM namespaces")
        local total = 0
        for _, ns in ipairs(namespaces) do
            local created = NamespaceRoleQueries.createFieldServiceRoles(ns.id)
            total = total + #created
        end
        print("[FieldService] Seeded field-service roles across " ..
            #namespaces .. " namespace(s): " .. total .. " role(s) created")
    end,
}
