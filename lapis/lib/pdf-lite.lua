-- luacheck: max line length 140
--[[
    A small PDF writer (pure Lua, no binaries)
    ==========================================
    The API image has no wkhtmltopdf or Chrome, so documents made in the background (the AI lead
    report) are drawn here: A4 pages, Helvetica / Helvetica-Bold (built into every PDF reader, so no
    font files), wrapped text, headings, bullet lists, label/value rows, rules, a coloured badge and
    "Page n of N" footers. Text is UTF-8 in, Windows-1252 out (what the built-in fonts can show);
    anything else becomes "?".

        local Pdf = require("lib.pdf-lite")
        local doc = Pdf.new({ title = "Lead report" })
        doc:heading("Lead report")
        doc:text("Hello £5 – “quoted”", { size = 11 })
        local bytes = doc:render()     -- "%PDF-1.4 ... %%EOF"

    Specced by spec/pdf-lite_spec.lua.
]]

local Pdf = {}
Pdf.__index = Pdf

local PAGE_W, PAGE_H = 595, 842 -- A4 in points

-- Glyph widths (per 1000 em) for ASCII 32..126, from the standard Helvetica AFM files.
local W_REG = { 278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556,
    556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556,
    833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556,
    556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260,
    334, 584 }
local W_BOLD = { 278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556,
    556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611,
    833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611,
    556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280,
    389, 584 }

-- Unicode code points outside Latin-1 that Windows-1252 has.
local CP1252 = {
    [0x20AC] = 0x80, [0x201A] = 0x82, [0x0192] = 0x83, [0x201E] = 0x84, [0x2026] = 0x85, [0x2020] = 0x86, [0x2021] = 0x87,
    [0x02C6] = 0x88, [0x2030] = 0x89, [0x0160] = 0x8A, [0x2039] = 0x8B, [0x0152] = 0x8C, [0x017D] = 0x8E, [0x2018] = 0x91,
    [0x2019] = 0x92, [0x201C] = 0x93, [0x201D] = 0x94, [0x2022] = 0x95, [0x2013] = 0x96, [0x2014] = 0x97, [0x02DC] = 0x98,
    [0x2122] = 0x99, [0x0161] = 0x9A, [0x203A] = 0x9B, [0x0153] = 0x9C, [0x017E] = 0x9E, [0x0178] = 0x9F,
}

