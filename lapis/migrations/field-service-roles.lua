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

    -- [3] Backfill payments + timesheet_approvals onto existing service_manager
    -- roles (892 already ran, so this is a separate step).   (893)
    -- payments: record customer payments on invoices. timesheet_approvals:
    -- approve/reject engineer timesheets. Added only where absent, so an admin's
    -- own settings aren't overwritten.
    [3] = function()
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"payments":["manage"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'service_manager'
              AND NOT (permissions::jsonb ? 'payments')
        ]])
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"timesheet_approvals":["manage"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'service_manager'
              AND NOT (permissions::jsonb ? 'timesheet_approvals')
        ]])
        print("[FieldService] Backfilled service_manager payments/timesheet_approvals grants")
    end,

    -- [4] Backfill the Simpro-aligned grants (asset register, contracts, quotes,
    -- report pack incl. F-Gas, sync connector) onto operational roles in namespaces
    -- created AFTER migrations/simpro-menu.lua [4] ran — e.g. a namespace seeded
    -- from the older createFieldServiceRoles that lacked these modules. Guarded by
    -- the absence of the role's marker grant, so tenants that already have them
    -- (or an admin's customisation) are never clobbered.   (919)
    [4] = function()
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"fs_assets":["create","read","update","delete"],"fs_contracts":["create","read","update"],"fs_quotes":["create","read","update","delete"],"fs_reports":["read"],"simpro_sync":["read"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'service_manager'
              AND NOT (permissions::jsonb ? 'fs_reports')
        ]])
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"fs_assets":["read"],"fs_contracts":["read"],"fs_quotes":["create","read","update"],"fs_reports":["read"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'telecaller'
              AND NOT (permissions::jsonb ? 'fs_reports')
        ]])
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"fs_assets":["read","update"],"fs_contracts":["read"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'engineer'
              AND NOT (permissions::jsonb ? 'fs_assets')
        ]])
        print("[FieldService] Backfilled Simpro-aligned grants onto service_manager/telecaller/engineer")
    end,

    -- [5] Backfill users create/read onto existing service_manager roles so a
    -- manager can onboard staff (the "Add team member" flow creates a login).
    -- Added only where absent, so an admin's customisation isn't overwritten.   (920)
    [5] = function()
        db.query([[
            UPDATE namespace_roles
            SET permissions = (permissions::jsonb || '{"users":["create","read"]}'::jsonb)::text,
                updated_at = NOW()
            WHERE role_name = 'service_manager'
              AND NOT (permissions::jsonb ? 'users')
        ]])
        print("[FieldService] Backfilled service_manager users create/read grant")
    end,
}
