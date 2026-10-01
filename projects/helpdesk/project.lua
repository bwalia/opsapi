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

    -- Tables whose changes are published as events (helpdesk.ticket.created /
    -- updated / deleted) for this and other plugins to subscribe to. `verbs`
    -- add business events: helpdesk.ticket.closed fires when a ticket becomes
    -- closed (created closed, or changed from another status to closed).
    publishes = {
        ticket = { table = "helpdesk_tickets", verbs = { closed = { status = "closed" } } },
        -- opsapi:publishes (make:resource adds entries above this line)
    },

    -- Custom dashboard pages: our own HTML under ui/, shown in a sandboxed
    -- frame; it calls this plugin's API through the page bridge (PLUGINS.md §6.2).
    pages = {
        { key = "overview", label = "Support overview", entry = "ui/overview.html", module = "helpdesk_tickets",
          description = "Open tickets by priority, escalations and quick actions" },
        -- opsapi:pages (make:page adds entries above this line)
    },

    -- Dashboard sidebar: each entry opens a generated list/form page for an
    -- sdk.crud resource, or a custom page. icon = a Lucide icon name (see PLUGINS.md).
    menu = {
        { label = "Support overview", page = "overview", module = "helpdesk_tickets", icon = "LayoutDashboard" },
        { label = "Tickets", resource = "tickets", module = "helpdesk_tickets", icon = "LifeBuoy" },
        -- opsapi:menu (make:resource adds entries above this line)
    },
}
