-- Prometheus metrics for Property Deals (scraped at /metrics with the rest of
-- OpsAPI; dashboard: sre/grafana/dashboards/property-deals.json). Registered on
-- first use in each worker; a no-op where metrics are off (dev, lua_code_cache off).
--   gauges   property_deals_tasks_open / _tasks_overdue / _approvals_pending / _money_at_risk {namespace}
--            property_deals_deals_active {namespace, health}
--   counters property_deals_sla_events_total {namespace, level}            warned | overdue | escalated
--            property_deals_agent_runs_total {namespace, agent, status}     succeeded | failed | cancelled
--            property_deals_agent_cost_usd_total {namespace, agent}
local db = require("lapis.db")
local U = require("property_deals.util")

local M = {}

local cache = package.loaded._property_deals_metrics or {}
package.loaded._property_deals_metrics = cache

local function prom()
    local ok, pm = pcall(require, "lib.prometheus_metrics")
    if ok and pm.is_initialized and pm.is_initialized() then return pm.get_prometheus() end
    return nil
end

local function metric(kind, name, help, labels)
    if cache[name] then return cache[name] end
    local p = prom()
    if not p then return nil end
    local ok, m = pcall(p[kind], p, name, help, labels)
    if ok and m then cache[name] = m end
    return cache[name]
end

local slugs = {}
local function slug(ns)
    if not slugs[ns] then
        local r = U.one("SELECT slug FROM namespaces WHERE id = ?", ns)
        slugs[ns] = r and r.slug or tostring(ns)
    end
    return slugs[ns]
end

function M.inc(name, help, label_names, labels, by)
    local m = metric("counter", name, help, label_names)
    if m then pcall(m.inc, m, by or 1, labels) end
end

function M.sla(ns, stats)
    for _, level in ipairs({ "warned", "overdue", "escalated" }) do
        if (stats[level] or 0) > 0 then
            M.inc("property_deals_sla_events_total", "SLA steps taken (75/100/125%)", { "namespace", "level" },
                { slug(ns), level }, stats[level])
        end
    end
end

function M.agent_run(ns, agent, status, cost)
    M.inc("property_deals_agent_runs_total", "Agent runs by outcome", { "namespace", "agent", "status" },
        { slug(ns), agent or "unknown", status })
    if cost and cost > 0 then
        M.inc("property_deals_agent_cost_usd_total", "Agent spend in USD", { "namespace", "agent" }, { slug(ns), agent or "unknown" }, cost)
    end
end

--- Point-in-time gauges for one workspace (every minute from jobs/sla_tick.lua).
function M.gauges(ns)
    if not prom() then return end
    local s = slug(ns)
    local t = U.one([[
        SELECT COUNT(*) FILTER (WHERE pd_status NOT IN ('done', 'cancelled'))::int AS open,
               COUNT(*) FILTER (WHERE pd_status NOT IN ('done', 'cancelled') AND due_at < NOW())::int AS overdue
        FROM property_deals_task_details WHERE namespace_id = ?
    ]], ns)
    local a = U.one("SELECT COUNT(*)::int AS n FROM property_deals_approvals WHERE namespace_id = ? AND status = 'pending'", ns)
    local money = U.one("SELECT COALESCE(SUM(money_at_risk), 0)::float AS v FROM property_deals_deals WHERE namespace_id = ? AND status = 'active'", ns)
    local set = function(name, help, value, extra_names, extra)
        local names, labels = { "namespace" }, { s }
        for i, nme in ipairs(extra_names or {}) do names[#names + 1] = nme; labels[#labels + 1] = extra[i] end
        local g = metric("gauge", name, help, names)
        if g then pcall(g.set, g, value, labels) end
    end
    set("property_deals_tasks_open", "Open deal tasks", t.open)
    set("property_deals_tasks_overdue", "Open deal tasks past due", t.overdue)
    set("property_deals_approvals_pending", "Approvals waiting for a person", a.n)
    set("property_deals_money_at_risk", "Late-penalty money at risk on active deals", money.v)
    local by = { green = 0, amber = 0, red = 0 }
    for _, r in ipairs(db.query("SELECT health, COUNT(*)::int AS n FROM property_deals_deals WHERE namespace_id = ? AND status = 'active' GROUP BY health", ns)) do
        if by[r.health] then by[r.health] = r.n end
    end
    for h, v in pairs(by) do set("property_deals_deals_active", "Active deals by health", v, { "health" }, { h }) end
end

return M
