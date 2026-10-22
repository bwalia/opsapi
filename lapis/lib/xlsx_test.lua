--[[
    Self-check for lib/xlsx: builds a workbook, then reads the ZIP back and checks
    every entry's CRC, the required OOXML parts, and that formula-looking text is
    written as an inert inline string. Run from lapis/:  luajit lib/xlsx_test.lua
]]

package.path = "./?.lua;" .. package.path
local Xlsx = require("lib.xlsx")
local bit = require("bit")

local passed, failed = 0, 0
local function check(label, ok)
    if ok then passed = passed + 1 else failed = failed + 1; io.write("FAIL  " .. label .. "\n") end
end

local function rd16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function rd32(s, i) return rd16(s, i) + rd16(s, i + 2) * 65536 end

local bytes = Xlsx.build({
    { name = "Summary", widths = { 40, 16 }, rows = {
        { { "Tax return figures 2025-26", style = "title" } },
        { "Total income", { 29873.16, style = "money" } },
        { "=HYPERLINK(\"http://evil\")", 1 },
        { "Tom & Jerry <ltd>", nil, 3 },          -- nil gap → empty B4
    } },
    { name = "Boxes/With:Bad*Chars", rows = { { { "Box", style = "header" } } } },
    { name = "Boxes/With:Bad*Chars", rows = {} }, -- duplicate name gets de-duplicated
})

check("starts with a ZIP local header", bytes:sub(1, 4) == "PK\3\4")

-- Walk the local file headers.
local entries, i = {}, 1
while bytes:sub(i, i + 3) == "PK\3\4" do
    local crc, size, nlen, xlen = rd32(bytes, i + 14), rd32(bytes, i + 18), rd16(bytes, i + 26), rd16(bytes, i + 28)
    local name = bytes:sub(i + 30, i + 29 + nlen)
    local data = bytes:sub(i + 30 + nlen + xlen, i + 29 + nlen + xlen + size)
    local want = Xlsx._crc32(data)
    if want < 0 then want = want + 4294967296 end
    check("crc matches for " .. name, crc == want)
    entries[name] = data
    i = i + 30 + nlen + xlen + size
end

local count = 0
for _ in pairs(entries) do count = count + 1 end
local eocd = bytes:find("PK\5\6", 1, true)
check("end-of-central-directory present", eocd ~= nil)
check("EOCD entry count matches", eocd and rd16(bytes, eocd + 10) == count)

for _, part in ipairs({ "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
    "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml",
    "xl/worksheets/sheet2.xml", "xl/worksheets/sheet3.xml" }) do
    check("has part " .. part, entries[part] ~= nil)
end

local s1 = entries["xl/worksheets/sheet1.xml"] or ""
check("money cell is numeric with money style", s1:find('<c r="B2" s="3"><v>29873.16</v></c>', 1, true) ~= nil)
check("formula text stays an inline string", s1:find('<c r="A3" t="inlineStr"><is><t xml:space="preserve">'
    .. '=HYPERLINK(&quot;http://evil&quot;)</t></is></c>', 1, true) ~= nil)
check("no <f> formula element anywhere", not s1:find("<f>", 1, true))
check("XML special chars escaped", s1:find("Tom &amp; Jerry &lt;ltd&gt;", 1, true) ~= nil)
check("nil gap leaves B4 empty, C4 set", not s1:find('r="B4"', 1, true) and s1:find('r="C4"', 1, true) ~= nil)
check("column widths written", s1:find('<col min="1" max="1" width="40" customWidth="1"/>', 1, true) ~= nil)

local wb = entries["xl/workbook.xml"] or ""
check("illegal sheet-name chars stripped", wb:find('name="BoxesWithBadChars"', 1, true) ~= nil)
check("duplicate sheet name de-duplicated", wb:find('name="BoxesWithBadChars 2"', 1, true) ~= nil)
check("crc32 known vector", bit.band(Xlsx._crc32("123456789"), 0xFFFFFFFF) == bit.tobit(0xCBF43926))

io.write(string.format("\nxlsx: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
