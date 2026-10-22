--[[
    Minimal XLSX (Office Open XML spreadsheet) writer — pure Lua, no dependencies.

    Enough for report exports: several sheets of text / number cells, a bold and a
    shaded header style, a "#,##0.00" money format and column widths. Text is written
    as inline strings, which spreadsheet apps never evaluate, so a value such as
    "=HYPERLINK(...)" coming from user data stays literal text (no formula injection).

    The ZIP container uses the STORE method (no compression) — still a valid XLSX.
    ponytail: no shared strings and no compression; fine for report-sized workbooks
    (thousands of rows). Add DEFLATE (zlib via ffi) if files ever get large.

        local bytes = require("lib.xlsx").build({
            { name = "Summary", widths = { 44, 18 }, rows = {
                { { "Tax return figures 2025-26", style = "title" } },
                { "Total income", { 29873.16, style = "money" } },
            } },
        })

    A cell is a string, a number, nil (empty), or { value, style = <style> } where
    style is one of: bold, header, money, money_bold, title.
]]

local bit = require("bit")
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local Xlsx = {}

Xlsx.CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

-- cellXfs indexes in STYLES below.
local STYLE = { bold = 1, header = 2, money = 3, money_bold = 4, title = 5 }

local XML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'

local STYLES = XML .. [[<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">]]
    .. [[<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>]]
    .. [[<fonts count="3"><font><sz val="11"/><name val="Calibri"/></font>]]
    .. [[<font><b/><sz val="11"/><name val="Calibri"/></font>]]
    .. [[<font><b/><sz val="14"/><name val="Calibri"/></font></fonts>]]
    .. [[<fills count="3"><fill><patternFill patternType="none"/></fill>]]
    .. [[<fill><patternFill patternType="gray125"/></fill>]]
    .. [[<fill><patternFill patternType="solid"><fgColor rgb="FFE8EEF4"/><bgColor indexed="64"/></patternFill></fill></fills>]]
    .. [[<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>]]
    .. [[<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>]]
    .. [[<cellXfs count="6">]]
    .. [[<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>]]
    .. [[<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>]]
    .. [[<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>]]
    .. [[<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>]]
    .. [[<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>]]
    .. [[<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>]]
    .. [[</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>]]
    .. [[</styleSheet>]]

-- ---------------------------------------------------------------------------
-- ZIP (STORE) container
-- ---------------------------------------------------------------------------

local CRC = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if band(c, 1) == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
    end
    CRC[i] = c
end

local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bxor(rshift(c, 8), CRC[band(bxor(c, s:byte(i)), 0xFF)])
    end
    return bxor(c, 0xFFFFFFFF)
end
Xlsx._crc32 = crc32

local function u16(n) return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF)) end
local function u32(n)
    return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF), band(rshift(n, 16), 0xFF), band(rshift(n, 24), 0xFF))
end

