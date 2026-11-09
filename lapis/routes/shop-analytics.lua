-- luacheck: max line length 140
--[[
    Shop Analytics API — RBAC module "shop_analytics" (read)
    =========================================================
      GET /api/v2/shop/admin/analytics          ?from=YYYY-MM-DD&to=YYYY-MM-DD | ?days=30
                                                &bucket=day|week|month &compare=false
      GET /api/v2/shop/admin/analytics/survey   ?from=&to= | ?days=30 &survey=what-do-i-need
                                                survey funnel, drop-off by question, answers, apply by plan
      GET /api/v2/shop/admin/analytics/export   ?report=daily|products|chat_tools|survey (+ the same window params)
                                                → text/csv

    Server-derived metrics only (queries/ShopAnalyticsQueries.lua). A separate
    module from "shop" so revenue reporting can be given to people who should
    not edit the catalogue, and withheld from people who run fulfilment.
]]

local U = require("lib.shop-util")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local Analytics = require("queries.ShopAnalyticsQueries")
local Survey = require("queries.ShopSurveyQueries")
local ReportCsv = require("helper.report-csv")

local BASE = "/api/v2/shop/admin/analytics"
local MODULE = "shop_analytics"

local function guard(handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission(MODULE, "read", U.safe(function(self)
        return handler(self, self.namespace.id)
    end)))
end

local function window_params(p)
    return { from = p.from, to = p.to, days = p.days, bucket = p.bucket, compare = p.compare, survey = p.survey }
end

return function(app)
    app:get(BASE, guard(function(self, ns_id)
        local report, err = Analytics.report(ns_id, window_params(self.params))
        if not report then return U.fail(400, "VALIDATION_ERROR", err) end
        local res = U.ok(report)
        -- Figures for one tenant, behind auth: never cache in a shared proxy.
        res.headers = { ["Cache-Control"] = "private, no-store" }
        return res
    end))

    app:get(BASE .. "/survey", guard(function(self, ns_id)
        local report, err = Survey.report(ns_id, window_params(self.params))
        if not report then return U.fail(400, "VALIDATION_ERROR", err) end
        local res = U.ok(report)
        res.headers = { ["Cache-Control"] = "private, no-store" }
        return res
    end))

    app:get(BASE .. "/export", guard(function(self, ns_id)
        local report, status, msg = Analytics.export(ns_id, self.params.report, window_params(self.params))
        if not report then return U.fail(status, status == 404 and "NOT_FOUND" or "VALIDATION_ERROR", msg) end
        return {
            status = 200,
            content_type = "text/csv; charset=utf-8",
            headers = {
                ["Content-Disposition"] = ('attachment; filename="%s.csv"'):format(report.key),
                ["Cache-Control"] = "private, no-store",
            },
            layout = false,
            ReportCsv.render(report),
        }
    end))
end
