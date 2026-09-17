--[[
    CSV writer for report envelopes ({ columns = {{key,label,type}}, rows = {...} }).

    RFC 4180: double embedded quotes, wrap any cell containing a delimiter, quote
    or newline, and end lines with CRLF (Excel on Windows is where most of these
    land). Numeric columns whose value really is a number are written bare so
    Excel and Power BI type them as numbers rather than text.
]]

local ReportCsv = {}

local NUMERIC = { number = true, money = true, hours = true }

function ReportCsv.cell(value, col_type)
    if value == nil then return "" end
    if type(value) == "boolean" then return value and "Yes" or "No" end
    local s = tostring(value)
    if NUMERIC[col_type] and tonumber(s) then return s end
    -- A leading =, +, - or @ makes Excel evaluate the cell as a formula. Report
    -- text comes from free-text fields (site names, engineer notes), so prefix it
    -- with a quote rather than let a note execute when a customer opens the file.
    if s:find("^[=+%-@]") then s = "'" .. s end
    if s:find('[",\n\r]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

function ReportCsv.render(report)
    local out, header = {}, {}
    for _, c in ipairs(report.columns) do
        table.insert(header, ReportCsv.cell(c.label))
    end
    table.insert(out, table.concat(header, ","))

    for _, row in ipairs(report.rows) do
        local cells = {}
        for _, c in ipairs(report.columns) do
            table.insert(cells, ReportCsv.cell(row[c.key], c.type))
        end
        table.insert(out, table.concat(cells, ","))
    end
    return table.concat(out, "\r\n") .. "\r\n"
end

return ReportCsv
