--[[
    Regression spec: plugin platform (helper.project-loader, helper.plugin-sdk,
    bin/opsapi). Needs the image's Lua deps (lapis, cjson), so run it in the
    container:

        docker exec -w /app opsapi luajit spec/plugin-platform_spec.lua

    Guards the properties that make plugins safe in a multi-tenant deployment:
    input is whitelisted + type-checked, a plugin can't replace a core route
    or squat a core prefix, bad manifests are refused, and the CLI generates
    code that loads.
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path
local APP = io.open("./helper/plugin-sdk.lua") and "." or "lapis"

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local sdk = require("helper.plugin-sdk")
local ProjectLoader = require("helper.project-loader")
local cjson = require("cjson")

print("sdk.validate")
local rules = {
    title = { type = "string", required = true, max = 10 },
    status = { enum = { "open", "closed" } },
    priority = { type = "integer", min = 1, max = 5 },
    email = { type = "email" },
    due = { type = "date" },
    done = { type = "boolean" },
    meta = { type = "json" },
}
local clean, errs = sdk.validate({ title = "  Hi  ", priority = "3", done = "true", evil = "x", namespace_id = 9 }, rules)
check("valid input passes", clean ~= nil, errs and cjson.encode(errs))
check("strings are trimmed", clean and clean.title == "Hi")
check("numeric strings coerced", clean and clean.priority == 3)
check("'true' coerced to boolean", clean and clean.done == true)
check("unknown keys dropped (no mass assignment)", clean and clean.evil == nil and clean.namespace_id == nil)

clean, errs = sdk.validate({ status = "bogus", priority = 2.5, email = "nope", due = "1/2/2026", meta = "x" }, rules)
check("invalid input rejected", clean == nil)
check("required reported", errs and errs.title == "is required")
check("enum enforced", errs and errs.status and errs.status:find("one of"))
check("integer enforced", errs and errs.priority == "must be a whole number")
check("email pattern", errs and errs.email == "must be a valid email")
check("date pattern", errs and errs.due == "must be a valid date")
check("json must be a table", errs and errs.meta ~= nil)

clean = sdk.validate({ title = string.rep("a", 11) }, rules)
check("max length", clean == nil)
clean = sdk.validate({ priority = 9, title = "x" }, rules)
check("numeric max", clean == nil)
clean = sdk.validate({ priority = 2147483648, title = "x" }, { priority = { type = "integer" }, title = rules.title })
check("integer beyond Postgres INTEGER rejected", clean == nil)

clean, errs = sdk.validate({ priority = 2 }, rules, true)
check("partial update skips absent required fields", clean and clean.priority == 2, errs and cjson.encode(errs))
clean = sdk.validate({ title = cjson.null }, rules, true)
check("partial update: null on required rejected", clean == nil)
clean = sdk.validate({ priority = cjson.null, due = "" }, rules, true)
check("null / empty clears optional fields", clean and clean.priority == sdk.db.NULL and clean.due == sdk.db.NULL)

print("project-loader: manifests")
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp)
local function manifest(src)
    local path = tmp .. "/project.lua"
    local f = assert(io.open(path, "w"))
    f:write(src)
    f:close()
    return ProjectLoader.loadManifest(path, tmp)
end
local m, err = manifest('return { code = "my-plugin", name = "Mine" }')
check("valid manifest loads", m ~= nil, err)
check("code normalised", m and m.code == "my_plugin")
check("default api_prefix", m and m.api_prefix == "/api/v2/my-plugin")
check("default sdk_version", m and m.sdk_version == 1)
check("bad code refused", manifest('return { code = "9x", name = "x" }') == nil)
check("newer SDK refused", manifest('return { code = "x", name = "x", sdk_version = 99 }') == nil)
check("module without machine_name refused", manifest('return { code = "x", name = "x", modules = { { name = "y" } } }') == nil)
check("api_prefix outside /api refused", manifest('return { code = "x", name = "x", api_prefix = "/" }') == nil)
check("menu entry needs a declared module",
    manifest('return { code = "x", name = "x", menu = { { label = "L", resource = "r" } } }') == nil)
check("menu entry module must be one of the plugin's",
    manifest('return { code = "x", name = "x", modules = { { machine_name = "x_a" } }, '
        .. 'menu = { { label = "L", resource = "r", module = "crm_accounts" } } }') == nil)
check("valid menu entry loads",
    manifest('return { code = "x", name = "x", modules = { { machine_name = "x_a" } }, '
        .. 'menu = { { label = "L", resource = "r", module = "x_a" } } }') ~= nil)
check("built-in feature code reserved", ProjectLoader.isReservedCode("crm"))
check("fresh code not reserved", not ProjectLoader.isReservedCode("helpdesk"))

print("project-loader: routes")
local app = require("lapis").Application()
app:get("/api/v2/core/thing", function() end)
m = manifest('return { code = "probe", name = "Probe" }')
local proxy = ProjectLoader.createPrefixedApp(app, "/api/v2/core", m)
local ok, perr = pcall(proxy.get, proxy, "/thing", function() end)
check("replacing a core route is refused", not ok and tostring(perr):find("already registered"))
ok = pcall(proxy.post, proxy, "/thing", function() end)
check("a new verb on the path is allowed", ok)
proxy = ProjectLoader.createPrefixedApp(app, "/api/v2/probe", m)
ok = pcall(proxy.get, proxy, "/items", function() end)
check("own route registers", ok and m.routes[#m.routes].path == "/api/v2/probe/items")

os.execute("mkdir -p " .. tmp .. "/api")
local f = assert(io.open(tmp .. "/api/a.lua", "w"))
f:write('return function(app) app:get("/x", function() end) end')
f:close()
m = manifest('return { code = "squat", name = "Squat", api_prefix = "/api/v2/core" }')
ProjectLoader.loadRoutes(app, m)
check("squatting a core prefix is refused", m.errors[1] and m.errors[1]:find("already used"), m.errors[1])
check("... and nothing was registered", #m.routes == 0)

print("sdk.crud: dashboard page schema")
m = manifest('return { code = "pages", name = "Pages" }')
proxy = ProjectLoader.createPrefixedApp(app, "/api/v2/pages", m)
sdk.crud(proxy, "/things", {
    table = "pages_things",
    module = "pages_things",
    fields = {
        b = { type = "boolean" },
        a = { type = "string", required = true, label = "Alpha" },
        z = { type = "text" },
        s = { enum = { "x", "y" } },
    },
    filterable = { "a", "b", "s" },
    ui = { form = { "z" } },
    only = { "list", "show", "create" },
})
local page = m.resources.things
check("crud resource recorded on the plugin", page ~= nil)
local names = {}
for i, f in ipairs(page and page.fields or {}) do names[i] = f.name end
check("form order: ui.form, then required, then by name", table.concat(names, ",") == "z,a,b,s", table.concat(names, ","))
check("field label override", page and page.fields[2].label == "Alpha")
check("api_path includes the plugin prefix", page and page.api_path == "/api/v2/pages/things")
local filters = {}
for i, f in ipairs(page and page.filters or {}) do filters[i] = f.name end
check("only closed-set fields become filters", table.concat(filters, ",") == "b,s", table.concat(filters, ","))
check("default columns skip text fields", page and table.concat(page.columns, ",") == "a,b,s")
check("actions follow `only`", page and page.actions.create and not page.actions.update and not page.actions.delete)

print("plugin events")
local PluginEvents = require("helper.plugin-events")
local seen_entities, seen_tables, catalog_ok = {}, {}, true
for _, e in ipairs(PluginEvents.CATALOG) do
    if seen_entities[e.entity] or seen_tables[e.table] then catalog_ok = false end
    seen_entities[e.entity], seen_tables[e.table] = true, true
end
check("catalog: one entity per table", catalog_ok)

local function events_plugin(files)
    os.execute("rm -rf " .. tmp .. "/ev && mkdir -p " .. tmp .. "/ev/events")
    for name, src in pairs(files) do
        local fh = assert(io.open(tmp .. "/ev/events/" .. name .. ".lua", "w"))
        fh:write(src)
        fh:close()
    end
    local fh = assert(io.open(tmp .. "/ev/project.lua", "w"))
    fh:write('return { code = "evp", name = "Ev", publishes = { thing = "evp_things" } }')
    fh:close()
    local em = assert(ProjectLoader.loadManifest(tmp .. "/ev/project.lua", tmp .. "/ev"))
    return PluginEvents.loadSubscribers(em)
end
local subs, errs = events_plugin({
    billing = 'return { ["invoice.updated"] = function() end, ["crm.lead.*"] = function() end }',
})
check("subscriber = <code>.<file>", subs["evp.billing"] and subs["evp.billing"]["invoice.updated"] ~= nil)
check("wildcard subscriptions allowed", subs["evp.billing"] and subs["evp.billing"]["crm.lead.*"] ~= nil)
check("valid events file has no errors", #errs == 0, errs[1])
subs, errs = events_plugin({ bad = 'return { ["Invoice Updated"] = function() end }' })
check("bad event name refused", #errs == 1 and next(subs) == nil)
subs, errs = events_plugin({ bad = 'return { ["invoice.updated"] = "nope" }' })
check("non-function handler refused", #errs == 1)
subs, errs = events_plugin({ bad = 'return 42' })
check("events file must return a table", #errs == 1)
check("manifest publishes validated",
    manifest('return { code = "x", name = "x", publishes = { ["Bad Name"] = "t" } }') == nil)

print("business events (verbs)")
local verbs_ok = true
for _, src in ipairs(PluginEvents.CATALOG) do
    if PluginEvents.checkVerbs(src.verbs) then verbs_ok = false end
end
check("every core verb is valid", verbs_ok)
check("verb condition required", PluginEvents.checkVerbs({ closed = {} }) ~= nil)
check("base actions can't be verbs", PluginEvents.checkVerbs({ updated = { status = "x" } }) ~= nil)
check("verb values: scalars or a list", PluginEvents.checkVerbs({ done = { status = { "a", "b" }, flag = true } }) == nil
    and PluginEvents.checkVerbs({ done = { status = { a = 1 } } }) ~= nil)
check("bad verb column refused", PluginEvents.checkVerbs({ done = { ["status; drop"] = "x" } }) ~= nil)
local em = manifest('return { code = "vb", name = "V", publishes = { ticket = { table = "vb_tickets", '
    .. 'verbs = { closed = { status = "closed" } } }, note = "vb_notes" } }')
check("publishes: long form with verbs", em and em.publishes.ticket.table == "vb_tickets"
    and em.publishes.ticket.verbs.closed.status == "closed")
check("publishes: short form normalised", em and em.publishes.note.table == "vb_notes" and next(em.publishes.note.verbs) == nil)
check("publishes: bad verb refused", manifest('return { code = "vb", name = "V", publishes = { t = { table = "vb_t", '
    .. 'verbs = { deleted = { status = "x" } } } } }') == nil)
local evs = PluginEvents.entityEvents("invoice", { paid = {}, sent = {} })
check("entityEvents: base actions then sorted verbs",
    table.concat(evs, ",") == "invoice.created,invoice.updated,invoice.deleted,invoice.paid,invoice.sent")
local trig = io.open("helper/plugin-events.lua"):read("*a")
check("trigger fires a verb only when the row enters its state",
    trig:find("WHERE opsapi_event_match(d, v.value)", 1, true)
    and trig:find("AND (old_d IS NULL OR NOT opsapi_event_match(old_d, v.value))", 1, true))
check("verbs are part of the trigger call (changes recreate it)", trig:find("d.escape_literal(s.verbs_text)", 1, true) ~= nil)
check("a verb subscription installs the trigger", trig:find("AND s.verbs ? substr(sub.event, length(s.entity) + 2)", 1, true) ~= nil)

check("sdk.emit refuses core events", not pcall(PluginEvents.emit, 1, "invoice.paid", {}))
check("sdk.emit refuses nested core entities", not pcall(PluginEvents.emit, 1, "crm.lead.hot", {}))
check("sdk.emit refuses wildcards", not pcall(PluginEvents.emit, 1, "evp.thing.*", {}))

print("workspace webhooks: URL policy + signing")
local Webhooks = require("lib.outbound-webhooks")
local function url_ok(u) return (Webhooks.parseUrl(u)) ~= nil end
check("https public URL accepted", url_ok("https://hooks.example.com/opsapi?x=1"))
check("path defaults to /", (Webhooks.parseUrl("https://example.com") or {}).path == "/")
check("custom port kept", (Webhooks.parseUrl("https://example.com:8443/h") or {}).port == 8443)
check("http refused", not url_ok("http://example.com/h"))
check("credentials refused", not url_ok("https://user:pw@example.com/h"))
check("cloud metadata IP refused", not url_ok("https://169.254.169.254/latest/meta-data"))
check("loopback refused", not url_ok("https://127.0.0.1/h"))
check("private 10/8 refused", not url_ok("https://10.1.2.3/h"))
check("private 172.16/12 refused", not url_ok("https://172.20.0.1/h"))
check("private 192.168/16 refused", not url_ok("https://192.168.1.10/h"))
check("CGNAT refused", not url_ok("https://100.64.0.1/h"))
check("localhost refused", not url_ok("https://localhost/h"))
check("cluster names refused", not url_ok("https://api.default.svc/h") and not url_ok("https://x.cluster.local/h"))
check("dotless names refused", not url_ok("https://webhook-rx:8080/h"))
check("IPv6 literal refused", not url_ok("https://[::1]/h"))
check("public IP literal accepted", url_ok("https://8.8.8.8/h"))
check("isPublicIPv4", Webhooks.isPublicIPv4("1.1.1.1") and not Webhooks.isPublicIPv4("0.0.0.0")
    and not Webhooks.isPublicIPv4("172.31.255.255") and Webhooks.isPublicIPv4("172.32.0.1")
    and not Webhooks.isPublicIPv4("224.0.0.1") and not Webhooks.isPublicIPv4("999.1.1.1"))
check("signature matches an independent HMAC-SHA256 (Python)",
    Webhooks.sign("whsec_test", "1700000000", '{"type":"webhook.test"}')
        == "sha256=cf7d053522b08300fae293c3bcbf4e183d4a9538620c18dc9a46d063337936fa")
local body = cjson.decode(Webhooks.payload({ id = "e1", type = "invoice.updated", created_at = "2026-09-30T07:00:00Z",
    namespace = { id = "n1", slug = "acme" }, data = { uuid = "i1" }, changes = { status = { from = "sent", to = "paid" } } }))
check("payload shape", body.id == "e1" and body.type == "invoice.updated" and body.namespace.slug == "acme"
    and body.data.object.uuid == "i1" and body.data.changes.status.to == "paid")
check("'webhook' and 'core' are reserved plugin codes",
    ProjectLoader.isReservedCode("webhook") and ProjectLoader.isReservedCode("core"))
local modules_ok = true
for _, e in ipairs(PluginEvents.CATALOG) do
    if type(e.module) ~= "string" then modules_ok = false end
end
check("every core entity names its RBAC module", modules_ok)

print("bin/opsapi")
local dir = tmp .. "/plugins"
local cli = "luajit " .. APP .. "/bin/opsapi"
local function run(args)
    return os.execute(cli .. " " .. args .. " --dir " .. dir .. " >/dev/null 2>&1")
end
local function succeeded(r) return r == 0 or r == true end
check("plugin:new", succeeded(run("plugin:new help-desk")))
check("plugin:new refuses a built-in code", not succeeded(run("plugin:new crm")))
check("make:resource", succeeded(run("make:resource help-desk ticket title:string:required due:date done:boolean")))
check("make:resource rejects unknown type", not succeeded(run("make:resource help-desk thing a:blob")))
check("make:resource rejects reserved column", not succeeded(run("make:resource help-desk thing id:integer")))
local plugin = dir .. "/help-desk"
check("generated api compiles", loadfile(plugin .. "/api/tickets.lua") ~= nil)
local h = io.popen("ls " .. plugin .. "/migrations/*_create_help_desk_tickets.lua")
local mig = h:read("*l")
h:close()
check("generated migration compiles", mig and loadfile(mig) ~= nil)
m = ProjectLoader.loadManifest(plugin .. "/project.lua", plugin)
check("RBAC module added to manifest", m and m.modules[1] and m.modules[1].machine_name == "help_desk_tickets")
check("menu entry added to manifest", m and m.menu[1] and m.menu[1].resource == "tickets"
    and m.menu[1].module == "help_desk_tickets")
local api_src = io.open(plugin .. "/api/tickets.lua"):read("*a")
check("generated api declares its dashboard page", api_src:find("ui = {", 1, true) ~= nil)
check("no unfilled template placeholders", not api_src:find("{{", 1, true)
    and not io.open(mig):read("*a"):find("{{", 1, true))
check("plugin:check passes", succeeded(run("plugin:check")))
m = ProjectLoader.loadManifest(plugin .. "/project.lua", plugin)
check("make:resource publishes the table's events", m and m.publishes.ticket.table == "help_desk_tickets")
check("make:listener", succeeded(run("make:listener help-desk invoice.updated")))
check("listener file compiles", loadfile(plugin .. "/events/on_invoice_updated.lua") ~= nil)
check("listener registers its event",
    (PluginEvents.loadSubscribers(m))["help_desk.on_invoice_updated"] ~= nil)
check("make:listener refuses a malformed event", not succeeded(run("make:listener help-desk Invoice")))
check("make:job", succeeded(run("make:job help-desk close-stale 2h")))
local made = require("helper.plugin-jobs").loadJobs(m)["help_desk.close_stale"]
check("job file loads with its schedule", made ~= nil and made.every == 7200)
check("make:job refuses a bad schedule", not succeeded(run("make:job help-desk tick 5s")))
check("plugin:check passes with jobs", succeeded(run("plugin:check")))

print("custom pages")
check("make:page", succeeded(run('make:page help-desk overview "Desk overview"')))
m = ProjectLoader.loadManifest(plugin .. "/project.lua", plugin)
local pg = m and m.pages.overview
check("page registered in the manifest", pg and pg.entry == "ui/overview.html" and pg.module == "help_desk_tickets"
    and pg.label == "Desk overview")
local page_menu
for _, e in ipairs(m and m.menu or {}) do if e.page == "overview" then page_menu = e end end
check("page has a sidebar entry", page_menu ~= nil)
local html = io.open(plugin .. "/ui/overview.html"):read("*a")
check("page loads the bridge", html:find("/plugin-ui/_sdk/opsapi-ui.js", 1, true) and html:find("OpsAPI.connect()", 1, true))
check("page lists the plugin's first resource", html:find("const RESOURCE = 'tickets'", 1, true) ~= nil)
check("no unfilled page placeholders", not html:find("{{", 1, true))
check("make:page refuses a duplicate", not succeeded(run("make:page help-desk overview")))
check("plugin:check passes with a page", succeeded(run("plugin:check")))
check("page needs an existing entry path",
    manifest('return { code = "pg", name = "P", modules = { { machine_name = "pg_x" } }, '
        .. 'pages = { { key = "a", label = "A", entry = "ui/../secret.html", module = "pg_x" } } }') == nil)
check("page needs a declared module",
    manifest('return { code = "pg", name = "P", pages = { { key = "a", label = "A", entry = "ui/a.html", module = "nope" } } }') == nil)
check("page api prefixes must be /api/...",
    manifest('return { code = "pg", name = "P", modules = { { machine_name = "pg_x" } }, pages = { { key = "a", label = "A", '
        .. 'entry = "ui/a.html", module = "pg_x", api = { "https://evil.example" } } } }') == nil)
check("menu can't link to an unknown page",
    manifest('return { code = "pg", name = "P", modules = { { machine_name = "pg_x" } }, '
        .. 'menu = { { label = "A", page = "nope", module = "pg_x" } } }') == nil)
check("menu entry is a resource or a page, not both",
    manifest('return { code = "pg", name = "P", modules = { { machine_name = "pg_x" } }, pages = { { key = "a", '
        .. 'label = "A", entry = "ui/a.html", module = "pg_x" } }, menu = { { label = "A", page = "a", resource = "a", module = "pg_x" } } }') == nil)
local function src_of(path) local f = io.open(path); local t = f and f:read("*a"); if f then f:close() end; return t or "" end
check("ui files are public (no JWT), the API isn't", src_of("app.lua"):find('uri:match("^/plugin%-ui/")', 1, true) ~= nil)
local routes_src = src_of("routes/plugins.lua")
check("ui route only serves the plugin's ui/ folder through the path guard",
    routes_src:find("ProjectLoader.safeUiPath(self.params.splat)", 1, true)
    and routes_src:find('m.path .. "/ui/" .. rel', 1, true))
check("page bridge files ship with the image", src_of("static/plugin-ui/opsapi-ui.js"):find("OpsAPI", 1, true)
    and src_of("static/plugin-ui/opsapi-ui.css"):find("--ops-primary", 1, true)
    and src_of("Dockerfile"):find("\nCOPY static /app/static\n", 1, true))
-- API keys: a key scoped for a plugin's module may reach the plugin's prefix.
local ApiKey = require("helper.api-key")
local real_registered = ProjectLoader.getRegistered
ProjectLoader.getRegistered = function()
    return { { code = "helpdesk", api_prefix = "/api/v2/helpdesk", modules = { { machine_name = "helpdesk_tickets" } } } }
end
local key = { scopes = { helpdesk_tickets = { "read" } } }
check("api key: plugin module scope opens the plugin's prefix", ApiKey.permits_uri(key, "/api/v2/helpdesk/tickets"))
check("api key: ...not other plugins or core modules", not ApiKey.permits_uri(key, "/api/v2/helpdesk-x/tickets")
    and not ApiKey.permits_uri(key, "/api/v2/customers/1"))
check("api key: core scopes still match the URL segment", ApiKey.permits_uri({ scopes = { customers = { "read" } } }, "/api/v2/customers/1"))
check("api key: no scope, no access", not ApiKey.permits_uri({ scopes = {} }, "/api/v2/helpdesk/tickets"))
ProjectLoader.getRegistered = real_registered

local safe = ProjectLoader.safeUiPath
check("ui paths: nested files allowed", safe("assets/app.js") == "assets/app.js")
check("ui paths: traversal, hidden, absolute and odd characters refused",
    not safe("../project.lua") and not safe("a/../../x") and not safe(".env") and not safe("a/.git/x")
    and not safe("/etc/passwd") and not safe("a//b") and not safe("a b.html") and not safe("a%2e%2e") and not safe(""))

print("plugins per workspace: settings, on/off, jobs")
local function read_file(path)
    local f = assert(io.open(APP .. "/" .. path))
    local src = f:read("*a")
    f:close()
    return src
end
local ok_settings = manifest([[return { code = "x", name = "x", default_enabled = false, settings = {
    days = { type = "integer", default = 14, min = 1 }, token = { type = "string", secret = true },
    hook = { type = "url" } } }]])
check("settings + default_enabled load", ok_settings ~= nil and ok_settings.default_enabled == false
    and ok_settings.settings.days.default == 14)
check("settings default to {}", manifest('return { code = "x", name = "x" }').settings ~= nil)
check("default_enabled must be a boolean", manifest('return { code = "x", name = "x", default_enabled = "no" }') == nil)
check("setting names are lowercase", manifest('return { code = "x", name = "x", settings = { Bad = {} } }') == nil)
check("setting types are checked", manifest('return { code = "x", name = "x", settings = { a = { type = "json" } } }') == nil)
check("a default must pass its own rules",
    manifest('return { code = "x", name = "x", settings = { a = { type = "integer", min = 5, default = 1 } } }') == nil)
check("secrets: text-like only, no default",
    manifest('return { code = "x", name = "x", settings = { a = { type = "integer", secret = true } } }') == nil
    and manifest('return { code = "x", name = "x", settings = { a = { secret = true, default = "x" } } }') == nil)
check("url type validates", sdk.validate({ u = "https://hooks.example.com/x" }, { u = { type = "url" } }) ~= nil
    and sdk.validate({ u = "javascript:alert(1)" }, { u = { type = "url" } }) == nil)

local PluginJobs = require("helper.plugin-jobs")
local def = PluginJobs.check({ every = "15m", run = function() end })
check("job: every parsed", def and def.every == 900 and def.scope == "workspace")
check("job: under a minute refused", PluginJobs.check({ every = "30s", run = function() end }) == nil)
check("job: run function required", PluginJobs.check({ every = "1h" }) == nil)
check("job: at needs whole days", PluginJobs.check({ every = "1h", at = "03:00", run = function() end }) == nil)
check("job: bad at refused", PluginJobs.check({ every = "1d", at = "25:00", run = function() end }) == nil)
check("job: bad scope refused", PluginJobs.check({ every = "1h", scope = "tenant", run = function() end }) == nil)
local daily = PluginJobs.check({ every = "1d", at = "03:00", run = function() end })
local day = 86400
check("job: at runs at that time today when it's still ahead", PluginJobs.nextRun(daily, 2 * 3600) == 3 * 3600)
check("job: ...else tomorrow", PluginJobs.nextRun(daily, 4 * 3600) == day + 3 * 3600)
check("job: every 2d at keeps the time of day",
    PluginJobs.nextRun(PluginJobs.check({ every = "2d", at = "03:00", run = function() end }), 4 * 3600)
        == 2 * day + 3 * 3600)
check("job: every is the gap after a run", PluginJobs.nextRun(def, 1000) == 1900)

os.execute("mkdir -p " .. tmp .. "/jobs")
local jf = assert(io.open(tmp .. "/jobs/good_job.lua", "w"))
jf:write('return { every = "1h", run = function(job) end }')
jf:close()
jf = assert(io.open(tmp .. "/jobs/bad.lua", "w"))
jf:write('return { every = "soon", run = function() end }')
jf:close()
local jobs, job_errors = PluginJobs.loadJobs({ code = "x", path = tmp })
check("jobs files load as <code>.<file>", jobs["x.good_job"] ~= nil and jobs["x.good_job"].plugin == "x")
check("a broken jobs file is reported", #job_errors == 1 and job_errors[1]:find("jobs/bad.lua", 1, true))

-- "Off" must be a hard switch everywhere work happens for a workspace.
local ns_mw, events_src = read_file("middleware/namespace.lua"), read_file("helper/plugin-events.lua")
check("off: plugin routes 404 (requireNamespace gate)", ns_mw:find("handler = plugin_gate(handler)", 1, true)
    and ns_mw:find("PLUGIN_DISABLED", 1, true))
local _, trigger_checks = events_src:gsub("opsapi_plugin_enabled%(split_part%(subscriber", "")
check("off: no event deliveries (trigger + emit)", trigger_checks >= 3, trigger_checks)
check("off: no job runs (claim + seeding)", read_file("helper/plugin-jobs.lua"):find(
    "AND (namespace_id IS NULL OR opsapi_plugin_enabled(split_part(job, '.', 1), namespace_id))", 1, true))
check("off: pages + sidebar", read_file("routes/plugins.lua"):find("PluginWorkspaces.isEnabled(m.code", 1, true)
    and read_file("queries/MenuQueries.lua"):find("plugins_off[plugin_code]", 1, true))
check("settings: empty table stored as an object, not []",
    read_file("helper/plugin-workspaces.lua"):find('next(sets) and cjson.encode(sets) or "{}"', 1, true))
check("workspace API guarded by namespace.read / namespace.update",
    read_file("routes/plugins.lua"):find('requirePermission("namespace", "read"', 1, true)
    and read_file("routes/plugins.lua"):find('requirePermission("namespace", "update"', 1, true))
check("sdk.http goes through the SSRF guard", read_file("helper/plugin-sdk.lua"):find(
    'require("lib.outbound-webhooks").request(url', 1, true))

os.execute("rm -rf " .. tmp)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
