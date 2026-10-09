-- Weekly, per workspace: add new bank holidays from GOV.UK for the workspace's
-- jurisdiction (england-and-wales, scotland, northern-ireland). Only adds
-- dates; a workspace's own edits stay.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson.safe")
local sdk = require("helper.plugin-sdk")

local URL = "https://www.gov.uk/bank-holidays.json"

return {
    every = "7d",
    run = function(job)
        local jurisdiction = job.settings.jurisdiction or "england-and-wales"
        local res, err = sdk.http(URL, { method = "GET", timeout_ms = 10000 })
        if not res or res.status ~= 200 then
            return false, "GOV.UK bank holidays: " .. tostring(err or (res and res.status))
        end
        local data = cjson.decode(res.body or "")
        local events = data and data[jurisdiction] and data[jurisdiction].events
        if type(events) ~= "table" then return false, "no '" .. jurisdiction .. "' in the GOV.UK feed" end
        local added = 0
        for _, e in ipairs(events) do
            if type(e.date) == "string" and e.date:match("^%d%d%d%d%-%d%d%-%d%d$") and type(e.title) == "string" then
                local r = sdk.db.query([[
                    INSERT INTO property_deals_holidays (namespace_id, jurisdiction, holiday_date, name)
                    VALUES (?, ?, ?, ?) ON CONFLICT (namespace_id, jurisdiction, holiday_date) DO NOTHING
                ]], job.namespace_id, jurisdiction, e.date, e.title:sub(1, 120))
                added = added + (r.affected_rows or 0)
            end
        end
        if added > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] added ", added, " bank holiday(s) for ns=", job.namespace_id)
        end
    end,
}
