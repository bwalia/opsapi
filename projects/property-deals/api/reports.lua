-- Reports and data export (SPEC §3.8 #10, §4):
--   GET /reports/stage-times      ?from=YYYY-MM-DD&to=YYYY-MM-DD   time per stage (completed + current)
--   GET /reports/late-days        completed deals vs target, penalty cost, the worst ten
--   GET /reports/conversion       leads → deals → exchanged → completed, by month and by lead source
--   GET /reports/supplier-speed   per supplier: bookings, hours to confirm / to done, on-time %
--   GET /reports/party-speed      solicitors, lenders, councils…: hours to reply to chases, days to clear enquiries
--   GET /reports/ai-usage         spend and runs per day and agent, approval outcomes per agent
--   GET /export/:entity           ?format=csv|json&from=&to=   a workspace's data (managers; at most 50,000 rows)
-- Default window: the last 90 days. Times are UTC.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")
local R = require("property_deals.reports")

local EXPORTS = {
    deals = "property_deals_deals", tasks = "property_deals_task_details", properties = "property_deals_properties",
    buyer_profiles = "property_deals_buyer_profiles", suppliers = "property_deals_suppliers",
    bookings = "property_deals_bookings", enquiries = "property_deals_enquiries", chases = "property_deals_chases",
    compliance_checks = "property_deals_compliance_checks", documents = "property_deals_documents",
    approvals = "property_deals_approvals", agent_runs = "property_deals_agent_runs", matches = "property_deals_matches",
    market_records = "property_deals_market_records", stage_history = "property_deals_stage_history",
}
local MAX_ROWS = 50000

local function csv_cell(v)
    if v == nil or v == db.NULL or v == cjson.null then return "" end
    if type(v) == "table" then v = cjson.encode(v) end
    v = tostring(v)
    -- No formula injection when the file is opened in a spreadsheet.
    if v:match("^[=+%-@]") then v = "'" .. v end
    if v:find('[,"\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

return function(app)
    local function report(path, fn)
        app:get("/reports/" .. path, sdk.handler({ permission = "property_deals_reports.read" }, U.guard(function(self)
            local from, to = R.window(self.params)
            local data = fn(sdk.namespace_id(self), from, to)
            return sdk.ok(data, { from = from, to = to })
        end)))
    end
    report("stage-times", R.stage_times)
    report("late-days", R.late_days)
    report("conversion", R.conversion)
    report("supplier-speed", R.supplier_speed)
    report("party-speed", R.party_speed)
    report("ai-usage", R.ai_usage)

    app:get("/export/:entity", sdk.handler({ permission = "property_deals_reports.manage" }, U.guard(function(self)
        local tbl = EXPORTS[self.params.entity or ""]
        if not tbl then
            local names = {}
            for k in pairs(EXPORTS) do names[#names + 1] = k end
            table.sort(names)
            return sdk.error(404, "Unknown export; one of " .. table.concat(names, ", "))
        end
        local format = self.params.format == "json" and "json" or "csv"
        local ns = sdk.namespace_id(self)
        local where, args = { "namespace_id = ?" }, { ns }
        local from, to = self.params.from, self.params.to
        local date_col = tbl == "property_deals_stage_history" and "entered_at" or "created_at"
        if type(from) == "string" and from:match("^%d%d%d%d%-%d%d%-%d%d$") then where[#where + 1] = date_col .. " >= ?::date"; args[#args + 1] = from end
        if type(to) == "string" and to:match("^%d%d%d%d%-%d%d%-%d%d$") then where[#where + 1] = date_col .. " < ?::date"; args[#args + 1] = to end
        -- Never export sealed secrets or raw prompts' hidden fields; the tables here hold none, but be explicit.
        local rows = db.query("SELECT * FROM " .. tbl .. " WHERE " .. table.concat(where, " AND ") .. " ORDER BY id LIMIT "
            .. (MAX_ROWS + 1), unpack(args))
        local truncated = #rows > MAX_ROWS
        if truncated then table.remove(rows) end
        for _, r in ipairs(rows) do r.id, r.namespace_id, r.secret_sealed = nil, nil, nil end
        local stamp = os.date("!%Y%m%d")
        ngx.header["Content-Disposition"] = 'attachment; filename="property-deals-' .. self.params.entity .. "-" .. stamp .. "." .. format .. '"'
        if truncated then ngx.header["X-Truncated"] = tostring(MAX_ROWS) end
        if format == "json" then
            return { status = 200, layout = false, content_type = "application/json", cjson.encode(U.array(rows)) }
        end
        local cols = {}
        local seen = {}
        for _, r in ipairs(rows) do
            for k in pairs(r) do if not seen[k] then seen[k] = true; cols[#cols + 1] = k end end
        end
        table.sort(cols, function(a, b)
            if a == "uuid" then return true elseif b == "uuid" then return false end
            return a < b
        end)
        local out = { table.concat(cols, ",") }
        for _, r in ipairs(rows) do
            local line = {}
            for i, c in ipairs(cols) do line[i] = csv_cell(r[c]) end
            out[#out + 1] = table.concat(line, ",")
        end
        return { status = 200, layout = false, content_type = "text/csv; charset=utf-8", table.concat(out, "\r\n") .. "\r\n" }
    end)))
end
