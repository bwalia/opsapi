--[[
    Field Service — Simpro report pack routes

    Endpoints:
    - GET /api/v2/field-service/reports              - List the available reports
    - GET /api/v2/field-service/reports/:key         - Run one (?format=json|csv)

    Every report accepts the filters it declares in the catalogue; unknown query
    params are ignored, so a caller can pass the same filter bag to any report.

    format=csv streams the same rows the JSON returns, so what a customer opens
    in Excel and what they saw on screen cannot drift. DBS's Simpro pack notes
    that "all of the reports shown below can be exported in CSV/XL and connected
    to a Power Bi Dashboard", and that holds here for every report rather than a
    hand-picked few, because the CSV writer works off the report's own `columns`.

    PDF is deliberately not generated here. The dashboard and the iOS app both
    render the report from these rows using their own typographic layout (see
    lib/report-pdf.ts), which keeps one branded template per surface instead of
    a server-side renderer that neither can restyle.
]]

local Http = require("helper.field-service-http")
local Reports = require("queries.SimproReportQueries")
local ReportCsv = require("helper.report-csv")

-- The pack is portfolio-wide (every customer, every engineer's hours), so it is
-- gated on its own module rather than on fs_jobs read: engineers can read the
-- jobs they work but must not get the whole business's numbers. Managers and the
-- service desk are granted fs_reports read by migrations/simpro-menu.lua.
local READERS = { { "fs_reports", "read" } }

--- Everything a report might filter on, passed through verbatim. Reports read
--- only the keys they declare, so one bag serves the whole pack.
local function filters_from(self)
    local p = self.params
    return {
        date_from = p.date_from, date_to = p.date_to,
        customer_uuid = p.customer_uuid, site_uuid = p.site_uuid,
        asset_uuid = p.asset_uuid, asset_type_uuid = p.asset_type_uuid,
        contract_uuid = p.contract_uuid,
        months = p.months, weeks = p.weeks,
        expiring_within_days = p.expiring_within_days,
        limit = p.limit,
    }
end

return function(app)
    app:get("/api/v2/field-service/reports", Http.guard_any(READERS, function(self)
        return Http.ok(Reports.list())
    end))

    app:get("/api/v2/field-service/reports/:key", Http.guard_any(READERS, function(self)
        local report, err = Reports.run(self.namespace.id, self.params.key, filters_from(self))
        if not report then
            -- An unknown key is a 404; a bad filter (missing asset_uuid) is a 422.
            if tostring(err or ""):match("^Unknown report") then
                return Http.fail(404, err)
            end
            return Http.from_error(err)
        end

        if self.params.format == "csv" then
            local filename = ("%s-%s.csv"):format(report.key, os.date("!%Y%m%d"))
            return {
                status = 200,
                content_type = "text/csv; charset=utf-8",
                headers = {
                    ["Content-Disposition"] = ('attachment; filename="%s"'):format(filename),
                    -- A report is a point-in-time answer; never let a proxy serve
                    -- yesterday's numbers as today's.
                    ["Cache-Control"] = "no-store",
                },
                layout = false,
                ReportCsv.render(report),
            }
        end

        return Http.ok(report)
    end))
end