local function zip(files)
    local t = os.date("!*t")
    local dos_time = bor(lshift(t.hour, 11), lshift(t.min, 5), math.floor(t.sec / 2))
    local dos_date = bor(lshift(t.year - 1980, 9), lshift(t.month, 5), t.day)
    local out, central, offset = {}, {}, 0
    for _, f in ipairs(files) do
        local crc, size = crc32(f.data), #f.data
        local header = "PK\3\4" .. u16(20) .. u16(0) .. u16(0) .. u16(dos_time) .. u16(dos_date)
            .. u32(crc) .. u32(size) .. u32(size) .. u16(#f.name) .. u16(0) .. f.name
        out[#out + 1] = header
        out[#out + 1] = f.data
        central[#central + 1] = "PK\1\2" .. u16(20) .. u16(20) .. u16(0) .. u16(0) .. u16(dos_time)
            .. u16(dos_date) .. u32(crc) .. u32(size) .. u32(size) .. u16(#f.name) .. u16(0) .. u16(0)
            .. u16(0) .. u16(0) .. u32(0) .. u32(offset) .. f.name
        offset = offset + #header + size
    end
    local cd = table.concat(central)
    return table.concat(out) .. cd .. "PK\5\6" .. u16(0) .. u16(0) .. u16(#files) .. u16(#files)
        .. u32(#cd) .. u32(offset) .. u16(0)
end

-- ---------------------------------------------------------------------------
-- SpreadsheetML
-- ---------------------------------------------------------------------------

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

local function esc(s)
    -- Drop control characters XML 1.0 forbids (bank descriptions can carry them).
    s = tostring(s):gsub("[%z\1-\8\11\12\14-\31]", "")
    return (s:gsub('[&<>"]', ESC))
end

local function col(n)
    local s = ""
    while n > 0 do
        local r = (n - 1) % 26
        s = string.char(65 + r) .. s
        n = math.floor((n - 1) / 26)
    end
    return s
end

local function sheet_xml(sheet)
    local b = { XML, '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' }
    if sheet.widths and #sheet.widths > 0 then
        b[#b + 1] = "<cols>"
        for i, w in ipairs(sheet.widths) do
            b[#b + 1] = ('<col min="%d" max="%d" width="%s" customWidth="1"/>'):format(i, i, tostring(w))
        end
        b[#b + 1] = "</cols>"
    end
    b[#b + 1] = "<sheetData>"
    for r, row in ipairs(sheet.rows or {}) do
        b[#b + 1] = ('<row r="%d">'):format(r)
        for c = 1, table.maxn(row) do -- maxn: a row may leave cells empty (nil)
            local cell, v, style = row[c], row[c], nil
            if type(cell) == "table" then v, style = cell[1], STYLE[cell.style] end
            local ref = col(c) .. r
            local s = style and (' s="%d"'):format(style) or ""
            if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
                b[#b + 1] = ('<c r="%s"%s><v>%s</v></c>'):format(ref, s, ("%.15g"):format(v))
            elseif v ~= nil and v ~= "" then
                b[#b + 1] = ('<c r="%s"%s t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>')
                    :format(ref, s, esc(v))
            elseif style then
                b[#b + 1] = ('<c r="%s"%s/>'):format(ref, s)
            end
        end
        b[#b + 1] = "</row>"
    end
    b[#b + 1] = "</sheetData></worksheet>"
    return table.concat(b)
end

-- Sheet names: max 31 chars, none of []:*?/\ and unique (case-insensitive).
local function sheet_names(sheets)
    local names, used = {}, {}
    for i, s in ipairs(sheets) do
        local n = tostring(s.name or ""):gsub("[%[%]%*%?:/\\]", ""):sub(1, 31)
        if n == "" then n = "Sheet" .. i end
        local base, k = n, 2
        while used[n:lower()] do
            n = base:sub(1, 28) .. " " .. k
            k = k + 1
        end
        used[n:lower()] = true
        names[i] = n
    end
    return names
end

--- Build an .xlsx file. @param sheets { { name, widths?, rows } , ... }  @return string (bytes)
function Xlsx.build(sheets)
    local names = sheet_names(sheets)
    local wb, rels, ct = {}, {}, {}
    for i = 1, #sheets do
        wb[#wb + 1] = ('<sheet name="%s" sheetId="%d" r:id="rId%d"/>'):format(esc(names[i]), i, i)
        rels[#rels + 1] = ('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/'
            .. '2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>'):format(i, i)
        ct[#ct + 1] = ('<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/'
            .. 'vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'):format(i)
    end
    rels[#rels + 1] = ('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/'
        .. '2006/relationships/styles" Target="styles.xml"/>'):format(#sheets + 1)

    local files = {
        { name = "[Content_Types].xml", data = XML
            .. '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            .. '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            .. '<Default Extension="xml" ContentType="application/xml"/>'
            .. '<Override PartName="/xl/workbook.xml" ContentType="application/'
            .. 'vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            .. '<Override PartName="/xl/styles.xml" ContentType="application/'
            .. 'vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
            .. table.concat(ct) .. '</Types>' },
        { name = "_rels/.rels", data = XML
            .. '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            .. '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
            .. 'relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>' },
        { name = "xl/workbook.xml", data = XML
            .. '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            .. 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
            .. table.concat(wb) .. '</sheets></workbook>' },
        { name = "xl/_rels/workbook.xml.rels", data = XML
            .. '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            .. table.concat(rels) .. '</Relationships>' },
        { name = "xl/styles.xml", data = STYLES },
    }
    for i, s in ipairs(sheets) do
        files[#files + 1] = { name = ("xl/worksheets/sheet%d.xml"):format(i), data = sheet_xml(s) }
    end
    return zip(files)
end

return Xlsx
