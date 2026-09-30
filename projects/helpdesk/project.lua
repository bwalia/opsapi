-- Helpdesk — OpsAPI plugin manifest (guide: PLUGINS.md in the opsapi repo)
return {
    code = "helpdesk",          -- stable id: keys migrations + RBAC; never rename
    name = "Helpdesk",
    version = "0.1.0",
    description = "Example plugin: tenant-scoped support tickets. Regenerate or delete freely.",
    sdk_version = 1,            -- helper.plugin-sdk version this plugin targets

    -- RBAC modules. On first install admin/owner roles get "manage"; grant
    -- them to other roles from the dashboard's role settings.
    modules = {
        { machine_name = "helpdesk_tickets", name = "Tickets", category = "Helpdesk" },
        -- opsapi:modules (make:resource adds entries above this line)
    },
}