--- UTF-8 → Windows-1252 bytes. Control characters become spaces, anything unmappable "?".
function Pdf.encode(s)
    s = tostring(s or "")
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        local cp, len
        if c < 0x80 then cp, len = c, 1
        elseif c >= 0xC2 and c < 0xE0 and i + 1 <= n then cp, len = (c - 0xC0) * 64 + (s:byte(i + 1) - 0x80), 2
        elseif c >= 0xE0 and c < 0xF0 and i + 2 <= n then
            cp, len = (c - 0xE0) * 4096 + (s:byte(i + 1) - 0x80) * 64 + (s:byte(i + 2) - 0x80), 3
        elseif c >= 0xF0 and c < 0xF5 and i + 3 <= n then cp, len = -1, 4
        else cp, len = -1, 1 end
        if cp == 9 or cp == 10 or cp == 13 then out[#out + 1] = " "
        elseif cp >= 32 and cp < 127 then out[#out + 1] = string.char(cp)
        elseif cp >= 0xA0 and cp <= 0xFF then out[#out + 1] = string.char(cp)
        elseif cp > 0 and CP1252[cp] then out[#out + 1] = string.char(CP1252[cp])
        elseif cp >= 0 and cp < 32 or cp == 127 then out[#out + 1] = " "
        else out[#out + 1] = "?" end
        i = i + len
    end
    return table.concat(out)
end

--- Width in points of encoded (1252) text.
function Pdf.width(s, size, bold)
    local w, t = 0, bold and W_BOLD or W_REG
    for i = 1, #s do
        local b = s:byte(i)
        w = w + ((b >= 32 and b <= 126) and t[b - 31] or 556)
    end
    return w * size / 1000
end

--- Encoded text cut into lines no wider than `max` points (long words are split).
function Pdf.wrap(s, size, bold, max)
    local lines, line = {}, ""
    for word in s:gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if Pdf.width(try, size, bold) <= max then
            line = try
        else
            if line ~= "" then lines[#lines + 1] = line end
            while Pdf.width(word, size, bold) > max do -- a word longer than the line
                local cut = #word
                while cut > 1 and Pdf.width(word:sub(1, cut), size, bold) > max do cut = cut - 1 end
                lines[#lines + 1] = word:sub(1, cut)
                word = word:sub(cut + 1)
            end
            line = word
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

local function esc(s)
    return (s:gsub("[\\()]", "\\%0"))
end

local function num(n)
    return (string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", ""))
end

local function rgb(c)
    c = c or { 0, 0, 0 }
    return num(c[1]) .. " " .. num(c[2]) .. " " .. num(c[3])
end

--- opts: { title?, margin? (points, default 50), footer? (text before "Page n of N") }
function Pdf.new(opts)
    opts = opts or {}
    local self = setmetatable({ pages = {}, margin = opts.margin or 50, title = opts.title, footer = opts.footer }, Pdf)
    self:page()
    return self
end

function Pdf:page()
    self.ops = {}
    self.pages[#self.pages + 1] = self.ops
    self.y = PAGE_H - self.margin
end

function Pdf:need(h)
    if self.y - h < self.margin + 20 then self:page() end
end

function Pdf:space(h)
    self.y = self.y - (h or 8)
end

--- One run of text at x, y (encoded already).
function Pdf:draw(s, x, y, size, bold, color)
    self.ops[#self.ops + 1] = ("BT /%s %s Tf %s rg %s %s Td (%s) Tj ET"):format(bold and "F2" or "F1", num(size), rgb(color),
        num(x), num(y), esc(s))
end

--- Wrapped text. opts: { size = 10, bold, color = {r,g,b} (0..1), indent = 0, gap = line spacing factor }
function Pdf:text(s, opts)
    opts = opts or {}
    local size, indent = opts.size or 10, opts.indent or 0
    local lead = size * (opts.gap or 1.35)
    local max = PAGE_W - 2 * self.margin - indent
    for para in (tostring(s or "") .. "\n"):gmatch("(.-)\n") do
        local lines = Pdf.wrap(Pdf.encode(para), size, opts.bold, max)
        if #lines == 0 then self:space(lead * 0.6) end
        for _, line in ipairs(lines) do
            self:need(lead)
            self.y = self.y - lead
            self:draw(line, self.margin + indent, self.y + size * 0.25, size, opts.bold, opts.color)
        end
    end
end

function Pdf:heading(s, size)
    size = size or 14
    self:need(size * 3)
    self:space(size * 0.6)
    self:text(s, { size = size, bold = true, color = { 0.09, 0.2, 0.3 } })
    self:space(2)
end

--- "• item" lines.
function Pdf:bullets(items, opts)
    opts = opts or {}
    for _, it in ipairs(items or {}) do
        local size = opts.size or 10
        self:need(size * 1.4)
        self:draw(Pdf.encode("\226\128\162"), self.margin + 4, self.y - size * 1.35 + size * 0.25, size, false, opts.color)
        self:text(it, { size = size, indent = 16, color = opts.color })
    end
end

--- "Label: value" with the label in bold on its own column.
function Pdf:row(label, value, opts)
    opts = opts or {}
    if value == nil or value == "" then return end
    local size, col = opts.size or 10, opts.label_width or 120
    local lead = size * 1.35
    local lines = Pdf.wrap(Pdf.encode(value), size, false, PAGE_W - 2 * self.margin - col)
    self:need(lead)
    local l = Pdf.encode(label)
    for i, line in ipairs(#lines > 0 and lines or { "" }) do
        self:need(lead)
        self.y = self.y - lead
        if i == 1 then self:draw(l, self.margin, self.y + size * 0.25, size, true, { 0.3, 0.33, 0.38 }) end
        self:draw(line, self.margin + col, self.y + size * 0.25, size, false)
    end
end

function Pdf:rule(color)
    self:need(10)
    self:space(5)
    self.ops[#self.ops + 1] = ("%s RG 0.6 w %s %s m %s %s l S"):format(rgb(color or { 0.85, 0.87, 0.9 }), num(self.margin),
        num(self.y), num(PAGE_W - self.margin), num(self.y))
    self:space(5)
end

--- A filled box with big text, e.g. a score: badge("7/10", "Good fit", { 0.1, 0.6, 0.3 }).
function Pdf:badge(big, small, color)
    local h = 46
    self:need(h + 10)
    local y = self.y - h
    self.ops[#self.ops + 1] = ("%s rg %s %s 120 %s re f"):format(rgb(color), num(self.margin), num(y), num(h))
    self:draw(Pdf.encode(big), self.margin + 12, y + 20, 22, true, { 1, 1, 1 })
    if small and small ~= "" then self:draw(Pdf.encode(small), self.margin + 12, y + 7, 9, false, { 1, 1, 1 }) end
    self.y = y - 6
end

--- The finished file (a string).
function Pdf:render()
    local objs = {}
    local function add(body)
        objs[#objs + 1] = body
        return #objs
    end
    local catalog = add(false)
    local pages = add(false)
    local f1 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    local f2 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    local kids, total = {}, #self.pages
    for i, ops in ipairs(self.pages) do
        local footer = Pdf.encode((self.footer and (self.footer .. "   ") or "") .. "Page " .. i .. " of " .. total)
        local all = {}
        for k, op in ipairs(ops) do all[k] = op end
        all[#all + 1] = ("BT /F1 8 Tf 0.45 0.48 0.52 rg %s %s Td (%s) Tj ET"):format(num(self.margin), num(self.margin - 20), esc(footer))
        local stream = table.concat(all, "\n")
        local content = add("<< /Length " .. #stream .. " >>\nstream\n" .. stream .. "\nendstream")
        kids[#kids + 1] = add(("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] "
            .. "/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> /Contents %d 0 R >>")
            :format(pages, PAGE_W, PAGE_H, f1, f2, content))
    end
    local refs = {}
    for i, k in ipairs(kids) do refs[i] = k .. " 0 R" end
    objs[catalog] = ("<< /Type /Catalog /Pages %d 0 R >>"):format(pages)
    objs[pages] = ("<< /Type /Pages /Kids [%s] /Count %d >>"):format(table.concat(refs, " "), #kids)
    local info = add("<< /Producer (OpsAPI) /Title (" .. esc(Pdf.encode(self.title or "Document")) .. ") >>")

    local parts, offsets = { "%PDF-1.4\n%\226\227\207\211\n" }, {}
    local pos = #parts[1]
    for i, body in ipairs(objs) do
        offsets[i] = pos
        local chunk = i .. " 0 obj\n" .. body .. "\nendobj\n"
        parts[#parts + 1] = chunk
        pos = pos + #chunk
    end
    local xref = { "xref\n0 " .. (#objs + 1) .. "\n0000000000 65535 f \n" }
    for i = 1, #objs do xref[#xref + 1] = ("%010d 00000 n \n"):format(offsets[i]) end
    parts[#parts + 1] = table.concat(xref)
    parts[#parts + 1] = ("trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n")
        :format(#objs + 1, catalog, info, pos)
    return table.concat(parts)
end

return Pdf
