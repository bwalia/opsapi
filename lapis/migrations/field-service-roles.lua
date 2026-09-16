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

    -- [2] Backfill grants onto EXISTING service_manager roles.   (892)
    -- Step [1]/createFieldServiceRoles skip roles that already exist, so later
    -- additions to the seed never reach older tenants. Bring their managers up to
    -- date: invoices -> manage (so they can send/email/void, not just create), and
    -- products -> manage (the catalog). Guarded so we only upgrade roles still on
    -- the old defaults, never clobbering an admin's own customisation.
    [2] = function()
        -- invoices: give update/manage where the role still can't send an invoice.
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"invoices":["manage"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'service_manager'
              AND permissions::jsonb ? 'invoices'
              AND NOT (permissions::jsonb->'invoices' @> '["update"]'::jsonb)
              AND NOT (permissions::jsonb->'invoices' @> '["manage"]'::jsonb)
        ]])
        -- products: add manage only where the role has no products grant at all.
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"products":["manage"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'service_manager'
              AND NOT (permissions::jsonb ? 'products')
        ]])
        print("[FieldService] Backfilled service_manager invoices/products grants")
    end,
}
